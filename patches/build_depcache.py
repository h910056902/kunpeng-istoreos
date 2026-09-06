# -*- coding: utf-8 -*-
"""
批量计算哪些 app-meta-* 应用在当前架构下依赖可满足。
做法: 拉取路由器上的 opkg 包索引(gzip), 本地做依赖递归解析, 结果缓存回路由器。
校验基准: diskman/cups/gogs/emby=可装, 51ddns=不可装(缺 51ddns-agent)
"""
import paramiko, gzip, io, json, re, sys

HOST = '192.168.66.1'
USER = 'root'
PWD = __import__('os').environ.get('ROUTER_PW', 'admin')  # 路由器密码, 建议用环境变量 ROUTER_PW 传入
LIST_DIR = '/tmp/is-root/tmp/opkg-lists'
CACHE = '/tmp/istore_depcache.json'

# 架构优先级 (来自 /tmp/is-root/etc/opkg/arch.conf)
ARCH_PRIO = {'all': 1, 'noarch': 1, 'aarch64_generic': 5, 'aarch64_cortex-a53': 10}

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, 22, USER, PWD, timeout=15)
sftp = c.open_sftp()

# ---------- 1. 拉取所有包索引 ----------
_, o, _ = c.exec_command('ls %s' % LIST_DIR, timeout=20)
files = [f.strip() for f in o.read().decode().split() if f.strip()]
print('[lists] %d files: %s' % (len(files), ', '.join(files)))

pkgs = {}          # name -> {'arch':.., 'ver':.., 'deps':[..], 'provides':[..]}
providers = {}     # provide name -> [pkgname]

for fn in files:
    try:
        with sftp.open('%s/%s' % (LIST_DIR, fn), 'rb') as f:
            raw = f.read()
        if raw[:2] == b'\x1f\x8b':
            raw = gzip.decompress(raw)
        text = raw.decode('utf-8', 'replace')
    except Exception as ex:
        print('  ! skip %s: %s' % (fn, ex)); continue

    cur = None
    for line in text.split('\n'):
        if not line.strip():
            continue
        if line.startswith(' '):
            continue
        m = re.match(r'^([A-Za-z0-9-]+):\s*(.*)$', line)
        if not m:
            continue
        k, v = m.group(1), m.group(2).strip()
        if k == 'Package':
            cur = {'arch': 'all', 'ver': '0', 'deps': [], 'provides': []}
            pkgs[v] = cur
        elif cur is None:
            continue
        elif k == 'Architecture':
            cur['arch'] = v
        elif k == 'Version':
            cur['ver'] = v
        elif k == 'Depends':
            cur['deps'] = v
        elif k == 'Provides':
            cur['provides'] = [x.strip().split()[0] for x in v.split(',')]

print('[parsed] %d packages' % len(pkgs))

# 建立 provides 索引
for name, p in pkgs.items():
    providers.setdefault(name, []).append(name)
    for pv in p['provides']:
        providers.setdefault(pv, []).append(name)

# ---- 关键: 已安装的包(固件内置的 libc 等不在软件源索引里)也视为依赖已满足 ----
_, o, _ = c.exec_command('opkg list-installed 2>/dev/null', timeout=30)
installed = []
for line in o.read().decode('utf-8', 'replace').split('\n'):
    nm = line.split(' ')[0].strip()
    if nm:
        installed.append(nm)
for nm in installed:
    if nm not in pkgs:
        pkgs[nm] = {'arch': 'all', 'ver': '0', 'deps': '', 'provides': []}
    providers.setdefault(nm, [])
    if nm not in providers[nm]:
        providers[nm].append(nm)
# 已装包的 deps 无需再解析, 标记为满足
INSTALLED = set(installed)
print('[installed] %d packages already on device (视为依赖已满足)' % len(INSTALLED))


def arch_ok(a):
    return a in ARCH_PRIO


def parse_deps(depstr):
    """'libc, 51ddns-agent (>=1), a | b' -> [[alt1, alt2], ...]"""
    out = []
    if not depstr:
        return out
    # 按逗号切分 (忽略括号内的逗号)
    parts, depth, buf = [], 0, ''
    for ch in depstr:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(buf); buf = ''
        else:
            buf += ch
    if buf.strip():
        parts.append(buf)
    for p in parts:
        p = p.strip()
        if not p:
            continue
        alts = []
        for alt in p.split('|'):
            alt = re.sub(r'\(.*?\)', '', alt).strip()
            if alt:
                alts.append(alt)
        if alts:
            out.append(alts)
    return out


def resolve(name, seen=None, depth=0):
    """返回 None 表示可满足, 否则返回缺失的依赖名"""
    if seen is None:
        seen = set()
    if depth > 6:
        return None
    if name in seen:
        return None
    seen = seen | {name}

    # 已安装的包: 依赖视为满足, 不再递归
    if name in INSTALLED:
        return None

    cands = providers.get(name)
    if not cands:
        return name
    # 选一个架构兼容的候选
    pick = None
    for cand in cands:
        if cand in pkgs and arch_ok(pkgs[cand]['arch']):
            pick = cand
            break
    if pick is None:
        return name
    for alts in parse_deps(pkgs[pick]['deps']):
        ok = False
        lastmiss = None
        for a in alts:
            miss = resolve(a, seen, depth + 1)
            if miss is None:
                ok = True
                break
            lastmiss = miss
        if not ok:
            return lastmiss or alts[0]
    return None


# ---------- 2. 逐个 app-meta 判定 ----------
targets = sorted([n for n in pkgs if n.startswith('app-meta-')])
print('[targets] %d app-meta packages' % len(targets))

result = {}
bad = []
for t in targets:
    miss = resolve(t)
    if miss is None:
        result[t] = {'ok': True, 'reason': ''}
    else:
        result[t] = {'ok': False, 'reason': '缺少依赖: %s' % miss}
        bad.append((t, miss))

ok_n = sum(1 for v in result.values() if v['ok'])
print('[result] 可安装 %d / 不可安装 %d' % (ok_n, len(result) - ok_n))

# ---------- 3. 对照已知基准 ----------
print('\n[校验] 与实测对比:')
BASE = {'app-meta-diskman': True, 'app-meta-51ddns': False,
        'app-meta-cups': True, 'app-meta-gogs': True, 'app-meta-emby': True}
allmatch = True
for k, exp in BASE.items():
    got = result.get(k, {}).get('ok')
    flag = 'OK ' if got == exp else 'MISMATCH'
    if got != exp:
        allmatch = False
    print('  %-8s %-22s expect=%-5s got=%-5s %s' % (flag, k, exp, got, result.get(k, {}).get('reason', '')))
print('  => %s' % ('全部匹配, 解析器可信' if allmatch else '存在偏差, 需人工复核'))

print('\n[不可安装样本] 前 15 个:')
for t, m in bad[:15]:
    print('  %-28s 缺 %s' % (t, m))

# ---------- 4. 写回路由器 ----------
payload = json.dumps({'ts': __import__('time').time(), 'arch': 'aarch64_cortex-a53', 'pkgs': result})
with sftp.open(CACHE, 'w') as f:
    f.write(payload)
print('\n[written] %s (%d bytes, %d entries)' % (CACHE, len(payload), len(result)))

sftp.close()
c.close()

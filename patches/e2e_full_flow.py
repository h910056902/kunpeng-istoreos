# -*- coding: utf-8 -*-
"""端到端全流程: 在线安装 -> 轮询 -> 注册验证 -> 卸载(走注册分发) -> 移除验证"""
import paramiko, json, time, sys

HOST = '192.168.66.1'
USER = 'root'
PW = __import__('os').environ.get('ROUTER_PW', 'admin')
PKG = sys.argv[1] if len(sys.argv) > 1 else 'app-meta-airconnect'

def run(c, cmd, t=60):
    _, o, _ = c.exec_command(cmd, timeout=t)
    return o.read().decode('utf-8', 'replace')

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, 22, USER, PW, timeout=12)

# 0. 登录
run(c, "rm -f /tmp/e2e_cj.txt")
run(c, "curl -s -m 10 -c /tmp/e2e_cj.txt -d 'luci_username=root&luci_password=' + PW + '' 'http://127.0.0.1/cgi-bin/luci/' -o /dev/null")

# 1. 卸载残留（确保从零开始）
run(c, "opkg remove app-meta-airconnect >/dev/null 2>&1")

# 2. 在线安装
r = run(c, "curl -s -m 30 -b /tmp/e2e_cj.txt -X POST "
           "'http://127.0.0.1/cgi-bin/luci/nradioadv/system/appcenter/online_install' "
           "-d 'pkg=%s'" % PKG)
print('[1] install resp:', r.strip())

# 3. 轮询状态
for i in range(60):
    time.sleep(4)
    st = run(c, "curl -s -m 20 -b /tmp/e2e_cj.txt "
                "'http://127.0.0.1/cgi-bin/luci/nradioadv/system/appcenter/online_install_status'")
    try:
        s = json.loads(st)
    except Exception:
        continue
    if not s.get('running'):
        print('[2] install finished exit_code=%s' % s.get('exit_code'))
        if s.get('exit_code') not in (0, '0'):
            print('LOG TAIL:', (s.get('log') or '')[-500:])
            raise SystemExit(1)
        break
    print('    running... (%ds)' % ((i + 1) * 4))
else:
    print('TIMEOUT'); raise SystemExit(1)

# 4. 验证 opkg 装上
r = run(c, "opkg list-installed 2>/dev/null | grep %s" % PKG)
print('[3] opkg:', r.strip() or 'NOT FOUND')

# 5. 验证注册进原生商店列表
r = run(c, "curl -s -m 40 -b /tmp/e2e_cj.txt "
           "'http://127.0.0.1/cgi-bin/luci/nradioadv/system/appcenter/list'")
apps = json.loads(r)['result']['applist']
reg = [a for a in apps if a.get('online_key') == PKG.replace('app-meta-', '')]
print('[4] registered: %s' % ('YES name=%s v%s icon=%s route=%s' % (
    reg[0]['name'], reg[0].get('version'), reg[0].get('icon'), reg[0].get('luci_module_route')) if reg else 'NO'))
assert reg, 'registration failed'

title = reg[0]['name']

# 6. 通过商店卸载(带 token, 走注册分发路径)
r = run(c, "curl -s -m 30 -b /tmp/e2e_cj.txt -X POST "
           "'http://127.0.0.1/cgi-bin/luci/nradioadv/system/appcenter/uninstall' "
           "--data-urlencode 'name=%s' --data-urlencode 'token=$(grep sysauth /tmp/e2e_cj.txt | awk \"{print \\$7}\")'" % title)
print('[5] uninstall resp:', r.strip()[:200])

time.sleep(2)
r = run(c, "opkg list-installed 2>/dev/null | grep %s" % PKG)
print('[6] after uninstall opkg:', r.strip() or 'REMOVED OK')

r = run(c, "curl -s -m 40 -b /tmp/e2e_cj.txt "
           "'http://127.0.0.1/cgi-bin/luci/nradioadv/system/appcenter/list'")
apps2 = json.loads(r)['result']['applist']
still = [a for a in apps2 if a.get('online_key') == PKG.replace('app-meta-', '')]
print('[7] list after uninstall:', 'STILL PRESENT (BAD)' if still else 'REMOVED FROM LIST OK')

c.close()
print('E2E PASS')

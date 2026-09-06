# -*- coding: utf-8 -*-
"""端到端测试: 在线应用安装全流程"""
import paramiko, json, time, sys

HOST = '192.168.66.1'
USER = 'root'
PWD = __import__('os').environ.get('ROUTER_PW', 'admin')  # 路由器密码, 建议用环境变量 ROUTER_PW 传入
PKG = sys.argv[1] if len(sys.argv) > 1 else 'app-meta-diskman'

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, 22, USER, PWD, timeout=15)


def sh(cmd, t=60):
    _, o, e = c.exec_command(cmd, timeout=t)
    return o.read().decode('utf-8', 'replace')


# 登录
sh("rm -f /tmp/e2e_cj.txt; curl -s -m 10 -c /tmp/e2e_cj.txt -d 'luci_username=root&luci_password=' + PW + '' 'http://127.0.0.1/cgi-bin/luci/' -o /dev/null")

print('=' * 60)
print('E2E 安装测试: %s' % PKG)
print('=' * 60)

# 0) 前置状态
print('\n[0] 安装前是否已在本地: %s' % (sh("opkg list-installed 2>/dev/null | grep -c '^%s '" % PKG).strip() or '0'))
st = json.loads(sh("curl -s -m 20 -b /tmp/e2e_cj.txt 'http://127.0.0.1/cgi-bin/luci/nradioadv/system/appcenter/online_install_status'"))
print('    任务运行中: %s' % st.get('running'))

# 1) precheck
pc = json.loads(sh("curl -s -m 90 -b /tmp/e2e_cj.txt 'http://127.0.0.1/cgi-bin/luci/nradioadv/system/appcenter/online_precheck?pkg=%s'" % PKG))
print('\n[1] 预检: ok=%s  reason=%s' % (pc.get('ok'), pc.get('reason') or '-'))
if not pc.get('ok'):
    print('    -> 预检不通过, 前端应显示「不兼容」, 终止测试')
    c.close(); sys.exit(0)

# 2) 发起安装
res = sh("curl -s -m 60 -b /tmp/e2e_cj.txt -X POST "
         "'http://127.0.0.1/cgi-bin/luci/nradioadv/system/appcenter/online_install' -d 'pkg=%s'" % PKG)
print('\n[2] 发起安装 -> %s' % res.strip())
r = json.loads(res)
if r.get('code') != 0:
    print('    !! 启动失败: %s' % r.get('msg'))
    c.close(); sys.exit(1)

# 3) 轮询状态
print('\n[3] 轮询任务状态:')
last_tip = ''
for i in range(120):
    time.sleep(5)
    try:
        st = json.loads(sh("curl -s -m 20 -b /tmp/e2e_cj.txt "
                           "'http://127.0.0.1/cgi-bin/luci/nradioadv/system/appcenter/online_install_status'"))
    except Exception:
        continue
    log = st.get('log', '')
    lines = [l.strip() for l in log.split('\n') if l.strip()]
    tip = lines[-1] if lines else ''
    if st.get('running'):
        if tip != last_tip:
            print('    [%3ds] %s' % (i * 5, tip[:100]))
            last_tip = tip
    else:
        print('    [%3ds] 任务结束 exit_code=%s' % (i * 5, st.get('exit_code')))
        break
else:
    print('    !! 轮询超时')

# 4) 验证
print('\n[4] 安装后验证:')
cnt = sh("opkg list-installed 2>/dev/null | grep -c '^%s '" % PKG).strip()
print('    %s 已安装: %s' % (PKG, '是' if cnt.strip() not in ('', '0') else '否'))
print('    实际条目: %s' % (sh("opkg list-installed 2>/dev/null | grep '^%s '" % PKG).strip() or '(无)'))

# 5) 再查在线列表里的 installed 标记
try:
    lst = json.loads(sh("curl -s -m 30 -b /tmp/e2e_cj.txt "
                        "'http://127.0.0.1/cgi-bin/luci/nradioadv/system/appcenter/online_list'"))
    hit = [a for a in lst.get('list', []) if a.get('pkg') == PKG]
    print('    online_list 中 installed = %s' % (hit[0].get('installed') if hit else 'N/A'))
except Exception as ex:
    print('    online_list 查询失败: %s' % ex)

c.close()

# -*- coding: utf-8 -*-
"""部署 UnblockNeteaseMusic 的 LuCI 经典控制器垫片。

背景: NROS 固件的 LuCI dispatcher 不支持 menu.d(view) 类型应用，
luci-app-unblockneteasemusic 的页面会 404。此脚本上传经典 Lua controller + CBI 模型，
让「服务 → 云音乐解锁」页面在原生 LuCI 可用（商店里点「打开」也能进）。

用法: python unm_luci_shim.py   （ROUTER_PW 环境变量，默认 admin）
"""
import paramiko, os, time

HOST, USER = '192.168.66.1', 'root'
PW = os.environ.get('ROUTER_PW', 'admin')
BASE = os.path.dirname(os.path.abspath(__file__))

CTRL_DST = '/usr/lib/lua/luci/controller/unblockneteasemusic.lua'
MODEL_DST = '/usr/lib/lua/luci/model/cbi/unblockneteasemusic.lua'


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, 22, USER, PW, timeout=12)
    sftp = c.open_sftp()

    def put(local, dst):
        sftp.put(os.path.join(BASE, local), dst)
        print('uploaded:', dst)

    put('unm_luci_shim/controller.lua', CTRL_DST)
    put('unm_luci_shim/model.lua', MODEL_DST)
    sftp.close()

    _, o, _ = c.exec_command(
        "lua -e \"assert(loadfile('%s')); assert(loadfile('%s')); print('SYNTAX_OK')\" 2>&1"
        % (CTRL_DST, MODEL_DST), timeout=25)
    print(o.read().decode('utf-8', 'replace').strip())

    _, o, _ = c.exec_command(
        "rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache; sleep 1; "
        "curl -s -m 10 -c /tmp/unm_cj.txt -d 'luci_username=root&luci_password=%s' "
        "http://127.0.0.1/cgi-bin/luci/ -o /dev/null; "
        "curl -s -m 15 -b /tmp/unm_cj.txt -o /dev/null -w '%%{http_code}' "
        "http://127.0.0.1/cgi-bin/luci/admin/services/unblockneteasemusic" % PW, timeout=60)
    print('页面 HTTP:', o.read().decode().strip())
    c.close()


if __name__ == '__main__':
    main()

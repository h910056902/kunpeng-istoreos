# -*- coding: utf-8 -*-
"""修正 _online_inst_map: opkg list-installed 输出为 'pkg - ver' 三段式"""
import paramiko, time

LUA = '/usr/lib/lua/luci/controller/nradio_adv/appcenter.lua'

OLD_MAP = """	for line in out:gmatch("[^\\r\\n]+") do
		local base, ver = line:match("^app%-meta%-([%w%-%+%.]+)%s+(%S+)")
		if base and ver then inst[base] = ver end
	end"""
NEW_MAP = """	for line in out:gmatch("[^\\r\\n]+") do
		local base, rest = line:match("^app%-meta%-([%w%-%+%.]+)%s+(.+)$")
		if base and rest then
			local ver = rest:match("(%S+)$")
			if ver then inst[base] = ver end
		end
	end"""

OLD_VER = 'version = tostring(ver),'
NEW_VER = 'version = (ver ~= "-" and tostring(ver)) or tostring(a.version or "-"),'

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
import os
c.connect('192.168.66.1', 22, 'root', os.environ.get('ROUTER_PW', 'admin'), timeout=12)

sftp = c.open_sftp()
with sftp.open(LUA, 'r') as f:
    src = f.read().decode('utf-8')

if NEW_MAP.split('\n')[2].strip() in src:
    print('SKIP: already fixed')
else:
    ok = True
    if OLD_MAP not in src:
        print('FAIL: map anchor not found'); ok = False
    if OLD_VER not in src:
        print('FAIL: ver anchor not found'); ok = False
    if ok:
        bak = LUA + '.bak-ver-' + time.strftime('%Y%m%d_%H%M%S')
        with sftp.open(bak, 'w') as f:
            f.write(src)
        src = src.replace(OLD_MAP, NEW_MAP, 1).replace(OLD_VER, NEW_VER, 1)
        with sftp.open(LUA, 'w') as f:
            f.write(src)
        print('PATCHED, backup:', bak)
sftp.close()
_, o, _ = c.exec_command("rm -rf /tmp/luci-modulecache /tmp/luci-indexcache; lua -e \"assert(loadfile('%s')); print('SYNTAX_OK')\" 2>&1" % LUA, timeout=25)
print(o.read().decode('utf-8', 'replace').strip())
c.close()

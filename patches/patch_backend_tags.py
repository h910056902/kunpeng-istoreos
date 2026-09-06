# -*- coding: utf-8 -*-
"""后端补丁: online_list 输出增加 tags 与 time 字段(供前端分类/排序)"""
import paramiko

LUA = '/usr/lib/lua/luci/controller/nradio_adv/appcenter.lua'

OLD = """					incompatible = incompat or false,
					reason = reason or ""
				})"""
NEW = """					incompatible = incompat or false,
					reason = reason or "",
					tags = app.tags or {},
					time = tonumber(app.time) or 0
				})"""

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
import os
c.connect('192.168.66.1', 22, 'root', os.environ.get('ROUTER_PW', 'admin'), timeout=12)

sftp = c.open_sftp()
with sftp.open(LUA, 'r') as f:
    content = f.read().decode('utf-8')

if 'tags = app.tags' in content:
    print('SKIP: already patched')
elif OLD not in content:
    print('FAIL: anchor not found')
    raise SystemExit(1)
else:
    bak = LUA + '.bak-oltag-' + __import__('time').strftime('%Y%m%d_%H%M%S')
    with sftp.open(bak, 'w') as f:
        f.write(content)
    content = content.replace(OLD, NEW)
    with sftp.open(LUA, 'w') as f:
        f.write(content)
    print('PATCHED, backup:', bak)

sftp.close()

_, o, _ = c.exec_command(
    "lua -e \"assert(loadfile('%s')); print('SYNTAX_OK')\" 2>&1" % LUA, timeout=25)
print(o.read().decode('utf-8', 'replace').strip())
c.close()

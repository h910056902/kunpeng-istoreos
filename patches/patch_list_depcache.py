# -*- coding: utf-8 -*-
"""
让 online_list 合并依赖预检缓存 -> 装不上的应用直接标记「不兼容」
"""
import paramiko, datetime

HOST = '192.168.66.1'
USER = 'root'
PWD = __import__('os').environ.get('ROUTER_PW', 'admin')  # 路由器密码, 建议用环境变量 ROUTER_PW 传入
LUA = '/usr/lib/lua/luci/controller/nradio_adv/appcenter.lua'

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, 22, USER, PWD, timeout=15)
sftp = c.open_sftp()

with sftp.open(LUA, 'r') as f:
    src = f.read().decode('utf-8')
orig = src
ts = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
with sftp.open(LUA + '.bak-depcache-' + ts, 'w') as f:
    f.write(src)
print('[backup] %s.bak-depcache-%s' % (LUA, ts))

# ---------- 1) 插入依赖缓存读取函数 ----------
ANCHOR = 'function action_online_list()'
assert ANCHOR in src
HELPER = r'''-- 读取依赖可安装性缓存 (/tmp/istore_depcache.json), 由 build_depcache.py 生成
local function _istore_depcache()
	local cjson = require "cjson"
	local fh = io.open("/tmp/istore_depcache.json")
	if not fh then return {} end
	local raw = fh:read("*a")
	fh:close()
	local ok, dec = pcall(cjson.decode, raw or "")
	if ok and type(dec) == "table" and type(dec.pkgs) == "table" then
		return dec.pkgs
	end
	return {}
end

'''
src = src.replace(ANCHOR, HELPER + ANCHOR, 1)
print('  * +_istore_depcache()')

# ---------- 2) 在列表里合并缓存 ----------
OLD = """			if arch_ok then
				local incompat, reason = _online_incompat(app)
				table.insert(result, {"""
NEW = """			if arch_ok then
				local incompat, reason = _online_incompat(app)
				-- 依赖预检: 软件源中缺少依赖(多为 kmod 内核模块)的应用标为不兼容
				if (not incompat) and (not installed["app-meta-" .. name]) then
					local dep = DEPCACHE["app-meta-" .. name]
					if dep and dep.ok == false then
						incompat, reason = true, tostring(dep.reason or "依赖不满足")
					end
				end
				table.insert(result, {"""
assert OLD in src, 'list body anchor not found'
src = src.replace(OLD, NEW, 1)
print('  * online_list 合并依赖缓存')

# ---------- 3) 在函数开头加载缓存 ----------
OLD2 = """	local result = {}
	local installed = {}

	local out_i = util.exec("opkg list-installed 2>/dev/null | grep '^app-meta-'")"""
NEW2 = """	local result = {}
	local installed = {}
	local DEPCACHE = _istore_depcache()

	local out_i = util.exec("opkg list-installed 2>/dev/null | grep '^app-meta-'")"""
assert OLD2 in src, 'decl anchor not found'
src = src.replace(OLD2, NEW2, 1)
print('  * 加载 DEPCACHE')

with sftp.open(LUA, 'w') as f:
    f.write(src)
print('[written] %s (%d -> %d bytes)' % (LUA, len(orig), len(src)))

_, o, e = c.exec_command('luac -p %s 2>&1 || lua -e "assert(loadfile(\'%s\'))" 2>&1' % (LUA, LUA), timeout=25)
chk = (o.read() + e.read()).decode('utf-8', 'replace').strip()
print('[syntax] %s' % (chk or 'OK'))
_, o, _ = c.exec_command('rm -rf /tmp/luci-*cache* 2>/dev/null; echo CLEARED', timeout=15)
print('[cache] ' + o.read().decode().strip())

sftp.close()
c.close()

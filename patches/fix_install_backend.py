# -*- coding: utf-8 -*-
"""
修复「点击安装没有实际安装效果」
后端: /usr/lib/lua/luci/controller/nradio_adv/appcenter.lua
  1. action_online_install  -- 真实返回码 + 任务忙检测 (原来永远返回 code=0)
  2. action_online_install_status -- 新增: 查询任务运行状态/退出码/日志
"""
import paramiko, datetime, sys

HOST = '192.168.66.1'
USER = 'root'
PWD = __import__('os').environ.get('ROUTER_PW', 'admin')  # 路由器密码, 建议用环境变量 ROUTER_PW 传入
LUA = '/usr/lib/lua/luci/controller/nradio_adv/appcenter.htm'.replace('.htm', '.lua')

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, 22, USER, PWD, timeout=15)
sftp = c.open_sftp()

with sftp.open(LUA, 'r') as f:
    src = f.read().decode('utf-8')

ts = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
bak = LUA + '.bak-fixinstall-' + ts
with sftp.open(bak, 'w') as f:
    f.write(src)
print('[backup] %s' % bak)

orig = src
changed = []

# ---------- 1) 新增 entry: online_install_status / online_precheck ----------
old_entry = '\tentry({"nradioadv", "system", "appcenter", "online_install"}, call("action_online_install"), nil, nil, true).leaf = true\n'
new_entry = (old_entry +
    '\tentry({"nradioadv", "system", "appcenter", "online_install_status"}, call("action_online_install_status"), nil, nil, true).leaf = true\n'
    '\tentry({"nradioadv", "system", "appcenter", "online_precheck"}, call("action_online_precheck"), nil, nil, true).leaf = true\n')
if 'online_install_status' not in src:
    assert old_entry in src, 'entry for online_install not found'
    src = src.replace(old_entry, new_entry, 1)
    changed.append('entry: +online_install_status +online_precheck')

# ---------- 2) 重写 action_online_install ----------
start = src.find('function action_online_install()')
assert start > 0, 'action_online_install not found'
end_marker = '-- ========= /iStore online install integration ========='
end = src.find(end_marker, start)
assert end > 0, 'end marker not found'

new_fn = r'''-- 判断 istore 安装任务是否正在运行
local function _istore_task_running()
	local util = require "luci.util"
	local st = util.exec("/etc/init.d/tasks task_status istore 2>/dev/null")
	return (st:match('"running"%s*:%s*true') ~= nil)
end

-- 读取 istore 安装任务状态
local function _istore_task_status()
	local util = require "luci.util"
	local st = util.exec("/etc/init.d/tasks task_status istore 2>/dev/null")
	local running = (st:match('"running"%s*:%s*true') ~= nil)
	local exit_code = st:match('"exit_code"%s*:%s*"?(-?%d+)"?') or ""
	local log = util.exec("tail -n 30 /var/log/tasks/istore.log 2>/dev/null")
	return running, exit_code, log
end

function action_online_install()
	local http = require "luci.http"
	local cjson = require "cjson"
	local nixio = require "nixio"
	local pkg = http.formvalue("pkg") or ""
	local result = { code = -1, msg = "invalid package" }

	if pkg:match("^app%-meta%-[a-zA-Z0-9_%-]+$") then
		-- 同一 task_id 只能有一个实例, 正在跑时必须拒绝, 否则会被静默丢弃
		if _istore_task_running() then
			result = { code = -4, msg = "已有安装任务正在进行，请等待其完成后再试" }
		else
			local incompat, reason = false, ""
			local data = _online_fetch_catalog()
			local ok, decoded = pcall(cjson.decode, data or "")
			local apps = (ok and decoded and decoded.result and decoded.result.apps) or {}
			for _, app in ipairs(apps) do
				if ("app-meta-" .. tostring(app.name or "")) == pkg then
					incompat, reason = _online_incompat(app)
					break
				end
			end
			if incompat then
				result = { code = -2, msg = reason }
			else
				-- 记录本次目标包, 供状态查询使用
				os.execute("echo -n " .. _online_shquote(pkg) .. " > /tmp/istore_install_target 2>/dev/null")
				os.execute("rm -f /var/log/tasks/istore.log 2>/dev/null")
				local cmd = "/etc/init.d/tasks task_add istore " .. _online_shquote("is-opkg install " .. pkg)
				-- 用文件捕获真实退出码, 兼容 Lua5.1 / 5.3 的 os.execute 差异
				os.execute(cmd .. " >/dev/null 2>&1; echo -n $? > /tmp/istore_task_rc 2>/dev/null")
				local rc = "1"
				local fh = io.open("/tmp/istore_task_rc")
				if fh then rc = fh:read("*l") or "1"; fh:close() end
				if rc == "0" then
					result = { code = 0, msg = "started" }
				else
					result = { code = -3, msg = "安装任务启动失败(可能已有任务在运行)" }
				end
			end
		end
	end

	http.prepare_content("application/json")
	http.write_json(result)
end

-- 查询安装任务进度/结果, 前端轮询
function action_online_install_status()
	local http = require "luci.http"
	local pkg = ""
	local fh = io.open("/tmp/istore_install_target")
	if fh then pkg = (fh:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", ""); fh:close() end

	local running, exit_code, log = _istore_task_status()

	http.prepare_content("application/json")
	http.write_json({ running = running, exit_code = exit_code, pkg = pkg, log = log })
end

-- 预检: 用 opkg --noaction 判断依赖是否可解析
function action_online_precheck()
	local http = require "luci.http"
	local util = require "luci.util"
	local pkg = http.formvalue("pkg") or ""
	local out = { ok = false, reason = "invalid package" }

	if pkg:match("^app%-meta%-[a-zA-Z0-9_%-]+$") then
		local conf = "/tmp/is-root/etc/opkg.conf"
		local confdir = "/tmp/is-root/etc/opkg"
		if not nixio.fs.access(conf) then
			os.execute("is-opkg update >/dev/null 2>&1")
		end
		local cmd = "OPKG_CONF_DIR=" .. confdir .. " opkg -f " .. conf ..
			" --noaction install " .. _online_shquote(pkg) .. " 2>&1"
		local res = util.exec(cmd)
		if res:match("Cannot install package") or res:match("Unknown package") or res:match("Collected errors") then
			local reason = res:match("cannot find dependency ([%w%-%._%+]+) for")
			if reason then
				out = { ok = false, reason = "缺少依赖: " .. reason }
			elseif res:match("incompatible with the architectures") then
				out = { ok = false, reason = "当前架构不兼容" }
			elseif res:match("Unknown package") then
				out = { ok = false, reason = "软件源中无此包" }
			else
				out = { ok = false, reason = "依赖无法解析" }
			end
		else
			out = { ok = true, reason = "" }
		end
	end

	http.prepare_content("application/json")
	http.write_json(out)
end

'''

src = src[:start] + new_fn + src[end:]
changed.append('action_online_install rewritten')
changed.append('+action_online_install_status')
changed.append('+action_online_precheck')

with sftp.open(LUA, 'w') as f:
    f.write(src)
print('[written] %s (%d -> %d bytes)' % (LUA, len(orig), len(src)))
for x in changed:
    print('  * ' + x)

# 语法检查
_, o, e = c.exec_command('lua -e "assert(loadfile(\'%s\'))" 2>&1 || luac -p %s 2>&1' % (LUA, LUA), timeout=25)
chk = (o.read() + e.read()).decode('utf-8', 'replace').strip()
print('[syntax] %s' % (chk or 'OK'))

sftp.close()
c.close()

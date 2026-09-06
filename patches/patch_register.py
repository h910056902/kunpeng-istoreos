# -*- coding: utf-8 -*-
"""注册补丁: 在线安装的 app-meta-* 应用自动注册进原生商店
1) 列表合并: opkg 已装的 app-meta 包 + /tmp/istore_online_cache.json 元数据 -> applist
2) 动作分发: 卸载/打开对未注册到 ubus 的在线应用本地处理
3) 图标: 从 iStore CDN 下载到 /www/luci-static/nradio/images/icon/online-<base>.png
"""
import paramiko, time

LUA = '/usr/lib/lua/luci/controller/nradio_adv/appcenter.lua'

HELPERS = '''
-- ========= online installed registry v1 (auto-register) =========
local function _online_inst_map()
	local util = require "luci.util"
	local inst = {}
	local out = util.exec("opkg list-installed 2>/dev/null | grep '^app-meta-'") or ""
	for line in out:gmatch("[^\\r\\n]+") do
		local base, ver = line:match("^app%-meta%-([%w%-%+%.]+)%s+(%S+)")
		if base and ver then inst[base] = ver end
	end
	return inst
end

local function _online_meta_apps()
	local cjson = require "cjson"
	local vfs = require "nixio.fs"
	local raw = vfs.readfile("/tmp/istore_online_cache.json")
	local ok, decoded = pcall(cjson.decode, raw or "")
	return (ok and decoded and decoded.result and decoded.result.apps) or {}
end

local function _online_icon_sync(base, icon_src)
	local vfs = require "nixio.fs"
	local dir = "/www/luci-static/nradio/images/icon/"
	local dst = dir .. "online-" .. base .. ".png"
	if vfs.access(dst) then return "online-" .. base .. ".png" end
	if icon_src and #icon_src > 0 and vfs.access(dir) then
		local url = "https://istore.linkease.com.cdn.koolcenter.com" .. icon_src
		os.execute("(curl -s -m 12 -o " .. dst .. ".tmp '" .. url .. "' && mv " .. dst .. ".tmp " .. dst .. ") >/dev/null 2>&1 &")
	end
	return "app_default.png"
end

local function nradio_appcenter_online_installed_merge(parameter)
	if type(parameter) ~= "table" then parameter = { applist = {} } end
	if type(parameter.applist) ~= "table" then parameter.applist = {} end
	local inst = _online_inst_map()
	if not next(inst) then return parameter end

	local existing = {}
	for _, e in ipairs(parameter.applist) do
		if type(e) == "table" and e.name then existing[tostring(e.name)] = true end
	end

	for _, a in ipairs(_online_meta_apps()) do
		local base = tostring(a.name or "")
		local ver = inst[base]
		if ver then
			inst[base] = nil
			local title = tostring(a.title or base)
			if not existing[title] and not existing[base] then
				local route = tostring(a.entry or ""):gsub("^/cgi%-bin/luci/", ""):gsub("^/", "")
				table.insert(parameter.applist, {
					name = title,
					version = tostring(ver),
					size = 0,
					status = 1,
					has_luci = (#route > 0) and 1 or 0,
					open = 0,
					icon = _online_icon_sync(base, tostring(a.icon or "")),
					des = tostring(a.description or ""),
					action_status = 0,
					luci_module_route = route,
					online_key = base
				})
			end
		end
	end

	-- 缓存之外的 app-meta 包兜底注册
	for base, ver in pairs(inst) do
		if not existing[base] then
			table.insert(parameter.applist, {
				name = base, version = tostring(ver), size = 0, status = 1,
				has_luci = 0, open = 0, icon = "app_default.png",
				des = "在线安装的应用", action_status = 0,
				luci_module_route = "", online_key = base
			})
		end
	end
	return parameter
end
'''

MERGE_OLD = 'return nradio_appcenter_version_sync(nradio_appcenter_local_apps_merge(nradio_appcenter_runtime_compat_v2(applist.parameter)))'
MERGE_NEW = 'return nradio_appcenter_version_sync(nradio_appcenter_local_apps_merge(nradio_appcenter_online_installed_merge(nradio_appcenter_runtime_compat_v2(applist.parameter))))'

DISPATCH = '''
-- 在线安装、未注册到 ubus appcenter 的应用: 本地处理卸载/打开
local function nradio_appcenter_online_action(name, action)
	if not name or #name == 0 then return nil end
	local inst = _online_inst_map()
	local base = nil
	if inst[name] then
		base = name
	else
		for _, a in ipairs(_online_meta_apps()) do
			if tostring(a.title or "") == tostring(name) then
				base = tostring(a.name or "")
				break
			end
		end
	end
	if not base or not inst[base] then return nil end
	local util = require "luci.util"
	if action == "uninstall" then
		util.exec("opkg remove --force-removal-of-dependent-packages app-meta-" .. base .. " >/tmp/nradio-online-uninstall.log 2>&1")
		return { code = 0, msg = operation_msg['uninstall'] }
	elseif action == "open" or action == "close" then
		return { code = 0, msg = "OK" }
	end
	return nil
end
'''

CORE_ANCHOR = '''	local local_app = _local_app_lookup(name)
	if local_app then
		nradio_appcenter_local_app_action(local_app, action)
		return
	end
'''
CORE_NEW = CORE_ANCHOR + '''
	local online_result = nradio_appcenter_online_action(name, action)
	if online_result then
		luci.nradio.luci_call_result(online_result)
		return
	end
'''

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
import os
c.connect('192.168.66.1', 22, 'root', os.environ.get('ROUTER_PW', 'admin'), timeout=12)

sftp = c.open_sftp()
with sftp.open(LUA, 'r') as f:
    src = f.read().decode('utf-8')

if 'nradio_appcenter_online_installed_merge' in src:
    print('SKIP: already patched')
    sftp.close(); c.close()
    raise SystemExit(0)

ok = True
if MERGE_OLD not in src:
    print('FAIL: merge anchor not found'); ok = False
if CORE_ANCHOR not in src:
    print('FAIL: core anchor not found'); ok = False
if 'function action_app_list_data()' not in src:
    print('FAIL: list_data anchor not found'); ok = False

if ok:
    bak = LUA + '.bak-reg-' + time.strftime('%Y%m%d_%H%M%S')
    with sftp.open(bak, 'w') as f:
        f.write(src)
    # 1) helpers 插在 action_app_list_data 前
    src = src.replace('function action_app_list_data()', HELPERS + '\nfunction action_app_list_data()', 1)
    # 2) 列表合并
    src = src.replace(MERGE_OLD, MERGE_NEW, 1)
    # 3) dispatch: 插在 action_app_core 定义前
    src = src.replace('function action_app_core(name,action)', DISPATCH + '\nfunction action_app_core(name,action)', 1)
    src = src.replace(CORE_ANCHOR, CORE_NEW, 1)
    with sftp.open(LUA, 'w') as f:
        f.write(src)
    print('PATCHED, backup:', bak)

sftp.close()
_, o, e = c.exec_command("lua -e \"assert(loadfile('%s')); print('SYNTAX_OK')\" 2>&1" % LUA, timeout=25)
print(o.read().decode('utf-8', 'replace').strip())
c.close()

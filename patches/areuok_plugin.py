# -*- coding: utf-8 -*-
"""Are-u-ok (AUK9527) 插件接入鲲鹏原生商店 — 本地 CLI

用法:
  python areuok_plugin.py deploy              # 部署/更新路由器端助手 + 打商店合并补丁
  python areuok_plugin.py list                # 列出可安装插件
  python areuok_plugin.py install <name>      # 安装插件并注册进原生商店
  python areuok_plugin.py uninstall <name>    # 卸载并注销
  python areuok_plugin.py status              # 查看注册表
  python areuok_plugin.py e2e [name]          # 端到端: 安装->列表验证->商店卸载->验证(默认 kms)

路由器密码: 环境变量 ROUTER_PW（默认 admin）
"""
import paramiko, json, time, sys, os

HOST = '192.168.66.1'
USER = 'root'
PW = os.environ.get('ROUTER_PW', 'admin')
LUA = '/usr/lib/lua/luci/controller/nradio_adv/appcenter.lua'
HELPER_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'kp-areuok.sh')
HELPER_DST = '/usr/bin/kp-areuok'

# ---------- Lua 补丁片段 (areuok-merge-v1) ----------

AREUOK_HELPERS = '''
-- ========= areuok registry merge v1 (AUK9527/Are-u-ok 插件注册) =========
local function _areuok_split_pipe(s)
	local t, pos = {}, 1
	while true do
		local n = s:find("|", pos, true)
		if not n then t[#t+1] = s:sub(pos); break end
		t[#t+1] = s:sub(pos, n - 1)
		pos = n + 1
	end
	return t
end

local function _areuok_registry()
	local vfs = require "nixio.fs"
	local rows = {}
	local raw = vfs.readfile("/etc/areuok_registry.list") or ""
	for line in raw:gmatch("[^\\r\\n]+") do
		local f = _areuok_split_pipe(line)
		if f[1] and #f[1] > 0 then rows[#rows+1] = f end
	end
	return rows
end

local function _areuok_full_inst()
	local util = require "luci.util"
	local set = {}
	local out = util.exec("opkg list-installed 2>/dev/null") or ""
	for line in out:gmatch("[^\\r\\n]+") do
		local p = line:match("^(%S+)")
		if p then set[p] = true end
	end
	return set
end

local function nradio_appcenter_areuok_installed_merge(parameter)
	if type(parameter) ~= "table" then parameter = { applist = {} } end
	if type(parameter.applist) ~= "table" then parameter.applist = {} end
	local rows = _areuok_registry()
	if #rows == 0 then return parameter end
	local inst = _areuok_full_inst()

	local existing = {}
	for _, e in ipairs(parameter.applist) do
		if type(e) == "table" and e.name then existing[tostring(e.name)] = true end
	end

	for _, f in ipairs(rows) do
		-- 字段: 1 key 2 title 3 pkgs 4 ver 5 time 6 route 7 istore名 8 描述
		local key, title, pkgs, ver, route, iname, des = f[1], f[2], f[3] or "", f[4] or "", f[6] or "", f[7] or "", f[8] or ""
		local alive = false
		for p in pkgs:gmatch("%S+") do
			if inst[p] then alive = true; break end
		end
		if alive and not existing[title] and not existing[key] then
			local icon_src = ""
			for _, a in ipairs(_online_meta_apps()) do
				if tostring(a.name or "") == iname then icon_src = tostring(a.icon or ""); break end
			end
			local route_n = route:gsub("^/cgi%-bin/luci/", ""):gsub("^/", "")
			table.insert(parameter.applist, {
				name = title,
				version = tostring(ver),
				size = 0,
				status = 1,
				has_luci = (#route_n > 0) and 1 or 0,
				open = 0,
				icon = _online_icon_sync(key, icon_src),
				des = des .. "（Are-u-ok 插件）",
				action_status = 0,
				luci_module_route = route_n,
				online_key = "areuok-" .. key
			})
			existing[title] = true
		end
	end
	return parameter
end
'''

AREUOK_DISPATCH = '''
-- areuok-dispatch-v1: Are-u-ok 插件的卸载/打开走 kp-areuok
local function nradio_appcenter_areuok_action(name, action)
	if not name or #name == 0 then return nil end
	local rows = _areuok_registry()
	for _, f in ipairs(rows) do
		if f[1] == name or f[2] == name then
			local util = require "luci.util"
			if action == "uninstall" then
				util.exec("kp-areuok uninstall " .. f[1] .. " >/tmp/nradio-areuok-uninstall.log 2>&1")
				return { code = 0, msg = operation_msg['uninstall'] }
			end
			return { code = 0, msg = "OK" }
		end
	end
	return nil
end
'''

CHAIN_OLD = 'return nradio_appcenter_version_sync(nradio_appcenter_local_apps_merge(nradio_appcenter_online_installed_merge(nradio_appcenter_runtime_compat_v2(applist.parameter))))'
CHAIN_NEW = 'return nradio_appcenter_version_sync(nradio_appcenter_local_apps_merge(nradio_appcenter_online_installed_merge(nradio_appcenter_areuok_installed_merge(nradio_appcenter_runtime_compat_v2(applist.parameter)))))'

DISPATCH_ANCHOR = 'local online_result = nradio_appcenter_online_action(name, action)'
DISPATCH_NEW = '''	local areuok_result = nradio_appcenter_areuok_action(name, action)
	if areuok_result then
		luci.nradio.luci_call_result(areuok_result)
		return
	end
''' + DISPATCH_ANCHOR


def sh(c, cmd, t=90):
    _, o, e = c.exec_command(cmd, timeout=t)
    out = o.read().decode('utf-8', 'replace')
    err = e.read().decode('utf-8', 'replace')
    return out, err


def login(c):
    sh(c, "rm -f /tmp/areuok_cj.txt")
    sh(c, "curl -s -m 10 -c /tmp/areuok_cj.txt -d 'luci_username=root&luci_password=%s' "
          "'http://127.0.0.1/cgi-bin/luci/' -o /dev/null" % PW)


def app_list(c):
    out, _ = sh(c, "curl -s -m 40 -b /tmp/areuok_cj.txt "
                   "'http://127.0.0.1/cgi-bin/luci/nradioadv/system/appcenter/list'", 60)
    return json.loads(out)['result']['applist']


def patch_lua(c):
    sftp = c.open_sftp()
    with sftp.open(LUA, 'r') as f:
        src = f.read().decode('utf-8')

    has_merge = 'nradio_appcenter_areuok_installed_merge' in src
    has_action = 'function nradio_appcenter_areuok_action' in src
    has_call = 'nradio_appcenter_areuok_action(name, action)' in src

    if has_merge and has_action and has_call and CHAIN_NEW in src:
        print('LUA: areuok 补丁完整，跳过')
        sftp.close(); c.close()
        return

    bak = LUA + '.bak-areuok-' + time.strftime('%Y%m%d_%H%M%S')
    with sftp.open(bak, 'w') as f:
        f.write(src)
    changed = False

    # 1) 合并函数 + 注册表 helpers
    if not has_merge:
        assert CHAIN_OLD in src, '合并链锚点未找到，请先跑 patch_register.py'
        src = src.replace('function action_app_list_data()', AREUOK_HELPERS + '\nfunction action_app_list_data()', 1)
        src = src.replace(CHAIN_OLD, CHAIN_NEW, 1)
        changed = True
        print('LUA: 插入 merge helpers + 合并链')

    # 2) 动作分发函数（修复历史版本缺失定义的问题）
    if not has_action:
        assert 'function action_app_core(name,action)' in src, 'action_app_core 锚点未找到'
        src = src.replace('function action_app_core(name,action)', AREUOK_DISPATCH + '\nfunction action_app_core(name,action)', 1)
        changed = True
        print('LUA: 插入 areuok action 分发函数')

    # 3) 分发调用点
    if not has_call:
        assert DISPATCH_ANCHOR in src, 'dispatch 锚点未找到'
        src = src.replace(DISPATCH_ANCHOR, DISPATCH_NEW, 1)
        changed = True
        print('LUA: 插入 dispatch 调用')

    if changed:
        with sftp.open(LUA, 'w') as f:
            f.write(src)
        print('LUA: PATCHED, backup:', bak)
    sftp.close()
    out, _ = sh(c, "lua -e \"assert(loadfile('%s')); print('SYNTAX_OK')\" 2>&1" % LUA, 25)
    print('LUA:', out.strip())
    sh(c, "rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache")


def deploy():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, 22, USER, PW, timeout=12)
    sftp = c.open_sftp()
    with open(HELPER_SRC, 'rb') as f:
        sftp.put(HELPER_SRC, HELPER_DST + '.new')
    sh(c, "mv %s.new %s && chmod +x %s" % (HELPER_DST, HELPER_DST, HELPER_DST))
    # 语法自检
    out, err = sh(c, "sh -n %s && echo HELPER_SYNTAX_OK" % HELPER_DST)
    print('HELPER:', out.strip() or err.strip())
    sftp.close()
    patch_lua(c)
    c.close()


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'help'
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, 22, USER, PW, timeout=12)
    login(c)

    if cmd == 'deploy':
        deploy()
    elif cmd == 'list':
        deploy()
        out, err = sh(c, "kp-areuok list")
        print(out or err)
    elif cmd == 'status':
        deploy()
        out, err = sh(c, "kp-areuok status")
        print(out or err)
    elif cmd == 'install':
        name = sys.argv[2]
        deploy()
        out, err = sh(c, "kp-areuok install %s" % name, 900)
        print(out)
        if err.strip():
            print('[stderr]', err.strip()[:500])
    elif cmd == 'uninstall':
        name = sys.argv[2]
        out, err = sh(c, "kp-areuok uninstall %s" % name, 300)
        print(out or err)
    elif cmd == 'e2e':
        name = sys.argv[2] if len(sys.argv) > 2 else 'kms'
        deploy()
        e2e(c, name)
    else:
        print(__doc__)

    c.close()


def e2e(c, name):
    ok = True
    # 登记行格式: key|title|pkgs|ver|time|route|iname|des
    _, _ = sh(c, "")
    rows = {l.split('|')[0]: l.split('|') for l in sh(c, "cat /etc/areuok_registry.list 2>/dev/null")[0].splitlines()}

    # 1) 安装
    print('[1] kp-areuok install %s' % name)
    out, err = sh(c, "kp-areuok install %s" % name, 900)
    print(out)
    if '完成' not in out:
        print('E2E FAIL: 安装未成功'); sys.exit(1)
    line = sh(c, "grep '^%s|' /etc/areuok_registry.list" % name)[0].strip()
    assert line, '注册表未写入'
    f = line.split('|')
    key, title, pkgs, ver, route = f[0], f[1], f[2], f[3], f[5]
    print('    registry: key=%s title=%s ver=%s route=%s' % (key, title, ver, route))

    # 2) opkg 验证
    miss = [p for p in pkgs.split() if not sh(c, "opkg status %s 2>/dev/null | grep -q '^Package:' && echo y" % p)[0].strip()]
    print('[2] opkg 安装验证:', 'PASS' if not miss else 'FAIL 缺少 %s' % miss)
    ok = ok and not miss

    # 3) LuCI 菜单存在
    if route:
        found = sh(c, "ls /usr/lib/lua/luci/controller/ | grep -i %s || "
                      "grep -rl 'entry' /usr/lib/lua/luci/controller/ 2>/dev/null | xargs grep -l '\"%s\"' 2>/dev/null | head -1" % (route, route))[0].strip()
        print('[3] LuCI 控制器:', ('PASS ' + found) if found else 'WARN 未找到控制器(可能由 menu 文件提供)')
        if route == 'vlmcsd':
            page = sh(c, "curl -s -m 10 -b /tmp/areuok_cj.txt -o /dev/null -w '%%{http_code}' "
                         "'http://127.0.0.1/cgi-bin/luci/admin/services/%s'" % route)[0].strip()
            print('    页面探测 admin/services/%s -> HTTP %s' % (route, page))

    # 4) 原生商店列表
    apps = app_list(c)
    reg = [a for a in apps if a.get('online_key') == 'areuok-' + key]
    if reg:
        a = reg[0]
        print('[4] 原生商店注册: PASS name=%s v%s icon=%s route=%s' % (a['name'], a.get('version'), a.get('icon'), a.get('luci_module_route')))
    else:
        print('[4] 原生商店注册: FAIL'); ok = False

    # 5) 走商店卸载分发
    r = sh(c, "curl -s -m 30 -b /tmp/areuok_cj.txt -X POST "
              "'http://127.0.0.1/cgi-bin/luci/nradioadv/system/appcenter/uninstall' "
              "--data-urlencode 'name=%s' --data-urlencode 'token=$(grep sysauth /tmp/areuok_cj.txt | awk \"{print \\$7}\")'" % title, 60)[0]
    print('[5] 商店卸载 resp:', r.strip()[:150])
    time.sleep(3)
    gone = not sh(c, "opkg list-installed 2>/dev/null | grep -E '^(%s) '" % ' |'.join(pkgs.split()))[0].strip()
    print('[6] opkg 移除:', 'PASS' if gone else 'FAIL')
    ok = ok and gone
    apps2 = app_list(c)
    still = [a for a in apps2 if a.get('online_key') == 'areuok-' + key]
    print('[7] 列表移除:', 'PASS' if not still else 'FAIL 仍存在')

    print('=' * 40)
    print('E2E %s' % ('PASS ✅' if (ok and not still) else 'FAIL ❌'))


if __name__ == '__main__':
    main()

-- kunpeng shim: 经典 Lua 控制器垫片
-- 背景: NROS 固件的 LuCI dispatcher 不支持 menu.d (view 类型),
--       luci-app-unblockneteasemusic 装上后页面 404。此垫片用 CBI 注册同路径页面。
module("luci.controller.unblockneteasemusic", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/unblockneteasemusic") then
		return
	end
	local page
	page = entry({"admin", "services", "unblockneteasemusic"}, cbi("unblockneteasemusic"), _("云音乐解锁"), 50)
	page.dependent = true
end

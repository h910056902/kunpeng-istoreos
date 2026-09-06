-- kunpeng shim: UnblockNeteaseMusic 经典 CBI 配置页
-- 对应 /etc/config/unblockneteasemusic，保存后自动 restart 服务
local sys = require "luci.sys"
local running = sys.call("pgrep -f 'unblockneteasemusic/core/app.js' >/dev/null 2>&1") == 0

m = Map("unblockneteasemusic")
m.title = translate("云音乐解锁 (UnblockNeteaseMusic)")
m.description = running
	and translate("当前状态：运行中（端口见下方设置）。LAN 设备可通过 PAC/代理方式使用。")
	or translate("当前状态：未运行，请在下方勾选「启用服务」并保存应用。")

s = m:section(NamedSection, "config", "unblockneteasemusic", translate("基本设定"))
s.addremove = false

o = s:option(Flag, "enable", translate("启用服务"))
o.rmempty = false

o = s:option(Value, "music_source", translate("音源顺序"))
o.default = "kugou kuwo migu pyncmd"
o.description = translate("空格分隔，支持: kugou kuwo migu pyncmd joox qq youtube bilibili")

o = s:option(ListValue, "replace_music_source", translate("音源替换策略"))
o:value("don't_replace", translate("不替换（仅解锁灰色）"))
o:value("lower_than_192kbps", translate("低于 192kbps 时替换"))
o:value("lower_than_320kbps", translate("低于 320kbps 时替换"))
o:value("lower_than_999kbps", translate("低于 999kbps 时替换"))
o:value("replace_all", translate("全部替换"))

o = s:option(Value, "http_port", translate("HTTP 端口"))
o.datatype = "port"
o.default = "5200"

o = s:option(Value, "https_port", translate("HTTPS 端口"))
o.datatype = "port"
o.default = "5201"

o = s:option(ListValue, "hijack_ways", translate("劫持方式"))
o:value("use_ipset", translate("ipset + dnsmasq（推荐，网关模式）"))
o:value("use_hosts", translate("hosts（端口固定 80/443）"))

o = s:option(Flag, "pub_access", translate("允许非局域网访问"))
o = s:option(Flag, "strict_mode", translate("严格模式（减少误替换）"))
o = s:option(Flag, "enable_flac", translate("启用无损 FLAC"))
o = s:option(Flag, "select_max_br", translate("自动选择最高音质"))
o = s:option(Flag, "block_ads", translate("屏蔽广告"))
o = s:option(Flag, "disable_upgrade_check", translate("禁用客户端升级检查"))
o = s:option(Flag, "auto_update", translate("自动更新核心"))

o = s:option(ListValue, "update_time", translate("核心更新时间（点）"))
for h = 0, 23 do
	o:value(h, string.format("%02d:00", h))
end
o.default = "3"

o = s:option(ListValue, "log_level", translate("日志等级"))
o:value("debug", "debug")
o:value("info", "info")
o:value("warn", "warn")
o:value("error", "error")
o.default = "info"

-- 保存后自动重启服务
m.on_after_commit = function(self)
	sys.call("/etc/init.d/unblockneteasemusic restart >/dev/null 2>&1")
end

return m

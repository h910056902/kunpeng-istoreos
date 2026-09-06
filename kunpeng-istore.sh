#!/bin/sh
#===============================================================================
# 鲲鹏路由器 · iStoreOS 化（软件层面：不刷整机固件）
# LuCI + iStore 商店 + Argon + Quickstart 等，接近 iStoreOS 管理与界面
#
# 逻辑与资源引用自开源项目（主题 IPK、文件传输、iStore 安装流程等同源）：
#   https://github.com/wukongdaily/gl-inet-onescript
# 本脚本去掉 GL-iNet 机型专用项（换源 / 风扇 / 分区 / 原厂 distfeeds 等），
# 保留通用「应用商店 + Argon + Quickstart + 常用元包」流程，适配鲲鹏无限等
# 基于官方或第三方 OpenWrt 的固件（需 opkg、网络正常）。
# 自动补齐：脚本会节流执行 opkg update，并尽量安装 curl/wget/证书、LuCI 与本地 IPK 常见依赖；
#   KP_SKIP_OPKG_UPDATE=1 可跳过 update；仅依赖可执行: sh $0 deps
#   KP_REWRITE_SNAPSHOT_FEED=0 关闭：将 distfeeds 内 downloads.openwrt.org 的 21.02-SNAPSHOT 改写成 21.02.7
#
# 「像素级」尽量对齐 gl-inet 的做法：
#   - 主题 / 文件传输 IPK：优先从 gl-inet-onescript 的 GitHub raw 拉取（与仓库 theme 目录同源），
#     失败再回退 mt3000.netlify.app（与上游脚本相同 CDN）。
#   - Argon：装包后按环境变量 KP_ARGON_PRESET 写入 UCI（默认 purple，接近常见 iStore 观感；
#     可 export KP_ARGON_PRESET=factory 与上游 GL 脚本「装完不改主题页」一致）。
#   - Quickstart：在 is-opkg 可用时尽量 force-reinstall 首页相关包并追加与上游一致的隐藏按钮 CSS。
#   仍受 LuCI 大版本、厂商魔改、屏幕 DPI 影响，无法保证与某一具体机型截图 100% 逐像素相同。
#
# 用法（在路由器 SSH 或串口 shell 内执行）：
#   wget -O /tmp/kunpeng-istore.sh '你的托管地址/kunpeng-istore.sh'
#   sh /tmp/kunpeng-istore.sh
# 一行远程执行（等同 sh kunpeng-istore.sh one，需可访问的 raw HTTPS 脚本地址）：
#   (wget -T 30 -qO- 'https://.../kunpeng-istore.sh' || curl -fsSL 'https://.../kunpeng-istore.sh') | sh -s one
# 或本脚本已在路由器上时，仅填 URL 拉最新版再一键：
#   KP_SCRIPT_URL='https://.../kunpeng-istore.sh' sh /path/kunpeng-istore.sh remote
#   sh /path/kunpeng-istore.sh remote 'https://.../kunpeng-istore.sh'
# 安装到快捷命令（可选）：
#   cp -f "$0" /usr/bin/kp && chmod +x /usr/bin/kp
#===============================================================================

UPSTREAM_THEME_BASE="https://mt3000.netlify.app/theme"
UPSTREAM_FILETRANSFER_BASE="https://mt3000.netlify.app/luci-app-filetransfer"
THEME_BASE_GH="https://raw.githubusercontent.com/wukongdaily/gl-inet-onescript/master/theme"
FILETRANSFER_BASE_GH="https://raw.githubusercontent.com/wukongdaily/gl-inet-onescript/master/luci-app-filetransfer"
ISTORE_REPO="https://istore.linkease.com/repo/all/store"
THIRD_PARTY_SOURCE="https://istore.linkease.com/repo/all/nas_luci"

red() { printf '\033[31m\033[01m%s\033[0m\n' "$1"; }
green() { printf '\033[32m\033[01m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m\033[01m%s\033[0m\n' "$1"; }

die() {
	red "$1"
	exit 1
}

# 依次尝试多个 URL，成功则返回 0（用于与上游仓库同字节 IPK）
fetch_first_url() {
	_out="$1"
	shift
	rm -f "$_out"
	for _url in "$@"; do
		if command -v curl >/dev/null 2>&1; then
			curl -fsSL --connect-timeout 20 --max-time 120 -o "$_out" "$_url" && [ -s "$_out" ] && return 0
		fi
		rm -f "$_out"
		if command -v wget >/dev/null 2>&1; then
			wget -T 20 -q -O "$_out" "$_url" && [ -s "$_out" ] && return 0
		fi
		rm -f "$_out"
	done
	return 1
}

fetch_theme_ipk() {
	_name="$1"
	_out="$2"
	fetch_first_url "$_out" "${THEME_BASE_GH}/${_name}" "${UPSTREAM_THEME_BASE}/${_name}"
}

fetch_filetransfer_ipk() {
	_name="$1"
	_out="$2"
	fetch_first_url "$_out" "${FILETRANSFER_BASE_GH}/${_name}" "${UPSTREAM_FILETRANSFER_BASE}/${_name}"
}

ensure_openwrt() {
	[ -f /etc/openwrt_release ] || die "未检测到 /etc/openwrt_release，请在 OpenWrt 路由器上运行本脚本。"
}

KP_LOG=/tmp/kunpeng-istore.log
kp_log() {
	_ts=$(date '+%F %T' 2>/dev/null) || _ts=.
	printf '%s %s\n' "$_ts" "$*" >>"$KP_LOG" 2>/dev/null || true
}

# 主题/uci 变更后重启 Web 与 LuCI 后端，避免界面仍显示默认主题
restart_luci_web_services() {
	kp_log "restart_luci_web_services"
	/etc/init.d/rpcd restart 2>/dev/null || true
	/etc/init.d/uhttpd restart 2>/dev/null || true
	/etc/init.d/nginx restart 2>/dev/null || true
	[ -x /sbin/luci ] && /sbin/luci reload 2>/dev/null || true
}

register_argon_luci_theme_uci() {
	if uci -q get luci.themes.Argon >/dev/null 2>&1; then
		uci set luci.themes.Argon='/luci-static/argon'
		uci commit luci
		kp_log "uci luci.themes.Argon registered"
	fi
}

# 从网络拉取本脚本最新副本并 exec 一键（用于路由器上已有旧版 kp 时自我更新）
run_remote_latest() {
	RURL=$1
	[ -n "$RURL" ] || die "缺少脚本 URL。"
	_tmp="/tmp/kunpeng-istore-run.sh"
	rm -f "$_tmp"
	fetch_first_url "$_tmp" "$RURL" || die "下载脚本失败，请检查 URL 与网络。"
	# 防止 CDN/代理返回 HTML 错误页被当脚本执行
	_head=$(head -c 64 "$_tmp" 2>/dev/null | tr -d '\r')
	case "$_head" in
	'#!/'*) ;;
	*)
		rm -f "$_tmp"
		die "下载内容不是 shell 脚本（请检查 URL 是否指向 raw 文件、是否需登录）。"
		;;
	esac
	chmod 755 "$_tmp" 2>/dev/null
	exec sh "$_tmp" one
}

get_lan_ip() {
	uci -q get network.lan.ipaddr
}

get_model() {
	[ -r /tmp/sysinfo/model ] && cat /tmp/sysinfo/model || echo "Unknown"
}

# 上游脚本里用于 Argon 依赖的预编译 IPK 面向常见 aarch64 环境；其它架构从软件源安装
use_upstream_theme_deps() {
	_arch=$(sed -n "s/^DISTRIB_ARCH='\\(.*\\)'$/\\1/p" /etc/openwrt_release 2>/dev/null)
	case "$_arch" in
	*aarch64*) return 0 ;;
	*) return 1 ;;
	esac
}

is_iStoreOS() {
	_id=$(sed -n "s/^DISTRIB_ID='\\(.*\\)'$/\\1/p" /etc/openwrt_release 2>/dev/null)
	[ "$_id" = "iStoreOS" ]
}

remove_check_signature_option() {
	_opkg_conf="/etc/opkg.conf"
	[ -f "$_opkg_conf" ] && sed -i '/option check_signature/d' "$_opkg_conf"
}

add_check_signature_option() {
	_opkg_conf="/etc/opkg.conf"
	[ -f "$_opkg_conf" ] || return 0
	grep -q "option check_signature" "$_opkg_conf" 2>/dev/null || echo "option check_signature 1" >>"$_opkg_conf"
}

# 解析 is-opkg 绝对路径（PATH 或常见安装位置）
resolve_is_opkg() {
	if command -v is-opkg >/dev/null 2>&1; then
		command -v is-opkg
		return 0
	fi
	for _p in /bin/is-opkg /usr/bin/is-opkg /sbin/is-opkg; do
		if [ -x "$_p" ]; then
			printf '%s\n' "$_p"
			return 0
		fi
	done
	return 1
}

# 查找 firewall 中 name=wan 的 zone 下标（避免误改 @zone[1] 非 WAN）
firewall_wan_zone_idx() {
	_i=0
	while uci -q get "firewall.@zone[$_i]" >/dev/null; do
		_name=$(uci -q get "firewall.@zone[$_i].name")
		if [ "$_name" = "wan" ]; then
			printf '%s\n' "$_i"
			return 0
		fi
		_i=$((_i + 1))
	done
	return 1
}

# ---------- opkg：自动补齐脚本运行与装包所需依赖 ----------
KP_OPKG_STAMP="/tmp/.kunpeng-istore-opkg-updated"

# 官方 21.02-SNAPSHOT 目录常已下线，wget 404/8；默认改写成 21.02.7 再 opkg update（设 KP_REWRITE_SNAPSHOT_FEED=0 关闭）
maybe_rewrite_snapshot_distfeeds() {
	[ "${KP_REWRITE_SNAPSHOT_FEED:-1}" = "0" ] && return 0
	_f=/etc/opkg/distfeeds.conf
	[ -f "$_f" ] || return 0
	grep -q 'downloads\.openwrt\.org' "$_f" 2>/dev/null || return 0
	grep -q '21\.02-SNAPSHOT' "$_f" 2>/dev/null || return 0
	kp_log "rewrite distfeeds 21.02-SNAPSHOT -> 21.02.7"
	cp -f "$_f" "${_f}.kunpeng-snapbak" 2>/dev/null || true
	sed -i 's|21\.02-SNAPSHOT|21.02.7|g' "$_f" 2>/dev/null || true
}

# 设为 1 可跳过 opkg update（离线或已手动更新时）
opkg_update_throttled() {
	command -v opkg >/dev/null 2>&1 || return 0
	[ "${KP_SKIP_OPKG_UPDATE:-0}" = "1" ] && return 0
	maybe_rewrite_snapshot_distfeeds
	_now=$(date +%s 2>/dev/null || echo 0)
	_last=0
	[ -r "$KP_OPKG_STAMP" ] && _last=$(cat "$KP_OPKG_STAMP" 2>/dev/null || echo 0)
	case "$_last" in *[!0-9]*) _last=0 ;; esac
	case "$_now" in *[!0-9]*) _now=0 ;; esac
	# 30 分钟内不重复 update，减轻源压力
	if [ "$_last" -gt 0 ] 2>/dev/null; then
		_delta=$((_now - _last))
		if [ "$_delta" -lt 1800 ] 2>/dev/null && [ "$_delta" -ge 0 ] 2>/dev/null; then
			return 0
		fi
	fi
	if opkg update; then
		echo "$_now" >"$KP_OPKG_STAMP" 2>/dev/null || true
	else
		yellow "opkg update 失败，后续自动补齐依赖可能不完整。"
	fi
}

# 是否已通过 opkg 安装某包
is_opkg_pkg_installed() {
	_pn="$1"
	[ -n "$(opkg list-installed "$_pn" 2>/dev/null)" ]
}

# 未安装则 opkg install（忽略失败，由调用方重试或报错）
opkg_install_if_missing() {
	_pn="$1"
	is_opkg_pkg_installed "$_pn" && return 0
	opkg install "$_pn" 2>/dev/null
}

# HTTPS 下载、解压 Packages.gz、拉取 IPK 等所需工具与证书链
ensure_opkg_base_for_download() {
	command -v opkg >/dev/null 2>&1 || return 0
	opkg_update_throttled
	# 证书（名称因版本而异，多试）
	for _p in ca-bundle ca-certificates; do
		opkg_install_if_missing "$_p" || true
	done
	# uclient-fetch / curl 常用 SSL 后端
	for _p in libustream-openssl libustream-mbedtls libustream-wolfssl; do
		opkg_install_if_missing "$_p" || true
	done
	# curl
	opkg_install_if_missing curl || true
	# wget（多种包名）
	if ! command -v wget >/dev/null 2>&1; then
		for _p in wget-ssl wget-nossl wget; do
			opkg_install_if_missing "$_p" && break
		done
	fi
	# gzip（部分精简固件无独立 gzip，BusyBox 通常自带；仍尝试安装）
	command -v gzip >/dev/null 2>&1 || opkg_install_if_missing gzip || true
}

# LuCI / Argon / 本地 IPK 常见依赖，从软件源尽量补齐
ensure_opkg_luci_runtime_deps() {
	command -v opkg >/dev/null 2>&1 || return 0
	opkg_update_throttled
	for _p in luci-lib-ipkg luci-compat luci-lua-runtime luci-lib-jsonc luci-lib-nixio luci-base \
		libopenssl3 libmbedtls12 libmbedtls luci-lib-fs tar coreutils-base64; do
		opkg_install_if_missing "$_p" || true
	done
}

# Quickstart / ipt 相关可选内核模块
ensure_opkg_quickstart_extra() {
	command -v opkg >/dev/null 2>&1 || return 0
	opkg_update_throttled
	for _p in iptables-mod-tproxy iptables-mod-socket iptables-mod-iprange iptables-mod-nfqueue; do
		opkg_install_if_missing "$_p" || true
	done
}

# 安装本地 .ipk：失败则先补 LuCI 依赖再试，最后 --force-depends
opkg_install_local_ipks() {
	command -v opkg >/dev/null 2>&1 || return 1
	if opkg install "$@"; then
		return 0
	fi
	yellow "本地 IPK 安装失败，尝试从软件源补齐 LuCI/OpenSSL 等依赖后重试..."
	ensure_opkg_luci_runtime_deps
	if opkg install "$@"; then
		return 0
	fi
	yellow "再次失败，尝试 --force-depends（可能影响依赖一致性，请留意 opkg 输出）。"
	opkg install "$@" --force-depends
}

# 0=清空第三方 customfeeds 并 opkg update；1=追加 istore 第三方 nas_luci 源
setup_software_source() {
	if [ "$1" = "0" ]; then
		echo "# add your custom package feeds here" >/etc/opkg/customfeeds.conf
		if is_iStoreOS; then
			add_check_signature_option
		fi
		opkg update || yellow "opkg update 失败，请检查网络与软件源。"
	elif [ "$1" = "1" ]; then
		remove_check_signature_option
		echo "# add your custom package feeds here" >/etc/opkg/customfeeds.conf
		echo "src/gz third_party_source $THIRD_PARTY_SOURCE" >>/etc/opkg/customfeeds.conf
		opkg update || yellow "opkg update（含第三方源）失败。"
	else
		yellow "setup_software_source: 无效参数"
	fi
}

add_dhcp_domain() {
	_domain_name="time.android.com"
	_domain_ip="203.107.6.88"
	_existing=$(uci show dhcp 2>/dev/null | grep "dhcp.@domain\[[0-9]*\].name='${_domain_name}'" || true)
	if [ -z "$_existing" ]; then
		uci add dhcp domain >/dev/null 2>&1
		uci set "dhcp.@domain[-1].name=$_domain_name"
		uci set "dhcp.@domain[-1].ip=$_domain_ip"
		uci commit dhcp
	fi
}

add_author_info() {
	uci -q get system.@system[0] >/dev/null 2>&1 || return 0
	uci set system.@system[0].description='kunpeng-istore (based on wukongdaily/gl-inet-onescript)'
	uci set system.@system[0].notes='iStoreOS style helper. Upstream: https://github.com/wukongdaily/gl-inet-onescript'
	uci commit system 2>/dev/null || true
}

setup_timezone() {
	uci -q get system.@system[0] >/dev/null 2>&1 || return 0
	uci set system.@system[0].zonename='Asia/Shanghai'
	uci set system.@system[0].timezone='CST-8'
	uci commit system 2>/dev/null || true
	/etc/init.d/system reload 2>/dev/null || true
}

# 可选：将 WAN 区 input 设为 ACCEPT（与上游脚本一致，降低作为主路由时下挂访问难度，有安全风险）
setup_firewall_wan_accept() {
	if [ ! -t 0 ]; then
		yellow "非交互终端，跳过 WAN 入站修改（若需要请在本机 SSH 菜单中执行）。"
		return 0
	fi
	yellow "是否将防火墙 WAN 入站设为 ACCEPT（与 gl-inet 默认一致）？[y/N]"
	read -r _ans
	case "$_ans" in
	y | Y)
		_wz=$(firewall_wan_zone_idx)
		if [ -n "$_wz" ]; then
			uci set "firewall.@zone[${_wz}].input=ACCEPT" && uci commit firewall && /etc/init.d/firewall reload 2>/dev/null
			green "已设置 WAN（zone ${_wz}）input=ACCEPT"
		else
			yellow "未找到 name=wan 的防火墙区域，跳过（请手动在 LuCI 防火墙中调整）。"
		fi
		;;
	*)
		yellow "已跳过 WAN 入站修改"
		;;
	esac
}

patch_openwrt_release_description() {
	_file="/etc/openwrt_release"
	[ -f "$_file" ] || return 0
	_new="OpenWrt like iStoreOS style (kunpeng-istore, theme/install flow from wukongdaily/gl-inet-onescript)"
	_content=$(cat "$_file")
	_updated=$(printf '%s\n' "$_content" | sed "s#DISTRIB_DESCRIPTION='[^']*'#DISTRIB_DESCRIPTION='${_new}'#")
	printf '%s\n' "$_updated" >"$_file"
}

# 与 jerrykuku/luci-app-argon-config 仓库 root/etc/config/argon 一致（GL 脚本装完主题后未改 UCI 时的基线）
apply_argon_factory_defaults() {
	[ -f /etc/config/argon ] || return 0
	uci -q show argon.@global[0] >/dev/null 2>&1 || return 0
	uci set argon.@global[0].primary='#5e72e4'
	uci set argon.@global[0].dark_primary='#483d8b'
	uci set argon.@global[0].blur='10'
	uci set argon.@global[0].blur_dark='10'
	uci set argon.@global[0].transparency='0.5'
	uci set argon.@global[0].transparency_dark='0.5'
	uci set argon.@global[0].mode='normal'
	uci set argon.@global[0].online_wallpaper='bing'
	uci commit argon 2>/dev/null || true
	green "Argon UCI 已对齐官方默认模板（蓝紫系 + Bing 壁纸 + blur 10）。"
}

# 常见「紫色 iStore / 易截图一致」：主色偏紫、关闭随机壁纸避免登录页抽卡
apply_argon_istore_purple_preset() {
	[ -f /etc/config/argon ] || return 0
	uci -q show argon.@global[0] >/dev/null 2>&1 || return 0
	uci set argon.@global[0].primary='#8b5cf6'
	uci set argon.@global[0].dark_primary='#5b21b6'
	uci set argon.@global[0].blur='12'
	uci set argon.@global[0].blur_dark='12'
	uci set argon.@global[0].transparency='0.42'
	uci set argon.@global[0].transparency_dark='0.42'
	uci set argon.@global[0].mode='normal'
	uci set argon.@global[0].online_wallpaper='none'
	uci commit argon 2>/dev/null || true
	green "Argon UCI 已应用紫色 iStore 常见预设（无 Bing 随机图）。"
}

# KP_ARGON_PRESET: purple（默认）| factory | off
apply_argon_preset_from_env() {
	case "${KP_ARGON_PRESET:-purple}" in
	factory | "")
		apply_argon_factory_defaults
		;;
	purple | istore)
		apply_argon_istore_purple_preset
		;;
	off | none)
		yellow "KP_ARGON_PRESET=off，跳过 Argon UCI 写入。"
		;;
	*)
		yellow "未知 KP_ARGON_PRESET=${KP_ARGON_PRESET}，使用 factory。"
		apply_argon_factory_defaults
		;;
	esac
}

# 参考 gl-inet-onescript：从 iStore 官方仓库拉取 luci-app-store 并释放 is-opkg
do_istore() {
	echo "==> 安装 iStore 应用商店（linkease/istore 流程）"
	ensure_opkg_base_for_download
	FCURL="curl --fail --show-error --location"

	if ! command -v curl >/dev/null 2>&1; then
		die "无法使用 curl（已尝试 opkg 自动安装）。请检查软件源或手动: opkg install curl ca-bundle libustream-openssl"
	fi

	# 仅用 gzip -dc 解压（避免 zcat 与 gzip 串联争用同一 stdin 导致损坏）；BusyBox/OpenWrt 均支持
	IPK=$(
		$FCURL "$ISTORE_REPO/Packages.gz" | gzip -dc 2>/dev/null |
			grep -m1 '^Filename: luci-app-store.*\.ipk$' | sed -n 's/^Filename: \(.*\)$/\1/p'
	)
	[ -n "$IPK" ] || IPK=$(
		$FCURL "$ISTORE_REPO/Packages.gz" | zcat 2>/dev/null |
			grep -m1 '^Filename: luci-app-store.*\.ipk$' | sed -n 's/^Filename: \(.*\)$/\1/p'
	)
	[ -n "$IPK" ] || die "无法解析 luci-app-store 的 ipk 文件名（Packages.gz 解压失败或网络异常），请检查 curl、gzip/zcat。"

	$FCURL "$ISTORE_REPO/$IPK" | tar -xzO ./data.tar.gz | tar -xzO ./bin/is-opkg >/tmp/is-opkg

	[ -s "/tmp/is-opkg" ] || die "释放 is-opkg 失败。"
	chmod 755 /tmp/is-opkg
	/tmp/is-opkg update
	/tmp/is-opkg opkg install --force-reinstall luci-lib-taskd luci-lib-xterm
	/tmp/is-opkg opkg install --force-reinstall luci-app-store || die "luci-app-store 安装失败（is-opkg 返回错误），请查看上文 opkg 输出。"
	[ -s "/etc/init.d/tasks" ] || /tmp/is-opkg opkg install --force-reinstall taskd
	[ -s "/usr/lib/lua/luci/cbi.lua" ] || /tmp/is-opkg opkg install luci-compat >/dev/null 2>&1
	command -v is-opkg >/dev/null 2>&1 || [ -x /bin/is-opkg ] || yellow "若 is-opkg 不在 PATH，请使用 /bin/is-opkg 或重新登录 shell。"
}

do_install_depends_ipk() {
	fetch_theme_ipk "luci-lua-runtime_all.ipk" "/tmp/luci-lua-runtime_all.ipk" || return 1
	fetch_theme_ipk "libopenssl3.ipk" "/tmp/libopenssl3.ipk" || return 1
	fetch_theme_ipk "luci-compat.ipk" "/tmp/luci-compat.ipk" || return 1
	opkg_install_local_ipks "/tmp/luci-lua-runtime_all.ipk" "/tmp/libopenssl3.ipk" "/tmp/luci-compat.ipk" || return 1
}

do_install_argon_skin() {
	echo "==> 安装 Argon 主题（固定版本与上游脚本一致）"
	ensure_opkg_base_for_download
	opkg_update_throttled
	ensure_opkg_luci_runtime_deps
	opkg_install_if_missing luci-lib-ipkg || true

	if use_upstream_theme_deps; then
		do_install_depends_ipk || yellow "上游依赖 IPK 安装失败，尝试继续用系统源已装依赖。"
	else
		for _p in luci-compat luci-lua-runtime libopenssl3; do
			opkg_install_if_missing "$_p" || true
		done
	fi

	_argon_dl_ok=1
	fetch_theme_ipk "luci-theme-argon-master_2.2.9.4_all.ipk" "/tmp/luci-theme-argon.ipk" || _argon_dl_ok=0
	fetch_theme_ipk "luci-app-argon-config_0.9_all.ipk" "/tmp/luci-app-argon-config.ipk" || _argon_dl_ok=0
	fetch_theme_ipk "luci-i18n-argon-config-zh-cn.ipk" "/tmp/luci-i18n-argon-config-zh-cn.ipk" || _argon_dl_ok=0

	if [ "$_argon_dl_ok" = 1 ] && opkg_install_local_ipks /tmp/luci-theme-argon.ipk /tmp/luci-app-argon-config.ipk /tmp/luci-i18n-argon-config-zh-cn.ipk; then
		kp_log "argon installed from local ipk"
	else
		yellow "本地 Argon IPK 不可用或安装失败，改从软件源安装（版本可能与 GL 脚本固定包不同）…"
		opkg_update_throttled
		if opkg install luci-theme-argon luci-app-argon-config luci-i18n-argon-config-zh-cn 2>/dev/null; then
			kp_log "argon installed from opkg feed (full)"
		elif opkg install luci-theme-argon luci-app-argon-config 2>/dev/null; then
			kp_log "argon installed from opkg feed (partial, no zh-cn ipk)"
		else
			die "opkg 安装 Argon 失败（本地 IPK 与软件源均失败），请检查网络、软件源与架构。"
		fi
	fi

	uci set luci.main.mediaurlbase='/luci-static/argon'
	uci set luci.main.lang='zh_cn'
	register_argon_luci_theme_uci
	uci commit luci

	apply_argon_preset_from_env

	restart_luci_web_services
	kp_log "do_install_argon_skin done"

	green "Argon 已安装并设为默认主题；已尝试重启 uhttpd/rpcd。请清空缓存或无痕窗口重新打开 LuCI。"
}

do_install_filetransfer() {
	mkdir -p /tmp/luci-app-filetransfer/
	cd /tmp/luci-app-filetransfer/ || exit 1
	ensure_opkg_luci_runtime_deps
	fetch_filetransfer_ipk "luci-app-filetransfer_all.ipk" "./luci-app-filetransfer_all.ipk" || return 1
	fetch_filetransfer_ipk "luci-lib-fs_1.0-14_all.ipk" "./luci-lib-fs_1.0-14_all.ipk" || return 1
	opkg_install_local_ipks ./luci-app-filetransfer_all.ipk ./luci-lib-fs_1.0-14_all.ipk || return 1
}

# 与 gl-inet.sh 中 hide_homepage_format_button 意图一致（修正上游损坏的 heredoc 写法）
apply_quickstart_parity_css() {
	TARGET="/www/luci-static/quickstart/style.css"
	MARKER="/* hide quickstart disk button */"
	[ -f "$TARGET" ] || {
		yellow "未找到 $TARGET ，跳过 Quickstart 样式补丁（可能尚未安装 quickstart）。"
		return 0
	}
	if ! grep -q "$MARKER" "$TARGET" 2>/dev/null; then
		printf '\n%s\n.value-data button {\n  display: none !important;\n}\n' "$MARKER" >>"$TARGET"
		green "已追加 Quickstart 样式：隐藏磁盘区格式化按钮（对齐 gl-inet 行为）。"
	else
		yellow "Quickstart 隐藏格式化按钮样式已存在，跳过。"
	fi
}

update_luci_app_quickstart() {
	ISP=$(resolve_is_opkg) || {
		red "未找到 is-opkg，请先执行「一键 iStoreOS 风格化」或菜单安装 iStore。"
		return 1
	}

	"$ISP" update
	# 尽量与上游「更新 quickstart」一致：重装首页与中文包，减少版本漂移带来的界面差分
	"$ISP" opkg install --force-reinstall luci-app-quickstart 2>/dev/null || true
	"$ISP" opkg install --force-reinstall quickstart 2>/dev/null || true
	"$ISP" install luci-i18n-quickstart-zh-cn --force-depends >/dev/null 2>&1 || true
	ensure_opkg_quickstart_extra
	opkg install luci-i18n-base-zh-cn 2>/dev/null || true
	apply_quickstart_parity_css
	restart_luci_web_services
	kp_log "update_luci_app_quickstart done"

	LAN_IP=$(get_lan_ip)
	LAN_IP=${LAN_IP:-192.168.1.1}
	yellow "Quickstart / 首页组件已尝试更新。请用浏览器访问："
	green "  http://${LAN_IP}/cgi-bin/luci/"
	green "若厂商将 LuCI 放在其它端口（例如 :8080），请自行替换端口。"
}

install_istore_os_style() {
	do_install_argon_skin
	opkg install luci-i18n-base-zh-cn 2>/dev/null || true
	opkg install ttyd 2>/dev/null || yellow "ttyd 安装失败（可忽略或稍后从软件源安装）"
	do_install_filetransfer || yellow "文件传输组件安装失败（可稍后重试菜单项）"

	if ISP=$(resolve_is_opkg); then
		"$ISP" install app-meta-sftp 2>/dev/null || yellow "app-meta-sftp 未安装成功"
		"$ISP" install app-meta-ddnsto 2>/dev/null || yellow "app-meta-ddnsto 未安装成功"
		"$ISP" install app-meta-diskman 2>/dev/null || yellow "app-meta-diskman 未安装成功"
	else
		yellow "is-opkg 不可用，跳过元应用安装（请先完成 iStore 安装）。"
	fi

	patch_openwrt_release_description
}

one_click_istore_style() {
	kp_log "one_click_istore_style start"
	green ">>> 一键 iStoreOS 化（鲲鹏路由器 · 软件层面）"
	echo "    机型: $(get_model)"
	_dist_arch=$(sed -n "s/^DISTRIB_ARCH='\(.*\)'$/\1/p" /etc/openwrt_release 2>/dev/null)
	echo "    架构: ${_dist_arch:-unknown}"

	install_self_shortcut
	ensure_opkg_base_for_download
	ensure_opkg_luci_runtime_deps
	do_istore
	install_istore_os_style
	update_luci_app_quickstart

	add_author_info
	add_dhcp_domain
	setup_timezone

	yellow "是否调整防火墙 WAN 入站？（默认否，更安全）"
	setup_firewall_wan_accept

	restart_luci_web_services
	kp_log "one_click_istore_style end"
	green "一键流程结束。建议清空浏览器缓存后重新打开 LuCI。"
}

do_install_filemanager() {
	do_istore
	ISP=$(resolve_is_opkg) || {
		red "未找到可执行的 is-opkg"
		return 1
	}
	"$ISP" install app-meta-linkease
	LAN_IP=$(get_lan_ip)
	LAN_IP=${LAN_IP:-192.168.1.1}
	green "尝试打开: http://${LAN_IP}/cgi-bin/luci/admin/services/linkease/file/?path=/root"
}

add_custom_feed() {
	echo "# add your custom package feeds here" >/etc/opkg/customfeeds.conf
	printf "请输入自定义软件源 URL（一行，通常以你的 target 子路径结尾）: "
	read -r feed_url
	if [ -n "$feed_url" ]; then
		echo "src/gz custom_feed $feed_url" >>/etc/opkg/customfeeds.conf
		opkg update || yellow "opkg update 失败"
	else
		yellow "未输入 URL，未修改。"
	fi
}

remove_custom_feed() {
	echo "# add your custom package feeds here" >/etc/opkg/customfeeds.conf
	opkg update || yellow "opkg update 失败"
}

install_self_shortcut() {
	_script="$0"
	case "$_script" in
	sh | ash | -sh | /bin/sh | /bin/ash | /usr/bin/sh | /usr/bin/ash)
		yellow "当前为管道或匿名 shell（\$0=$_script），跳过安装 /usr/bin/kp；请用: sh /绝对路径/kunpeng-istore.sh"
		return 0
		;;
	esac
	[ -f "$_script" ] || {
		yellow "无法定位脚本文件（\$0=$_script），跳过 kp。"
		return 0
	}
	if [ -w /usr/bin ] 2>/dev/null; then
		cp -f "$_script" /usr/bin/kp && chmod +x /usr/bin/kp && green "已安装快捷命令: kp"
	else
		yellow "无法写入 /usr/bin，跳过安装 kp（请使用 root 运行）。"
	fi
}

main_menu() {
	ensure_openwrt
	install_self_shortcut
	ensure_opkg_base_for_download

	while true; do
		clear
		echo "========================================================================"
		echo " 鲲鹏路由器 · iStoreOS 化 | kunpeng-istore（基于 wukongdaily/gl-inet-onescript）"
		echo " 当前机型: $(get_model)"
		echo " 快捷命令: kp （若已安装到 /usr/bin）"
		echo "========================================================================"
		echo " 1) 一键 iStoreOS 化（iStore + Argon + Quickstart + 常用组件）"
		echo " 2) 仅安装 iStore 应用商店"
		echo " 3) 仅安装 Argon 主题（IPK/软件源 + KP_ARGON_PRESET，默认 purple）"
		echo " 4) 更新 Quickstart（force-reinstall + 中文 + 首页 CSS 补丁）"
		echo " 5) 安装易有文件管理（需已装 iStore）"
		echo " 6) 追加第三方 nas_luci 源并 opkg update"
		echo " 7) 清空 customfeeds 并 opkg update"
		echo " 8) 手动添加自定义软件源 URL 到 customfeeds"
		echo " 9) 清除自定义软件源"
		echo "10) 仅重新应用 Argon「官方默认」UCI（蓝紫基线，对齐 jerrykuku 模板）"
		echo "11) 仅重新应用 Argon「紫色 iStore」UCI（紫主色 + 关 Bing）"
		echo "12) 仅重装 Quickstart 相关包 + 应用首页 CSS 补丁"
		echo "13) 仅自动补齐 opkg 依赖（下载/LuCI/iptables 等，不装主题与商店）"
		echo " Q) 退出"
		echo "========================================================================"
		printf "请选择: "
		read -r choice

		case "$choice" in
		1) one_click_istore_style ;;
		2) do_istore ;;
		3) do_install_argon_skin ;;
		4) update_luci_app_quickstart ;;
		5) do_install_filemanager ;;
		6) setup_software_source 1 ;;
		7) setup_software_source 0 ;;
		8) add_custom_feed ;;
		9) remove_custom_feed ;;
		10) apply_argon_factory_defaults ;;
		11) apply_argon_istore_purple_preset ;;
		12) update_luci_app_quickstart ;;
		13)
			ensure_opkg_base_for_download
			ensure_opkg_luci_runtime_deps
			ensure_opkg_quickstart_extra
			green "已尝试补齐 opkg 依赖（可重复执行）。"
			;;
		q | Q) exit 0 ;;
		*) red "无效选项" ;;
		esac

		printf "\n按 Enter 继续..."
		read -r _
	done
}

# 非交互：sh kunpeng-istore.sh one  执行一键
case "$1" in
one | 1 | install | i)
	ensure_openwrt
	one_click_istore_style
	;;
remote | fetch)
	ensure_openwrt
	_R=${2:-$KP_SCRIPT_URL}
	run_remote_latest "$_R"
	;;
deps | prepare | deps-only)
	ensure_openwrt
	ensure_opkg_base_for_download
	ensure_opkg_luci_runtime_deps
	ensure_opkg_quickstart_extra
	green "opkg 依赖已尝试补齐。"
	;;
menu | "")
	main_menu
	;;
*)
	echo "用法: sh $0                 # 交互菜单"
	echo "      sh $0 one|install      # 非交互一键（全功能）"
	echo "      sh $0 remote '<脚本HTTPS地址>'   # 下载该 URL 的脚本并执行一键"
	echo "      sh $0 deps              # 仅自动补齐 opkg 依赖"
	echo "      KP_SCRIPT_URL='https://...' sh $0 remote"
	echo "一行远程: (wget -qO- 'URL' || curl -fsSL 'URL') | sh -s one"
	echo "环境变量 KP_ARGON_PRESET: purple（默认）| factory | off  （示例: KP_ARGON_PRESET=factory sh $0 one）"
	echo "环境变量 KP_SKIP_OPKG_UPDATE=1  跳过节流内的 opkg update（已手动更新源时）"
	echo "环境变量 KP_REWRITE_SNAPSHOT_FEED=0  不自动把 21.02-SNAPSHOT 改为 21.02.7（默认会改写）"
	;;
esac

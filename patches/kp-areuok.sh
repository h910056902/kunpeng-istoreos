#!/bin/sh
# kp-areuok - AUK9527/Are-u-ok 插件安装器（鲲鹏无限路由器专用）
# 用法: kp-areuok list | status | install <name> | uninstall <name>
# 仓库: https://github.com/AUK9527/Are-u-ok
# 说明: Are-u-ok 的 .run 是 Makeself 自解压包(内含 ipk), 直接 sh 安装;
#       安装后把插件登记到 /etc/areuok_registry.list, 原生商店会合并显示。

REPO_BASE="${AREUOK_REPO:-https://raw.githubusercontent.com/AUK9527/Are-u-ok/main}"
MIRROR="${AREUOK_MIRROR:-}"
REG=/etc/areuok_registry.list
TMP_RUN=/tmp/areuok_plugin.run
LUCI_CACHE="/tmp/luci-indexcache* /tmp/luci-modulecache"

# 清单: key|标题|route|a53文件|x86文件|iStore元数据名|描述
MANIFEST='
kms|KMS 服务器|admin/services/vlmcsd|KMS_a53.run|KMS_x86.run|vlmcsd|KMS 激活服务器（Windows/Office 系统激活）
nps|NPS 内网穿透|admin/services/nps|NPS_a53.run|NPS_x86.run|nps|nps 内网穿透客户端
openclash|OpenClash|admin/services/openclash|OpenClash_*_core.run|OpenClash_*_core.run|openclash|多协议代理客户端（含 Clash 内核）
openvpn-client|OpenVPN 客户端|admin/services/openvpn|OpenVPN_2021*.run|OpenVPN_x86.run|openvpn|OpenVPN 客户端
openvpn-server|OpenVPN 服务端|admin/services/openvpn|OpenVPN-Server_a53.run|OpenVPN-Server_x86.run|openvpn|OpenVPN 服务端
adguardhome|AdGuard Home|admin/services/adguardhome|adguardhome.run|adguardhome.run|adguardhome|全网广告拦截与 DNS 服务
mosdns|MosDNS|admin/services/mosdns|mosdns_*_aarch64_a53*.run|mosdns_*_x86_64*.run|mosdns|DNS 分流 / 去广告
unblockneteasemusic|云音乐解锁|admin/services/unblockneteasemusic|unblockneteasemusic.run|unblockneteasemusic.run|unblockneteasemusic|解除网易云音乐灰色歌曲限制
ssr-plus|SSR-Plus|admin/services/ssr-plus|SSR-Plus_*_aarch64*.run|SSR-Plus_*_x86_64*.run|ssr-plus|代理客户端（勿与 PassWall 同装）
passwall|PassWall|admin/services/passwall|PassWall_*_aarch64*.run|PassWall_*_x86_64*.run|passwall|代理客户端（勿与 SSR-Plus 同装）
passwall2|PassWall2|admin/services/passwall2|PassWall2_*_aarch64*.run|PassWall2_*_x86_64*.run|passwall2|代理客户端
'

arch_dir() {
	case "$(uname -m)" in
		x86_64) echo "x86/all" ;;
		*)      echo "apps/all" ;;
	esac
}

dl() { # $1=url $2=out
	local url="$1" out="$2"
	if [ -n "$MIRROR" ]; then
		curl -fsSL -m 600 "${MIRROR}${url}" -o "$out" 2>/dev/null && [ -s "$out" ] && return 0
		wget -T 45 -q "${MIRROR}${url}" -O "$out" 2>/dev/null && [ -s "$out" ] && return 0
	fi
	curl -fsSL -m 600 "$url" -o "$out" 2>/dev/null && [ -s "$out" ] && return 0
	wget -T 45 -q "$url" -O "$out" 2>/dev/null && [ -s "$out" ] && return 0
	return 1
}

clear_cache() { rm -rf $LUCI_CACHE 2>/dev/null; }

manifest_line() {
	echo "$MANIFEST" | while IFS= read -r l; do
		case "$l" in "$1|"*) echo "$l"; break ;; esac
	done
}

field() { echo "$1" | cut -d'|' -f"$2"; }

cmd_list() {
	echo "可安装插件（来源 AUK9527/Are-u-ok, 架构目录: $(arch_dir)）:"
	echo "$MANIFEST" | while IFS= read -r l; do
		[ -z "$l" ] && continue
		key=$(field "$l" 1); title=$(field "$l" 2)
		if grep -q "^$key|" "$REG" 2>/dev/null; then st="[已装]"; else st="[    ]"; fi
		printf '%s %-22s %s\n' "$st" "$key" "$title"
	done
}

cmd_status() {
	if [ -f "$REG" ]; then cat "$REG"; else echo "（尚未安装任何 Are-u-ok 插件）"; fi
}

do_install() {
	key="$1"
	[ -n "$key" ] || { echo "用法: kp-areuok install <name>（name 见 kp-areuok list）"; exit 1; }
	line=$(manifest_line "$key")
	[ -n "$line" ] || { echo "未知插件: $key"; exit 1; }

	title=$(field "$line" 2); route=$(field "$line" 3)
	iname=$(field "$line" 6); des=$(field "$line" 7)
	dir=$(arch_dir)
	if [ "$dir" = "x86/all" ]; then pat=$(field "$line" 5); else pat=$(field "$line" 4); fi

	file=""
	case "$pat" in
		*\**) # 通配: 从 GitHub API 取目录列表匹配
			api=$(echo "$dir" | awk -F/ '{print $1"/"$2}')
			list=$(curl -fsSL -m 30 "https://api.github.com/repos/AUK9527/Are-u-ok/contents/$dir" 2>/dev/null)
			[ -z "$list" ] && [ -n "$MIRROR" ] && list=$(curl -fsSL -m 30 "${MIRROR}https://api.github.com/repos/AUK9527/Are-u-ok/contents/$dir" 2>/dev/null)
			preg=$(echo "$pat" | sed 's/\./\\./g; s/\*/.*/g')
			file=$(echo "$list" | grep -o '"name": *"[^"]*"' | sed 's/"name": *//' | tr -d '"' | grep -E "^$preg\$" | head -n1)
			[ -z "$file" ] && { echo "FAIL: 仓库中找不到匹配 $pat 的文件（网络问题或清单过期）"; exit 1; }
			;;
		*) file="$pat" ;;
	esac

	echo "[1/5] 目标文件: $dir/$file"
	rm -f "$TMP_RUN"
	echo "[2/5] 下载中..."
	dl "$REPO_BASE/$dir/$file" "$TMP_RUN" || { echo "FAIL: 下载失败（可设置 AREUOK_MIRROR=https://ghproxy.net/ 加速）"; exit 1; }
	echo "      已下载 $(du -k "$TMP_RUN" | awk '{print $1}') KB"

	opkg list-installed > /tmp/areuok_before 2>/dev/null

	echo "[3/5] 安装 .run 包..."
	# 先解出包清单（不执行）, 再正常安装
	rm -rf /tmp/areuok_ex; mkdir -p /tmp/areuok_ex
	sh "$TMP_RUN" --target /tmp/areuok_ex --noexec >/dev/null 2>&1
	bundle_pkgs=$(ls /tmp/areuok_ex/*.ipk 2>/dev/null | while IFS= read -r f; do basename "$f" | cut -d_ -f1; done | sort -u | tr '\n' ' ')
	if ! sh "$TMP_RUN"; then
		echo "FAIL: .run 自解压安装失败"; rm -f "$TMP_RUN"; exit 1
	fi
	rm -f "$TMP_RUN"; rm -rf /tmp/areuok_ex

	opkg list-installed > /tmp/areuok_after 2>/dev/null
	newpkgs=$(diff /tmp/areuok_before /tmp/areuok_after 2>/dev/null | grep '^> ' | awk '{print $2}' | sort -u | tr '\n' ' ')
	# 包清单 = 本次新装的 + 包内本来就装好的（.run 可重复安装）
	pkgs=""
	for p in $bundle_pkgs $newpkgs; do
		case " $pkgs " in *" $p "*) continue ;; esac
		if opkg status "$p" 2>/dev/null | grep -q '^Package:'; then pkgs="$pkgs $p"; fi
	done
	pkgs=$(echo $pkgs)
	if [ -z "$pkgs" ]; then
		echo "FAIL: .run 内的 ipk 包均未安装成功"; exit 1
	fi
	ver=""
	for p in $pkgs; do
		case "$p" in luci-app-*) ver=$(grep "^$p " /tmp/areuok_after | awk '{print $3}'); break ;; esac
	done
	[ -z "$ver" ] && for p in $pkgs; do
		case "$p" in luci-app-*) ver=$(grep "^$p - " /tmp/areuok_after | awk '{print $3}'); break ;; esac
	done
	[ -z "$ver" ] && ver=$(echo $pkgs | awk '{print $1}')

	echo "[4/5] 登记到原生商店注册表..."
	touch "$REG"
	grep -v "^$key|" "$REG" > "$REG.tmp" 2>/dev/null; mv "$REG.tmp" "$REG"
	echo "$key|$title|$pkgs|$(echo "$ver" | tr '|' ' ')|$(date '+%Y-%m-%d')|$route|$iname|$des" >> "$REG"

	clear_cache
	echo "[5/5] 完成: $title 已安装并注册进原生应用商店"
	echo "      包: $pkgs"
}

do_uninstall() {
	key="$1"
	[ -n "$key" ] || { echo "用法: kp-areuok uninstall <name>"; exit 1; }
	line=$(grep "^$key|" "$REG" 2>/dev/null | head -n1)
	[ -n "$line" ] || { echo "未安装: $key"; exit 1; }
	pkgs=$(field "$line" 3)
	echo "[1/2] opkg remove: $pkgs"
	i=0
	while [ $i -lt 2 ]; do
		for p in $pkgs; do
			opkg remove --force-removal-of-dependent-packages "$p" >/dev/null 2>&1
		done
		i=$((i+1))
	done
	grep -v "^$key|" "$REG" > "$REG.tmp" 2>/dev/null; mv "$REG.tmp" "$REG"
	clear_cache
	echo "[2/2] 已从原生商店注销: $key"
}

case "$1" in
	list)      cmd_list ;;
	status)    cmd_status ;;
	install)   shift; do_install "$1" ;;
	uninstall) shift; do_uninstall "$1" ;;
	*) echo "用法: kp-areuok list | status | install <name> | uninstall <name>"; exit 1 ;;
esac

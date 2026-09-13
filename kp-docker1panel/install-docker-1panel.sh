#!/bin/sh
# ================================================================
# 鲲鹏 NRadio C2000 Max (OpenWrt 21.02-SNAPSHOT, aarch64_cortex-a53)
# Docker + 1Panel 一键安装脚本（幂等 / 非交互 / 分阶段门禁）
#
# 设计依据（2026-09-13 实测 + 官方源码比对）：
#   * 1Panel 官方 install.sh v1.10.34-lts 的 OpenWrt 分支：
#       - 二进制/脚本路径: /usr/local/bin/{1panel,1pctl} -> /usr/bin 符号链接
#       - 1pctl 中 sed 写入 BASE_DIR / ORIGINAL_{PORT,USERNAME,PASSWORD,ENTRANCE} / LANGUAGE
#       - 二进制首次启动读取 /usr/local/bin/1pctl 的这些值初始化数据库（已用 strings 验证）
#       - 服务: initscript/1paneld.procd -> /etc/init.d/1paneld (USE_PROCD=1, START=95)
#       - GeoIP.mmdb -> $BASE_DIR/1panel/geo/ ; lang/ -> /usr/local/bin/lang
#   * 本机约束:
#       - vendor kernel 5.4.281: BRIDGE_NETFILTER/OVERLAY_FS/MEMCG 内建, kmod-veth 已有匹配包
#       - musl libc: 官方 arm64 二进制为静态链接（无 INTERP），可直接运行
#       - 10086=nr_webui / 10087=kpwebui / 10088=kp-quickstart-webui，面板改用 10090
#       - 已有 daemon.json（镜像加速+日志轮转+data-root=/mnt/storage/data/docker），默认不改动
#
# 用法（SSH 到路由器后）:
#   /bin/sh install-docker-1panel.sh
# 可用环境变量覆盖默认值（见下）
# ================================================================

# ---------------- 可调参数 ----------------
PANEL_PORT="${PANEL_PORT:-10090}"
PANEL_BASE_DIR="${PANEL_BASE_DIR:-/mnt/storage/data}"     # 面板数据根（eMMC 数据分区）
PANEL_USERNAME="${PANEL_USERNAME:-admin}"
PANEL_PASSWORD="${PANEL_PASSWORD:-auto}"                  # auto = 随机 12 位十六进制
PANEL_ENTRANCE="${PANEL_ENTRANCE:-auto}"                  # auto = 随机 10 位十六进制
ONEPANEL_VERSION="${ONEPANEL_VERSION:-v1.10.34-lts}"
ONEPANEL_CHANNEL="${ONEPANEL_CHANNEL:-stable}"
DOCKER_ENABLE_BRIDGE="${DOCKER_ENABLE_BRIDGE:-0}"         # 1 = 启用 docker0 网桥 + iptables（会改 daemon.json）
REGISTER_APPSTORE="${REGISTER_APPSTORE:-1}"               # 1 = 注册进鲲鹏应用商店
CRED_FILE="${CRED_FILE:-/root/1panel-credentials.txt}"

LAN_IP="$(uci -q get network.lan.ipaddr 2>/dev/null || echo 192.168.66.1)"
DL_BASE="https://resource.fit2cloud.com/1panel/package/${ONEPANEL_CHANNEL}/${ONEPANEL_VERSION}/release"
PKG_NAME="1panel-${ONEPANEL_VERSION}-linux-arm64.tar.gz"
PKG_DIR="1panel-${ONEPANEL_VERSION}-linux-arm64"
TMP_DIR="/mnt/storage/data/kp-tmp"
RUN_BASE_DIR="${PANEL_BASE_DIR}/1panel"
DB_FILE="${RUN_BASE_DIR}/db/1Panel.db"

# ---------------- 日志工具 ----------------
STEP=""
step() { STEP="$1"; echo; echo "=============================================="; echo ">>> $STEP"; echo "=============================================="; }
info() { echo "  [info] $1"; }
ok()   { echo "  [ OK ] $1"; }
warn() { echo "  [warn] $1"; }
die()  { echo "  [FAIL] $1" >&2; echo "  (阶段: ${STEP:-init})" >&2; exit 1; }

hexgen() { head -c "$1" /dev/urandom | md5sum | cut -c1-"$2"; }

# 从 /usr/local/bin/1pctl 读回已写入的配置值（幂等重跑时回填凭据）
# 说明：1Panel 二进制首启时从 1pctl 播种 DB，1pctl 里始终保留明文配置；
#       密码若含转义字符（!@#$%*_,.? 前的反斜杠）在此处反转义还原。
pv() { grep "^$1=" /usr/local/bin/1pctl 2>/dev/null | head -n1 | cut -d= -f2- | sed 's/\\//g'; }

# ---------------- Stage 0: 预检 ----------------
step "Stage 0 / 环境预检"

[ "$(id -u)" = "0" ] || die "必须以 root 运行"
[ "$(uname -m)" = "aarch64" ] || die "仅支持 aarch64（当前: $(uname -m)）"

grep -q " /mnt/storage/data " /proc/mounts 2>/dev/null \
  || die "数据分区 /mnt/storage/data 未挂载（本机 eMMC p2, f2fs）"

AVAIL_KB=$(df -k /mnt/storage/data | awk 'NR==2{print $4}')
[ "${AVAIL_KB:-0}" -gt 1048576 ] || warn "数据分区剩余不足 1GB（当前 ${AVAIL_KB}KB），继续但可能空间紧张"

command -v bash >/dev/null 2>&1 || { opkg update >/dev/null 2>&1; opkg install bash || die "bash 安装失败（1pctl 依赖）"; }
for t in curl tar gzip sha256sum md5sum; do
  command -v "$t" >/dev/null 2>&1 || die "缺少工具: $t"
done
ok "预检通过（aarch64 / 数据分区可用 ${AVAIL_KB}KB）"

# ---------------- Stage 1: Docker 就绪 ----------------
step "Stage 1 / Docker 就绪（已装则校验，未装则安装）"

if ! command -v docker >/dev/null 2>&1; then
  info "未检测到 docker，开始安装（aliyun packages 源）..."
  opkg update >/dev/null 2>&1 \
    || warn "opkg update 失败（网络/源问题）；若后续安装包失败，请检查 /etc/opkg/distfeeds.conf（可换 aliyun 镜像）"
  opkg install kmod-veth kmod-br-netfilter dockerd docker || die "dockerd/docker 安装失败"
else
  DOCKER_VER="$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  info "检测到 docker ${DOCKER_VER:-unknown}"
fi

# kmod-veth：容器 bridge 网络必需（本机 vendor 内核无 CONFIG_VETH，须装包）
opkg status kmod-veth 2>/dev/null | grep -q "Status: install ok installed" \
  || opkg install kmod-veth || warn "kmod-veth 安装失败：bridge 网络将不可用（host 模式不受影响）"

# docker-compose：1Panel 应用部署依赖（缺失时降级为警告：面板本身可用）
if ! docker-compose version >/dev/null 2>&1; then
  opkg install docker-compose \
    || warn "docker-compose 安装失败：面板可正常使用，但应用商店部署应用需依赖它（可稍后手动 opkg install docker-compose）"
fi
ok "docker-compose: $(docker-compose version --short 2>/dev/null || docker-compose -v 2>/dev/null)"

# 时区数据：1Panel 时间显示依赖
opkg status zoneinfo-asia 2>/dev/null | grep -q "Status: install ok installed" \
  || opkg install zoneinfo-asia || warn "zoneinfo-asia 安装失败（仅影响时区显示）"

# daemon.json 策略：
#   不存在        -> 写入本机验证过的保守配置（host 优先，不动防火墙）
#   存在          -> 默认原样保留；仅当 DOCKER_ENABLE_BRIDGE=1 时切换为网桥+iptables 模式
if [ ! -f /etc/docker/daemon.json ]; then
  info "写入 /etc/docker/daemon.json（保守配置）"
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "data-root": "/mnt/storage/data/docker",
  "storage-driver": "overlay2",
  "bridge": "none",
  "iptables": false,
  "log-level": "warn",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.m.daocloud.io",
    "https://docker.1panel.live"
  ]
}
EOF
elif [ "$DOCKER_ENABLE_BRIDGE" = "1" ] && grep -q '"iptables": *false' /etc/docker/daemon.json; then
  info "DOCKER_ENABLE_BRIDGE=1: 停止 dockerd -> 配置防火墙区 -> 切换网桥模式"
  cp /etc/docker/daemon.json /etc/docker/daemon.json.kp_bak 2>/dev/null   # 备份必须在 sed 之前（原配置）
  /etc/init.d/dockerd stop >/dev/null 2>&1
  /etc/init.d/dockerd uciadd >/dev/null 2>&1 || warn "uciadd 失败（docker 防火墙区未建）"
  sed -i -e '/"bridge"/d' -e 's/"iptables": *false/"iptables": true/' /etc/docker/daemon.json
  info "已切换：删除 bridge:none，iptables=true（原配置备份于 daemon.json.kp_bak）"
fi

# 启动/校验 dockerd
if ! docker info >/dev/null 2>&1; then
  /etc/init.d/dockerd enable >/dev/null 2>&1
  /etc/init.d/dockerd start || die "dockerd 启动失败"
  n=0
  while [ $n -lt 30 ]; do
    docker info >/dev/null 2>&1 && break
    n=$((n+1)); sleep 2
  done
  docker info >/dev/null 2>&1 || die "dockerd 30 次探测后仍未就绪"
fi
ok "dockerd 运行中: server $(docker version --format '{{.Server.Version}}' 2>/dev/null), 存储 $(docker info 2>/dev/null | grep 'Storage Driver' | awk '{print $3}')"

# ---------------- Stage 2: 1Panel 下载与安装 ----------------
step "Stage 2 / 1Panel ${ONEPANEL_VERSION} 下载与安装"

if command -v 1panel >/dev/null 2>&1 && [ -f "$DB_FILE" ]; then
  info "检测到已有安装（$DB_FILE），从 1pctl 回读凭据，跳过安装，仅确保服务运行"
  _v="$(pv ORIGINAL_PORT)"     ; [ -n "$_v" ] && PANEL_PORT="$_v"
  _v="$(pv ORIGINAL_USERNAME)" ; [ -n "$_v" ] && PANEL_USERNAME="$_v"
  _v="$(pv ORIGINAL_ENTRANCE)" ; [ -n "$_v" ] && PANEL_ENTRANCE="$_v"
  _v="$(pv ORIGINAL_PASSWORD)" ; [ -n "$_v" ] && PANEL_PASSWORD="$_v"
  [ -n "$PANEL_ENTRANCE" ] && [ "$PANEL_ENTRANCE" != "auto" ] \
    || die "无法从 1pctl 回读入口码（/usr/local/bin/1pctl 异常），请检查安装状态"
  ok "已回读: 端口=${PANEL_PORT} 用户=${PANEL_USERNAME} 入口=${PANEL_ENTRANCE}"
else
  # --- 凭据生成 ---
  [ "$PANEL_ENTRANCE" = "auto" ] && PANEL_ENTRANCE="$(hexgen 16 10)"
  [ "$PANEL_PASSWORD" = "auto" ] && PANEL_PASSWORD="$(hexgen 32 12)"
  echo "$PANEL_ENTRANCE"   | grep -qE '^[a-zA-Z0-9_]{3,30}$' || die "entrance 不合法"
  echo "$PANEL_PASSWORD"   | grep -qE '^[a-zA-Z0-9_!@#$%*,.?]{8,30}$' || die "password 不合法"
  echo "$PANEL_USERNAME"   | grep -qE '^[a-zA-Z0-9_]{3,30}$' || die "username 不合法"

  # --- 端口占用检查 ---
  if netstat -lnt 2>/dev/null | grep -q ":${PANEL_PORT} "; then
    die "端口 $PANEL_PORT 已被占用，请换端口重跑：PANEL_PORT=xxxx /bin/sh $0"
  fi

  # --- 下载 + SHA256 校验 ---
  mkdir -p "$TMP_DIR"
  cd "$TMP_DIR" || die "无法进入 $TMP_DIR"
  curl -s -m 30 "${DL_BASE}/checksums.txt" -o checksums.txt || die "checksums.txt 下载失败"
  EXPECT="$(grep " ${PKG_NAME}\$" checksums.txt | awk '{print $1}')"
  [ -n "$EXPECT" ] || die "checksums.txt 中找不到 $PKG_NAME"
  if [ ! -f "$PKG_NAME" ]; then
    info "下载 $PKG_NAME ..."
    curl -LOk -m 600 -o "$PKG_NAME" "${DL_BASE}/${PKG_NAME}" || die "安装包下载失败"
  fi
  ACTUAL="$(sha256sum "$PKG_NAME" | awk '{print $1}')"
  [ "$ACTUAL" = "$EXPECT" ] || { rm -f "$PKG_NAME"; die "SHA256 不匹配（已删除损坏包）: expect=$EXPECT actual=$ACTUAL"; }
  ok "SHA256 校验通过"

  # --- 全新初始化（清理残留的半成品数据目录） ---
  rm -rf "$RUN_BASE_DIR"
  rm -rf "$TMP_DIR/$PKG_DIR"
  tar zxf "$PKG_NAME" || die "解包失败"
  [ -f "$PKG_DIR/1panel" ] || die "包内缺少 1panel 二进制"
  cd "$PKG_DIR" || die "无法进入 $PKG_DIR"

  # --- 官方 init_configure 流程（OpenWrt 分支） ---
  mkdir -p /usr/local/bin
  cp ./1panel /usr/local/bin/ && chmod +x /usr/local/bin/1panel
  ln -sf /usr/local/bin/1panel /usr/bin/1panel
  cp ./1pctl /usr/local/bin/ && chmod +x /usr/local/bin/1pctl
  ln -sf /usr/local/bin/1pctl /usr/bin/1pctl
  sed -i -e "s#^BASE_DIR=.*#BASE_DIR=${PANEL_BASE_DIR}#g"                /usr/local/bin/1pctl
  sed -i -e "s#^ORIGINAL_PORT=.*#ORIGINAL_PORT=${PANEL_PORT}#g"          /usr/local/bin/1pctl
  sed -i -e "s#^ORIGINAL_USERNAME=.*#ORIGINAL_USERNAME=${PANEL_USERNAME}#g" /usr/local/bin/1pctl
  ESCAPED_PWD="$(echo "$PANEL_PASSWORD" | sed 's/[!@#$%*_,.?]/\\\\&/g')"
  sed -i -e "s#^ORIGINAL_PASSWORD=.*#ORIGINAL_PASSWORD=${ESCAPED_PWD}#g" /usr/local/bin/1pctl
  sed -i -e "s#^ORIGINAL_ENTRANCE=.*#ORIGINAL_ENTRANCE=${PANEL_ENTRANCE}#g" /usr/local/bin/1pctl
  sed -i -e "s#^LANGUAGE=.*#LANGUAGE=zh#g"                               /usr/local/bin/1pctl
  ok "1panel/1pctl 已就位，1pctl 已写入端口/账号/入口"

  # --- GeoIP + 语言包 ---
  mkdir -p "${RUN_BASE_DIR}/geo"
  cp -f ./GeoIP.mmdb "${RUN_BASE_DIR}/geo/" 2>/dev/null
  rm -rf /usr/local/bin/lang            # 先清残留，避免 cp 到已存在目录产生 lang/lang 嵌套
  cp -r ./lang /usr/local/bin/lang

  # --- procd 服务（官方 1paneld.procd, START=95） ---
  cp ./initscript/1paneld.procd /etc/init.d/1paneld
  chmod +x /etc/init.d/1paneld
  /etc/init.d/1paneld enable || warn "1paneld enable 失败（开机自启未生效）"
  /etc/init.d/1paneld start || die "1paneld 启动失败"
  ok "1paneld 已启动（procd, START=95）"

  cp -rf ./initscript "${RUN_BASE_DIR}/"

  # --- 启动等待门禁 ---
  n=0
  while [ $n -lt 20 ]; do
    if /etc/init.d/1paneld status 2>/dev/null | grep -q '^running' \
       && netstat -lnt 2>/dev/null | grep -q ":${PANEL_PORT} "; then
      break
    fi
    n=$((n+1)); sleep 2
  done
  netstat -lnt 2>/dev/null | grep -q ":${PANEL_PORT} " || die "面板端口 ${PANEL_PORT} 未监听（查看日志: logread | grep 1panel）"
  ok "面板监听端口 ${PANEL_PORT}"

  # --- 清理安装包（凭据已持久化，不影响重装） ---
  cd / && rm -rf "$TMP_DIR/$PKG_DIR" "$TMP_DIR/$PKG_NAME" "$TMP_DIR/checksums.txt"
fi

# ---------------- Stage 3 / 验证 ----------------
step "Stage 3 / 端到端验证"

if ! /etc/init.d/1paneld status 2>/dev/null | grep -q '^running'; then
  /etc/init.d/1paneld start || die "1paneld 启动失败"
  sleep 3
fi

PANEL_VER="$(1pctl version 2>/dev/null | grep -m1 -oE 'v[0-9][0-9A-Za-z.-]*')"
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 8 "http://127.0.0.1:${PANEL_PORT}/${PANEL_ENTRANCE}")"
DOCKER_SV="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"

info "1pctl version : ${PANEL_VER:-unknown}"
info "HTTP /${PANEL_ENTRANCE} -> ${HTTP_CODE}（期望 200）"
info "docker server : ${DOCKER_SV:-unknown}"

[ "$HTTP_CODE" = "200" ] || die "面板 HTTP 探测失败（got $HTTP_CODE），检查 logread | grep 1panel"
docker info >/dev/null 2>&1 || die "docker info 失败"
ok "1Panel 与 Docker 均就绪"

# ---------------- Stage 4 / 凭据落盘 + 汇总 ----------------
step "Stage 4 / 凭据持久化"

umask 077
cat > "$CRED_FILE" <<EOF
# 1Panel 安装信息（$(date '+%Y-%m-%d %H:%M:%S')）
版本:     ${ONEPANEL_VERSION}
地址:     http://${LAN_IP}:${PANEL_PORT}/${PANEL_ENTRANCE}
用户名:   ${PANEL_USERNAME}
密码:     ${PANEL_PASSWORD}
数据目录: ${RUN_BASE_DIR}
服务管理: /etc/init.d/1paneld {start|stop|restart|status}
命令行:   1pctl {status|user-info|version|update|reset|uninstall}
卸载:     1pctl uninstall（会询问 y 确认）
EOF
chmod 600 "$CRED_FILE"
ok "凭据已写入 $CRED_FILE（仅 root 可读）"

# ---------------- Stage 5 / 鲲鹏应用商店入口（可选） ----------------
if [ "$REGISTER_APPSTORE" = "1" ] && [ -f /etc/kp_store/installed.list ]; then
  step "Stage 5 / 注册应用商店入口"
  if grep -q "^1panel|" /etc/kp_store/installed.list; then
    info "商店入口已存在，跳过"
  else
    TS=$(date +%s)
    echo "1panel|1Panel 管理面板|docker|${ONEPANEL_VERSION}|${TS}|-|docker|现代化 Linux 运维面板：容器/应用商店/网站/文件/计划任务/监控|http://${LAN_IP}:${PANEL_PORT}/${PANEL_ENTRANCE}" >> /etc/kp_store/installed.list
    chmod 600 /etc/kp_store/installed.list 2>/dev/null
    # 同步 plugins.json（JSON 版注册表，字段 id/name/pkg/route/source/des/open_url）
    lua -e '
local list, json = {}, require "luci.jsonc"
local f = io.open("/etc/kp_store/installed.list"); if not f then return end
for l in f:read("*a"):gmatch("[^\r\n]+") do
  local p = {}
  for v in l:gmatch("[^|]+") do p[#p+1] = v end
  if #p >= 9 then
    list[#list+1] = { id=p[1], name=p[2], pkg=p[3], ver=p[4], ts=p[5],
                      route=(p[6] ~= "-" and p[6] or ""), source=p[7],
                      des=p[8], open_url=(p[9] ~= "-" and p[9] or "") }
  end
end
f:close()
local o = io.open("/etc/kp_store/plugins.json", "w")
o:write(json.stringify(list)); o:close()
' 2>/dev/null || warn "plugins.json 同步失败（installed.list 已更新）"
    ok "已注册 1Panel 入口（open_url 指向面板）"
  fi
fi

# ---------------- 完成汇总 ----------------
echo
echo "================================================"
echo "  安装完成"
echo "================================================"
echo "  面板地址 : http://${LAN_IP}:${PANEL_PORT}/${PANEL_ENTRANCE}"
echo "  用户名   : ${PANEL_USERNAME}"
echo "  密码     : ${PANEL_PASSWORD}"
echo "  凭据文件 : ${CRED_FILE}"
echo "  服务管理 : /etc/init.d/1paneld {start|stop|restart|status}"
echo "  面板信息 : 1pctl user-info"
echo "================================================"

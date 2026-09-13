#!/bin/sh
# ================================================================
# 鲲鹏 OpenWrt (aarch64) Docker + 1Panel 一行命令安装器
#
# 用法一（PC / 任意终端，一行 SSH 完成）:
#   ssh root@192.168.66.1 "wget -qO- https://raw.githubusercontent.com/h910056902/kunpeng-istoreos/main/kp-docker1panel/remote-install.sh | sh"
#
# 用法二（已在路由器 shell 中）:
#   wget -qO- https://raw.githubusercontent.com/h910056902/kunpeng-istoreos/main/kp-docker1panel/remote-install.sh | sh
#
# 自定义参数（环境变量会透传给主安装脚本）:
#   ssh root@192.168.66.1 "wget -qO- <同上URL> | PANEL_PORT=10091 sh"
#
# 设计说明:
#   - 多源下载回退: raw.githubusercontent.com -> ghfast.top -> gh-proxy.com
#   - 先落盘到 /tmp 再执行（避免 curl|sh 模式下 stdin 被管道占用，
#     且失败可重跑: sh /tmp/kp-install-docker-1panel.sh）
#   - 主脚本幂等: 已装 Docker/1Panel 时自动校验并回读凭据，不会破坏现有安装
# ================================================================
set -u

REPO="h910056902/kunpeng-istoreos"
BRANCH="main"
REL="kp-docker1panel/install-docker-1panel.sh"
TARGET="/tmp/kp-install-docker-1panel.sh"

# 三个下载源（换行分隔，for 按空白分词逐个尝试）
BASES="https://raw.githubusercontent.com/${REPO}/${BRANCH}
https://ghfast.top/https://raw.githubusercontent.com/${REPO}/${BRANCH}
https://gh-proxy.com/https://raw.githubusercontent.com/${REPO}/${BRANCH}"

fetch() { # $1=url $2=目标文件 -> 成功返回 0
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -m 60 -o "$2" "$1" && [ -s "$2" ]
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 60 -O "$2" "$1" && [ -s "$2" ]
  else
    echo "[FAIL] 路由器上既没有 curl 也没有 wget，请先 opkg install curl" >&2
    return 2
  fi
}

echo ">>> 下载主安装脚本 ..."
OK=0
for b in $BASES; do
  echo "    尝试: $b/$REL"
  if fetch "$b/$REL" "$TARGET"; then
    OK=1
    echo "    下载成功 ($(wc -c < "$TARGET") 字节)"
    break
  fi
done
if [ "$OK" != "1" ]; then
  echo "[FAIL] 三个下载源均不可达。手动排查:" >&2
  echo "       1) 路由器能否上网  2) DNS 是否被劫持 (nslookup raw.githubusercontent.com)" >&2
  echo "       3) 也可在 PC 下载后 pscp 上传: pscp -scp install-docker-1panel.sh root@192.168.66.1:/tmp/" >&2
  exit 1
fi

echo ">>> 开始安装（幂等，可重复执行）..."
sh "$TARGET"
RC=$?
echo
[ $RC -eq 0 ] && echo ">>> 完成。凭据: cat /root/1panel-credentials.txt" \
             || echo ">>> 安装失败（exit $RC）。重试: sh $TARGET"
exit $RC

#!/bin/sh
B="http://192.168.66.1:10090"
echo "=== 1pctl version（完整） ==="
1pctl version 2>&1
echo
echo "=== 1pctl user-info ==="
1pctl user-info 2>&1
echo
echo "=== 服务状态与自启 ==="
/etc/init.d/1paneld status
ls -la /etc/rc.d/ | grep 1paneld
echo
echo "=== 面板进程与内存 ==="
ps w | grep -E "1panel" | grep -v grep
PID=$(pidof 1panel)
grep VmRSS /proc/$PID/status 2>/dev/null
echo
echo "=== HTTP 探测 ==="
ENT=$(grep '^入口' /root/1panel-credentials.txt 2>/dev/null | awk -F'/' '{print $NF}')
[ -z "$ENT" ] && ENT=$(sed -n 's#^入口:.*http://.*/##p' /root/1panel-credentials.txt)
echo "entrance=$ENT"
for p in "/$ENT" "/"; do
  curl -s -o /dev/null -w "$p -> %{http_code}\n" -m 8 "$B$p"
done
echo
echo "=== 原有容器完好性 ==="
docker ps --format '{{.Names}} {{.Status}}'
echo
echo "=== 商店注册表 ==="
grep "^1panel|" /etc/kp_store/installed.list | cut -c1-120
echo
echo "=== 凭据文件权限 ==="
ls -la /root/1panel-credentials.txt
echo "=== DONE ==="

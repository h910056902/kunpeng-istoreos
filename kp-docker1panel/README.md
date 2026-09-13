# 鲲鹏路由器 Docker + 1Panel 一键安装（OpenWrt 21.02 / aarch64）

## SSH 一行命令安装（推荐）

在任意能连上路由器的终端执行（把 IP 换成你的路由器地址）：

```
ssh root@192.168.66.1 "wget -qO- https://raw.githubusercontent.com/h910056902/kunpeng-istoreos/main/kp-docker1panel/remote-install.sh | sh"
```

- 自动从 GitHub 拉取主脚本（三源回退：raw.githubusercontent.com → ghfast.top → gh-proxy.com），落盘 `/tmp` 后执行
- 自定义参数透传：`ssh root@192.168.66.1 "wget -qO- <同上URL> | PANEL_PORT=10091 sh"`
- 下载失败时可手动：PC 下载后 `pscp -scp install-docker-1panel.sh root@192.168.66.1:/tmp/`，再 SSH 执行 `sh /tmp/kp-install-docker-1panel.sh`

主脚本：`install-docker-1panel.sh`（全流程非交互、幂等，可重复执行）

## 本机可行性结论（2026-09-13 实测）

| 前提 | 结论 |
|---|---|
| 内核 5.4.281 kmod | mt7987 target 源有匹配的 `kmod-veth 5.4.281-1`（与内核包 hash 一致）|
| 内核内建 | BRIDGE_NETFILTER/OVERLAY_FS/MEMCG/NAMESPACES=内建，cgroup2 已挂载（controllers: cpuset cpu io memory pids）|
| musl 兼容 | 1Panel 官方 arm64 二进制**静态链接**（无 ld-linux INTERP），直接跑 |
| systemd 缺失 | 官方包自带 `initscript/1paneld.procd`（USE_PROCD=1, START=95）|
| Docker | 本机已装 dockerd 20.10.17（overlay2, 数据在 /mnt/storage/data/docker），脚本自动跳过重装 |

## 脚本五个阶段

1. **Stage 0 预检**：root / aarch64 / 数据分区 / bash / curl tar sha256sum
2. **Stage 1 Docker**：已装→校验；未装→`opkg install kmod-veth kmod-br-netfilter dockerd docker`；补 docker-compose、zoneinfo-asia；daemon.json 已存在则**不动**（保守策略）
3. **Stage 2 1Panel**：下载 v1.10.34-lts arm64（resource.fit2cloud.com 国内 CDN）→ checksums.txt SHA256 门禁 → 官方 init_configure 流程（/usr/local/bin/{1panel,1pctl} + /usr/bin 符号链接 + sed 写入端口/账号/入口到 1pctl）→ GeoIP → lang/zh → `1paneld.procd` 装成 procd 服务 → 启动等待门禁
4. **Stage 3 验证**：`1pctl version` + 入口 HTTP 200 门禁 + `docker info`
5. **Stage 4/5**：凭据写 `/root/1panel-credentials.txt`（600）；注册鲲鹏应用商店入口（installed.list + plugins.json 同步）

## 关键机制（为什么这样写）

- **1Panel 首次启动从 `/usr/local/bin/1pctl` 解析 `BASE_DIR`、`ORIGINAL_PORT/USERNAME/PASSWORD/ENTRANCE`** 初始化数据库（已用二进制 strings 验证），所以必须先 sed 再启动，顺序不能反
- 面板数据根选 `/mnt/storage/data`（eMMC p2, f2fs, 3.5G），避免占 4G overlay；官方默认 /opt 仅作回退
- 端口用 **10090**：10086=nr_webui、10087=kpwebui、10088=kp-quickstart-webui 均被占用
- 官方 install.sh 的 `configure_accelerator` 会**覆盖** /etc/docker/daemon.json（只留一个镜像源）——本机已有更优配置（1ms.run + daocloud + 日志轮转 + data-root），脚本明确不执行该步骤
- 当前 daemon.json 是 `"bridge":"none","iptables":false`（host 网络为主）。1Panel 商店里需要端口映射的应用会受影响；需要时设 `DOCKER_ENABLE_BRIDGE=1` 重跑，脚本会停 dockerd → `uciadd` 建 docker 防火墙区 → 切换 iptables=true

## 可覆盖参数（环境变量）

```
PANEL_PORT=10090  PANEL_BASE_DIR=/mnt/storage/data  PANEL_USERNAME=admin
PANEL_PASSWORD=auto  PANEL_ENTRANCE=auto
ONEPANEL_VERSION=v1.10.34-lts  ONEPANEL_CHANNEL=stable
DOCKER_ENABLE_BRIDGE=0  REGISTER_APPSTORE=1
```

## 日常运维

```
1pctl user-info                 # 面板地址/账号
1pctl update password           # 交互改密
/etc/init.d/1paneld restart     # 重启面板
logread | grep 1panel           # 日志（procd stderr -> syslog）
1pctl uninstall                 # 卸载（含 /mnt/storage/data/1panel 数据）
```

当前安装信息（2026-09-13）：`admin`，入口见 `/root/1panel-credentials.txt`。

## v2 修复记录（2026-09-13 晚，幂等重跑实测通过）

1. **[严重] 幂等路径凭据回填**：重跑时此前凭据变量仍是 `auto`，导致 Stage 3 HTTP 探测 404 误报失败、凭据文件被垃圾值覆盖。现从 `/usr/local/bin/1pctl` 回读真实 端口/用户/入口/密码（含转义反转义），凭据文件重写内容正确
2. **[bug] daemon.json 备份顺序**：原脚本在 `sed` 修改之后才 `cp` 备份（备份的是已改文件）；改为先备份后修改
3. **[bug] lang 目录嵌套**：`cp -r ./lang /usr/local/bin/lang` 在目标已存在时会复制成 `lang/lang`；先 `rm -rf` 再复制
4. **[bug] procd status 误判**：`grep -q running` 会误匹配 "not running"；改为行首匹配 `grep -q '^running'`
5. **[bug] 1pctl version 解析**：该命令输出两行（版本行+模式行），原 `tail -n1` 抓到模式行；改为正则提取 `v[0-9]...`
6. **[优化] docker-compose 安装失败 die→warn**（面板本身可用，仅应用商店部署受限）
7. **[优化] opkg update 失败 die→warn**（提示检查 distfeeds.conf / 换 aliyun 源）

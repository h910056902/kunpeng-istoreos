# 鲲鹏路由器 · iStoreOS 化（软件层面）

**iStoreOS 化**＝在**不刷 iStoreOS 整机固件**的前提下，把现有 **OpenWrt / 鲲鹏无限等类 OpenWrt** 系统，一键装上与 [gl-inet-onescript](https://github.com/wukongdaily/gl-inet-onescript) 同源的 **iStore 商店、Argon 主题、Quickstart、文件传输** 等，使 Web 管理界面与使用习惯**接近 iStoreOS**（组件化风格化，不是更换发行版）。

本仓库仅保留 **`kunpeng-istore.sh`**，并去掉 GL‑iNet 机型专用的换源、风扇、分区等逻辑，便于 **鲲鹏无限** 或其它第三方 OpenWrt 固件使用。

**NROS 搞机速查**（SSH 入口、主题页、App Center 路径、官方 `src/gz` 源）：见根目录 **`搞机手册.md`**。

## 前置条件

- 已开启 SSH，使用 **root** 登录。
- 路由器可访问外网（需拉取 `istore.linkease.com`、`raw.githubusercontent.com` 或 `mt3000.netlify.app` 等）。
- `opkg` 可用；建议先配置好与你固件 **架构一致** 的官方或镜像软件源。
- 脚本会**自动尝试安装** curl/wget、证书链、LuCI 与本地 IPK 常见依赖，并对 `opkg update` 做**约 30 分钟节流**。仅补依赖可执行：`sh kunpeng-istore.sh deps`。已手动更新源时可设：`KP_SKIP_OPKG_UPDATE=1`。

## 使用方式

### SSH 一行命令（推荐：等同全功能一键 `one`）

把下面**整行**里的 `脚本URL` 换成你托管的 `kunpeng-istore.sh` 的 **HTTPS 直链**（需可被路由器 wget/curl 访问，例如 GitHub **raw**、jsDelivr、Gitee raw、自建静态站）。用 **root** SSH 登录路由器后粘贴回车即可，无需先把文件拷进路由器：

```sh
(wget -T 45 -qO- '脚本URL' || curl -fsSL --connect-timeout 20 --max-time 120 '脚本URL') | sh -s one
```

**示例（把 `用户名` / `仓库名` / 分支改成你的）**：

- GitHub raw：`https://raw.githubusercontent.com/用户名/仓库名/main/kunpeng-istore.sh`
- jsDelivr：`https://cdn.jsdelivr.net/gh/用户名/仓库名@main/kunpeng-istore.sh`

国内若 raw 较慢，可在 URL 前加镜像前缀（自行替换为当前可用的 ghproxy 类地址）。

**路由器上已有一份脚本时**，可拉最新再一键（与上面管道效果相同）：

```sh
sh /root/kunpeng-istore.sh remote 'https://raw.githubusercontent.com/用户名/仓库名/main/kunpeng-istore.sh'
# 或
KP_SCRIPT_URL='https://...' sh /root/kunpeng-istore.sh remote
```

### Windows：PuTTY 一键推送到鲲鹏（默认 192.168.66.1）

在同一局域网内的 **Windows** 上安装 [PuTTY](https://www.putty.org/)（含 `plink.exe`、`pscp.exe`）后，在仓库目录打开 **PowerShell**：

```powershell
.\ssh-deploy-kunpeng.ps1
```

默认依次尝试 root 密码 **`password`**、**`admin`**，上传 `kunpeng-istore.sh` 到路由器并执行 **`sh /tmp/kunpeng-istore.sh one`**（一键 iStoreOS 化）。仅补依赖：

```powershell
.\ssh-deploy-kunpeng.ps1 -Action deps
```

指定密码（避免脚本里写死）：`$env:KP_ROUTER_PASS='你的密码'; .\ssh-deploy-kunpeng.ps1`

> 说明：云端环境无法访问你家 `192.168.66.1`，需在你**本机**运行上述脚本；首次连接会用 `echo y |` 接受 SSH 主机指纹。

### 本地拷贝再运行

将本仓库中的 `kunpeng-istore.sh` 拷贝到路由器（例如放到 `/root/`），执行：

```sh
chmod +x /root/kunpeng-istore.sh
sh /root/kunpeng-istore.sh
```

- 不带参数：进入 **交互菜单**；首次运行会尝试把脚本复制为 **`/usr/bin/kp`**，之后可在 shell 里直接输入 `kp`。
- 非交互一键（与管道 `sh -s one` 相同）：

```sh
sh /root/kunpeng-istore.sh one
# 或
sh /root/kunpeng-istore.sh install
```

紫色 Argon 观感（可选，与默认「官方 Argon 模板蓝紫」不同）：

```sh
KP_ARGON_PRESET=purple sh /root/kunpeng-istore.sh one
```

一行远程并带紫色预设（注意 `export`，否则管道内子 shell 可能读不到变量）：

```sh
export KP_ARGON_PRESET=purple; (wget -T 45 -qO- '脚本URL' || curl -fsSL '脚本URL') | sh -s one
```

完成后用浏览器打开 LuCI（地址一般为 `http://<LAN_IP>/cgi-bin/luci/`，若厂商使用 **8080** 等端口请自行替换）。

## 说明与致谢

- **主题与文件传输 IPK**：优先从 **[gl-inet-onescript 仓库 theme / luci-app-filetransfer 的 GitHub raw](https://github.com/wukongdaily/gl-inet-onescript)** 下载（与仓库内文件同源），失败再回退 `mt3000.netlify.app`（与上游 `gl-inet.sh` 一致）。**aarch64** 仍会优先用上游预置依赖 IPK，其它架构从当前 `opkg` 源补齐依赖。
- **「像素级」对齐**：脚本在安装 Argon 后写入 `/etc/config/argon`（默认与 [jerrykuku/luci-app-argon-config](https://github.com/jerrykuku/luci-app-argon-config) 官方默认一致）；对 Quickstart 追加与 gl-inet 同意图的 CSS，并尽量 `force-reinstall` 首页相关包。LuCI 大版本、DPI、厂商魔改仍可能造成视觉差分。
- **一键将 WAN 入站改为 ACCEPT** 与上游默认行为类似，但本脚本改为 **可选**（交互询问），以降低误暴露风险。
- 核心思路与资源归属：**[wukongdaily/gl-inet-onescript](https://github.com/wukongdaily/gl-inet-onescript)**；iStore 见 **[linkease/istore](https://github.com/linkease/istore)**。

## 原生应用中心（App Center）美化与在线商店增强

针对 NROS 自带的应用中心（`/cgi-bin/luci/nradioadv/system/appcenter`）与 iStore 商店（`/cgi-bin/luci/admin/store`）的增强，全部改动集中在 `patches/` 目录，按需执行（路由器密码建议用环境变量 `ROUTER_PW` 传入）：

| 脚本 | 作用 |
|---|---|
| `patches/istore-aurora-v1.css` + 部署逻辑 | iStore 商店「极光」暗色玻璃风格覆盖层 |
| `patches/fix_install_backend.py` / `fix_install_frontend.py` | 修复在线安装：后端真实返回执行结果、前端轮询进度/失败原因/重试 |
| `patches/patch_backend_tags.py` | 在线列表接口补充 `tags` / `time` 字段 |
| `patches/build_depcache.py` + `patch_list_depcache.py` | 依赖可安装性预检：装不上的应用直接标「不兼容」并给出缺依赖原因 |
| `patches/patch_register.py` + `patch_ver_fix.py` | **在线安装的应用自动注册进原生商店**：出现在「已安装」列表，带图标、入口路由、支持打开/卸载 |
| `patches/e2e_full_flow.py` | 端到端回归：安装 → 轮询 → 注册 → 卸载 → 移除 全链路验证 |

注册机制说明：原生商店列表来自 `ubus appcenter list`，在线安装的包不会出现在其中。补丁在 `action_app_list_data` 里把 `opkg list-installed` 中已装的 `app-meta-*` 包与 iStore 在线仓库元数据（`/tmp/istore_online_cache.json`）合并进列表，并对未注册到 ubus 的应用本地处理卸载/打开动作，图标自动从 iStore CDN 下载到 `/www/luci-static/nradio/images/icon/online-<pkg>.png`。


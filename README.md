# 鲲鹏路由器 · 一键 iStoreOS 化 + 商店美化增强

> **一句话介绍**：不刷机、不改固件，通过一个 Shell 脚本 + 一组 Python 补丁，让你的 **鲲鹏无限（NROS）** 或其它 OpenWrt 路由器拥有 **iStore 商店、Argon 主题**，并顺手修好原生「应用中心」在线安装的一堆坑。

- 仓库地址：<https://github.com/h910056902/kunpeng-istoreos>
- 适用设备：鲲鹏无限 NROS（如 192.168.66.1），以及其它类 OpenWrt 固件
- 难度：会 SSH 登录路由器即可，全程复制粘贴

---

## 一、这套东西能干什么

| 模块 | 效果 |
|---|---|
| `kunpeng-istore.sh` 一键脚本 | 安装 iStore 商店、Argon 主题、Quickstart、文件传输，让界面和使用习惯接近 iStoreOS（**不是刷 iStoreOS 固件**，只是装组件） |
| iStore 商店「极光」主题 | 暗色玻璃风格 CSS 覆盖层，替换默认界面 |
| 应用中心在线安装修复 | 原生「应用中心 → 在线应用」点安装时：显示真实进度、失败原因、可重试，不再静默失败 |
| 依赖预检 | 装不上的应用直接标「不兼容」并说明缺什么依赖，不浪费你时间 |
| 安装自动注册 | 从在线应用装好的程序，**自动出现在原生商店「已安装」列表**，带图标、可打开、可卸载 |
| 列表优化 | 在线应用支持分类筛选、按更新时间排序、不兼容的沉底显示 |

改造思路源自 [wukongdaily/gl-inet-onescript](https://github.com/wukongdaily/gl-inet-onescript)（GL-iNet 版），本仓库去掉了 GL 机型专用逻辑，适配鲲鹏无限等第三方固件。

---

## 二、准备工作

1. 路由器已开启 SSH，能以 **root** 登录（鲲鹏无限默认地址 `192.168.66.1`）。
2. 路由器能上网（需访问 `istore.linkease.com`、`raw.githubusercontent.com` 等）。
3. `opkg` 可用，建议先配好与固件**架构一致**的软件源。

> NROS 的 SSH 入口、主题页、App Center 路径、官方源等速查信息，见根目录 **`搞机手册.md`**。

---

## 三、怎么用（三选一）

### 方式 1：SSH 一行命令（推荐，最简单）

用 root SSH 登录路由器，把下面整行粘贴执行（先把 `脚本URL` 换成 `kunpeng-istore.sh` 的 HTTPS 直链，例如你自己的 GitHub raw 地址）：

```sh
(wget -T 45 -qO- '脚本URL' || curl -fsSL --connect-timeout 20 --max-time 120 '脚本URL') | sh -s one
```

URL 示例（把 `用户名/仓库名` 换成你自己的）：

- GitHub raw：`https://raw.githubusercontent.com/用户名/仓库名/main/kunpeng-istore.sh`
- jsDelivr：`https://cdn.jsdelivr.net/gh/用户名/仓库名@main/kunpeng-istore.sh`

脚本执行完，浏览器打开 `http://<路由器IP>/cgi-bin/luci/` 即可看到新界面。

### 方式 2：Windows 一键推送（PuTTY）

适合不想手敲 SSH 命令的 Windows 用户。在同一局域网的电脑上装好 [PuTTY](https://www.putty.org/)（含 `plink.exe`、`pscp.exe`），在仓库目录打开 PowerShell：

```powershell
.\ssh-deploy-kunpeng.ps1              # 上传脚本并执行一键安装
.\ssh-deploy-kunpeng.ps1 -Action deps # 只补依赖
$env:KP_ROUTER_PASS='你的密码'; .\ssh-deploy-kunpeng.ps1  # 指定密码（默认依次尝试 password / admin）
```

### 方式 3：本地拷贝再运行

把 `kunpeng-istore.sh` 拷到路由器（如 `/root/`）：

```sh
sh /root/kunpeng-istore.sh            # 交互菜单（首次运行会注册 kp 命令，之后直接输 kp）
sh /root/kunpeng-istore.sh one        # 非交互一键安装
KP_ARGON_PRESET=purple sh /root/kunpeng-istore.sh one   # 可选：紫色 Argon 皮肤
```

---

## 四、应用中心增强补丁（patches/ 目录）

上面的脚本装好 iStore 后，如果还想修复/增强**原生应用中心**的在线安装功能，按需在**本机**运行以下 Python 补丁（会自动 SSH 到路由器打补丁；路由器密码建议用环境变量 `ROUTER_PW` 传入，不要写死）：

| 补丁 | 干什么 | 说明 |
|---|---|---|
| `istore-aurora-v1.css` | iStore 商店换「极光」暗色皮肤 | 部署到 `/www/luci-static/istore/` |
| `fix_install_backend.py` | 修后端 | 安装接口返回真实结果，新增进度轮询和安装前预检接口 |
| `fix_install_frontend.py` | 修前端 | 安装按钮显示进度/失败原因，支持重试 |
| `build_depcache.py` | 建依赖缓存 | 解析 opkg 索引，算出哪些应用当前架构装得上 |
| `patch_list_depcache.py` | 列表预检 | 装不上的应用标「不兼容」+ 缺依赖原因，且沉底排序 |
| `patch_backend_tags.py` | 列表增强 | 在线列表接口补充分类 `tags`、更新时间 `time` 字段 |
| `patch_register.py` | **自动注册** | 在线装好的应用自动进原生商店「已安装」列表，带图标和入口 |
| `patch_ver_fix.py` | 修版本号 | 注册时从 opkg 输出正确解析版本号 |
| `e2e_full_flow.py` | 端到端测试 | 安装 → 轮询 → 注册 → 卸载 → 移除，全链路自检 |

**自动注册的原理**（给想看懂的人）：原生商店的应用列表来自 `ubus appcenter list`，而通过 iStore 在线安装的 `app-meta-*` 包并不在其中。补丁在后端把 `opkg list-installed` 中的已装 `app-meta-*` 与 iStore 在线缓存（`/tmp/istore_online_cache.json`）合并进列表；对未注册到 ubus 的应用，本地处理卸载/打开动作；图标自动从 iStore CDN 下载到 `/www/luci-static/nradio/images/icon/online-<pkg>.png`。

> ⚠️ 已知限制：部分缓存写在路由器的 `/tmp`，**重启后会丢失**（如依赖预检缓存），重跑对应补丁脚本即可恢复。

---

## 五、Are-u-ok 插件接入（AUK9527 仓库一键装）

[Are-u-ok](https://github.com/AUK9527/Are-u-ok) 是 iStore 生态知名的 .run 自解压插件合集（PassWall、OpenClash、KMS、AdGuard Home 等）。本仓库提供 `patches/areuok_plugin.py`，把它的插件**一键装进鲲鹏原生应用商店**：安装后自动登记、带图标出现在「已安装」列表、可直接在商店里卸载。

```bash
cd patches
python areuok_plugin.py list                 # 列出可安装的 11 个插件
python areuok_plugin.py install kms          # 一键安装（自动下载 .run → 安装 → 注册进商店）
python areuok_plugin.py status               # 查看已装清单
python areuok_plugin.py uninstall kms        # 卸载并从商店注销
python areuok_plugin.py e2e                  # 端到端自检：安装→验证→商店卸载→验证
```

可用插件：`kms`、`nps`、`openclash`、`openvpn-client`、`openvpn-server`、`adguardhome`、`mosdns`、`unblockneteasemusic`、`ssr-plus`、`passwall`、`passwall2`

工作机制（给想看懂的人）：

1. `patches/kp-areuok.sh` 部署到路由器 `/usr/bin/kp-areuok`，负责按架构（`apps/all` = aarch64，`x86/all` = x86_64）从 GitHub raw 下载 .run（支持 `AREUOK_MIRROR` 加速前缀），执行 makeself 自解压安装。
2. 安装后把插件信息写入 `/etc/areuok_registry.list`（**持久化，重启不丢**）。
3. 商店后端新增 `areuok_installed_merge`：把注册表里仍处于已安装状态的插件合并进原生商店列表（图标优先复用 iStore 在线缓存）；卸载动作分发到 `kp-areuok uninstall`。

说明：卸载只移除插件本体的 ipk，`.run` 安装过程中自动补的依赖（如 node）会保留，避免误伤其他程序；PassWall 与 SSR-Plus 勿同时安装（上游说明）。

已验证：`kms`（已装场景）与 `unblockneteasemusic`（全新安装 + 自动补依赖场景）端到端全部 PASS，包括商店内一键卸载。

### NROS 固件 LuCI 页面 404 兼容（menu.d 垫片）

⚠️ **NROS 固件的 LuCI dispatcher 不支持 menu.d（view 类型）应用**，因此 Are-u-ok 里 `luci-app-unblockneteasemusic`、以及固件上其他 menu.d 应用（frpc/frps/ddns-go 等）安装后页面都会 404。本仓库为网易云插件提供了经典 Lua/CBI 垫片：

```bash
cd patches
python unm_luci_shim.py   # 部署经典控制器，恢复「服务 → 云音乐解锁」页面
```

垫片内容见 `patches/unm_luci_shim/`（controller.lua + model.lua，CBI 配置页支持启用开关、音源、替换策略、端口、劫持方式等，保存后自动重启服务）。网易云插件额外步骤：装完需在页面里**勾选「启用服务」**（上游默认 `enable=0` 不会自启）。

**手机端使用方法**：手机连上路由器 WiFi 后，把代理设为 `192.168.66.1:5200`（HTTP）；或在浏览器打开 `http://192.168.66.1:5200/proxy.pac` 按说明配置。之后播放网易云音乐灰色/无损歌曲即可走解锁通道。

**解锁效果已实测**（周杰伦《晴天》id=186016，VIP 灰色歌曲）：直连网易云 API 返回 `url:null, code:404`；经 `192.168.66.1:5200` 代理调用同一 API，返回 `code:200, type:flac, br:999000`，音源自动替换为 kuwo 无损；随后经代理拉取完整文件 55.4MB，文件头 `fLaC`，为真实无损音频。注意：解锁重写发生在网易云「取歌曲地址 API」层面，直接 curl 访问 `song/media/outer/url` 跳转不会体现解锁效果，需以客户端/API 实测为准。

---

## 五、常见问题

**Q：改了 Lua 之后页面没变化？**
LuCI 有模块缓存，SSH 上去清一下再刷新：

```sh
rm -rf /tmp/luci-modulecache /tmp/luci-indexcache
```

**Q：WAN 口入站会被放开吗？**
不会自动放开。上游脚本默认放开 WAN 入站，本仓库改成了**交互询问（可选）**，降低误暴露风险。

**Q：Argon 装完观感和预期不一样？**
脚本会写入 `/etc/config/argon`，默认对齐 [luci-app-argon-config](https://github.com/jerrykuku/luci-app-argon-config) 官方默认值；LuCI 大版本、DPI、厂商魔改仍可能造成视觉差异。

---

## 七、目录速览

```
├── kunpeng-istore.sh          # 一键 iStoreOS 化脚本（核心）
├── ssh-deploy-kunpeng.ps1     # Windows 一键推送脚本
├── sync-opkg-offline-from-pc.ps1  # opkg 离线源同步
├── 搞机手册.md                # NROS 速查手册（SSH/路径/源）
├── patches/                   # 应用中心增强补丁（见第四节表格）
├── assets/                    # 离线应用/恢复辅助脚本
├── openwrt/                   # 静态主题资源（css/js）
└── router_backup/             # 路由器配置备份
```

---

## 致谢

- 核心思路与资源：[wukongdaily/gl-inet-onescript](https://github.com/wukongdaily/gl-inet-onescript)
- iStore：[linkease/istore](https://github.com/linkease/istore)
- Argon 主题：[jerrykuku/luci-app-argon-config](https://github.com/jerrykuku/luci-app-argon-config)

# PassWall2 · sing-box only (Xray removed)

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-21.02%2B-blue)](https://openwrt.org/)

个人自用的 [PassWall2](https://github.com/Openwrt-Passwall/openwrt-passwall2) 复刻：**剔除 Xray**，
代理核心只保留 sing-box / Shadowsocks-Rust / ShadowsocksR，其余功能与上游一致，并且每天自动跟随上游更新。

A personal fork of [Openwrt-Passwall/openwrt-passwall2](https://github.com/Openwrt-Passwall/openwrt-passwall2)
with **all Xray support removed**; everything else tracks upstream and is re-synced daily.

## 与上游的区别

| 项目 | 说明 |
| --- | --- |
| Xray | 组件、客户端/服务端节点类型、`util_xray.lua`、`run_xray()`、`xray-core` 依赖全部删除，全仓无 `xray` 代码 |
| 组件更新页 | 顺序 Geoview → Sing-Box → Passwall2，`【 版本 】` 列、按钮与标签对齐、表单居中、小号按钮；删掉 `/tmp` 红字提示与反向代理说明 |
| 自更新地址 | Passwall2 的「检查更新」指向本仓库的 releases |
| 发布包 | 精简发布：只发主包和中文语言包（共 4 个文件），不带 13 个架构依赖包；依赖在安装时从上游同版本 release 按需取用 |
| 日志 | 运行日志固定 13px 等宽字体，不随主题变化 |
| 默认配置 | 随包附带一份实机模板（DNS/转发/分流规则齐全，**不含真实节点**，保留「精准分流」分流节点） |
| 恢复默认配置 | 用上面这份模板重写配置：保留设置与分流节点，丢弃真实节点，复位后需手动启动服务 |

细节见 [FORK-NOTES.md](FORK-NOTES.md)。

## 安装

**一键安装 / 更新**

```bash
curl -fsSL --retry 3 -o /tmp/pw2.sh https://raw.githubusercontent.com/lima-droid/openwrt-passwall2/main/install.sh && sh /tmp/pw2.sh
```

也可以直接 `sh -c "$(curl -fsSL ...)"`，但网络抖动时上面这种「先下载再执行」的写法会明确报
`下载失败`，而不是静默什么都不做。

脚本只从本仓库最新 release 取两样东西：`luci-app-passwall2` 主包和
`luci-i18n-passwall2-zh-cn` 中文语言包（release 就这 4 个文件，没有其他语言包，也没有
架构依赖包）。运行依赖由脚本现场补齐：sing-box 核心优先用系统软件源，找不到时再从
sing-box 官方 release 下载对应架构的静态二进制；tcping、geoview、v2ray-geoip、
v2ray-geosite 等则从上游同 tag 的 `packages_<ipk|apk>_<架构>.zip` 里按需取出安装，
只装点名的包，`xray-core` 永远不会被安装。已有 `/etc/config/passwall2` 会保留；
首次安装会生成默认配置。

直接下载的 release 资产必须通过 GitHub API 提供的 SHA-256 校验。`gh-proxy.com` 和
`ghfast.top` 只用于传输资产，API 与摘要始终直连 `api.github.com`；脚本不会关闭 TLS
证书校验，也不会安装摘要缺失或校验失败的包。API 被限流时会中止，可稍后重试。

| 参数 | 作用 |
| --- | --- |
| 无 | 安装 / 更新到最新 release |
| `--check` | 只检查版本、下载并校验包、检查核心与依赖，不安装 |
| `--version 26.11.3-1` | 安装指定版本 |
| `--force` | 已是最新也重装 |
| `--unlock` | 清理残留的安装锁 |
| `--uninstall` | 零残留卸载：配置、包、文件、服务、定时任务和防火墙规则全部删除 |
| `--purge` | 同 `--uninstall`，保留旧参数兼容 |

用 `curl | sh` 形式时这样传参：

```bash
curl -fsSL https://raw.githubusercontent.com/lima-droid/openwrt-passwall2/main/install.sh | sh -s -- --check
```

零残留卸载：

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/lima-droid/openwrt-passwall2/main/install.sh)" sh --uninstall
```

如果 `raw.githubusercontent.com` 报 `TLS connect error`，换镜像取同一份脚本：

```bash
curl -fsSL -o /tmp/pw2.sh https://gh-proxy.com/https://raw.githubusercontent.com/lima-droid/openwrt-passwall2/main/install.sh
sh /tmp/pw2.sh
```

脚本内部下载 release 资产时也会自动在 `github.com` → `gh-proxy.com` → `ghfast.top` 之间回退，
但每个下载文件都必须匹配 GitHub API 的 SHA-256。
上次安装被中断留下的锁会被识别为失效并自动清理，确实卡住时也可以 `sh install.sh --unlock`。

**手动安装**

从 [Releases](../../releases/latest) 下载主包和中文语言包即可，两者都是 `all` 架构。
release 里没有可执行核心，也没有架构依赖包：手动安装时还需确保 `/usr/bin/sing-box` 可用，
软件源没有时从 [sing-box 官方 Release](https://github.com/SagerNet/sing-box/releases)
选择匹配架构的 musl 静态包；tcping、geoview 等依赖可从软件源或上游同版本 release 的
`packages_<ipk|apk>_<架构>.zip` 里取。

**opkg（OpenWrt 23.05 及更早 / iStoreOS）**

```bash
opkg update
opkg install luci-app-passwall2_<版本>_all.ipk
# 需要中文界面再装：luci-i18n-passwall2-zh-cn_<版本>_all.ipk
```

**apk（OpenWrt 24.10+）**

```bash
apk add --allow-untrusted luci-app-passwall2-<版本>-r1.apk
# 语言包：luci-i18n-passwall2-zh-cn-<版本>.apk
```

手动下载本地包时，先用 GitHub API 的 `digest: sha256:...` 或官方校验值确认文件，再用
`sha256sum` 核对。`--allow-untrusted` 只适用于已经核验过的本地包。

装完刷新 LuCI（或 `/etc/init.d/uhttpd restart`）。首次安装的配置就是上面那份默认模板。

## 协议支持

Hysteria2、TUIC、AnyTLS、WireGuard、SSH、VMess、VLESS、Trojan、Shadowsocks、ShadowsocksR
均通过 sing-box / SS-Rust / SSR 提供；Xray 专属的 xhttp、mkcp 等传输方式随 Xray 一起移除。

## 自动同步上游

本仓库不是用 merge 跟随上游，而是每次从上游原始树重新生成（见 `tools/strip_xray.py`）：

```
上游 main → strip_xray.py（带断言的重写）→ check_tree.py（无 xray / Lua 语法 / JSON）→ 提交
```

`.github/workflows/sync-upstream.yml` 每天 03:17 UTC 跑一次；上游改动导致某条规则失效时，
它不会破坏仓库，而是开一个 `sync-failure` issue 说明是哪条规则、哪个文件需要更新。
同步成功后会自动派发构建，不需要手动操作。

## 发布

构建只保留 `job_check` 和 `job_build_passwall2`，每次 release 固定 4 个文件：

```
luci-app-passwall2-<版本>-r1.apk
luci-app-passwall2_<版本>-r1_all.ipk
luci-i18n-passwall2-zh-cn-<版本>.apk
luci-i18n-passwall2_<版本>_all.ipk
```

不再自己编译 13 个架构的依赖包（那是构建耗时和失败的主要来源），安装时按架构从上游同版本
release 取，只装需要的包。每天 12:30 还有一个巡检任务：同步或构建失败时自动修规则、重跑，
修不动才在 issue 里留给你。

## 许可

GPL-3.0，与上游一致。所有上游版权声明均保留，代码版权归
[Openwrt-Passwall](https://github.com/Openwrt-Passwall/openwrt-passwall2) 及原作者所有。

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
| 日志 | 运行日志固定 13px 等宽字体，不随主题变化 |
| 默认配置 | 随包附带一份实机模板（DNS/转发/分流规则齐全，**不含真实节点**，保留「精准分流」分流节点） |
| 恢复默认配置 | 用上面这份模板重写配置：保留设置与分流节点，丢弃真实节点，复位后需手动启动服务 |

细节见 [FORK-NOTES.md](FORK-NOTES.md)。

## 安装

从 [Releases](../../releases/latest) 下载与路由器架构对应的包。

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

## 许可

GPL-3.0，与上游一致。所有上游版权声明均保留，代码版权归
[Openwrt-Passwall](https://github.com/Openwrt-Passwall/openwrt-passwall2) 及原作者所有。

# openwrt-passwall2 — sing-box / SS / SSR only (Xray removed)

Personal fork of [Openwrt-Passwall/openwrt-passwall2](https://github.com/Openwrt-Passwall/openwrt-passwall2)
with **all Xray support removed**. Everything else follows upstream.

## What is different from upstream

| Area | Change |
| --- | --- |
| LuCI app-update component | `com.lua`: the `Xray` component (XTLS/Xray-core) is gone; only geoview + sing-box remain |
| Client node type | `type/2_xray.lua` deleted, so "Xray" is not selectable as a node type |
| Server node type | `server/type/2_xray.lua` deleted |
| Config generator | `util_xray.lua` deleted; `server_app.lua` and `app.sh` only start sing-box / SS / SSR |
| Subscription import | `subscribe.lua` no longer targets Xray for SS / VMess / VLESS / Trojan / Hysteria2; only sing-box |
| Global settings | the `Xray Settings` section, `global_xray` uci section and `xray_noise_packets` are gone |
| Package deps | Makefile no longer selects `xray-core`; the "Basic Core" choice is sing-box only |
| Default config | `0_default_config` ships sing-box sample nodes, no `xray_file` |
| CI package list | `xray-core` removed from the SDK build list |
| Translations | `.po` entries that only described Xray are dropped; reworded UI strings fall back to English until upstream/luCI regenerates them |
| Docs | Xray removed from README feature lists and install notes |

Hysteria2, TUIC, AnyTLS, WireGuard, SSH, VMess, VLESS, Trojan, Shadowsocks and ShadowsocksR
keep working through sing-box — these are sing-box features, not Xray ones.

## UI tweaks on top of upstream

Applied by `tools/strip_xray.py` (`rules_fork_ui`), so they survive every sync:

- **Default config** (`root/usr/share/passwall2/0_default_config`)
  - the fork ships its own settings template (kept in `tools/ui/0_default_config`),
    taken from a real working config and stripped of every node entry
  - `reset_config` restores that template but filters out `config nodes` blocks and
    `option node` lines, and prefers `/etc/passwall2_template.conf` when present
    (so a device-local template survives package upgrades)
- **Component update page** (`app_update.lua`, `app_version.htm`)
  - rows ordered Geoview → Sing-Box → Passwall2, Xray row gone
  - fixed label column, so all "Check update" buttons line up
  - form centred in a 40rem column, two blank lines of padding at the bottom
  - the "run from /tmp" red hint and the GitHub-proxy description removed
  - Passwall2 update check points at `lima-droid/openwrt-passwall2` releases
- **Log pages** (`log/log.htm`, `server/log.htm`)
  - log textarea pinned to 12px monospace so the theme cannot blow it up

## How upstream updates are pulled in

This fork is **not** a merge of upstream. Resolving merge conflicts in ~25 rewritten files
every week would be unmaintainable, so the fork is re-derived from upstream on every sync:

```
upstream tree  --tools/strip_xray.py-->  fork tree
```

`tools/strip_xray.py` is a deterministic rewriter with assertions. Each rule anchors on
current upstream text; if upstream moves that code, the script fails loudly with the file
and the rule instead of silently generating a broken package.

Daily sync is done by `.github/workflows/sync-upstream.yml`:

1. clone upstream `main`
2. run `tools/strip_xray.py` on the clone
3. run `tools/check_tree.py` (no remaining `xray` references, every `.lua` parses,
   every `.json` is valid)
4. `rsync` the result over this repo (keeping `tools/`, `FORK-NOTES.md`, the sync workflow)
5. commit + push, or open an issue labelled `sync-failure` when a rule no longer matches

### When the sync job fails

The issue names the failing rule, e.g.

```
luci-app-passwall2/luasrc/passwall2/com.lua: regex hit 0 time(s), expected 1
  pattern: _M\.xray = \{.*?\n\}\n\n
```

Run the script locally to reproduce:

```bash
git clone https://github.com/Openwrt-Passwall/openwrt-passwall2.git /tmp/upstream
python3 tools/strip_xray.py /tmp/upstream
python3 tools/check_tree.py /tmp/upstream
```

Fix the rule in `tools/strip_xray.py` (usually an anchor that moved), commit, then re-run
the workflow (`Actions -> Sync upstream -> Run workflow`).

## Local checks

```bash
python3 -m pip install luaparser
python3 tools/strip_xray.py /tmp/upstream   # rewrite a pristine upstream copy
python3 tools/check_tree.py /tmp/upstream   # assertions
```

## Build

Same as upstream: drop this repo into an OpenWrt buildroot `package/` and select
`luci-app-passwall2`. The dependency `sing-box` is selected by the package config.

## License

GPL-3.0, same as upstream. All upstream copyright notices are preserved.

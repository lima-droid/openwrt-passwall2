# Repository Instructions

These instructions are mandatory for every change in this repository.

## Project Goal

This repository is a daily-synced fork of:

```text
Openwrt-Passwall/openwrt-passwall2
```

The required result is:

1. Keep package versions exactly equal to upstream.
2. Remove the Xray core and all Xray-only code.
3. Preserve the fork's component-update UI, log styling, and reset template.
4. Build a lean release: main APK/IPK plus the `zh-cn` language pack only;
   architecture dependency bundles come from the upstream release at install
   time.
5. Point install/update operations at this fork.
6. Keep install, update, and zero-residue uninstall automated and reproducible.

Do not add unrelated features or redesign working upstream components.

## Source Ownership

Fork-owned files and directories:

```text
install.sh
AGENTS.md
FORK-NOTES.md
tools/
.github/workflows/sync-upstream.yml
.github/workflows/Auto compile with openwrt sdk.yml
```

The generated application tree is:

```text
luci-app-passwall2/
```

Never make a persistent change only in the generated application tree when the
same change must survive upstream sync. Put the transformation rule in:

```text
tools/strip_xray.py
```

and then update the generated tree as well.

The build workflow is fork-owned and must not be copied from upstream during
sync. GitHub's built-in `GITHUB_TOKEN` cannot push changes to workflow files
unless the workflow push originates from a token with the dedicated Workflows
permission. Keeping this file fork-owned prevents successful source syncs from
failing at the final push step.

## Required Fork Customizations

The following upstream-sync transformations must always remain:

- Remove Xray UI types, runtime code, package selection, commands, and strings.
- Component updates point PassWall2 at:
  `lima-droid/openwrt-passwall2`
- Preserve the component-update layout in `tools/ui/app_version.css`.
- Keep client and server log output at 13px monospace.
- Keep reset-template behavior that preserves only `_shunt` nodes and drops real
  proxy nodes/subscriptions.
- Use `tools/ui/0_default_config` as the source reset template.

Do not remove or alter these customizations unless the user explicitly asks.

## Upstream Sync Rules

Sync means re-deriving the tree from a fresh upstream checkout:

```text
clone latest upstream
-> run tools/strip_xray.py
-> run tools/check_tree.py
-> copy generated tree while preserving fork-owned files
```

Do not replace this with a Git merge.

Package versions must remain identical to upstream. Do not bump
`PKG_VERSION` or `PKG_RELEASE` unless the user explicitly requests a divergent
version.

The release tag format is upstream version plus release, for example:

```text
tag:     26.11.3-1
IPK:     26.11.3-r1
APK:     26.11.3-r1
```

## Build And Release Rules

- Use the standard OpenWrt SDK GitHub Actions workflow.
- Lean release only: `job_check` and `job_build_passwall2`. The 13-architecture
  `job_auto_compile` matrix was removed on purpose; do not bring it back unless
  the user asks for the full dependency bundles again.
- Do not handcraft release packages on Windows.
- Same-version rebuilds must use `-f force=true` and overwrite release assets.
- Installer dependency ZIP preference:
  1. This fork's matching Release.
  2. Same-version upstream architecture ZIP as a temporary fallback.
  3. System package feed only as a final fallback.
- The upstream fallback may extract only the requested runtime packages and must
  never install `xray-core`.
- Do not delete or recreate a Release/Tag without explicit user approval.
- Do not leave failed, cancelled, or warning-only runs in the final history.

## Installer Rules

`install.sh` is the single lifecycle entry point:

```text
1 install
2 update
3 status
4 zero-residue uninstall
0 exit
```

- Installation and update must work without manual dependency installation.
- Uninstall must remove package files, dependencies, configuration, LuCI,
  rpcd, ucitrack, init/hotplug, cron entries, logs, temp data, firewall UCI,
  nftables/ipset/iptables state, and iStoreOS backup copies.
- Explicitly remove both:

```text
/etc/config/passwall2
/etc/config/passwall2_server
```

- Uninstall must work when invoked through
  `sh -c "$(curl ...)"`. Never kill the installer's own process through broad
  `pgrep -f passwall2` cleanup.
- Preserve aligned, equal-width output labels and the established menu text.

## Change Discipline

- Make the smallest change that satisfies the request.
- Do not modify CI runners, matrix jobs, release automation, or packaging flow
  unless that is the requested task.
- Do not change unrelated files.
- Do not store credentials, tokens, node addresses, UUIDs, passwords, or private
  keys in the repository.
- Preserve user changes in a dirty worktree.

## Validation

Before committing any sync or transformation change, validate a fresh upstream
clone:

```bash
git clone --depth 1 https://github.com/Openwrt-Passwall/openwrt-passwall2.git /tmp/upstream
python3 tools/strip_xray.py /tmp/upstream
python3 -m pip install --quiet luaparser
python3 tools/check_tree.py /tmp/upstream
```

Validate scripts and workflows:

```bash
sh -n install.sh
sh -n luci-app-passwall2/root/usr/share/passwall2/iptables.sh
sh -n luci-app-passwall2/root/usr/share/passwall2/nftables.sh
actionlint ".github/workflows/Auto compile with openwrt sdk.yml"
git diff --check
```

For installer changes:

- Test `--status` as a read-only check.
- Test menu display and cancellation paths.
- Test zero-residue uninstall only when the user has explicitly approved it.
- After uninstall, independently verify packages, config, processes, UCI,
  nftables, and `/tmp` contain no PassWall2 residue.

Do not claim completion until the build is successful and the Release contains
the expected main package and language packs.

## Git

- Use focused Conventional Commit messages.
- Keep the working tree clean after committing.
- Do not push unless the user asks to push.
- Never force-push or rewrite published history unless explicitly requested.

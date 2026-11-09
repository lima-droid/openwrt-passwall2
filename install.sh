#!/bin/sh
#
# PassWall2 一键安装 / 更新脚本（lima-droid/openwrt-passwall2 分支）
#
# 安装 / 更新 / 卸载 PassWall2。安装时从本仓库 Release 获取主包、中文语言包，
# 自动补齐 sing-box 和依赖；卸载时删除配置、运行状态、防火墙规则和所有专用文件。
#
# 用法：
#   sh install.sh                 # 打开安装 / 更新 / 状态 / 卸载菜单
#   sh install.sh --check         # 只检查（查版本、验证资源可下载），不安装
#   sh install.sh --version TAG   # 安装指定版本，例如 --version 26.11.3-1
#   sh install.sh --force         # 版本相同也重装
#   sh install.sh --unlock        # 清理残留的安装锁
#   sh install.sh --uninstall     # 零残留卸载（兼容 --purge）
#   sh install.sh --purge         # 同 --uninstall
#   sh install.sh --help          # 显示说明
#
# 一行执行：
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/lima-droid/openwrt-passwall2/main/install.sh)"
#
set -eu

REPO="lima-droid/openwrt-passwall2"
API="https://api.github.com/repos/$REPO/releases"

PKG_MAIN="luci-app-passwall2"
PKG_I18N="luci-i18n-passwall2-zh-cn"
DEPS="tcping geoview v2ray-geoip v2ray-geosite"
CORE_PKG="sing-box"

LOCKDIR="/tmp/passwall2-install.lock"
STATE_FILE="/etc/passwall2-installer.state"
TMPFILES=""
LOCK_OWNED=0
LOCK_TOKEN=""
MODE="install"
TAG=""
FORCE=0
ARG_COUNT="$#"
UPDATE_ONLY=0

log()  { printf '%s\n' "==> $*"; }
warn() { printf '%s\n' "[WARN] $*" >&2; }
die()  { printf '%s\n' "[ERROR] $*" >&2; exit 1; }

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RESET="$(printf '\033[0m')"
	C_BOLD="$(printf '\033[1m')"
	C_CYAN="$(printf '\033[36m')"
	C_GREEN="$(printf '\033[32m')"
	C_YELLOW="$(printf '\033[33m')"
	C_RED="$(printf '\033[31m')"
else
	C_RESET=""; C_BOLD=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

ui_rule() {
	printf '%s\n' "${C_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
}

ui_title() {
	printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$1" "$C_RESET"
	ui_rule
}

ui_kv() {
	printf '  %s：%s\n' "$1" "$2"
}

usage() {
	cat <<'EOF'
用法:
  sh install.sh                 # 打开管理菜单
  sh install.sh --install       # 直接安装
  sh install.sh --update        # 直接更新
  sh install.sh --status        # 查看状态
  sh install.sh --check         # 只检查，不安装
  sh install.sh --version TAG   # 安装指定版本（如 26.11.3-1）
  sh install.sh --force         # 已是最新也重装
  sh install.sh --unlock        # 清理残留的安装锁
  sh install.sh --uninstall     # 零残留卸载（含配置和防火墙）
  sh install.sh --purge         # 同 --uninstall
EOF
}

release_lock() {
	if [ "$LOCK_OWNED" = 1 ] && [ -f "$LOCKDIR/owner" ] &&
		[ "$(cat "$LOCKDIR/owner" 2>/dev/null || true)" = "$LOCK_TOKEN" ]; then
		rm -rf "$LOCKDIR"
	fi
	LOCK_OWNED=0
}

cleanup() {
	release_lock
	for f in $TMPFILES; do
		rm -rf "$f" 2>/dev/null || true
	done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

register_tmp() { TMPFILES="$TMPFILES $1"; }

while [ "$#" -gt 0 ]; do
	case "$1" in
		--check) MODE="check" ;;
		--install) MODE="install" ;;
		--update) MODE="update"; UPDATE_ONLY=1 ;;
		--status) MODE="status" ;;
		--version)
			[ "$#" -ge 2 ] || die "--version 需要一个参数"
			TAG="$2"
			shift
			;;
		--force) FORCE=1 ;;
		--unlock) MODE="unlock" ;;
		--uninstall) MODE="uninstall" ;;
		--purge) MODE="purge" ;;
		-h|--help) usage; exit 0 ;;
		*) die "未知参数: $1（--help 查看用法）" ;;
	esac
	shift
done

if [ "$ARG_COUNT" -eq 0 ] && [ -t 0 ]; then
	MODE="menu"
fi

# ---------- 包管理器 ----------
if command -v apk >/dev/null 2>&1 && [ -s /lib/apk/db/installed ]; then
	PM=apk
elif command -v opkg >/dev/null 2>&1; then
	PM=opkg
else
	die "未检测到 opkg 或 apk"
fi
case "$PM" in
	opkg) EXT=ipk ;;
	apk) EXT=apk ;;
esac

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }
for c in sed grep awk head basename mktemp sha256sum; do need_cmd "$c"; done
require_downloader() {
	if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
		die "缺少 curl 或 wget"
	fi
}
case "$MODE" in
	install|update|check) require_downloader ;;
esac

[ -f /etc/openwrt_release ] || die "未检测到 /etc/openwrt_release，这不像是 OpenWrt 系统"

pkg_installed() {
	case "$PM" in
		opkg) opkg list-installed 2>/dev/null | grep -q "^$1 " ;;
		apk) apk info -e "$1" >/dev/null 2>&1 ;;
	esac
}

pkg_version() {
	case "$PM" in
		opkg) opkg status "$1" 2>/dev/null | sed -n 's/^Version: //p' | head -n1 ;;
		apk) apk list --installed --manifest "$1" 2>/dev/null | awk -v n="$1" '$1 == n {print $2; exit}' ;;
	esac
}

pkg_install_files() {
	case "$PM" in
		opkg) opkg install "$@" ;;
		apk) apk add --allow-untrusted "$@" ;;
	esac
}

pkg_remove() {
	case "$PM" in
		opkg) opkg remove "$@" ;;
		apk) apk del "$@" ;;
	esac
}

refresh_luci() {
	rm -rf /tmp/luci-* /tmp/.luci* /tmp/luci-indexcache* 2>/dev/null || true
	if [ -x /etc/init.d/rpcd ]; then
		/etc/init.d/rpcd restart >/dev/null 2>&1 || warn "rpcd 重启失败"
	fi
}

state_get() {
	[ -f "$STATE_FILE" ] || return 0
	sed -n "s/^$1=//p" "$STATE_FILE" | tail -n1
}

stop_passwall_services() {
	for init in passwall2 passwall2_server; do
		[ -x "/etc/init.d/$init" ] || continue
		"/etc/init.d/$init" disable >/dev/null 2>&1 || true
		if command -v timeout >/dev/null 2>&1; then
			timeout 30 "/etc/init.d/$init" stop >/dev/null 2>&1 || true
		else
			"/etc/init.d/$init" stop >/dev/null 2>&1 || true
		fi
	done

	for pattern in \
		'/usr/share/passwall2/' \
		'/tmp/etc/passwall2/' \
		'/var/etc/passwall2/' \
		'passwall2_server/bin/'; do
		for pid in $(pgrep -f "$pattern" 2>/dev/null || true); do
			[ "$pid" = "$$" ] && continue
			exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
			case "${exe##*/}" in
				sh|ash|busybox|curl|wget|grep|pgrep|sed|awk) continue ;;
			esac
			kill "$pid" >/dev/null 2>&1 || true
		done
	done
	sleep 2
	for pattern in \
		'/usr/share/passwall2/' \
		'/tmp/etc/passwall2/' \
		'/var/etc/passwall2/' \
		'passwall2_server/bin/'; do
		for pid in $(pgrep -f "$pattern" 2>/dev/null || true); do
			[ "$pid" = "$$" ] && continue
			exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
			case "${exe##*/}" in
				sh|ash|busybox|curl|wget|grep|pgrep|sed|awk) continue ;;
			esac
			kill -9 "$pid" >/dev/null 2>&1 || true
		done
	done
}

clean_iptables_chains() {
	ipt_cmd="$1"
	command -v "$ipt_cmd" >/dev/null 2>&1 || return 0
	for table in filter nat mangle raw; do
		chains="$("$ipt_cmd" -t "$table" -S 2>/dev/null |
			sed -n 's/^-N \([^ ]*\).*/\1/p' |
			grep -Ei 'psw2|passwall' || true)"
		for chain in $chains; do
			for parent in INPUT FORWARD OUTPUT PREROUTING POSTROUTING; do
				while "$ipt_cmd" -t "$table" -C "$parent" -j "$chain" >/dev/null 2>&1; do
					"$ipt_cmd" -t "$table" -D "$parent" -j "$chain" >/dev/null 2>&1 || break
				done
			done
			"$ipt_cmd" -t "$table" -F "$chain" >/dev/null 2>&1 || true
			"$ipt_cmd" -t "$table" -X "$chain" >/dev/null 2>&1 || true
		done
	done
}

clean_passwall_network_state() {
	if command -v nft >/dev/null 2>&1; then
		nft list tables 2>/dev/null |
			awk '$3 == "passwall2" {print $2, $3}' |
			while read -r family table; do
				nft delete table "$family" "$table" >/dev/null 2>&1 || true
			done || true
	fi

	if command -v ipset >/dev/null 2>&1; then
		ipset list -n 2>/dev/null |
			grep -Ei '^(psw2|passwall)' |
			while read -r setname; do
				ipset destroy "$setname" >/dev/null 2>&1 || true
			done || true
	fi

	clean_iptables_chains iptables
	clean_iptables_chains ip6tables
	clean_iptables_chains iptables-legacy
	clean_iptables_chains ip6tables-legacy
}

clean_passwall_uci() {
	for sec in $(uci -q show firewall 2>/dev/null |
		sed -n 's/^firewall\.\([^.]*\)=.*/\1/p'); do
		case "$sec" in
			*passwall2*) uci -q delete "firewall.$sec" || true ;;
			*)
				case "$(uci -q get "firewall.$sec.path" 2>/dev/null || true)" in
					*passwall2*) uci -q delete "firewall.$sec" || true ;;
				esac
				;;
		esac
	done
	uci -q delete firewall.passwall2 || true
	uci -q delete firewall.passwall2_server || true

	for sec in $(uci -q show ucitrack 2>/dev/null |
		sed -n 's/^ucitrack\.\([^.]*\)=.*/\1/p'); do
		case "$sec" in
			*passwall2*) uci -q delete "ucitrack.$sec" || true ;;
		esac
	done
	uci -q delete ucitrack.@passwall2[-1] || true
	uci -q delete ucitrack.@passwall2_server[-1] || true

	for mount in $(uci -q get 'dhcp.@dnsmasq[0].addnmount' 2>/dev/null || true); do
		case "$mount" in
			*passwall2*) uci -q del_list "dhcp.@dnsmasq[0].addnmount=$mount" || true ;;
		esac
	done
	uci -q delete 'dhcp.@dnsmasq[0].localuse' || true
	uci -q delete 'uhttpd.main.max_requests' || true

	for config in firewall ucitrack dhcp uhttpd; do
		[ -f "/etc/config/$config" ] && uci -q commit "$config" || true
	done
}

clean_passwall_crontab() {
	[ -f /etc/crontabs/root ] || return 0
	sed -i '/passwall2/d' /etc/crontabs/root
	if [ -x /etc/init.d/cron ]; then
		/etc/init.d/cron restart >/dev/null 2>&1 || true
	fi
}

reload_firewall() {
	if [ -x /etc/init.d/firewall ]; then
		/etc/init.d/firewall reload >/dev/null 2>&1 ||
			/etc/init.d/firewall restart >/dev/null 2>&1 || true
	fi
}

remove_passwall_packages() {
	case "$PM" in
		opkg)
			packages="$(opkg list-installed 2>/dev/null |
				awk '$1 == "luci-app-passwall2" || $1 ~ /^luci-i18n-passwall2-/ {print $1}')"
			;;
		apk)
			packages="$(apk list --installed --manifest 2>/dev/null |
				awk '$1 == "luci-app-passwall2" || $1 ~ /^luci-i18n-passwall2-/ {print $1}')"
			;;
	esac
	[ -n "$packages" ] || return 0
	pkg_remove $packages >/dev/null 2>&1 ||
		while read -r package; do
			[ -n "$package" ] || continue
			pkg_installed "$package" || continue
			case "$PM" in
				opkg) opkg remove --force-depends "$package" >/dev/null 2>&1 || true ;;
				apk) apk del "$package" >/dev/null 2>&1 || true ;;
			esac
		done <<EOF
$(printf '%s\n' "$packages" | tr ' ' '\n')
EOF
}

remove_passwall_files() {
	rm -rf \
		/usr/share/passwall2 \
		/usr/share/v2ray \
		/usr/share/sing-box \
		/etc/sing-box \
		/usr/lib/lua/luci/passwall2 \
		/usr/lib/lua/luci/model/cbi/passwall2 \
		/usr/lib/lua/luci/view/passwall2 \
		/www/luci-static/resources/view/passwall2 \
		/tmp/etc/passwall2 \
		/tmp/etc/passwall2_* \
		/var/etc/passwall2 \
		/var/etc/passwall2_* \
		/tmp/luci-modulecache \
		/tmp/passwall2-core.* 2>/dev/null || true
	rm -f \
		/etc/config/passwall2 \
		/etc/config/passwall2_server \
		/etc/config/passwall2_* \
		/etc/config/passwall2-* \
		/etc/passwall2_template.conf \
		/etc/init.d/passwall2 \
		/etc/init.d/passwall2_server \
		/etc/hotplug.d/iface/98-passwall2 \
		/etc/hotplug.d/ntp/30-passwall2-resync \
		/usr/lib/lua/luci/controller/passwall2.lua \
		/usr/lib/lua/luci/i18n/passwall2.*.lmo \
		/usr/share/rpcd/acl.d/luci-app-passwall2.json \
		/usr/share/ucitrack/luci-app-passwall2.json \
		/usr/share/ucitrack/luci-app-passwall2-server.json \
		/var/etc/passwall2.include \
		/var/etc/config/passwall2 \
		/var/etc/config/passwall2_* \
		/tmp/passwall2-release.* \
		/tmp/passwall2-singbox.* \
		/tmp/passwall2-core.* \
		/tmp/check-luci-app-passwall2* \
		/tmp/check-luci-i18n-passwall2* \
		/tmp/pw2.sh \
		"$STATE_FILE" 2>/dev/null || true
	rm -rf /tmp/log/passwall2* /var/log/passwall2* \
		/tmp/dnsmasq.d/*passwall2* /tmp/dnsmasq.d/passwall2* \
		/var/lock/*passwall2* /var/run/*passwall2* 2>/dev/null || true
	rm -f /etc/rc.d/*passwall2* /etc/hotplug.d/*/*passwall2* \
		/etc/uci-defaults/*passwall2* \
		/etc/istore/uci-defaults_bak/*passwall2* \
		/usr/share/luci/menu.d/*passwall2* \
		/usr/lib/opkg/info/*passwall2* \
		/lib/apk/packages/*passwall2* 2>/dev/null || true
	rm -rf /tmp/luci-* /tmp/.luci* /tmp/luci-indexcache* 2>/dev/null || true
	find /tmp -iname '*passwall2*' -exec rm -rf {} + 2>/dev/null || true
}

remove_passwall_dependencies() {
	for package in $DEPS; do
		pkg_installed "$package" || continue
		if ! pkg_remove "$package" >/dev/null 2>&1; then
			case "$PM" in
				opkg) opkg remove --force-depends "$package" >/dev/null 2>&1 || true ;;
				apk) apk --force-broken-world del "$package" >/dev/null 2>&1 || true ;;
			esac
		fi
	done
	if pkg_installed "$CORE_PKG"; then
		if ! pkg_remove "$CORE_PKG" >/dev/null 2>&1; then
			case "$PM" in
				opkg) opkg remove --force-depends "$CORE_PKG" >/dev/null 2>&1 || true ;;
				apk) apk --force-broken-world del "$CORE_PKG" >/dev/null 2>&1 || true ;;
			esac
		fi
	fi
	[ "$(command -v "$CORE_PKG" 2>/dev/null || true)" = "/usr/bin/$CORE_PKG" ] &&
		rm -f "/usr/bin/$CORE_PKG" || true
}

verify_passwall_removed() {
	residual=""
	case "$PM" in
		opkg) installed="$(opkg list-installed 2>/dev/null |
			awk '$1 == "luci-app-passwall2" || $1 ~ /^luci-i18n-passwall2-/ {print $1}')" ;;
		apk) installed="$(apk list --installed --manifest 2>/dev/null |
			awk '$1 == "luci-app-passwall2" || $1 ~ /^luci-i18n-passwall2-/ {print $1}')" ;;
	esac
	[ -z "$installed" ] || residual="$residual packages:$installed"
	for package in $DEPS "$CORE_PKG"; do
		pkg_installed "$package" && residual="$residual dependency:$package"
	done
	[ -e "/usr/bin/$CORE_PKG" ] && residual="$residual /usr/bin/$CORE_PKG"

	for path in \
		/etc/config/passwall2 \
		/etc/config/passwall2_server \
		/etc/passwall2_template.conf \
		/etc/init.d/passwall2 \
		/etc/init.d/passwall2_server \
		/usr/share/passwall2 \
		/usr/share/v2ray \
		/usr/share/sing-box \
		/etc/sing-box \
		/usr/lib/lua/luci/passwall2 \
		/usr/lib/lua/luci/controller/passwall2.lua \
		/usr/lib/lua/luci/model/cbi/passwall2 \
		/usr/lib/lua/luci/view/passwall2 \
		/usr/share/rpcd/acl.d/luci-app-passwall2.json \
		/usr/share/ucitrack/luci-app-passwall2.json \
		/usr/share/ucitrack/luci-app-passwall2-server.json \
		/var/etc/passwall2.include \
		/var/etc/config/passwall2 \
		/var/etc/passwall2 \
		/tmp/etc/passwall2; do
		[ -e "$path" ] && residual="$residual $path"
	done
	for path in /etc/istore/uci-defaults_bak/*passwall2*; do
		[ -e "$path" ] && residual="$residual $path"
	done
	if uci -q show firewall 2>/dev/null | grep -q 'passwall2'; then
		residual="$residual firewall-uci"
	fi
	if command -v nft >/dev/null 2>&1 &&
		nft list tables 2>/dev/null | grep -q ' passwall2$'; then
		residual="$residual nft-passwall2"
	fi
	if [ -f /etc/crontabs/root ] && grep -q 'passwall2' /etc/crontabs/root; then
		residual="$residual crontab"
	fi
	[ -z "$residual" ] || die "卸载后发现残留:$residual"
}

# ---------- 下载 ----------
# GitHub Release 资产可按顺序换镜像重试。API 不经过镜像，资产摘要必须来自
# 已验证的 api.github.com；镜像只能传输与摘要一致的文件。
mirror_urls() {
	url="$1"
	printf '%s\n' "$url"
	case "$url" in
		https://github.com/*|https://raw.githubusercontent.com/*)
			printf '%s\n' "https://gh-proxy.com/$url"
			printf '%s\n' "https://ghfast.top/$url"
			;;
	esac
}

download_file() {
	url="$1"; out="$2"
	for u in $(mirror_urls "$url"); do
		if command -v curl >/dev/null 2>&1; then
			curl -fsSL --retry 2 --connect-timeout 15 "$u" -o "$out" 2>/dev/null && return 0
		fi
		if command -v wget >/dev/null 2>&1; then
			wget -qO "$out" "$u" 2>/dev/null && return 0
		fi
	done
	return 1
}

# ---------- Release 信息 ----------
JSON="$(mktemp /tmp/passwall2-release.XXXXXX)"; register_tmp "$JSON"
RELEASE_TAG=""
ASSET_URLS=""
ASSET_DIGESTS=""

parse_asset_urls() {
	sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\)".*/\1/p' "$1"
}

parse_asset_digests() {
	awk '
		function value(line) {
			sub(/^[^:]*:[[:space:]]*"/, "", line)
			sub(/",?[[:space:]]*$/, "", line)
			return line
		}
		/"digest":[[:space:]]*"sha256:/ {
			digest = value($0)
			if (url != "") {
				print digest "\t" url
				url = ""
				digest = ""
			}
		}
		/"browser_download_url":[[:space:]]*"/ {
			if (digest != "") {
				print digest "\t" value($0)
				digest = ""
			} else {
				url = value($0)
			}
		}
		END {
			if (url != "" && digest != "") print digest "\t" url
		}
	' "$1"
}

fetch_release() {
	if [ -n "$TAG" ]; then
		rel_url="$API/tags/$TAG"
	else
		rel_url="$API/latest"
	fi

	if download_file "$rel_url" "$JSON" && [ -s "$JSON" ]; then
		RELEASE_TAG=$(sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' "$JSON" | head -n1)
		ASSET_URLS=$(parse_asset_urls "$JSON")
		ASSET_DIGESTS=$(parse_asset_digests "$JSON")
	fi

	[ -n "$RELEASE_TAG" ] || return 1
	return 0
}

pick_asset() {
	printf '%s\n' "$ASSET_URLS" | grep -E "$1" | head -n1
}

pick_asset_from() {
	urls="$1"
	pattern="$2"
	printf '%s\n' "$urls" | grep -E "$pattern" | head -n1
}

asset_name() { basename "$1"; }

asset_digest_from() {
	digests="$1"
	url="$2"
	printf '%s\n' "$digests" |
		awk -F '\t' -v u="$url" '$2 == u { print $1; exit }'
}

verify_sha256() {
	file="$1"
	digest="$2"
	expected="${digest#sha256:}"
	case "$expected" in
		""|*[!0-9a-f]*)
			die "无效的 SHA-256 摘要: $digest"
			;;
	esac
	[ "${#expected}" -eq 64 ] || die "无效的 SHA-256 摘要长度: $digest"
	actual="$(sha256sum "$file" | awk '{print $1}')"
	[ "$actual" = "$expected" ] ||
		die "$(asset_name "$file") SHA-256 校验失败（期望 $expected，实际 $actual）"
}

download_verified_from() {
	url="$1"
	out="$2"
	digests="$3"
	source_name="${4:-release}"
	digest="$(asset_digest_from "$digests" "$url")"
	[ -n "$digest" ] ||
		die "$source_name 没有提供 $(asset_name "$url") 的 SHA-256，拒绝未校验安装"
	download_file "$url" "$out" || die "下载失败: $(asset_name "$url")"
	[ -s "$out" ] || die "下载为空: $(asset_name "$url")"
	verify_sha256 "$out" "$digest"
}

download_verified() {
	url="$1"
	out="$2"
	download_verified_from "$url" "$out" "$ASSET_DIGESTS" "PassWall2 release"
}

tag_to_pkgver() {
	printf '%s' "$1" | sed 's/-\([0-9][0-9]*\)$/-r\1/'
}

pkg_install_packages() {
	case "$PM" in
		opkg) opkg install "$@" ;;
		apk) apk add "$@" ;;
	esac
}

core_ready() {
	command -v "$CORE_PKG" >/dev/null 2>&1 &&
		"$CORE_PKG" version >/dev/null 2>&1
}

PM_UPDATED=0
pm_update_once() {
	[ "$PM_UPDATED" = 1 ] && return 0
	case "$PM" in
		opkg) opkg update >/dev/null 2>&1 || warn "opkg update 未完全成功" ;;
		apk) apk update >/dev/null 2>&1 || warn "apk update 未完全成功" ;;
	esac
	PM_UPDATED=1
}

singbox_asset_pattern() {
	darch="$(
		unset DISTRIB_ARCH
		. /etc/openwrt_release 2>/dev/null || true
		printf '%s' "${DISTRIB_ARCH:-}"
	)"
	[ -n "$darch" ] || die "无法从 /etc/openwrt_release 读取 DISTRIB_ARCH"

	case "$darch" in
		x86_64|amd64) target="amd64" ;;
		i386|i486|i586|i686) target="386" ;;
		aarch64*|arm64*) target="arm64" ;;
		arm_arm1176*) target="armv6" ;;
		arm_*) target="armv7" ;;
		mips64el*|mips64el_*) target="mips64le-softfloat" ;;
		mips64*|mips64_*) target="mips64-softfloat" ;;
		mipsel*|mipsel_*) target="mipsle-softfloat" ;;
		mips*|mips_*) target="mips-softfloat" ;;
		riscv64*) target="riscv64" ;;
		*)
			die "没有已知的 sing-box 架构映射: $darch"
			;;
	esac
	printf '%s\n' "linux-${target}-musl\\.tar\\.gz$"
}

fetch_singbox_release() {
	SB_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
	SB_JSON="$(mktemp /tmp/passwall2-singbox.XXXXXX)"; register_tmp "$SB_JSON"
	download_file "$SB_API" "$SB_JSON" && [ -s "$SB_JSON" ] ||
		die "无法获取 sing-box 官方 release（可能触发 GitHub API 限流）"
	SB_TAG="$(sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' "$SB_JSON" | head -n1)"
	SB_ASSET_URLS="$(parse_asset_urls "$SB_JSON")"
	SB_ASSET_DIGESTS="$(parse_asset_digests "$SB_JSON")"
	[ -n "$SB_TAG" ] && [ -n "$SB_ASSET_URLS" ] ||
		die "sing-box 官方 release 信息不完整"
}

install_core_from_upstream() {
	fetch_singbox_release
	asset_pattern="$(singbox_asset_pattern)"
	core_url="$(pick_asset_from "$SB_ASSET_URLS" "$asset_pattern" || true)"
	[ -n "$core_url" ] ||
		die "sing-box $SB_TAG 没有匹配当前架构的核心包"

	need_cmd tar
	core_archive="/tmp/$(asset_name "$core_url")"; register_tmp "$core_archive"
	core_dir="$(mktemp -d /tmp/passwall2-core.XXXXXX)"; register_tmp "$core_dir"
	log "从 sing-box $SB_TAG 补装核心: $(asset_name "$core_url")"
	download_verified_from "$core_url" "$core_archive" "$SB_ASSET_DIGESTS" "sing-box release"
	tar -xzf "$core_archive" -C "$core_dir" --strip-components=1 ||
		die "无法解压 $(asset_name "$core_url")"
	core_file="$core_dir/sing-box"
	[ -f "$core_file" ] || die "sing-box 压缩包中没有核心二进制"
	chmod 0755 "$core_file"
	"$core_file" version >/dev/null 2>&1 ||
		die "下载的 sing-box 与当前 CPU 架构不兼容"

	staged_core="/usr/bin/.sing-box.new.$$"
	register_tmp "$staged_core"
	cp "$core_file" "$staged_core" || die "无法复制 sing-box 到 /usr/bin"
	chmod 0755 "$staged_core"
	mv -f "$staged_core" /usr/bin/sing-box || die "无法安装 /usr/bin/sing-box"
	core_ready || die "sing-box 安装后仍无法运行"
	log "sing-box 已安装: $(core_version)"
}

ensure_core() {
	if core_ready; then
		log "sing-box 可用: $(core_version)"
		return 0
	fi

	log "sing-box 缺失，先尝试系统软件源"
	pm_update_once
	if pkg_install_packages "$CORE_PKG" >/dev/null 2>&1 && core_ready; then
		log "sing-box 已安装: $(core_version)"
		return 0
	fi

	warn "系统软件源没有可用的 sing-box，改用官方 release 二进制"
	install_core_from_upstream
}

core_version() {
	"$CORE_PKG" version 2>/dev/null | head -n1
}

core_version_short() {
	core_version | sed 's/^sing-box version //'
}

install_dependencies() {
	missing=""
	for d in $DEPS; do
		pkg_installed "$d" || missing="$missing $d"
	done
	[ -n "$missing" ] || return 0

	log "补装依赖:$missing"
	pm_update_once
	pkg_install_packages $missing ||
		warn "部分依赖安装失败，正在核对结果"

	missing=""
	for d in $DEPS; do
		pkg_installed "$d" || missing="$missing $d"
	done
	[ -z "$missing" ] || die "依赖仍缺失:$missing"
}

# ---------- 检查 ----------
do_check() {
	require_downloader
	ui_title "PassWall2 检查"
	log "包管理器: $PM（扩展名 .$EXT）"
	log "查询 release: ${TAG:-latest}"
	fetch_release || die "无法获取 release 信息（网络或仓库不可达）"
	log "最新 release: $RELEASE_TAG  (包版本 $(tag_to_pkgver "$RELEASE_TAG"))"

	cur="$(pkg_version "$PKG_MAIN" || true)"
	log "已安装: ${cur:-未安装}"

	if [ "$PM" = opkg ]; then
		main_url="$(pick_asset "/${PKG_MAIN}_[0-9][^/]*\.ipk$")"
		i18n_url="$(pick_asset "/${PKG_I18N}_[0-9][^/]*\.ipk$")"
	else
		main_url="$(pick_asset "/${PKG_MAIN}-[0-9][^/]*\.apk$")"
		i18n_url="$(pick_asset "/${PKG_I18N}-[0-9][^/]*\.apk$")"
	fi

	[ -n "$main_url" ] || die "release 里没有 ${PKG_MAIN} 的 .$EXT 包"
	log "主包: $(asset_name "$main_url")"
	if [ -n "$i18n_url" ]; then
		log "语言包: $(asset_name "$i18n_url")"
	else
		warn "release 里没有中文语言包（界面会是英文）"
	fi

	check_file="/tmp/check-$(asset_name "$main_url")"; register_tmp "$check_file"
	download_verified "$main_url" "$check_file"
	log "已校验: $(asset_name "$main_url")"
	if [ -n "$i18n_url" ]; then
		check_i18n="/tmp/check-$(asset_name "$i18n_url")"; register_tmp "$check_i18n"
		download_verified "$i18n_url" "$check_i18n"
		log "已校验: $(asset_name "$i18n_url")"
	fi

	log "检查依赖:"
	check_status=0
	for d in $DEPS; do
		if pkg_installed "$d"; then
			log "   $d 已安装"
		else
			warn "   $d 缺失（安装时会自动尝试补装）"
			check_status=1
		fi
	done
	if core_ready; then
		log "   sing-box 可用: $(core_version)"
	elif command -v "$CORE_PKG" >/dev/null 2>&1; then
		warn "   sing-box 存在但无法运行"
		check_status=1
	else
		warn "   sing-box 缺失（安装时会从软件源或 release 架构包补装）"
		check_status=1
	fi
	return "$check_status"
}

do_status() {
	cur="$(pkg_version "$PKG_MAIN" || true)"
	i18n_version="$(pkg_version "$PKG_I18N" || true)"
	core_state="未安装"
	if core_ready; then
		core_state="$(core_version_short)"
	elif command -v "$CORE_PKG" >/dev/null 2>&1; then
		core_state="存在但无法运行"
	fi
	service_state="${C_RED}未运行${C_RESET}"
	if command -v pgrep >/dev/null 2>&1 &&
		pgrep -f '/tmp/etc/passwall2/' >/dev/null 2>&1; then
		service_state="${C_GREEN}运行中${C_RESET}"
	fi
	boot_state="未启用"
	[ -L /etc/rc.d/S99passwall2 ] && boot_state="已启用"
	config_state="${C_YELLOW}未找到${C_RESET}"
	[ -s /etc/config/passwall2 ] && config_state="${C_GREEN}已配置${C_RESET}"
	firewall_state="${C_YELLOW}未配置${C_RESET}"
	if [ -n "$(uci -q get firewall.passwall2.path 2>/dev/null || true)" ]; then
		firewall_state="${C_GREEN}已接入${C_RESET}"
	fi

	ui_title "PassWall2 状态"
	ui_kv "包管理器" "$PM"
	ui_kv "安装版本" "${cur:-${C_RED}未安装${C_RESET}}"
	ui_kv "中文语言" "${i18n_version:-${C_YELLOW}未安装${C_RESET}}"
	ui_kv "核心版本" "$core_state"
	ui_kv "运行状态" "$service_state"
	ui_kv "开机启动" "$boot_state"
	ui_kv "配置文件" "$config_state"
	ui_kv "防火墙　" "$firewall_state"

	missing=""
	for dependency in $DEPS; do
		pkg_installed "$dependency" || missing="$missing $dependency"
	done
	[ -z "$missing" ] || missing="${missing# }"
	ui_kv "依赖状态" "${missing:-${C_GREEN}全部正常${C_RESET}}"

	if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
		if fetch_release; then
			latest="$(tag_to_pkgver "$RELEASE_TAG")"
			if [ -n "$cur" ] && [ "$cur" = "$latest" ]; then
				ui_kv "上游版本" "${C_GREEN}已是最新${C_RESET}（$latest）"
			else
				ui_kv "上游版本" "${C_YELLOW}可更新${C_RESET}（$latest）"
			fi
		else
			ui_kv "上游版本" "${C_YELLOW}暂时无法检查${C_RESET}"
		fi
	else
		ui_kv "上游版本" "${C_YELLOW}缺少下载工具${C_RESET}"
	fi
	ui_rule
}

# ---------- 安装 ----------
do_install() {
	require_downloader
	cur="$(pkg_version "$PKG_MAIN" || true)"
	if [ "$UPDATE_ONLY" = 1 ] && [ -z "$cur" ]; then
		die "PassWall2 尚未安装，请先选择“安装”"
	fi
	fetch_release || die "无法获取 release 信息（网络或仓库不可达）"
	want="$(tag_to_pkgver "$RELEASE_TAG")"

	if [ "$cur" = "$want" ] && [ "$FORCE" != 1 ]; then
		need_repair=0
		core_ready || need_repair=1
		for dependency in $DEPS; do
			pkg_installed "$dependency" || need_repair=1
		done
		if [ "$need_repair" = 1 ]; then
			ui_title "补齐运行组件"
			ensure_core
			install_dependencies
		fi
		ui_title "无需更新"
		ui_kv "当前版本" "$cur"
		ui_kv "上游版本" "$want"
		ui_kv "更新状态" "${C_GREEN}已是最新${C_RESET}"
		ui_rule
		exit 0
	fi

	ui_title "PassWall2 安装 / 更新"
	log "release: $RELEASE_TAG（包版本 $want）"
	log "当前版本: ${cur:-未安装}"
	ensure_core
	install_dependencies

	if [ "$PM" = opkg ]; then
		main_url="$(pick_asset "/${PKG_MAIN}_[0-9][^/]*\.ipk$")"
		i18n_url="$(pick_asset "/${PKG_I18N}_[0-9][^/]*\.ipk$")"
	else
		main_url="$(pick_asset "/${PKG_MAIN}-[0-9][^/]*\.apk$")"
		i18n_url="$(pick_asset "/${PKG_I18N}-[0-9][^/]*\.apk$")"
	fi
	[ -n "$main_url" ] || die "release 里没有 ${PKG_MAIN} 的 .$EXT 包"

	main_file="/tmp/$(asset_name "$main_url")"; register_tmp "$main_file"
	log "下载: $(asset_name "$main_url")"
	download_verified "$main_url" "$main_file"

	files="$main_file"
	if [ -n "$i18n_url" ]; then
		i18n_file="/tmp/$(asset_name "$i18n_url")"; register_tmp "$i18n_file"
		log "下载: $(asset_name "$i18n_url")"
		if (download_verified "$i18n_url" "$i18n_file") 2>/dev/null; then
			files="$files $i18n_file"
		else
			warn "语言包下载或校验失败，跳过（界面会是英文）"
		fi
	fi

	log "安装: $(for f in $files; do printf '%s ' "$(basename "$f")"; done)"
	if ! pkg_install_files $files; then
		cat >&2 <<'EOF'
[ERROR] 安装失败。常见原因：
  1. 固件版本/依赖与预编译包不匹配
  2. 软件源被第三方固件改写，依赖解析异常
  3. 已安装同名包版本更高（可先 --uninstall 再装）
排查：先更新软件源后重试；仍失败请附上上面的日志。
EOF
		exit 1
	fi

	new="$(pkg_version "$PKG_MAIN" || true)"
	[ -n "$new" ] || die "安装后读不到版本，可能没有真正装上"
	refresh_luci
	ui_title "PassWall2 安装完成"
	ui_kv "安装版本" "$new"
	ui_kv "核心版本" "$(core_version_short)"
	ui_kv "配置文件" "${C_GREEN}已保留或已生成${C_RESET}"
	ui_kv "访问位置" "LuCI → 服务 → PassWall2"
	ui_kv "页面缓存" "页面未更新时按 Ctrl+F5"
	ui_rule
}

# ---------- 卸载 ----------
do_uninstall() {
	ui_title "PassWall2 零残留卸载"
	log "零残留卸载 PassWall2"
	log "停止服务并禁用自启动"
	stop_passwall_services
	log "清理防火墙和网络规则"
	clean_passwall_uci
	clean_passwall_network_state
	clean_passwall_crontab
	reload_firewall
	log "移除 PassWall2 软件包"
	remove_passwall_packages
	log "删除配置、LuCI、运行状态和临时文件"
	remove_passwall_files
	log "清理安装器补装的组件"
	remove_passwall_dependencies
	# Package removal and firewall reload can regenerate cache files, so flush again.
	clean_passwall_uci
	clean_passwall_network_state
	remove_passwall_files
	reload_firewall
	refresh_luci
	verify_passwall_removed
	ui_title "PassWall2 卸载完成"
	ui_kv "软件包　" "${C_GREEN}已删除${C_RESET}"
	ui_kv "配置文件" "${C_GREEN}已删除${C_RESET}"
	ui_kv "防火墙　" "${C_GREEN}已清除${C_RESET}"
	ui_kv "残留检查" "${C_GREEN}通过${C_RESET}"
	ui_rule
}

interactive_menu() {
	while :; do
		printf '\n'
		ui_title "管理器"
		printf '  %s1%s  安装\n' "$C_GREEN" "$C_RESET"
		printf '  %s2%s  更新\n' "$C_CYAN" "$C_RESET"
		printf '  %s3%s  状态\n' "$C_YELLOW" "$C_RESET"
		printf '  %s4%s  卸载\n' "$C_RED" "$C_RESET"
		printf '  %s0%s  退出\n' "$C_BOLD" "$C_RESET"
		ui_rule
		printf '  请选择 [0-4]: '
		read -r choice
		read_status=$?
		if [ "$read_status" -ne 0 ]; then
			printf '\n'
			exit 0
		fi
		case "$choice" in
			1)
				MODE="install"
				UPDATE_ONLY=0
				return 0
				;;
			2)
				MODE="update"
				UPDATE_ONLY=1
				return 0
				;;
			3)
				MODE="status"
				return 0
				;;
			4)
				printf '\n%s即将执行零残留卸载：配置、包、依赖、LuCI、服务、定时任务和防火墙规则都会删除。%s\n' \
					"$C_RED" "$C_RESET"
				printf '输入 YES 确认卸载，其他内容取消: '
				read -r confirm
				read_status=$?
				if [ "$read_status" -ne 0 ]; then
					printf '\n'
					exit 0
				fi
				case "$confirm" in
					YES|yes|Yes|是|y|Y)
						MODE="uninstall"
						return 0
						;;
					*)
						printf '%s已取消卸载。%s\n' "$C_YELLOW" "$C_RESET"
						;;
				esac
				;;
			0|q|Q|quit|exit)
				printf '%s已退出。%s\n' "$C_CYAN" "$C_RESET"
				exit 0
				;;
			*)
				printf '%s无效选项，请输入 0-4。%s\n' "$C_RED" "$C_RESET"
				;;
		esac
	done
}

# ---------- 主流程 ----------
lock_process_start() {
	[ -r "/proc/$1/stat" ] || return 1
	sed 's/^.*) //' "/proc/$1/stat" | awk '{print $20}'
}

claim_lock() {
	LOCK_OWNED=1
	start_time="$(lock_process_start $$ || true)"
	LOCK_TOKEN="$$:${start_time:-unknown}"
	if ! printf '%s\n' "$LOCK_TOKEN" > "$LOCKDIR/owner"; then
		release_lock
		return 1
	fi
	printf '%s\n' "$$" > "$LOCKDIR/pid"
	return 0
}

acquire_lock() {
	if mkdir "$LOCKDIR" 2>/dev/null; then
		claim_lock
		return
	fi

	old_owner="$(cat "$LOCKDIR/owner" 2>/dev/null || true)"
	old_pid="${old_owner%%:*}"
	old_start="${old_owner#*:}"
	[ "$old_pid" != "$old_owner" ] || old_start=""
	[ -n "$old_pid" ] || old_pid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"

	if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
		current_start="$(lock_process_start "$old_pid" || true)"
		if [ -z "$old_start" ] || [ -z "$current_start" ] ||
			[ "$old_start" = "$current_start" ]; then
			return 1
		fi
	fi

	warn "清理残留锁（进程 ${old_pid:-未知} 已退出或 PID 已被复用）"
	stale_lock="$LOCKDIR.stale.$$"
	if ! mv "$LOCKDIR" "$stale_lock" 2>/dev/null; then
		return 1
	fi
	rm -rf "$stale_lock"
	mkdir "$LOCKDIR" 2>/dev/null || return 1
	claim_lock
}

if [ "$MODE" = "unlock" ]; then
	rm -rf "$LOCKDIR"
	log "已清理锁: $LOCKDIR"
	exit 0
fi

if ! acquire_lock; then
	die "已有另一个 PassWall2 任务正在运行（$LOCKDIR）；确认没有在跑后可用 --unlock 清理"
fi

if [ "$MODE" = "menu" ]; then
	interactive_menu
fi

case "$MODE" in
	check) do_check ;;
	install|update) do_install ;;
	status) do_status ;;
	uninstall|purge) do_uninstall ;;
esac

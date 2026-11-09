#!/bin/sh
#
# PassWall2 一键安装 / 更新脚本（lima-droid/openwrt-passwall2 分支）
#
# 只做一件事：从本仓库的 GitHub Release 里取 luci-app-passwall2 + 中文语言包，
# 用系统自带的包管理器装上；依赖（tcping/geoview/v2ray-geoip/v2ray-geosite）缺失时自动补。
#
# 用法：
#   sh install.sh                 # 安装 / 更新到最新 release
#   sh install.sh --check         # 只检查（查版本、验证资源可下载），不安装
#   sh install.sh --version TAG   # 安装指定版本，例如 --version 26.11.3-1
#   sh install.sh --force         # 版本相同也重装
#   sh install.sh --unlock        # 清理残留的安装锁
#   sh install.sh --uninstall     # 卸载（保留 /etc/config/passwall2）
#   sh install.sh --purge         # 卸载并删除配置
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
TMPFILES=""
LOCK_OWNED=0
LOCK_TOKEN=""
MODE="install"
TAG=""
FORCE=0

log()  { printf '%s\n' "==> $*"; }
warn() { printf '%s\n' "[WARN] $*" >&2; }
die()  { printf '%s\n' "[ERROR] $*" >&2; exit 1; }

usage() {
	cat <<'EOF'
用法:
  sh install.sh                 # 安装 / 更新到最新 release
  sh install.sh --check         # 只检查，不安装
  sh install.sh --version TAG   # 安装指定版本（如 26.11.3-1）
  sh install.sh --force         # 已是最新也重装
  sh install.sh --unlock        # 清理残留的安装锁
  sh install.sh --uninstall     # 卸载（保留配置）
  sh install.sh --purge         # 卸载并删除配置
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
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
	die "缺少 curl 或 wget"
fi

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

# ---------- 安装 ----------
do_install() {
	cur="$(pkg_version "$PKG_MAIN" || true)"
	fetch_release || die "无法获取 release 信息（网络或仓库不可达）"
	want="$(tag_to_pkgver "$RELEASE_TAG")"
	log "release: $RELEASE_TAG（包版本 $want）"
	log "当前版本: ${cur:-未安装}"

	ensure_core
	install_dependencies

	if [ "$cur" = "$want" ] && [ "$FORCE" != 1 ]; then
		log "PassWall2 已经是最新版本（--force 可强制重装）"
		exit 0
	fi

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
	log "安装完成: $new"
	refresh_luci
	log "已有配置 /etc/config/passwall2 已保留；首次安装会生成默认配置"
	log "打开 LuCI → 服务 → PassWall2；界面若仍显示旧版本，Ctrl+F5 刷新"
}

# ---------- 卸载 ----------
do_uninstall() {
	log "卸载 PassWall2"
	if ! pkg_installed "$PKG_MAIN"; then
		log "未安装 $PKG_MAIN，无需卸载"
	else
		pkg_remove "$PKG_MAIN" || warn "卸载 $PKG_MAIN 失败（可能有包依赖它）"
	fi
	pkg_installed "$PKG_I18N" && { pkg_remove "$PKG_I18N" || warn "卸载语言包失败"; }
	if [ "$MODE" = purge ]; then
		rm -f /etc/config/passwall2 && log "已删除 /etc/config/passwall2"
	else
		log "保留 /etc/config/passwall2（--purge 可删除）"
	fi
	refresh_luci
	log "卸载完成"
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

case "$MODE" in
	check) do_check ;;
	install) do_install ;;
	uninstall|purge) do_uninstall ;;
esac

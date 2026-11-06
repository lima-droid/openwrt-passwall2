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
ASSETS_PAGE="https://github.com/$REPO/releases/expanded_assets"

PKG_MAIN="luci-app-passwall2"
PKG_I18N="luci-i18n-passwall2-zh-cn"
DEPS="tcping geoview v2ray-geoip v2ray-geosite"

LOCKDIR="/tmp/passwall2-install.lock"
TMPFILES=""
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
  sh install.sh --uninstall     # 卸载（保留配置）
  sh install.sh --purge         # 卸载并删除配置
EOF
}

cleanup() {
	rmdir "$LOCKDIR" 2>/dev/null || true
	for f in $TMPFILES; do
		rm -f "$f" 2>/dev/null || true
	done
}
trap cleanup EXIT INT TERM

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
for c in sed grep awk head mktemp; do need_cmd "$c"; done

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
download_file() {
	url="$1"; out="$2"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 --connect-timeout 15 "$url" -o "$out" 2>/dev/null && return 0
		curl -fsSL --retry 2 --connect-timeout 15 -k "$url" -o "$out" 2>/dev/null && return 0
	fi
	if command -v wget >/dev/null 2>&1; then
		wget -qO "$out" "$url" 2>/dev/null && return 0
		wget -qO "$out" --no-check-certificate "$url" 2>/dev/null && return 0
	fi
	return 1
}

http_ok() {
	url="$1"
	if command -v curl >/dev/null 2>&1; then
		code=$(curl -sIL --connect-timeout 10 --max-time 30 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
		case "$code" in 200|206|302) return 0 ;; esac
		# 部分 CDN 对 HEAD 不友好，用 Range GET 再确认一次
		code=$(curl -sL -r 0-0 --connect-timeout 10 --max-time 30 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
		case "$code" in 200|206|302) return 0 ;; esac
		return 1
	fi
	return 0
}

# ---------- Release 信息 ----------
JSON="$(mktemp /tmp/passwall2-release.XXXXXX)"; register_tmp "$JSON"
RELEASE_TAG=""
ASSET_URLS=""

fetch_release() {
	if [ -n "$TAG" ]; then
		rel_url="$API/tags/$TAG"
	else
		rel_url="$API/latest"
	fi

	if download_file "$rel_url" "$JSON" && [ -s "$JSON" ]; then
		RELEASE_TAG=$(sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' "$JSON" | head -n1)
		ASSET_URLS=$(sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\)".*/\1/p' "$JSON")
	fi

	if [ -z "$RELEASE_TAG" ]; then
		# API 被限流时退回网页
		warn "GitHub API 不可用，改用 release 页面"
		page="$(mktemp /tmp/passwall2-page.XXXXXX)"; register_tmp "$page"
		if [ -n "$TAG" ]; then
			download_file "https://github.com/$REPO/releases/tag/$TAG" "$page" || return 1
			RELEASE_TAG="$TAG"
		else
			download_file "https://github.com/$REPO/releases/latest" "$page" || return 1
			RELEASE_TAG=$(sed -n 's|.*/releases/tag/\([^"/?#]*\)".*|\1|p' "$page" | head -n1)
		fi
		[ -n "$RELEASE_TAG" ] || return 1
		download_file "$ASSETS_PAGE/$RELEASE_TAG" "$page" || return 1
		ASSET_URLS=$(sed -n 's|.*href="\(/'"$REPO"'/releases/download/[^"]*\)".*|https://github.com\1|p' "$page")
	fi

	[ -n "$RELEASE_TAG" ] || return 1
	return 0
}

pick_asset() {
	printf '%s\n' "$ASSET_URLS" | grep -E "$1" | head -n1
}

asset_name() { basename "$1"; }

tag_to_pkgver() {
	printf '%s' "$1" | sed 's/-\([0-9][0-9]*\)$/-r\1/'
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

	for u in $main_url $i18n_url; do
		if http_ok "$u"; then
			log "可下载: $(asset_name "$u")"
		else
			warn "无法访问: $u"
		fi
	done

	log "检查依赖:"
	for d in $DEPS; do
		if pkg_installed "$d"; then
			log "   $d 已安装"
		else
			warn "   $d 缺失（安装时会自动尝试补装）"
		fi
	done
}

# ---------- 安装 ----------
do_install() {
	cur="$(pkg_version "$PKG_MAIN" || true)"
	fetch_release || die "无法获取 release 信息（网络或仓库不可达）"
	want="$(tag_to_pkgver "$RELEASE_TAG")"
	log "release: $RELEASE_TAG（包版本 $want）"
	log "当前版本: ${cur:-未安装}"

	if [ "$cur" = "$want" ] && [ "$FORCE" != 1 ]; then
		log "已经是最新版本，无需安装（--force 可强制重装）"
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
	download_file "$main_url" "$main_file" || die "下载主包失败"
	[ -s "$main_file" ] || die "主包下载为空"

	files="$main_file"
	if [ -n "$i18n_url" ]; then
		i18n_file="/tmp/$(asset_name "$i18n_url")"; register_tmp "$i18n_file"
		log "下载: $(asset_name "$i18n_url")"
		if download_file "$i18n_url" "$i18n_file" && [ -s "$i18n_file" ]; then
			files="$files $i18n_file"
		else
			warn "语言包下载失败，跳过（界面会是英文）"
		fi
	fi

	# 依赖：缺哪个补哪个
	missing=""
	for d in $DEPS; do
		pkg_installed "$d" || missing="$missing $d"
	done
	if [ -n "$missing" ]; then
		log "补装依赖:$missing"
		case "$PM" in
			opkg) opkg update >/dev/null 2>&1 || warn "opkg update 未完全成功"
			      opkg install $missing || warn "部分依赖安装失败，PassWall2 可能功能受限" ;;
			apk)  apk update >/dev/null 2>&1 || true
			      apk add $missing || warn "部分依赖安装失败，PassWall2 可能功能受限" ;;
		esac
	fi

	log "安装: $(for f in $files; do printf '%s ' "$(basename "$f")"; done)"
	if ! pkg_install_files $files; then
		cat >&2 <<'EOF'
[ERROR] 安装失败。常见原因：
  1. 固件版本/依赖与预编译包不匹配
  2. 软件源被第三方固件改写，依赖解析异常
  3. 已安装同名包版本更高（可先 --uninstall 再装）
排查：opkg update 后重试；仍失败请附上上面的日志。
EOF
		exit 1
	fi

	new="$(pkg_version "$PKG_MAIN" || true)"
	[ -n "$new" ] || die "安装后读不到版本，可能没有真正装上"
	log "安装完成: $new"
	refresh_luci
	log "配置文件 /etc/config/passwall2 未被修改"
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
if ! mkdir "$LOCKDIR" 2>/dev/null; then
	die "已有另一个 PassWall2 任务正在运行（$LOCKDIR）"
fi

case "$MODE" in
	check) do_check ;;
	install) do_install ;;
	uninstall|purge) do_uninstall ;;
esac

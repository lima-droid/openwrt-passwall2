local _M = {}

local function gh_release_url(self)
	--return "https://api.github.com/repos/" .. self.repo .. "/releases/latest"
	return "https://github.com/Openwrt-Passwall/openwrt-passwall-packages/releases/download/api-cache/" .. string.lower(self.name) .. "-release-api.json"
end

local function gh_pre_release_url(self)
	--return "https://api.github.com/repos/" .. self.repo .. "/releases?per_page=1"
	return "https://github.com/Openwrt-Passwall/openwrt-passwall-packages/releases/download/api-cache/" .. string.lower(self.name) .. "-pre-release-api.json"
end

_M.order = {
	"geoview",
	"sing-box"
}

-- The LuCI package has its own update flow and is not a binary component.
-- This fork publishes its own releases, so the in-app updater must look at this
-- repository instead of the upstream API cache.
local FORK_RELEASES = "https://api.github.com/repos/lima-droid/openwrt-passwall2/releases/latest"

_M.passwall2 = {
	name = "PassWall2",
	get_url = function(self)
		return FORK_RELEASES
	end
}

_M["sing-box"] = {
	name = "Sing-Box",
	repo = "SagerNet/sing-box",
	get_url = gh_release_url,
	cmd_version = "version",
	zipped = true,
	zipped_suffix = "tar.gz",
	default_path = "/usr/bin/sing-box",
	match_fmt_str = "linux%%-%s",
	file_tree = {
		x86_64 = "amd64%-musl",
		x86     = "386%-musl",
		aarch64 = "arm64%-musl",
		rockchip = "arm64%-musl",
		mips    = "mips%-softfloat",
		mips64  = "mips64%-softfloat",
		mipsel  = "mipsle%-softfloat%-musl",
		mips64el = "mips64le%-softfloat",
		armv7   = "armv7%-musl",
		armv8   = "arm64%-musl",
		riscv64 = "riscv64%-musl"
	}
}

_M.geoview = {
	name = "Geoview",
	repo = "snowie2000/geoview",
	get_url = gh_release_url,
	cmd_version = '-version 2>/dev/null | awk \'NR==1 && $1=="Geoview" {print $2}\'',
	zipped = false,
	default_path = "/usr/bin/geoview",
	match_fmt_str = "linux%%-%s",
	file_tree = {
		mipsel = "mipsle",
		mips64el = "mips64le"
	}
}

return _M

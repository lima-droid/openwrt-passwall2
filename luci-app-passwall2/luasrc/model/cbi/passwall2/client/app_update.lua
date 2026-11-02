local api = require "luci.passwall2.api"
api.set_default_cbi()

local com = require "luci.passwall2.com"

m = Map()

-- [[ App Settings ]]--
s = m:section(NamedSection, "@global_app[0]", "global_app", translate("App Update"))

s:appendTemplate("/app_update/app_version", {com = com})

o = s:option(ListValue, "gh_proxy_url", translate("GitHub Proxy"))
o.default = ""
o:value("", translate("Close(Not use)"))
o:value("https://gh-proxy.org/", "gh-proxy.org")
o:value("https://ghproxy.cc/", "ghproxy.cc")
o:value("https://mirror.ghproxy.com/", "ghproxy.com")
o:value("https://ghfast.top/", "ghfast.top")

for _, k in ipairs(com.order) do
	local v = com[k]
	o = s:option(Value, k:gsub("%-","_") .. "_file", translatef("%s App Path", v.name))
	o.default = v.default_path or ("/usr/bin/" .. k)
	o.placeholder = o.default
	function o:remove(section)
		self:write(section, self.default)
	end
end

return api.return_map(m)

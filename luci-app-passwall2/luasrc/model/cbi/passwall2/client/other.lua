local api = require "luci.passwall2.api"
api.set_default_cbi()

local fs = api.fs
local has_singbox = api.finded_com("sing-box")

local port_validate = function(self, value, t)
	return value:gsub("-", ":")
end

m = Map()

-- [[ Delay Settings ]]--
s = m:section(NamedSection, "@global_delay[0]", "global_delay", translate("Delay Settings"))

---- Open and close Daemon
o = s:option(Flag, "start_daemon", translate("Open and close Daemon"))
o.default = 1
o.rmempty = false

---- Delay Start
o = s:option(Value, "start_delay", translate("Delay Start"), translate("Units:seconds"))
o.default = "1"
o.rmempty = true

for index, value in ipairs({"stop", "start", "restart"}) do
	o = s:option(ListValue, value .. "_week_mode", translate(value .. " automatically mode"))
	o:value("", translate("Disable"))
	if value == "restart" then
		o:value(8, translate("Loop Mode"))
	end
	o:value(7, translate("Every day"))
	o:value(1, translate("Every Monday"))
	o:value(2, translate("Every Tuesday"))
	o:value(3, translate("Every Wednesday"))
	o:value(4, translate("Every Thursday"))
	o:value(5, translate("Every Friday"))
	o:value(6, translate("Every Saturday"))
	o:value(0, translate("Every Sunday"))

	o = s:option(Value, value .. "_time_mode", translate(value .. " Time"))
	o:value("0:00")
	for t = 0, 23 do
		if t == 12 then
			o:value(t .. ":30")
		elseif t == 23 then
			o:value(t .. ":59")
		else
			o:value(t .. ":00")
		end
	end
	o.default = "0:00"
	o.datatype = "timehhmm"
	o:depends(value .. "_week_mode", "0")
	o:depends(value .. "_week_mode", "1")
	o:depends(value .. "_week_mode", "2")
	o:depends(value .. "_week_mode", "3")
	o:depends(value .. "_week_mode", "4")
	o:depends(value .. "_week_mode", "5")
	o:depends(value .. "_week_mode", "6")
	o:depends(value .. "_week_mode", "7")

	o = s:option(ListValue, value .. "_interval_mode", translate(value .. " Interval(Hour)"))
	for t = 1, 24 do o:value(t, t .. " " .. translate("Hour")) end
	o.default = 2
	o:depends(value .. "_week_mode", "8")
end

-- [[ Forwarding Settings ]]--
s = m:section(NamedSection, "@global_forwarding[0]", "global_forwarding", translate("Forwarding Settings"))

---- TCP No Redir Ports
o = s:option(Value, "tcp_no_redir_ports", translate("TCP No Redir Ports"))
o:value("", translate("No patterns are used"))
o:value("1:65535", translate("All"))
o.validate = port_validate

---- UDP No Redir Ports
o = s:option(Value, "udp_no_redir_ports", translate("UDP No Redir Ports"),
	"<font color='red'>" ..
	translate("Fill in the ports you don't want to be forwarded by the agent, with the highest priority.") ..
	"</font>")
o:value("", translate("No patterns are used"))
o:value("1:65535", translate("All"))
o.validate = port_validate

---- TCP Redir Ports
o = s:option(Value, "tcp_redir_ports", translate("TCP Redir Ports"))
o:value("1:65535", translate("All"))
o:value("22,25,53,80,143,443,465,587,853,873,993,995,5222,8080,8443,9418", translate("Common Use"))
o:value("80,443", translate("Only Web"))
o.default = o.keylist[1]
o.validate = port_validate

---- UDP Redir Ports
o = s:option(Value, "udp_redir_ports", translate("UDP Redir Ports"))
o:value("1:65535", translate("All"))
o.default = o.keylist[1]
o.validate = port_validate

o = s:option(DummyValue, "tips", " ")
o.rawhtml = true
o.cfgvalue = function(t, n)
	return string.format('<font color="red">%s</font>',
	translate("The port settings support single ports and ranges.<br>Separate multiple ports with commas (,).<br>Example: 21,80,443,1000:2000."))
end

---- Use nftables
o = s:option(ListValue, "prefer_nft", translate("Prefer firewall tools"))
o.default = "1"
o:value("0", "Iptables")
o:value("1", "Nftables")

---- Check the transparent proxy component
local handle = io.popen("lsmod")
local mods = ""
if handle then
	mods = handle:read("*a") or ""
	handle:close()
end

if (mods:find("REDIRECT") and mods:find("TPROXY")) or (mods:find("nft_redir") and mods:find("nft_tproxy")) then
	o = s:option(ListValue, "tcp_proxy_way", translate("TCP Proxy Way"))
	o.default = "redirect"
	o:value("redirect", "REDIRECT")
	o:value("tproxy", "TPROXY")
	o:depends("ipv6_tproxy", false)
	o.remove = function(self, section)
		-- Do not delete while hidden
	end

	o = s:option(ListValue, "_tcp_proxy_way", translate("TCP Proxy Way"))
	o.default = "tproxy"
	o:value("tproxy", "TPROXY")
	o:depends("ipv6_tproxy", true)
	o.write = function(self, section, value)
		self.map:set(section, "tcp_proxy_way", value)
	end

	if mods:find("ip6table_mangle") or mods:find("nft_tproxy") then
		---- IPv6 TProxy
		o = s:option(Flag, "ipv6_tproxy", translate("IPv6 TProxy"),
			"<font color='red'>" ..
			translate("Experimental feature. Make sure that your node supports IPv6.") ..
			"</font>")
		o.default = 0
		o.rmempty = false
	end
end

o = s:option(Flag, "accept_icmp", translate("Hijacking ICMP (PING)"))
o.default = 0

o = s:option(Flag, "accept_icmpv6", translate("Hijacking ICMPv6 (IPv6 PING)"))
o:depends("ipv6_tproxy", true)
o.default = 0

function clean_text(text)
	local nbsp = string.char(0xC2, 0xA0)
	local fullwidth_space = string.char(0xE3, 0x80, 0x80)
	return text
		:gsub("\t", " ")
		:gsub(nbsp, " ")
		:gsub(fullwidth_space, " ")
		:gsub("^%s+", "")
		:gsub("%s+$", "\n")
		:gsub("\r\n", "\n")
		:gsub("[ \t]*\n[ \t]*", "\n")
end

local direct_ip_file = "/usr/share/passwall2/direct_ip"
o = s:option(TextValue, "direct_ip", translate("Direct IP List"), "<font color='red'>" .. translate("These had been joined ip addresses will connect directly (not entering the core).") .. "</font>")
o.rows = 15
o.wrap = "off"
o.cfgvalue = function(self, section)
	return fs.readfile(direct_ip_file) or ""
end
o.write = function(self, section, value)
	fs.writefile(direct_ip_file, value:gsub("\r\n", "\n"))
end
o.remove = function(self, section, value)
	fs.writefile(direct_ip_file, "")
end
o.validate = function(self, value)
	local ipmasks= {}
	value = clean_text(value)
	string.gsub(value, '[^' .. "\r\n" .. ']+', function(w) table.insert(ipmasks, api.trim(w)) end)
	for index, ipmask in ipairs(ipmasks) do
		if ipmask ~= "" and not ipmask:find("^#") and not ipmask:find("^geoip:") then
			if not ( datatypes.ipmask4(ipmask) or datatypes.ipmask6(ipmask) ) then
				return nil, ipmask .. " " .. translate("Not valid IP format, please re-enter!")
			end
		end
	end
	return value
end


if has_singbox then
	s = m:section(NamedSection, "@global_singbox[0]", "global_singbox", "Sing-Box " .. translate("Settings"))

	o = s:option(Flag, "record_fragment", "TLS Record " .. translate("Fragment"),
		translate("Split handshake data into multiple TLS records for better censorship evasion. Low overhead. Recommended to enable first."))
	o.default = 0

	o = s:option(Flag, "fragment", "TLS TCP " .. translate("Fragment"),
		translate("Split handshake into multiple TCP segments. Enhances obfuscation. May increase delay. Use only if needed."))
	o.default = 0
end

return api.return_map(m)

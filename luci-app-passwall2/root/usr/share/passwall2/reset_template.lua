-- Restore /etc/config/passwall2 from the default template.
--
-- Nodes are NOT restored, with one exception: shunt nodes (protocol '_shunt').
-- Those describe the routing layout rather than a server, so they belong to the
-- settings template. Real proxy nodes / subscriptions are dropped.
--
-- Set _G.PW2_RESET_DST to write somewhere else (used by the local tests).
local fs = require "nixio.fs"

local src = "/etc/passwall2_template.conf"
if not fs.access(src) then
	src = "/usr/share/passwall2/0_default_config"
end
if not fs.access(src) then return end

local lines = {}
for line in io.lines(src) do
	lines[#lines + 1] = line
end

local out = {}
local i = 1
while i <= #lines do
	local line = lines[i]
	if line:match("^config%s+nodes") then
		local block, j = { line }, i + 1
		while j <= #lines and not lines[j]:match("^config%s") do
			block[#block + 1] = lines[j]
			j = j + 1
		end
		local shunt = false
		for _, l in ipairs(block) do
			if l:match("^%s*option%s+protocol%s+['\"]_shunt['\"]") then
				shunt = true
			end
		end
		if shunt then
			for _, l in ipairs(block) do
				out[#out + 1] = l
			end
		end
		i = j
	else
		out[#out + 1] = line
		i = i + 1
	end
end

local dst = _G.PW2_RESET_DST or "/etc/config/passwall2"
fs.writefile(dst, table.concat(out, "\n") .. "\n")

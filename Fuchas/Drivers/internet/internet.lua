local spec = {}
local fs = require("filesystem")
local cp = ...

function spec.getRank()
	return 1
end

function spec.getName()
	return "EnderNet Conformity 2000"
end

function spec.isCompatible(address)
	return cp.proxy(address).type == "internet"
end

function spec.new(address)
	local drv = {}
	local int = cp.proxy(address)

	function drv.httpDownload(url, dest)
		local h = int.request(url)
		h.finishConnect()
		local file = fs.open(dest, "w")
		if not file then
			h.close()
			error("cannot write " .. tostring(dest))
		end
		while true do
			local data = h.read()
			if not data or data == "" then break end
			file:write(data)
		end
		file:close()
		h.close()
		return true
	end

	function drv.readFully(url)
		local h = int.request(url)
		h.finishConnect()
		local chunks = {}
		while true do
			local data = h.read()
			if not data or data == "" then break end
			chunks[#chunks + 1] = data
		end
		h.close()
		return table.concat(chunks)
	end

	function drv.getCapabilities()
		return {
			tcp = int.isTcpEnabled(),
			udp = false,
			http = int.isHttpEnabled(),
			https = int.isHttpEnabled()
		}
	end

	return drv
end

return spec 

local primaries = {}
local vcomponents = {}

-- original component methods
local cp = component
local _list = component.list
local _type = component.type
local _proxy = component.proxy

function cp.list(filter, exact)
	local list = _list(filter, exact)
	for address, proxy in pairs(vcomponents) do
		local matches
		if not filter then
			matches = true
		elseif exact then
			matches = (proxy.type == filter)
		else
			matches = proxy.type and proxy.type:find(filter, 1, true) ~= nil
		end
		if matches then
			list[address] = proxy.type
		end
	end
	return list
end

function cp.type(address)
	for addr, proxy in pairs(vcomponents) do
		if addr == address then
			return proxy.type
		end
	end
	return _type(address)
end

function cp.proxy(address)
	for addr, proxy in pairs(vcomponents) do
		if addr == address then
			return proxy
		end
	end
	return _proxy(address)
end

function cp.get(address)
	for addr in cp.list() do
		if string.startsWith(addr, address) then
			return addr
		end
	end
	return nil
end

function cp.isConnected(address)
	if vcomponents[address] then
		return true
	end
	local ok, componentType = pcall(_type, address)
	return ok and componentType ~= nil
end

function cp.isVirtual(address)
	if vcomponents[address] then
		return true
	end
	local ok, proxy = pcall(_proxy, address)
	if not ok or proxy == nil then
		return false
	end
	local isVirtual
	ok, isVirtual = pcall(function() return proxy.isvirtual end)
	return ok and isVirtual == true
end

function cp.addVComponent(address, proxy)
	proxy.isvirtual = true
	proxy.address = proxy.address or address
	vcomponents[address] = proxy
end

function cp.removeVComponent(address)
	vcomponents[address] = nil
end

function cp.isAvailable(componentType)
	for _ in cp.list(componentType, true) do
		return true
	end
	return false
end

function cp.getPrimary(componentType)
	local primary = primaries[componentType]

	-- Be tolerant of primaries stored as addresses by older code.
	if type(primary) == "string" then
		primary = cp.proxy(primary)
		primaries[componentType] = primary
	end

	if primary ~= nil then
		local address = primary.address
		if address ~= nil and not cp.isConnected(address) then
			primary = nil
			primaries[componentType] = nil
		end
	end

	if primary == nil then
		local address = cp.list(componentType, true)()
		if address then
			primary = cp.proxy(address)
			primaries[componentType] = primary
		end
	end

	return primary
end

function cp.setPrimary(componentType, address)
	if type(address) == "string" then
		if not cp.isConnected(address) then
			error("not connected: " .. address)
		end
		primaries[componentType] = cp.proxy(address)
	elseif type(address) == "table" then
		if address.address and not cp.isConnected(address.address) and not address.isvirtual then
			error("not connected: " .. tostring(address.address))
		end
		primaries[componentType] = address
	else
		error("unsupported argument #2: " .. type(address))
	end
end

setmetatable(cp, {
	__index = function(_, key)
		return cp.getPrimary(key)
	end,
	-- component.gpu: Return component.getPrimary("gpu") if available
	-- component.getPrimary: Return getPrimary function
	__newindex = function(_, key, value)
		cp.setPrimary(key, value)
	end
	-- component.gpu = addr/proxy: Act same as component.setPrimary("gpu", addr/proxy)
	-- component.xlodkzek = proxy: Also works to set as primary (virtual) component
})

component = setmetatable({}, {
	__index = function(_, key)
		local sec = require("security")
		if sec.hasPermission("critical.component.get") then
			if key == "unrestricted" then
				return cp
			end
			return cp[key]
		else
			error("Not enough permission to access component")
		end
	end,
	__newindex = function(_, key, value)
		local sec = require("security")
		if sec.hasPermission("critical.component.set") then
			cp[key] = value
		end
	end
})

-- Driver need to be inited here in order to pass original component lib
package.loadPreBoot("driver", dofile("A:/Fuchas/Libraries/driver.lua", cp))
package.loadPreBoot("component", component)

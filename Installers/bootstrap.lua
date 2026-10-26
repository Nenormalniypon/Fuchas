-- Fuchas installer bootstrap for OpenOS.
--
-- Use this when the installer is not already on the computer:
--
--   wget -f https://raw.githubusercontent.com/Nenormalniypon/Fuchas/main/Installers/bootstrap.lua /tmp/fuchas-bootstrap.lua
--   /tmp/fuchas-bootstrap.lua
--
-- The bootstrap downloads the current installer (trying a few mirrors) and
-- runs it in-place.  It accepts an optional branch argument, for example
-- "/tmp/fuchas-bootstrap.lua dev".

local internet = require("internet")
local computer = require("computer")
local term = require("term")

local branch = ...
if type(branch) ~= "string" or branch == "" then
	branch = "main"
end

local urls = {
	"https://raw.githubusercontent.com/Nenormalniypon/Fuchas/" .. branch .. "/Installers/openos.lua",
	"https://cdn.jsdelivr.net/gh/Nenormalniypon/Fuchas@" .. branch .. "/Installers/openos.lua",
	"https://raw.githack.com/Nenormalniypon/Fuchas/" .. branch .. "/Installers/openos.lua"
}

local function fetch(url)
	local ok, connection = pcall(internet.request, url)
	if not ok or not connection then
		return nil, tostring(connection)
	end
	if connection.finishConnect then
		local cok, _, cerr = pcall(connection.finishConnect, connection)
		if not cok then
			pcall(connection.close, connection)
			return nil, tostring(cerr)
		end
	end
	if connection.response then
		local rok, code, message = pcall(connection.response, connection)
		if rok and type(code) == "number" and code >= 400 then
			pcall(connection.close, connection)
			return nil, "HTTP " .. tostring(code) .. " " .. tostring(message or "")
		end
	end
	local chunks = {}
	while true do
		local rok, data = pcall(connection.read, connection, 8192)
		if not rok then
			pcall(connection.close, connection)
			return nil, tostring(data)
		end
		if not data or data == "" then break end
		chunks[#chunks + 1] = data
	end
	pcall(connection.close, connection)
	local source = table.concat(chunks)
	if source == "" then
		return nil, "empty response"
	end
	if source:sub(1, 1) == "<" then
		return nil, "server returned HTML instead of Lua"
	end
	return source
end

local source, lastError
for _, url in ipairs(urls) do
	if term then
		term.write("Downloading installer from " .. url .. "\n")
	end
	local data, err = fetch(url)
	if data then
		source = data
		break
	end
	lastError = err
end

if not source then
	error("could not download the Fuchas installer: " .. tostring(lastError))
end

local installer, err = load(source, "=fuchas-installer")
if not installer then
	error("could not load the Fuchas installer: " .. tostring(err))
end

installer()

--- Filesystem library
-- @module filesystem
-- @alias filesystem

local filesystem = {}
local drives = {}
local noBit32 = OSDATA.CONFIG["NO_52_COMPAT"] -- cannot be changed by program as filesystem is initialized before any outside program.

local function readAll(node, path)
	if not node then return nil, "no drive" end
	local handle, err = node.open(path, "r")
	if not handle then
		return nil, err
	end
	local buf = ""
	local data = node.read(handle, math.huge)
	while data ~= nil do
		buf = buf .. data
		data = node.read(handle, math.huge)
	end
	node.close(handle)
	return buf
end

local function writeAllTo(node, path, content)
	if not node then return false, "no drive" end
	local handle, err = node.open(path, "w")
	if not handle then
		return false, err
	end
	node.write(handle, content)
	node.close(handle)
	return true
end

-- Create the parent directory of `path` if it does not exist yet.  The
-- original copy/rename helpers failed with a bare "open failed" whenever the
-- destination directory was missing.
local function ensureParent(path)
	local parent = filesystem.path(path)
	if parent == "" or filesystem.isDirectory(parent) then
		return true
	end
	local ok, err = pcall(filesystem.makeDirectory, parent)
	if not ok then
		return false, err
	end
	return true
end

local function segments(path)
	local parts = {}
	for part in path:gmatch("[^\\/]+") do
		local current, up = part:find("^%.?%.$")
		if current then
			if up == 2 then
				table.remove(parts)
			end
		else
			table.insert(parts, part)
		end
	end
	return parts
end

local function findNode(path)
	checkArg(1, path, "string")
	local seg = segments(path)
	if #seg > 0 then
		local let = seg[1]:sub(1, 1):upper()
		if seg[1]:sub(2, 2) ~= ":" then
			error("no drive separator found (missing \":\", " .. seg[1] .. ") in " .. path)
		end
		if not drives[let] then
			error("Invalid drive letter: " .. let)
		end
		local d = drives[let]
		return d.fs, path:sub(3, path:len()), d
	end
end

-------------------------------------------------------------------------------

function filesystem.canonical(path)
	return table.concat(segments(path), "/")
end

function filesystem.concat(...)
	local set = table.pack(...)
	for index, value in ipairs(set) do
		checkArg(index, value, "string")
	end
	return filesystem.canonical(table.concat(set, "/"))
end

function filesystem.get(path)
	local node, rest = findNode(path)
	if node then
		rest = filesystem.canonical(rest)
		return node, rest
	end
	return nil, "no such file system"
end

function filesystem.realPath(path)
	local node, rest, drive = findNode(path)
	if not node or not drive then
		return nil
	end
	return drive.letter:upper() .. ":/" .. filesystem.canonical(rest)
end

function filesystem.unmountDrive(letter)
	if letter:len() ~= 1 then
		return false, "invalid length"
	end
	drives[letter:upper()] = nil
	return true
end

function filesystem.isDriveFormatted(letter)
	local drive = drives[letter:upper()]
	if drive == nil then
		error("invalid drive: " .. letter .. ":/")
	end
	if drive.unmanaged then
		return (drive.fs.readSector(0) == string.rep(string.char(0), drive.fs.getSectorSize()))
	else
		return true
	end
end

function filesystem.isMounted(letter)
	return drives[letter:upper()] ~= nil
end

function filesystem.freeDriveLetter()
	for code = string.byte("A"), string.byte("Z") do
		local letter = string.char(code)
		if not drives[letter] then
			return letter
		end
	end
	return nil
end

function filesystem.getLetter(address)
	for k, v in pairs(drives) do
		if v.fs.address == address then
			return k
		end
	end
end

function filesystem.getDrive(path)
	return findNode(path)
end

function filesystem.mounts()
	return drives
end

function filesystem.mountDrive(proxy, letter)
	if letter:len() ~= 1 then
		return false, "invalid length"
	end
	if drives[letter:upper()] then
		return false, "drive already mounted"
	end
	drives[letter:upper()] = {
		fs = proxy,
		unmanaged = (proxy.type == "drive"),
		letter = letter:upper()
	}
	return true
end

function filesystem.getProxy(letter)
	if letter:len() ~= 1 then
		return false, "invalid length"
	end
	return drives[letter:upper()]
end

function filesystem.path(path)
	local parts = segments(path)
	if #parts == 0 then
		return ""
	elseif #parts == 1 then
		-- Root of a drive, e.g. "A:/".  The old implementation returned "/"
		-- here, which made filesystem.path("A:/") lose the drive letter.
		return parts[1] .. "/"
	end
	return table.concat(parts, "/", 1, #parts - 1) .. "/"
end

function filesystem.name(path)
	checkArg(1, path, "string")
	local parts = segments(path)
	return parts[#parts]
end

function filesystem.exists(path)
	if path:len() < 2 then
		return false
	else
		if path:sub(2, 2) ~= ":" then
			return false
		end
	end
	local node, rest = findNode(path)
	if node then
		return node.exists(rest)
	end
	return false
end

function filesystem.isDirectory(path)
	if not filesystem.exists(path) then return false end
	local node, rest = findNode(path)
	if not node then
		return false
	end
	return node.isDirectory(rest)
end

--- Read the .dir metadata file of a directory.
-- Layout: 4 bytes directory attributes (big-endian), 2 bytes entry count,
-- then for each entry: 1 byte name length, name, 4 bytes attributes.
local function readDirData(path)
	local data = {dirAttr = 0, list = {}, byName = {}}
	local node, rest = findNode(path)
	if not node or not node.exists(rest) then
		return data
	end
	local content = readAll(node, rest)
	if #content < 6 or not io.fromunum then
		return data
	end
	data.dirAttr = io.fromunum(content:sub(1, 4)) or 0
	local count = io.fromunum(content:sub(5, 6)) or 0
	local addr = 7
	for _ = 1, count do
		if addr > #content then break end
		local len = content:byte(addr)
		if not len or addr + len + 4 > #content then break end
		local name = content:sub(addr + 1, addr + len)
		local attr = io.fromunum(content:sub(addr + len + 1, addr + len + 4))
		if name ~= "" and attr ~= nil then
			data.list[#data.list + 1] = {name = name, attr = attr}
			data.byName[name] = attr
		end
		addr = addr + len + 5
	end
	return data
end

local function serializeDirData(data)
	if not io.tounum then
		error("io.tounum is not available")
	end
	local parts = {
		io.tounum(data.dirAttr or 0, 4, false, true),
		io.tounum(#data.list, 2, false, true)
	}
	for _, entry in ipairs(data.list) do
		local name = entry.name
		if #name > 255 then
			error("file name is too long for the .dir format: " .. name)
		end
		parts[#parts + 1] = string.char(#name)
		parts[#parts + 1] = name
		parts[#parts + 1] = io.tounum(entry.attr or 0, 4, false, true)
	end
	return table.concat(parts)
end

function filesystem.setAttributes(path, raw)
	local node = findNode(path)
	if not node then
		return false, "no such file system"
	end
	raw = tonumber(raw) or 0

	local isDirectory = filesystem.isDirectory(path)
	if not isDirectory and not filesystem.exists(path) then
		return false, "no such file"
	end
	-- Unmanaged filesystems may implement attributes themselves.
	if node.setAttributes then
		return node.setAttributes(path, raw)
	end
	if not io.tounum then
		return false, "attribute support is not available yet"
	end

	local dir, name
	if isDirectory then
		dir = path
		if dir:sub(-1) ~= "/" then dir = dir .. "/" end
	else
		dir = filesystem.path(path)
		name = filesystem.name(path)
	end
	if dir == "" then
		return false, "invalid path"
	end

	local dataPath = dir .. ".dir"
	local data = readDirData(dataPath)
	if isDirectory then
		data.dirAttr = raw
	else
		local found = false
		for _, entry in ipairs(data.list) do
			if entry.name == name then
				entry.attr = raw
				found = true
				break
			end
		end
		if not found then
			data.list[#data.list + 1] = {name = name, attr = raw}
			data.byName[name] = raw
		end
	end

	local dataNode, dataRest = findNode(dataPath)
	if not dataNode then
		return false, "no drive found for " .. tostring(dataPath)
	end
	local content = serializeDirData(data)
	local handle, err = dataNode.open(dataRest, "w")
	if not handle then
		return false, err
	end
	dataNode.write(handle, content)
	dataNode.close(handle)
	return true
end

function filesystem.getAttributes(path, raw)
	if not io.fromunum then return {} end -- this can only happen before complete boot, and isn't security fault as io is protected after boot.
	local attr = nil
	local node, rest = findNode(path)
	if node then
		if node.getAttributes then -- unmanaged node that supports attributes natively
			local ok, native = pcall(node.getAttributes, rest)
			if ok then attr = native end
		end
		if attr == nil then
			local isDirectory = filesystem.isDirectory(path)
			local dir
			if isDirectory then
				dir = path
				if dir:sub(-1) ~= "/" then dir = dir .. "/" end
			else
				dir = filesystem.path(path)
			end

			local dataPath = dir .. ".dir"
			local hasDirData = dir ~= "" and filesystem.exists(dataPath)
			if hasDirData then
				local data = readDirData(dataPath)
				if isDirectory then
					attr = data.dirAttr
				else
					local name = filesystem.name(path)
					attr = data.byName[name]
					if attr == nil then
						attr = data.dirAttr -- no attributes for this specific file
					end
				end
			else
				if dir == "" or dir:match("^%a:/$") then
					attr = 0
				else
					attr = filesystem.getAttributes(filesystem.path(dir), true)
					if attr == nil then attr = 0 end
				end
			end
		end
	end
	if raw then
		return attr
	end
	if attr == nil then attr = 0 end
	if _VERSION ~= "Lua 5.2" then
		return load([[
			local attr = ...
			return {
				readOnly = ((attr & 1) == 1),
				system = ((attr & 2) == 2),
				protected = ((attr & 4) == 4),
				hidden = ((attr & 8) == 8),
				noExecute = ((attr & 16) == 16),
			}
		]])(attr)
	elseif bit32 and bit32.band then
		return {
			readOnly = (bit32.band(attr, 1) == 1), -- always read-only
			system = (bit32.band(attr, 2) == 2), -- protected in Write
			protected = (bit32.band(attr, 4) == 4), -- protected in Read/Write
			hidden = (bit32.band(attr, 8) == 8), -- hidden
			noExecute = (bit32.band(attr, 16) == 16) -- not executable (even if the filename suggests it)
		}
	else
		error("missing bit32")
	end
end

function filesystem.list(path)
	local node, rest = findNode(path)
	local result = {}
	if node then
		if not node.exists(rest) then
			error("directory doesn't exists")
		end
		result = node.list(rest)
	else
		error("no drive found for " .. tostring(path))
	end
	local set = {}
	local keys = {}
	table.sort(result)
	for _,name in ipairs(result) do
		if name ~= ".dir" and type(name) == "string" then
			local key = filesystem.canonical(name)
			set[key] = name
			table.insert(keys, key)
		end
	end
	local i = 1
	setmetatable(set, {
		__call = function()
			i = i + 1
			return keys[i-1], set[keys[i-1]]
		end
	})
	return set
end

function filesystem.makeDirectory(path)
	local node, rest = findNode(path)
	if node then
		local ok, err = node.makeDirectory(rest)
		if not ok then
			error("could not create directory: " .. tostring(err))
		end
	else
		error("no drive")
	end
end

function filesystem.remove(path)
	local node, rest = findNode(path)
	if not node then
		return false
	end
	return node.remove(rest)
end

function filesystem.rename(oldPath, newPath)
	local oldNode, oldRest = findNode(oldPath)
	local newNode, newRest = findNode(newPath)
	if not oldNode or not newNode then
		return false, "drive not found"
	end
	if not oldNode.exists(oldRest) then
		return false, "source not found"
	end
	if oldNode == newNode then
		return oldNode.rename(oldRest, newRest)
	else
		local content, err = readAll(oldNode, oldRest)
		if content == nil then
			return false, err
		end
		local ok, perr = ensureParent(newPath)
		if not ok then
			return false, perr
		end
		return writeAllTo(newNode, newRest, content)
	end
end

function filesystem.unmanagedFilesystems()
	return {}
end

function filesystem.copy(src, dest)
	local oldNode, oldRest = findNode(src)
	local newNode, newRest = findNode(dest)
	if not oldNode or not newNode then
		return false, "drive not found"
	end
	local content, err = readAll(oldNode, oldRest)
	if content == nil then
		return false, err
	end
	local ok, perr = ensureParent(dest)
	if not ok then
		return false, perr
	end
	return writeAllTo(newNode, newRest, content)
end

function filesystem.open(path, mode)
	checkArg(1, path, "string")
	if not mode then
		mode = "r"
	end
	checkArg(2, mode, "string")
	assert(({r=true, rb=true, w=true, wb=true, a=true, ab=true})[mode],
		"bad argument #2 (r[b], w[b] or a[b] expected, got " .. mode .. ")")
	local attributes = filesystem.getAttributes(path) or {}
	if attributes.protected then
		if not require("security").hasPermission("file.protected") then
			return nil, "not enough permissions (requires permission \"file.protected\")"
		end
	end
	if mode ~= "r" and mode ~= "rb" and attributes.system and package.loaded.security then
		if not require("security").hasPermission("file.system") then
			return nil, "not enough permissions (requires permission \"file.system\")"
		end
	end
	if attributes.readOnly and mode ~= "r" and mode ~= "rb" then
		return nil, "file is read-only"
	end
	local node, rest = findNode(path)
	if not node then
		return nil, "drive not found"
	end
	if (({r=true,rb=true})[mode] and not node.exists(rest)) then
		return nil, "file not found"
	end
	local handle, reason = node.open(rest, mode)
	if not handle then
		return nil, reason
	end

	local function create_handle_method(key)
		return function(self, ...)
			if not self.handle then
				return nil, "file closed"
			end
			return self.fs[key](self.handle, ...)
		end
	end
	local cproc = nil
	if package.loaded and package.loaded.tasks then cproc = require("tasks").getCurrentProcess() end
	local stream =
	{
		fs = node,
		handle = handle,
		proc = cproc,
		close = function(self)
			if self.handle then
				self.fs.close(self.handle)
				self.handle = nil
				self:detach()
			end
		end,
		-- Detach handle from the process that created it: this operation is
		-- dangerous as it could leave the handle unclosed until shutdown !
		detach = function(self)
			if self.proc ~= nil then
				for k, v in pairs(self.proc.exitHandlers) do
					if v == self.exitHandler then
						table.remove(self.proc.exitHandlers, k)
						break
					end
				end
			end
		end
	}
	stream.read = create_handle_method("read")
	stream.seek = create_handle_method("seek")
	stream.write = create_handle_method("write")
	if stream.proc ~= nil then
		stream.exitHandler = function()
			stream:close()
		end
		table.insert(stream.proc.exitHandlers, stream.exitHandler)
	end
	return stream
end

filesystem.findNode = findNode
filesystem.segments = segments

-------------------------------------------------------------------------------

return filesystem

-- Fuchas installer for OpenOS
-- Supports downloading the package from GitHub or installing from a local
-- fuchas.cpio file (useful on computers without an internet card).
--
-- Tested with OpenOS on OpenComputers 1.7.x, 1.8.x (Lua 5.3) and the
-- experimental Lua 5.4 architecture.

local component  = require("component")
local computer   = require("computer")
local term       = require("term")
local gpu        = term.gpu()
local event      = require("event")
local filesystem = require("filesystem")

if _VERSION == "Lua 5.2" then
	-- Fuchas itself requires Lua 5.3+ (it uses native bitwise operators and
	-- string.pack).  Try to help the user switch instead of failing later.
	local switched = false
	if computer.getArchitectures and computer.setArchitecture then
		local ok, archs = pcall(computer.getArchitectures)
		if ok and type(archs) == "table" then
			for _, name in pairs(archs) do
				if name == "Lua 5.3" then
					pcall(computer.setArchitecture, "Lua 5.3")
					switched = true
					break
				end
			end
		end
	end
	if switched then
		error("Fuchas requires Lua 5.3 or newer. The computer was switched to Lua 5.3; please run the installer again.")
	else
		error("Fuchas requires Lua 5.3 or newer. Shift-click your CPU/APU and select the Lua 5.3 architecture, then run the installer again.")
	end
end

local width, height = gpu.getResolution()
local stage         = 1
local selected      = 2
local maxSelect     = 2
local run           = true
local branch        = "main"
local devRelease    = false
local doErase       = false
local downloading   = ""
local baseDir       = os.getenv("BASE_DIR") or "/"
local cpioBaseDir   = os.getenv("CPIO_BASE_DIR") or "/"
local localCpio     = os.getenv("FUCHAS_CPIO") or ""

local repoURL = "https://raw.githubusercontent.com/Nenormalniypon/Fuchas/"
local mirrorURLs = {
	"https://cdn.jsdelivr.net/gh/Nenormalniypon/Fuchas@",
	"https://raw.githack.com/Nenormalniypon/Fuchas/"
}

local function normalizeDir(path)
	path = tostring(path or "/"):gsub("\\", "/")
	if path == "" then path = "/" end
	if path:sub(-1) ~= "/" then path = path .. "/" end
	return path
end

baseDir = normalizeDir(baseDir)
if cpioBaseDir == "" then cpioBaseDir = baseDir end
cpioBaseDir = normalizeDir(cpioBaseDir)

local function isDirectory(path)
	local ok, result = pcall(filesystem.isDirectory, path)
	return ok and result == true
end

local function exists(path)
	local ok, result = pcall(filesystem.exists, path)
	return ok and result == true
end

local function ensureDir(path)
	if path == nil or path == "" or path == "/" then return true end
	path = path:gsub("\\", "/"):gsub("/+$", "")
	if path == "" or isDirectory(path) then return true end
	local parent = path:match("^(.*)/[^/]*$")
	if parent and parent ~= "" and parent ~= path then
		local ok, err = ensureDir(parent)
		if not ok then return nil, err end
	end
	local ok, err = pcall(filesystem.makeDirectory, path)
	if not ok and not isDirectory(path) then
		return nil, tostring(err)
	end
	return true
end

local node = filesystem.findNode(baseDir)
if not node then
	error("Base directory (" .. baseDir .. ") does not exist.")
end
if node.fs and node.fs.isReadOnly and node.fs.isReadOnly() then
	error("Base directory (" .. baseDir .. ") is read-only, are you trying to install from floppy?")
end

local cpioNode = filesystem.findNode(cpioBaseDir)
if not cpioNode then
	cpioBaseDir = baseDir
elseif cpioNode.fs and cpioNode.fs.isReadOnly and cpioNode.fs.isReadOnly() then
	cpioBaseDir = baseDir
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function readFile(path)
	local handle, err = io.open(path, "rb")
	if not handle then return nil, err end
	local chunks = {}
	while true do
		local data, rerr = handle:read(8192)
		if data == nil then
			if rerr then
				handle:close()
				return nil, rerr
			end
			break
		end
		if data == "" then break end
		chunks[#chunks + 1] = data
	end
	handle:close()
	return table.concat(chunks)
end

local function writeFile(path, data)
	local handle, err = io.open(path, "wb")
	if not handle then return nil, err end
	local ok, werr = handle:write(data)
	if not ok then
		handle:close()
		return nil, werr
	end
	local cok, cerr = handle:close()
	if cok == nil or cok == false then
		return nil, cerr or "could not close file"
	end
	return true
end

local function stringStream(data)
	local stream = {}
	local pos = 1
	function stream:read(amount)
		if amount == nil or amount == math.huge then
			amount = #data - pos + 1
		end
		amount = math.floor(amount)
		if amount <= 0 then return "" end
		if pos > #data then return nil end
		local chunk = data:sub(pos, pos + amount - 1)
		pos = pos + #chunk
		return chunk
	end
	function stream:seek(whence, offset)
		whence = whence or "cur"
		offset = math.floor(offset or 0)
		if whence == "set" or whence == "beg" then
			pos = offset + 1
		elseif whence == "cur" then
			pos = pos + offset
		elseif whence == "end" then
			pos = #data + offset + 1
		else
			return nil, "invalid whence"
		end
		if pos < 1 then pos = 1 end
		return pos - 1
	end
	function stream:close() end
	return stream
end

local function readExact(stream, amount, what)
	if amount == 0 then return "" end
	local chunks = {}
	local got = 0
	while got < amount do
		local chunk, err = stream:read(amount - got)
		if not chunk then
			return nil, (err or (what .. ": unexpected end of archive"))
		end
		if #chunk == 0 then
			return nil, what .. ": unexpected end of archive"
		end
		chunks[#chunks + 1] = chunk
		got = got + #chunk
	end
	return table.concat(chunks)
end

local function readInt(stream, amount)
	local bytes, err = readExact(stream, amount, "CPIO header")
	if not bytes then return nil, err end
	local value = 0
	for i = #bytes, 1, -1 do
		value = value * 256 + bytes:byte(i)
	end
	return value
end

local function validateCpio(data)
	if type(data) ~= "string" or #data < 26 then
		return false, "archive is empty or truncated"
	end
	local magic = data:byte(1) + data:byte(2) * 256
	if magic ~= 0x71C7 then
		if data:sub(1, 6) == "070701" or data:sub(1, 6) == "070702" then
			return false, "archive uses the 'newc' CPIO format; Fuchas needs the old binary format"
		end
		return false, string.format("not a Fuchas CPIO archive (magic 0x%04X)", magic)
	end
	if not data:find("TRAILER!!!", 1, true) then
		return false, "archive has no CPIO trailer (the download was probably incomplete)"
	end
	return true
end

local function cleanName(name)
	name = tostring(name or ""):gsub("\\", "/")
	name = name:gsub("^%./+", ""):gsub("^/+", "")
	if name == "" or name == "." then return nil end
	if name:match("^%a:") then return nil end
	for segment in name:gmatch("[^/]+") do
		if segment == ".." then return nil end
	end
	if name:find("\0", 1, true) then return nil end
	return name
end

-- Extract an old-binary (070707) CPIO archive.  Unlike the original parser
-- this validates every read, so a dead mirror can no longer cause
-- "string.byte(nil)" deep inside readint().
local function extract(data, onProgress)
	local stream = stringStream(data)
	local entries, files = 0, 0

	local function readHeader()
		local magic, err = readInt(stream, 2)
		if not magic then return nil, err end
		local names = {"dev", "ino", "mode", "uid", "gid", "nlink", "rdev"}
		local values = {}
		for i = 1, #names do
			local value, derr = readInt(stream, 2)
			if not value then return nil, derr end
			values[names[i]] = value
		end
		local high, herr = readInt(stream, 2)
		if not high then return nil, herr end
		local low, lerr = readInt(stream, 2)
		if not low then return nil, lerr end
		local namesize, nerr = readInt(stream, 2)
		if not namesize then return nil, nerr end
		local fhigh, ferr = readInt(stream, 2)
		if not fhigh then return nil, ferr end
		local flow, floerr = readInt(stream, 2)
		if not flow then return nil, floerr end
		return {
			magic = magic,
			mode = values.mode,
			namesize = namesize,
			filesize = fhigh * 65536 + flow
		}
	end

	while true do
		local header, herr = readHeader()
		if not header then return nil, herr end
		if header.magic ~= 0x71C7 then
			return nil, string.format("bad CPIO magic 0x%04X (expected 0x71C7)", header.magic)
		end

		local rawName, nerr = readExact(stream, header.namesize, "CPIO file name")
		if not rawName then return nil, nerr end
		local name = rawName:match("^([^%z]*)") or ""
		if header.namesize % 2 == 1 then
			local pad, perr = readExact(stream, 1, "CPIO name padding")
			if not pad then return nil, perr end
		end

		if name == "TRAILER!!!" then
			break
		end

		local clean, reason = cleanName(name)
		if not clean then
			return nil, "unsafe path in archive: " .. tostring(name) .. (reason and (" (" .. reason .. ")") or "")
		end

		local ftype = math.floor(header.mode / 4096) % 16
		local isDirectory = (ftype == 4) -- 0040000
		local isFile = (ftype == 8) -- 0100000

		local body = nil
		if isFile and header.filesize > 0 then
			local derr
			body, derr = readExact(stream, header.filesize, clean)
			if not body then return nil, derr end
		elseif header.filesize > 0 then
			local ignored, derr = readExact(stream, header.filesize, clean)
			if not ignored then return nil, derr end
		end
		if header.filesize % 2 == 1 then
			local pad, perr = readExact(stream, 1, "CPIO data padding")
			if not pad then return nil, perr end
		end

		local target = baseDir .. clean
		if isDirectory then
			local ok, derr = ensureDir(target)
			if not ok then
				return nil, "could not create directory " .. target .. ": " .. tostring(derr)
			end
		elseif isFile then
			local parent = target:match("^(.*)/[^/]*$")
			if parent then
				local ok, derr = ensureDir(parent)
				if not ok then
					return nil, "could not create directory " .. parent .. ": " .. tostring(derr)
				end
			end
			local ok, werr = writeFile(target, body or "")
			if not ok then
				return nil, "could not write " .. target .. ": " .. tostring(werr)
			end
			files = files + 1
		end

		entries = entries + 1
		if onProgress then
			onProgress(clean, entries, files, isDirectory)
		end
	end

	return entries, files
end

-- ---------------------------------------------------------------------------
-- Network
-- ---------------------------------------------------------------------------

local function getInternet()
	if component.getPrimary then
		local ok, internet = pcall(component.getPrimary, "internet")
		if ok and internet then return internet end
	end
	return component.internet
end

local drawStage -- defined with the UI below

local function httpGet(url)
	local internet = getInternet()
	if not internet then
		return nil, "no internet card is available"
	end

	local ok, connection, rerr = pcall(internet.request, url)
	if not ok then return nil, tostring(connection) end
	if not connection then return nil, tostring(rerr or "internet.request failed") end

	if connection.finishConnect then
		local cok, cres, cerr = pcall(connection.finishConnect, connection)
		if not cok then
			pcall(connection.close, connection)
			return nil, tostring(cres)
		elseif cres == false then
			pcall(connection.close, connection)
			return nil, tostring(cerr or "connection failed")
		end
	end

	if connection.response then
		local rok, code, message = pcall(connection.response, connection)
		code = rok and tonumber(code)
		if code and code >= 400 then
			pcall(connection.close, connection)
			return nil, "HTTP " .. code .. (message and (" " .. tostring(message)) or "")
		end
	end

	local chunks, total = {}, 0
	while true do
		local rok, data, derr = pcall(connection.read, connection, 8192)
		if not rok then
			pcall(connection.close, connection)
			return nil, tostring(data)
		end
		if data == nil then
			if derr then
				pcall(connection.close, connection)
				return nil, tostring(derr)
			end
			break
		end
		if #data == 0 then break end
		chunks[#chunks + 1] = data
		total = total + #data
	end
	pcall(connection.close, connection)

	if total == 0 then
		return nil, "empty response from " .. url
	end
	return table.concat(chunks)
end

local function archiveURLs()
	local b = devRelease and "dev" or "main"
	local urls = {repoURL .. b .. "/release.cpio"}
	for _, mirror in ipairs(mirrorURLs) do
		urls[#urls + 1] = mirror .. b .. "/release.cpio"
	end
	return urls
end

local function findLocalArchive()
	local candidates = {}
	if localCpio ~= "" then candidates[#candidates + 1] = localCpio end
	candidates[#candidates + 1] = cpioBaseDir .. "fuchas.cpio"
	if baseDir ~= cpioBaseDir then
		candidates[#candidates + 1] = baseDir .. "fuchas.cpio"
	end
	candidates[#candidates + 1] = "/fuchas.cpio"

	for _, path in ipairs(candidates) do
		if exists(path) then
			local data, err = readFile(path)
			if data then
				local ok, verr = validateCpio(data)
				if ok then return data, path end
				-- Remember the reason for the last bad local candidate.
				downloading = path .. ": " .. tostring(verr)
			elseif err then
				downloading = path .. ": " .. tostring(err)
			end
		end
	end
	return nil
end

local function downloadArchive()
	local errors = {}
	for _, url in ipairs(archiveURLs()) do
		downloading = url
		drawStage()
		local data, err = httpGet(url)
		if data then
			local ok, verr = validateCpio(data)
			if ok then return data, url end
			err = verr
		end
		errors[#errors + 1] = url .. ": " .. tostring(err)
	end
	return nil, table.concat(errors, "\n")
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local function drawBorder(x, y, borderWidth, borderHeight)
	gpu.set(x, y, "\226\149\148")
	gpu.set(x + borderWidth, y, "\226\149\151")
	gpu.fill(x + 1, y, borderWidth - 1, 1, "\226\149\144")
	gpu.fill(x + 1, y + borderHeight, borderWidth - 1, 1, "\226\149\144")
	gpu.set(x, y + borderHeight, "\226\149\154")
	gpu.set(x + borderWidth, y + borderHeight, "\226\149\157")
	gpu.fill(x, y + 1, 1, borderHeight - 1, "\226\149\145")
	gpu.fill(x + borderWidth, y + 1, 1, borderHeight - 1, "\226\149\145")
end

local function drawEntries()
	if stage == 1 then
		if selected == 1 then
			gpu.setBackground(0xFFFFFF)
			gpu.setForeground(0x000000)
		else
			gpu.setBackground(0x000000)
			gpu.setForeground(0xFFFFFF)
		end
		gpu.set(7, 11, "Erase \"OpenOS\" for a clean install")
		if selected == 2 then
			gpu.setBackground(0xFFFFFF)
			gpu.setForeground(0x000000)
		else
			gpu.setBackground(0x000000)
			gpu.setForeground(0xFFFFFF)
		end
		gpu.set(7, 12, "Keep \"OpenOS\", install dual-boot")
		gpu.setBackground(0x000000)
		gpu.setForeground(0xFFFFFF)
	elseif stage == 2 then
		if selected == 1 then
			gpu.setBackground(0xFFFFFF)
			gpu.setForeground(0x000000)
		else
			gpu.setBackground(0x000000)
			gpu.setForeground(0xFFFFFF)
		end
		gpu.set(7, 11, "Stable release (recommended)")
		if selected == 2 then
			gpu.setBackground(0xFFFFFF)
			gpu.setForeground(0x000000)
		else
			gpu.setBackground(0x000000)
			gpu.setForeground(0xFFFFFF)
		end
		gpu.set(7, 12, "Development release (unstable)")
		gpu.setBackground(0x000000)
		gpu.setForeground(0xFFFFFF)
	end
end

drawStage = function()
	gpu.setBackground(0x000000)
	gpu.setForeground(0xFFFFFF)
	gpu.fill(1, 1, width, height, " ")
	gpu.set(math.floor(width / 2 - 9), 1, "Fuchas Installation")
	if stage == 1 then
		gpu.set(5, 5, "You are going to install Fuchas on this computer.")
		gpu.set(5, 6, "You can either wipe your drive or put Fuchas")
		gpu.set(5, 7, "next to your OpenOS installation, and have")
		gpu.set(5, 8, "a dual-boot configuration.")
		drawBorder(6, 10, width - 12, 3)
		drawEntries()
	elseif stage == 2 then
		gpu.set(5, 5, "Fuchas is separated in two release channels.")
		gpu.set(5, 6, "Stable is recommended. Development has the")
		gpu.set(5, 7, "latest features but may be unstable.")
		drawBorder(6, 10, width - 12, 3)
		drawEntries()
	elseif stage == 3 then
		if not doErase then
			gpu.set(5, 4, "Information:")
			gpu.set(5, 5, "Dual-boot will be effective on the hard drive,")
			gpu.set(5, 6, "meaning dual-boot will not affect the EEPROM.")
			gpu.set(5, 7, "You will be prompted between launching OpenOS")
			gpu.set(5, 8, "or Fuchas when booting from this hard drive.")
			gpu.set(5, 10, "Please wait..")
		else
			gpu.set(5, 5, "OpenOS will be replaced by Fuchas.")
			gpu.set(5, 6, "Existing OpenOS files will not be deleted,")
			gpu.set(5, 7, "but the computer will boot directly into Fuchas.")
			gpu.set(5, 9, "Please wait..")
		end
	elseif stage == 4 then
		gpu.set(5, 5, "Fetching install files..")
	elseif stage == 5 then
		gpu.set(5, 5, "Installing Fuchas..")
		local text = tostring(downloading or "")
		if #text > width - 10 then text = "..." .. text:sub(#text - (width - 13)) end
		gpu.set(5, 6, text)
	elseif stage == 6 then
		gpu.set(5, 5, "Create your administrator account")
		gpu.set(5, 6, "Username: admin")
		gpu.set(5, 8, "New account password:")
		gpu.set(5, 9, string.rep(" ", width - 8))
		term.setCursor(5, 9)
	elseif stage == 7 then
		gpu.set(5, 5, "Done!")
		gpu.set(5, 6, "Restarting the computer..")
		gpu.set(5, 7, "Please wait..")
	end
end

local function showError(err)
	stage = 0
	gpu.setBackground(0x400000)
	gpu.setForeground(0xFFFFFF)
	gpu.fill(1, 1, width, height, " ")
	gpu.set(2, 1, "Fuchas installation failed")
	local row = 3
	for line in (tostring(err) .. "\n"):gmatch("([^\n]*)\n") do
		line = line:gsub("%c", " "):gsub("\t", " ")
		while #line > width - 4 do
			gpu.set(2, row, line:sub(1, width - 4))
			line = line:sub(width - 3)
			row = row + 1
			if row > height - 3 then break end
		end
		if row <= height - 3 then
			gpu.set(2, row, line)
			row = row + 1
		end
		if row > height - 3 then break end
	end
	gpu.set(2, height - 1, "Press any key to exit.")
	pcall(event.pull, "key_down")
	run = false
end

-- ---------------------------------------------------------------------------
-- Installation
-- ---------------------------------------------------------------------------

local function readPassword(prompt)
	drawStage()
	gpu.set(5, 8, prompt)
	gpu.set(5, 9, string.rep(" ", width - 8))
	term.setCursor(5, 9)

	local ok, password = pcall(term.read, nil, nil, nil, "*")
	if not ok or type(password) ~= "string" then
		-- Older OpenOS versions only understand the options table.
		ok, password = pcall(term.read, {pwchar = "*"})
	end
	if not ok or type(password) ~= "string" then
		error("could not read the password: " .. tostring(password))
	end
	return (password:gsub("[\r\n]+$", ""))
end

local function createAdminAccount()
	local password, confirmation
	repeat
		password = readPassword("New account password:")
		if password == "" then
			gpu.set(5, 11, "Password cannot be empty.")
			pcall(os.sleep, 1)
		else
			confirmation = readPassword("Confirm password:")
			if password ~= confirmation then
				gpu.set(5, 11, "Passwords do not match. Try again.")
				pcall(os.sleep, 1)
			end
		end
	until password ~= "" and password == confirmation

	if not ensureDir(baseDir .. "Users/admin") then
		error("could not create the admin user directory")
	end

	-- SHA3-512 is implemented in pure Lua and needs string.pack (Lua 5.3+).
	if not string.pack then
		error("this computer runs a Lua version without string.pack; Fuchas needs Lua 5.3 or newer")
	end

	local sha3 = dofile(baseDir .. "Fuchas/Libraries/sha3.min.lua")
	if not sha3 or not sha3.bin or not sha3.sha3 then
		error("the package is missing Fuchas/Libraries/sha3.min.lua")
	end

	if os.time then
		math.randomseed(os.time())
	else
		math.randomseed(math.floor(computer.uptime() * 1000))
	end
	local salt = {}
	for i = 1, 32 do
		salt[i] = string.char(math.random(0, 255))
	end
	salt = table.concat(salt)

	local hash = sha3.bin.stohex(sha3.sha3.sha512(salt .. password))
	local account = string.format([[
{
	name = "admin",
	password = "%s",
	salt = %q,
	security = "sha3-512",
	userId = 0,
	groups = {}
}
]], hash, salt)

	local ok, err = writeFile(baseDir .. "Users/admin/account.lon", account)
	if not ok then
		error("could not write the admin account: " .. tostring(err))
	end
end

local function install()
	local data, source = findLocalArchive()
	if not data then
		stage = 5
		drawStage()
		local err
		data, err = downloadArchive()
		if not data then
			error("Could not download Fuchas.\n" .. tostring(err) ..
				"\n\nDownload release.cpio manually and save it as " ..
				cpioBaseDir .. "fuchas.cpio, then run this installer again.")
		end
	else
		source = source or "local archive"
	end

	local ok, verr = validateCpio(data)
	if not ok then
		error("Invalid Fuchas package: " .. tostring(verr))
	end

	stage = 5
	downloading = source or "package"
	drawStage()

	local lastDraw = 0
	local count, writtenOrError = extract(data, function(name, entries, files)
		downloading = name
		if entries - lastDraw >= 8 then
			lastDraw = entries
			drawStage()
		end
	end)
	if not count then
		error("Could not extract the package: " .. tostring(writtenOrError))
	end

	local loader = doErase and "init.lua" or "dualboot_init.lua"
	local loaderPath = baseDir .. loader
	if not exists(loaderPath) then
		-- Older packages did not contain the boot loaders.  Keep a network
		-- fallback so such packages still install.
		local content, derr = httpGet(repoURL .. branch .. "/" .. loader)
		if not content then
			error("The package is missing " .. loader ..
				" and it could not be downloaded: " .. tostring(derr))
		end
		local wok, werr = writeFile(loaderPath, content)
		if not wok then
			error("Could not write " .. loaderPath .. ": " .. tostring(werr))
		end
	end

	if loader ~= "init.lua" then
		local content, rerr = readFile(loaderPath)
		if not content then
			error("Could not read " .. loaderPath .. ": " .. tostring(rerr))
		end
		local wok, werr = writeFile(baseDir .. "init.lua", content)
		if not wok then
			error("Could not write " .. baseDir .. "init.lua: " .. tostring(werr))
		end
	end

	if not exists(baseDir .. "Fuchas/Kernel/boot.lua") then
		error("The package did not contain the Fuchas kernel.")
	end
	if not exists(baseDir .. "Fuchas/Libraries/sha3.min.lua") then
		error("The package did not contain the password hashing library.")
	end

	stage = 6
	createAdminAccount()

	stage = 7
	drawStage()
	pcall(computer.shutdown, true)
	run = false
end

local function process()
	if stage == 2 then
		devRelease = (selected == 2)
		branch = devRelease and "dev" or "main"
		selected = 1
		stage = 3
		drawStage()
		os.sleep(2)
		stage = 4
		drawStage()
		local ok, err = xpcall(install, debug.traceback)
		if not ok then showError(err) end
	elseif stage == 1 then
		stage = 2
		doErase = (selected == 1)
		selected = 1
		drawStage()
	end
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

if width > 80 or height > 25 then
	gpu.setResolution(80, 25)
	width, height = 80, 25
end

gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
gpu.fill(1, 1, width, height, " ")
gpu.set(1, height, "Ctrl+C = Exit")
gpu.set(math.floor(width - 15), height, "Enter = Continue")

drawStage()
os.sleep(0.5) -- let the key that launched us go

while run do
	local id, _, _, code = event.pull()
	if id == "interrupted" then
		break
	elseif id == "key_down" then
		if code == 200 then -- up
			if selected > 1 then selected = selected - 1 end
		elseif code == 208 then -- down
			if selected < maxSelect then selected = selected + 1 end
		end
		drawEntries()
	elseif id == "key_up" then
		if code == 28 then -- enter
			process()
		end
	end
end

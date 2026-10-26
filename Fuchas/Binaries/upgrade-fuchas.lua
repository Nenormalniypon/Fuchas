-- Variables
local filesystem = require("filesystem")
local driverLib  = require("driver")

-- Fuchas blocks raw component access for non-admin processes, so prefer the
-- internet driver; fall back to the raw component when running as admin.
local internet
do
	local ok, net = pcall(function() return driverLib.internet end)
	if ok then internet = net end
end
if not internet then
	local ok, comp = pcall(function() return component.internet end)
	if ok then internet = comp end
end

local gpu
do
	local ok, drv = pcall(function() return driverLib.gpu end)
	if ok then gpu = drv end
end

local repoURL = "https://raw.githubusercontent.com/Nenormalniypon/Fuchas/main/"

-- AdorableCatgirl's uncpio
local function ext(stream)
	local dent = {
		magic = 0,
		dev = 0,
		ino = 0,
		mode = 0,
		uid = 0,
		gid = 0,
		nlink = 0,
		rdev = 0,
		mtime = 0,
		namesize = 0,
		filesize = 0
	}
	
	local function readint(amt)
		local tmp = 0
		for i=1, amt do
			local b = stream:read(1)
			if not b or #b == 0 then return nil end
			tmp = tmp + string.byte(b) * 2 ^ ((i-1)*8)
		end
		return tmp
	end
	local function ensureDir(path)
		local acc = ""
		for part in path:gmatch("[^/]+") do
			acc = acc .. (acc == "" and "" or "/") .. part
			if not filesystem.isDirectory("A:/" .. acc) then
				pcall(filesystem.makeDirectory, "A:/" .. acc)
			end
		end
	end
	local function fwrite()
		local dir = dent.name:match("^(.*)/[^/]*$")
		if dir then
			ensureDir(dir)
		end
		local hand = io.open("A:/" .. dent.name, "w")
		if not hand then
			error("cannot write A:/" .. dent.name)
		end
		hand:write(stream:read(dent.filesize) or "")
		hand:close()
	end
	while true do
		dent.magic = readint(2)
		if not dent.magic then break end
		local rev = false
		if (dent.magic ~= tonumber("070707", 8)) then rev = true end
		dent.dev = readint(2)
		dent.ino = readint(2)
		dent.mode = readint(2)
		dent.uid = readint(2)
		dent.gid = readint(2)
		dent.nlink = readint(2)
		dent.rdev = readint(2)
		dent.mtime = readint(2) * 65536 + readint(2)
		dent.namesize = readint(2)
		dent.filesize = readint(2) * 65536 + readint(2)
		local name = (stream:read(dent.namesize) or ""):sub(1, dent.namesize-1)
		if (name == "TRAILER!!!") then
			break
		end
		dent.name = name
		if gpu then
			local w = 80
			local okRes, res = pcall(gpu.getResolution)
			if okRes and type(res) == "number" then
				w = res
			end
			gpu.fill(1, 1, w, 25, 0x000000)
			gpu.set(math.floor(w / 2) - 9, 1, "Fuchas Installation")
			gpu.set(5, 5, "Downloading..")
			gpu.set(5, 6, name)
		end
		
		if (dent.namesize % 2 ~= 0) then
			stream:read(1)
		end
		local safe = not dent.name:find("%.%.") and dent.name:sub(1, 1) ~= "/"
		local isFile = dent.mode and math.floor(dent.mode / 32768) % 2 == 1
		local isDir = dent.mode and math.floor(dent.mode / 16384) % 2 == 1
		if isFile and safe then
			fwrite()
		elseif isDir and safe then
			ensureDir(dent.name)
			if dent.filesize > 0 then
				stream:read(dent.filesize)
			end
		elseif dent.filesize > 0 then
			-- Unsafe path or unknown entry type: skip the data but keep the
			-- stream aligned with the next CPIO header.
			stream:read(dent.filesize)
		end
		if (dent.filesize % 2 ~= 0) then
			stream:read(1)
		end
	end
end

local function download(url)
	if not internet then
		error("no internet card found")
	end
	local con = internet.request(url)
	if not con then
		error("request failed: " .. tostring(url))
	end
	local buf = {}
	while true do
		local data = con.read(math.huge)
		if not data or data == "" then break end
		buf[#buf + 1] = data
	end
	con.close()
	return table.concat(buf)
end

local function install()
	if not filesystem.isDirectory("A:/Temporary") then
		filesystem.makeDirectory("A:/Temporary")
	end
	print("Downloading release..")
	local cpioPath = "A:/Temporary/fuchas.cpio"
	if internet and internet.httpDownload then
		local ok, err = pcall(internet.httpDownload, repoURL .. "release.cpio", cpioPath)
		if not ok then
			error("download failed: " .. tostring(err))
		end
	else
		local cpio = download(repoURL .. "release.cpio")
		local tmpCpio = io.open(cpioPath, "w")
		if not tmpCpio then
			error("cannot write " .. cpioPath)
		end
		tmpCpio:write(cpio)
		tmpCpio:close()
	end
	local tmpCpio = filesystem.open(cpioPath, "r")
	if not tmpCpio then
		error("cannot open downloaded archive")
	end
	print("Extracting Fuchas..")
	ext(tmpCpio)
	tmpCpio:close()
	filesystem.remove(cpioPath)
end

print("Upgrading Fuchas (no new version check, always forced)")
install()

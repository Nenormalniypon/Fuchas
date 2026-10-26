local cpio = {}

-- This only reads/writes the "Old" binary format (magic 070707).
function cpio.parse(stream)
	local archive = {}

	local function readExact(count)
		if count == 0 then
			return ""
		end
		local data = stream:read(count)
		if not data or #data ~= count then
			error("unexpected end of cpio archive")
		end
		return data
	end

	-- The old binary format stores the 16-bit magic value 070707 in the
	-- native byte order.  Older versions of this parser read four bytes here
	-- (the magic plus the dev field), so every real archive failed the magic
	-- check.
	local magicBytes = readExact(2)
	local littleEndian
	if io.fromunum(magicBytes, true, 2) == 0x71C7 then
		littleEndian = true
	elseif io.fromunum(magicBytes, false, 2) == 0x71C7 then
		littleEndian = false
	else
		error("not a cpio file: invalid magic bytes")
	end
	-- The first header's magic has already been consumed for endianness
	-- detection, so feed it to the loop without reading it again.
	local firstMagic = 0x71C7
	local pendingMagic = true

	local function readShort()
		return io.fromunum(readExact(2), littleEndian, 2)
	end

	-- mtime and filesize are stored as a pair of 16-bit words, high word first.
	local function readInt()
		local high = readShort()
		local low = readShort()
		return bit32.bor(bit32.lshift(high, 16), low)
	end

	while true do
		local magic
		if pendingMagic then
			magic = firstMagic
			pendingMagic = false
		else
			magic = readShort()
		end
		if magic ~= 0x71C7 then
			error(string.format("not a cpio file: invalid magic 0x%04X", magic))
		end
		local dev = readShort()
		local ino = readShort()
		local mode = readShort()
		local uid = readShort()
		local gid = readShort()
		local nlink = readShort()
		local rdev = readShort()
		local mtime = readInt()
		local nameSize = readShort()
		local fileSize = readInt()

		if nameSize < 1 or nameSize > 65535 then
			error("invalid cpio entry name size")
		end
		local nameData = readExact(nameSize)
		local path = nameData:sub(1, nameSize - 1)
		if nameSize % 2 ~= 0 then
			readExact(1) -- name padding
		end
		if path == "TRAILER!!!" then
			break
		end

		local data = readExact(fileSize)
		if fileSize % 2 ~= 0 then
			readExact(1) -- data padding
		end

		local isFile = bit32.band(mode, tonumber("0100000", 8)) == tonumber("0100000", 8)
		local isDir = bit32.band(mode, tonumber("0040000", 8)) == tonumber("0040000", 8)

		table.insert(archive, {
			mode = mode,
			dev = dev,
			ino = ino,
			uid = uid,
			gid = gid,
			isFile = isFile,
			isDirectory = isDir,
			nlink = nlink,
			rdev = rdev,
			mtime = mtime,
			name = path,
			data = data
		})
	end
	return archive
end

-- Write a parsed archive file to a stream
function cpio.write(arc, stream)
	local inc = 3 -- increment counter used for "ino" fields

	local function writeStrangeInt(int)
		int = bit32.band(int or 0, 0xFFFFFFFF)
		local msb = bit32.rshift(int, 16)
		local lsb = bit32.band(int, 0xFFFF)
		stream:write(io.tounum(msb, 2, true, true))
		stream:write(io.tounum(lsb, 2, true, true))
	end

	-- Copy the list so repeated writes do not append multiple trailers to the
	-- caller's array.
	local entries = {}
	for i, entry in ipairs(arc) do
		entries[i] = entry
	end
	table.insert(entries, {
		data = "",
		name = "TRAILER!!!",
		mode = 0
	})

	for _, entry in ipairs(entries) do
		local path = entry.name
		local data = entry.data or ""
		stream:write(io.tounum(tonumber("070707", 8), 2, true, true)) -- magic
		stream:write(io.tounum(entry.dev or 0x800, 2, true, true)) -- dev
		stream:write(io.tounum(entry.ino or inc, 2, true, true)) -- ino
		local mode = entry.mode
		if not mode then
			if entry.isDirectory then
				mode = tonumber("040755", 8)
			elseif entry.isFile then
				mode = tonumber("100644", 8)
			else
				error("cannot write non-file and non-directory entry, use \"mode\" field to do so.")
			end
		elseif mode ~= 0 and bit32.band(mode, tonumber("0007777", 8)) == 0 then
			-- The caller supplied only a file type; add sane default permissions.
			mode = bit32.bor(mode, tonumber(entry.isDirectory and "0000755" or "0000644", 8))
		end
		if entry.isDirectory then
			if not entry.nlink then
				entry.nlink = 2
			elseif entry.nlink < 2 then
				entry.nlink = 2
			end
		end
		stream:write(io.tounum(mode, 2, true, true)) -- mode
		stream:write(io.tounum(entry.uid or 0, 2, true, true)) -- uid
		stream:write(io.tounum(entry.gid or 0, 2, true, true)) -- gid
		stream:write(io.tounum(entry.nlink or 1, 2, true, true)) -- nlink
		stream:write(io.tounum(entry.rdev or 0, 2, true, true)) -- rdev
		writeStrangeInt(entry.mtime or 0) -- mtime
		stream:write(io.tounum(path:len() + 1, 2, true, true)) -- namesize
		writeStrangeInt(data:len()) -- filesize

		stream:write(path .. "\0")
		if (path:len() + 1) % 2 ~= 0 then
			stream:write("\0")
		end
		stream:write(data)
		if data:len() % 2 ~= 0 then
			stream:write("\0")
		end

		inc = inc + 1
	end
end

return cpio
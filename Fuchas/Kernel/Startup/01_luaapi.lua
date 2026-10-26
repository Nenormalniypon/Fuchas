-- String
function string.toCharArray(s)
	local chars = {}
	for i = 1, unicode.len(s) do
		table.insert(chars, unicode.sub(s, i, i))
	end
	return chars
end

function string.toByteArray(s)
	local bytes = {}
	for i = 1, #s do
		table.insert(bytes, string.byte(s:sub(i, i)))
	end
	return bytes
end

function string.width(...)
	return unicode.wlen(...)
end

function string.startsWith(src, s)
	return (string.sub(src, 1, #s) == s)
end

function string.endsWith(src, s)
	return (string.sub(src, #src-#s+1, #src) == s)
end

function string.trim(s)
	-- trailing spaces
	local ogs = s
	for i=1, #s do
		local c = ogs:sub(i, i)
		if c == " " then
			s = s:sub(2, #s)
		else
			break
		end
	end

	-- ending spaces
	ogs = s
	for i=#s, 1, -1 do
		local c = s:sub(i, i)
		if c == " " then
			s = s:sub(1, #s-1)
		else
			break
		end
	end
	return s
end

function string.split(str, sep)
	if sep == nil then
		sep = "%s"
	end
	local t={}
	for part in string.gmatch(str, "([^"..sep.."]+)") do
		table.insert(t, part)
	end
	return t
end

function table.getn(tab)
	local i = 0
	for k, v in pairs(tab) do
		if type(k) == "number" then
			i = math.max(i, k+1)
		else
			i = i + 1
		end
	end
	return i
end

function table.contains(tab, element)
	local i = 0
	for k, v in pairs(tab) do
		if v == element then
			return k
		end
	end
	return nil
end

if _VERSION ~= "Lua 5.2" and not OSDATA.CONFIG["NO_52_COMPAT"] then
    load([[
	-- Lua 5.3/5.4 compatibility shim for the Lua 5.2 bit32 library.
	-- All arguments and results are normalized to unsigned 32-bit values,
	-- exactly like the original library.
	local MASK = 0xFFFFFFFF

	local function u32(x)
		return (x or 0) & MASK
	end

	bit32 = {}

	function bit32.band(...)
		local n = select("#", ...)
		if n == 0 then return MASK end
		local num = u32((...))
		for i = 2, n do
			num = num & u32(select(i, ...))
		end
		return u32(num)
	end

	function bit32.bor(...)
		local n = select("#", ...)
		if n == 0 then return 0 end
		local num = u32((...))
		for i = 2, n do
			num = num | u32(select(i, ...))
		end
		return u32(num)
	end

	function bit32.bxor(...)
		local n = select("#", ...)
		if n == 0 then return 0 end
		local num = u32((...))
		for i = 2, n do
			num = num ~ u32(select(i, ...))
		end
		return u32(num)
	end

	function bit32.bnot(x)
		return u32(~u32(x))
	end

	function bit32.lshift(x, disp)
		x = u32(x)
		disp = disp or 0
		if disp < 0 then return bit32.rshift(x, -disp) end
		if disp >= 32 then return 0 end
		return u32(x << disp)
	end

	function bit32.rshift(x, disp)
		x = u32(x)
		disp = disp or 0
		if disp < 0 then return bit32.lshift(x, -disp) end
		if disp >= 32 then return 0 end
		return u32(x >> disp)
	end

	function bit32.arshift(x, disp)
		x = u32(x)
		disp = disp or 0
		if disp < 0 then return bit32.lshift(x, -disp) end
		if disp == 0 then return x end
		if disp >= 32 then
			if (x & 0x80000000) ~= 0 then return MASK end
			return 0
		end
		local result = x >> disp
		if (x & 0x80000000) ~= 0 then
			result = result | (MASK << (32 - disp))
		end
		return u32(result)
	end

	function bit32.lrotate(x, disp)
		x = u32(x)
		disp = (disp or 0) % 32
		if disp == 0 then return x end
		return u32((x << disp) | (x >> (32 - disp)))
	end

	function bit32.rrotate(x, disp)
		x = u32(x)
		disp = (disp or 0) % 32
		if disp == 0 then return x end
		return u32((x >> disp) | (x << (32 - disp)))
	end

	function bit32.btest(...)
		return bit32.band(...) ~= 0
	end

	function bit32.extract(n, field, width)
		width = width or 1
		local mask = u32(bit32.lshift(1, width) - 1)
		return u32(bit32.rshift(n, field)) & mask
	end

	function bit32.replace(n, v, field, width)
		width = width or 1
		local mask = u32(bit32.lshift(1, width) - 1)
		n = u32(n)
		v = u32(v) & mask
		local shifted = u32(mask << field)
		return u32((n & ~shifted) | (v << field))
	end

	math.atan2 = math.atan2 or math.atan
          ]])()
end

local term = {}
local event = require("event")
local shell = require("shell")

function term.isAvailable()
	return true
end

function term.getViewport()
	local gpu = require("component").gpu
	if gpu and gpu.getViewport then
		return gpu.getViewport()
	end
	return 160, 50, 1, 1, 1, 1
end

function term.getGlobalArea()
	local gpu = require("component").gpu
	if gpu and gpu.getResolution then
		local w, h = gpu.getResolution()
		if w and h then
			return 1, 1, w, h
		end
	end
	return 1, 1, 160, 50
end

function term.pull(...)
	-- TODO: blink cursor
	return event.pull(...)
end

function term.setCursorBlink(blink)
	-- TODO!!
end

function term.getCursor()
	return shell.getCursor()
end

function term.setCursor(col, row)
	shell.setCursor(col, row)
end

function term.clear()
	return shell.clear()
end

function term.clearLine()
	shell.setCursor(1, shell.getY())
	-- TODO
end

-- Supports both the legacy OpenOS term.read(options) call and the modern
-- OpenComputers term.read(history, dobreak, hint, pwchar, filter) call.
function term.read(history, dobreak, hint, pwchar, filter)
	local options
	if type(history) == "table" and (history.dobreak ~= nil or history.history ~= nil
		or history.pwchar ~= nil or history.onType ~= nil or history.autocomplete ~= nil) then
		options = history
		dobreak = options.dobreak
	else
		options = {
			history = type(history) == "table" and history or nil,
			pwchar = pwchar
		}
	end
	if hint ~= nil then
		term.write(tostring(hint))
	end
	local str = shell.read(options)
	if dobreak == nil or dobreak then
		return str .. "\n"
	end
	return str
end

function term.write(value, wrap)
	-- TODO support false wrap value
	io.stdout:write(require("stardust/text").detab(value, 8))
end

function term.bind(gpu)
	error("cannot re-bind the terminal")
end

function term.screen()
	return require("component").list("screen")()
end

function term.keyboard()
	return require("component").screen.getKeyboards()[0]
end

function term.gpu()
	return require("component").proxy(require("component").list("gpu")())
end

return term

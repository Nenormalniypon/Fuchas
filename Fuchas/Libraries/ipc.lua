--- IPC library implemented using the per-process event system.
-- It implements OETF #18 (Open Inter-Process Communication), the main difference being that
-- `computer.pushProcessSignal` is used instead of `computer.pushSignal`.
-- @module ipc
-- @alias lib

local lib = {}
local tasks = require("tasks")
local event = require("event")

-- Events that belong to another socket are kept here so a later read() can
-- still receive them.  This is best-effort (IPC sockets are not streams), but
-- it avoids both losing messages and the old infinite resend loop.
local pending = {}
local MAX_PENDING = 256

--- Sockets are used for both listening and writing and are not necessary to be opened on both sides.
-- This is a best-effort asynchronous in write and synchronous in read message passing.
-- Due to the way they work, they cannot be closed unlike streams.
-- @int target process PID
-- @string id the unique identifier of the socket that should be shared between both processes
function lib.socket(target, id)
	if not tasks.getProcessMetrics(target) then
		error("invalid process: " .. tostring(target))
	end

	local socket = {}
	socket.target = target
	socket.id = id
	socket.pid = tasks.getCurrentProcess().pid -- source pid

	function socket:write(...)
		if self:closed() then
			error("ipc socket " .. tostring(self.id) .. " closed")
		end
		computer.pushProcessSignal(self.target, "oipc_sock_comms", self.id, ...)
	end

	function socket:read()
		if self:closed() then
			error("ipc socket " .. tostring(self.id) .. " closed")
		end

		-- First look at messages that were received while another socket was
		-- being read.
		for index = 1, #pending do
			local message = pending[index]
			if message[2] == self.id then
				table.remove(pending, index)
				return table.unpack(message, 3, message.n)
			end
		end

		while true do
			local message = table.pack(event.pull("oipc_sock_comms"))
			if message.n < 2 then
				return nil
			elseif message[2] == self.id then
				return table.unpack(message, 3, message.n)
			else
				if #pending >= MAX_PENDING then
					table.remove(pending, 1)
				end
				pending[#pending + 1] = message
			end
		end
	end

	function socket:closed()
		local proc = tasks.getProcess(self.target)
		return proc == nil or proc.status == "dead"
	end

	computer.pushProcessSignal(socket.target, "incoming_ipc_socket", socket.pid)

	return socket
end

return lib

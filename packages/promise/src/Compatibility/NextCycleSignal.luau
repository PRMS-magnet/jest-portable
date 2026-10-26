--!strict

local Task = require("../Runtime").Get().Task

local NextCycleSignal = {}

function NextCycleSignal:Connect(Callback: () -> ())
	local Active = true
	Task.Defer(function()
		while Active do
			Callback()
			if Active then
				Task.Wait()
			end
		end
	end)

	local Connection = {}
	function Connection:Disconnect()
		Active = false
	end
	return Connection
end

function NextCycleSignal:Wait(): number
	return Task.Wait()
end

return table.freeze(NextCycleSignal)

--!strict

local Json = require("@std/json")

local Contract = require("../Runtime/Contract")
local Task = require("./Lute/Task")
type RuntimeCapabilities = Contract.RuntimeCapabilities

local Provider = {}

-- Lute has one task library, so a spec's sandbox task is not needed; the scheduler is new each call
function Provider.Create(_HostTask: unknown?): RuntimeCapabilities
	return table.freeze({
		JsonDecode = Json.deserialize,
		JsonEncode = function(Value: unknown): string
			return Json.serialize(Value :: any)
		end,
		ModuleHost = "Lute",
		Task = Task.New(),
		WriteOutput = function(Message: string)
			print(Message)
		end,
		WriteWarning = function(Message: string)
			print(Message)
		end,
	})
end

return table.freeze(Provider)

--!strict

local HttpService = game:GetService("HttpService")

local Contract = require("../Runtime/Contract")
type RuntimeCapabilities = Contract.RuntimeCapabilities

local Roblox = table.freeze({
	GetService = function(Name: string): Instance
		return game:GetService(Name)
	end,
	IsInstance = function(Value: unknown): boolean
		return typeof(Value) == "Instance"
	end,
	NewInstance = Instance.new,
})

local Provider = {}

-- A spec's sandbox passes its own task library; the host's entry passes none, which means the engine's
function Provider.Create(HostTask: unknown?): RuntimeCapabilities
	local TaskLibrary: any = HostTask or task
	return table.freeze({
		JsonDecode = function(Source: string): unknown
			return HttpService:JSONDecode(Source)
		end,
		JsonEncode = function(Value: unknown): string
			return HttpService:JSONEncode(Value)
		end,
		ModuleHost = "Roblox",
		Roblox = Roblox,
		Task = table.freeze({
			Cancel = TaskLibrary.cancel,
			Defer = TaskLibrary.defer,
			Delay = TaskLibrary.delay,
			Spawn = TaskLibrary.spawn,
			Wait = TaskLibrary.wait,
		}),
		WriteOutput = function(Message: string)
			print(Message)
		end,
		WriteWarning = function(Message: string)
			warn(Message)
		end,
	})
end

return table.freeze(Provider)

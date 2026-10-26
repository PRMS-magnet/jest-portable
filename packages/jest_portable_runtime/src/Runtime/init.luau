--!strict

local Contract = require("./Runtime/Contract")
local AsyncScope = require("./Runtime/AsyncScope")
local StackFrames = require("./Runtime/StackFrames")
export type StackFrame = StackFrames.Frame
type RobloxResolution = Contract.RobloxResolution
type RuntimeCapabilities = Contract.RuntimeCapabilities
type RuntimeProvider = Contract.RuntimeProvider

local Current: RuntimeCapabilities? = nil
local CurrentProvider: RuntimeProvider? = nil

local function Validate(Capabilities: RuntimeCapabilities)
	assert(typeof(Capabilities) == "table", "Runtime capabilities must be a table")
	assert(typeof(Capabilities.JsonDecode) == "function", "Runtime.JsonDecode must be a function")
	assert(typeof(Capabilities.JsonEncode) == "function", "Runtime.JsonEncode must be a function")
	assert(typeof(Capabilities.WriteOutput) == "function", "Runtime.WriteOutput must be a function")
	assert(typeof(Capabilities.WriteWarning) == "function", "Runtime.WriteWarning must be a function")
	local ModuleHost = Capabilities.ModuleHost
	assert(
		ModuleHost == nil or ModuleHost == "Lute" or ModuleHost == "Roblox",
		"Runtime.ModuleHost must be Lute or Roblox"
	)

	local Roblox = Capabilities.Roblox
	if Roblox ~= nil then
		assert(typeof(Roblox) == "table", "Runtime.Roblox must be a table")
		assert(typeof(Roblox.GetService) == "function", "Runtime.Roblox.GetService must be a function")
		assert(typeof(Roblox.IsInstance) == "function", "Runtime.Roblox.IsInstance must be a function")
		assert(typeof(Roblox.NewInstance) == "function", "Runtime.Roblox.NewInstance must be a function")
	end

	local Task = Capabilities.Task
	assert(typeof(Task) == "table", "Runtime.Task must be a table")
	assert(typeof(Task.Cancel) == "function", "Runtime.Task.Cancel must be a function")
	assert(typeof(Task.Defer) == "function", "Runtime.Task.Defer must be a function")
	assert(typeof(Task.Delay) == "function", "Runtime.Task.Delay must be a function")
	assert(typeof(Task.Spawn) == "function", "Runtime.Task.Spawn must be a function")
	assert(typeof(Task.Wait) == "function", "Runtime.Task.Wait must be a function")
end

-- A host's entry passes its provider; a spec runtime's copy of this module gets the same provider with that spec's task library
local function Initialize(Provider: RuntimeProvider, HostTask: unknown?)
	assert(
		typeof(Provider) == "table" and typeof(Provider.Create) == "function",
		"Runtime provider must have a Create function"
	)
	if CurrentProvider ~= nil then
		assert(CurrentProvider == Provider, "Portable Jest runtime was initialized with a different provider")
		return
	end
	local Capabilities = Provider.Create(HostTask)
	Validate(Capabilities)
	CurrentProvider = Provider
	Current = table.freeze({
		JsonDecode = Capabilities.JsonDecode,
		JsonEncode = Capabilities.JsonEncode,
		ModuleHost = Capabilities.ModuleHost,
		Roblox = Capabilities.Roblox,
		Task = AsyncScope.Configure(Capabilities.Task),
		WriteOutput = Capabilities.WriteOutput,
		WriteWarning = Capabilities.WriteWarning,
	})
end

local function Get(): RuntimeCapabilities
	return assert(Current, "Portable Jest runtime must be initialized before use")
end

local function Provider(): RuntimeProvider
	return assert(CurrentProvider, "Portable Jest runtime must be initialized before use")
end

local function ResolveRoblox(): RobloxResolution
	local Roblox = Get().Roblox
	if Roblox ~= nil then
		return {
			Capability = Roblox,
			Refusal = nil,
			Status = "available",
		}
	end

	return {
		Capability = nil,
		Refusal = {
			Capability = "roblox.engine",
			Code = "runtime.capability-unsupported",
			Message = "The active Jest-Portable provider does not expose Roblox engine capabilities.",
		},
		Status = "unsupported",
	}
end

return table.freeze({
	AsyncScope = AsyncScope,
	Get = Get,
	Initialize = Initialize,
	Provider = Provider,
	ResolveRoblox = ResolveRoblox,
	StackFrames = StackFrames,
})

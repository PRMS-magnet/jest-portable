--!strict

local Contract = require("./Contract")
local ResolveInstancePath = require("../../JestRuntime/resolveInstancePath")
type ModuleHost = Contract.ModuleHost
type ResolvedModule = Contract.ResolvedModule

export type Options = {
	Resolutions: { [ModuleScript]: { [string]: ModuleScript } }?,
	SourceLabels: { [ModuleScript]: string }?,
	Sources: { [ModuleScript]: string }?,
}

type LoadedModule = {
	Cleanup: (() -> ())?,
	Function: () -> ...any,
}

type PrivateHost = ModuleHost & {
	DisposeFailure: string?,
	IsDisposed: boolean,
	Loaded: { [Instance]: LoadedModule },
	Resolutions: { [ModuleScript]: { [string]: ModuleScript } },
	SourceLabels: { [ModuleScript]: string },
	Sources: { [ModuleScript]: string },
}

local NativeRequire = require
local LoadModule = (debug :: any).loadmodule
local LoadModuleEnabled = typeof(LoadModule) == "function"
local FALLBACK_REQUIRE_BINDING = "local require = require;"
local MAX_SOURCES = 10_000
local MAX_SOURCE_BYTES = 16_777_216
local MAX_TOTAL_SOURCE_BYTES = 268_435_456
local MAX_CLEANUP_FAILURES = 8
local MAX_CLEANUP_FAILURE_BYTES = 512
local Host = {}
Host.__index = Host

local function Fail(Code: string, Message: string): never
	error(`{Code}: {Message}`, 0)
end

local function AssertActive(self: PrivateHost)
	if self.IsDisposed then
		Fail("module-host.disposed", "the Roblox module host has been disposed")
	end
end

local function IsNative(Request: string): boolean
	return string.sub(Request, 1, 5) == "@rbx/"
end

local function SourceLabel(self: PrivateHost, Module: ModuleScript): string
	return self.SourceLabels[Module] or Module:GetFullName()
end

local function Authored(self: PrivateHost, Module: ModuleScript): ResolvedModule
	return table.freeze({
		Key = Module,
		Kind = "authored",
		Reference = Module,
		SourceLabel = SourceLabel(self, Module),
	})
end

local function Native(Request: string): ResolvedModule
	return table.freeze({
		Key = `native:{Request}`,
		Kind = "native",
		Reference = Request,
		SourceLabel = Request,
	})
end

local function IsModule(Value: any): boolean
	return typeof(Value) == "Instance" and Value:IsA("ModuleScript")
end

local function IsGlobalLabel(Label: string): boolean
	return string.sub(Label, -7) == ".global"
		or string.sub(Label, -11) == ".global.lua"
		or string.sub(Label, -12) == ".global.luau"
end

local function SnapshotOptions(OptionsValue: Options?): ({ [ModuleScript]: { [string]: ModuleScript } }, { [ModuleScript]: string }, {
	[ModuleScript]: string,
})
	local Resolutions = {}
	local SourceLabels = {}
	local Sources = {}
	if OptionsValue == nil then
		return Resolutions, SourceLabels, Sources
	end
	if typeof(OptionsValue) ~= "table" then
		Fail("module-host.options", "Roblox module host options must be a table")
	end
	for Key in OptionsValue :: any do
		if Key ~= "Resolutions" and Key ~= "SourceLabels" and Key ~= "Sources" then
			Fail("module-host.options", `unsupported Roblox module host option {tostring(Key)}`)
		end
	end
	if OptionsValue.Resolutions ~= nil then
		if typeof(OptionsValue.Resolutions) ~= "table" then
			Fail("module-host.options", "Resolutions must be a caller ModuleScript map")
		end
		for Caller, Requests in OptionsValue.Resolutions do
			if not IsModule(Caller) or typeof(Requests) ~= "table" then
				Fail("module-host.options", "Resolutions must map caller ModuleScripts to request tables")
			end
			local CopiedRequests = {}
			for Request, Target in Requests do
				if typeof(Request) ~= "string" or Request == "" or not IsModule(Target) then
					Fail("module-host.options", "resolution requests must be non-empty strings targeting ModuleScripts")
				end
				if string.sub(Request, 1, 5) == "@std/" or IsNative(Request) then
					Fail("module-host.options", "native module namespaces cannot be remapped")
				end
				CopiedRequests[Request] = Target
			end
			Resolutions[Caller] = table.freeze(CopiedRequests)
		end
	end
	if OptionsValue.SourceLabels ~= nil then
		if typeof(OptionsValue.SourceLabels) ~= "table" then
			Fail("module-host.options", "SourceLabels must be a ModuleScript map")
		end
		for Module, Label in OptionsValue.SourceLabels do
			if
				not IsModule(Module)
				or typeof(Label) ~= "string"
				or Label == ""
				or #Label > 4_096
				or string.find(Label, "[%z\r\n]") ~= nil
			then
				Fail(
					"module-host.options",
					"source labels must be bounded non-empty single-line strings keyed by ModuleScript"
				)
			end
			if IsGlobalLabel(Label) ~= IsGlobalLabel(Module:GetFullName()) then
				Fail("module-host.options", "source labels cannot change global-module lifetime")
			end
			SourceLabels[Module] = Label
		end
	end
	if OptionsValue.Sources ~= nil then
		if typeof(OptionsValue.Sources) ~= "table" then
			Fail("module-host.options", "Sources must be a ModuleScript map")
		end
		local Count = 0
		local TotalBytes = 0
		for Module, Source in OptionsValue.Sources do
			if not IsModule(Module) or typeof(Source) ~= "string" or #Source > MAX_SOURCE_BYTES then
				Fail("module-host.options", "sources must be bounded strings keyed by ModuleScript")
			end
			Count += 1
			TotalBytes += #Source
			if Count > MAX_SOURCES or TotalBytes > MAX_TOTAL_SOURCE_BYTES then
				Fail("module-host.options", "sources exceed the module-count or combined byte limit")
			end
			Sources[Module] = Source
		end
	end
	return table.freeze(Resolutions), table.freeze(SourceLabels), table.freeze(Sources)
end

function Host.new(
	_PreloadedInitializerPath: string?,
	_SourceOverrides: { [string]: string }?,
	OptionsValue: Options?
): ModuleHost
	local Resolutions, SourceLabels, Sources = SnapshotOptions(OptionsValue)
	local self: PrivateHost = setmetatable({
		DisposeFailure = nil,
		IsDisposed = false,
		Loaded = {},
		Resolutions = Resolutions,
		SourceLabels = SourceLabels,
		Sources = Sources,
	}, Host) :: any
	return self
end

function Host:CanonicalizeEntry(Source: any): ResolvedModule
	local self = self :: PrivateHost
	AssertActive(self)
	if typeof(Source) ~= "Instance" or not Source:IsA("ModuleScript") then
		Fail("module-host.entry", "Roblox entry must be a ModuleScript")
	end
	return Authored(self, Source)
end

-- This module is packages/jest_runtime/src/Runtime/ModuleHost/Roblox, so the tree's packages folder is five parents up
function Host:CanonicalizeFramework(Path: string): ResolvedModule
	local self = self :: PrivateHost
	AssertActive(self)
	if typeof(Path) ~= "string" or Path == "" then
		Fail("module-host.framework", "framework module path must be a non-empty string")
	end
	local Current: Instance? = (script :: Instance)
	for _ = 1, 5 do
		Current = if Current == nil then nil else Current.Parent
	end
	for Segment in string.gmatch(Path, "[^/]+") do
		Current = if Current == nil then nil else Current:FindFirstChild(Segment)
	end
	if Current == nil or not Current:IsA("ModuleScript") then
		Fail("module-host.framework", `{Path} is not a ModuleScript in this package tree`)
	end
	return Authored(self, Current :: ModuleScript)
end

function Host:Resolve(From: ResolvedModule, Request: string): ResolvedModule
	local self = self :: PrivateHost
	AssertActive(self)
	if typeof(Request) ~= "string" or Request == "" then
		Fail("module-host.resolve", "module request must be a non-empty string")
	end
	if string.sub(Request, 1, 5) == "@std/" then
		Fail("module-host.native-unsupported", `Roblox cannot load the native module {Request}`)
	end
	if IsNative(Request) then
		return Native(Request)
	end
	if From.Kind ~= "authored" or typeof(From.Reference) ~= "Instance" then
		Fail("module-host.resolve", `authored request {Request} has native caller {From.SourceLabel}`)
	end
	local Requests = self.Resolutions[From.Reference]
	local Mapped = if Requests ~= nil then Requests[Request] else nil
	if Mapped ~= nil then
		return Authored(self, Mapped)
	end
	local Ok, Result = pcall(ResolveInstancePath, From.Reference, Request)
	if not Ok or Result == nil or not Result:IsA("ModuleScript") then
		Fail("module-host.resolve", `{Request} from {From.SourceLabel}: {tostring(Result)}`)
	end
	return Authored(self, Result)
end

local function Load(self: PrivateHost, Module: ModuleScript): LoadedModule
	local ModuleFunction: (() -> ...any)?
	local ErrorMessage: string?
	local Cleanup: (() -> ())?
	local Source = self.Sources[Module]
	local HasMappedSource = self.SourceLabels[Module] ~= nil or Source ~= nil
	if LoadModuleEnabled and not HasMappedSource then
		local Results = table.pack(pcall(LoadModule, Module))
		if Results[1] then
			ModuleFunction, ErrorMessage, Cleanup = Results[2], Results[3], Results[4]
		else
			LoadModuleEnabled = false
		end
	end
	if not LoadModuleEnabled or HasMappedSource then
		if Source == nil then
			Source = Module.Source
		end
		ModuleFunction, ErrorMessage = loadstring(FALLBACK_REQUIRE_BINDING .. Source, SourceLabel(self, Module))
	end
	if ModuleFunction == nil then
		Fail("module-host.load", `{SourceLabel(self, Module)}: {tostring(ErrorMessage)}`)
	end
	return {
		Cleanup = Cleanup,
		Function = ModuleFunction,
	}
end

function Host:Execute(Module: ResolvedModule, Environment: { [any]: any }): { [number]: any, n: number }
	local self = self :: PrivateHost
	AssertActive(self)
	if Module.Kind ~= "authored" or typeof(Module.Reference) ~= "Instance" then
		Fail("module-host.execute", `{Module.SourceLabel} is not an authored ModuleScript`)
	end
	local Reference = Module.Reference :: ModuleScript
	local Loaded = self.Loaded[Reference]
	if Loaded == nil then
		Loaded = Load(self, Reference)
		self.Loaded[Reference] = Loaded
	end
	setfenv(Loaded.Function, Environment)
	return table.pack(Loaded.Function())
end

function Host:LoadNative(Module: ResolvedModule): any
	local self = self :: PrivateHost
	AssertActive(self)
	if Module.Kind ~= "native" or typeof(Module.Reference) ~= "string" or not IsNative(Module.Reference) then
		Fail("module-host.native", `{Module.SourceLabel} is not an admitted native module`)
	end
	return NativeRequire(Module.Reference)
end

function Host:Dispose()
	local self = self :: PrivateHost
	if self.IsDisposed then
		if self.DisposeFailure ~= nil then
			Fail("module-host.cleanup", self.DisposeFailure)
		end
		return
	end
	self.IsDisposed = true
	local FailureCount = 0
	local Failures = {}
	for _, Loaded in self.Loaded do
		if Loaded.Cleanup ~= nil then
			local Ok, Failure = pcall(Loaded.Cleanup)
			if not Ok then
				FailureCount += 1
				local Message = if typeof(Failure) == "string"
					then Failure
					else `non-string cleanup failure ({typeof(Failure)})`
				if #Message > MAX_CLEANUP_FAILURE_BYTES then
					Message = string.sub(Message, 1, MAX_CLEANUP_FAILURE_BYTES - 3) .. "..."
				end
				table.insert(Failures, Message)
				table.sort(Failures)
				if #Failures > MAX_CLEANUP_FAILURES then
					table.remove(Failures)
				end
			end
		end
	end
	table.clear(self.Loaded)
	if FailureCount > 0 then
		local Message = `{FailureCount} cleanup callbacks failed:\n{table.concat(Failures, "\n")}`
		if FailureCount > #Failures then
			Message ..= `\n{FailureCount - #Failures} additional cleanup failures`
		end
		-- A failed callback may have partially cleaned up, so retries only repeat its diagnostic.
		self.DisposeFailure = Message
		Fail("module-host.cleanup", Message)
	end
end

return table.freeze({
	new = Host.new,
})

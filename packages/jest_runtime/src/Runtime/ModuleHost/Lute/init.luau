--!strict

local fs = require("@lute/fs")
local luau = require("@std/luau")

local Contract = require("./Contract")
local PreloadedFactories = require("./Lute/PreloadedFactories")
local PreloadedMetadata = require("./Lute/PreloadedMetadata")
local PreloadedResolutions = require("./Lute/PreloadedResolutions")
type ModuleHost = Contract.ModuleHost
type ResolvedModule = Contract.ResolvedModule

type CompiledSource = {
	Bytecode: luau.Bytecode,
	Source: string,
}

type PrivateHost = ModuleHost & {
	Compiled: { [string]: CompiledSource },
	IsDisposed: boolean,
	PreloadedRoot: string?,
	SourceOverrides: { [string]: string },
}

-- This module's place in the tree; whatever precedes it in its own path is the tree's packages folder
local SELF_KEY = "jest_runtime/src/Runtime/ModuleHost/Lute/init.luau"
local NativeRequire = require
local Host = {}
Host.__index = Host

-- Installed packages do not change during a run, so each of their modules is read and compiled once per process, not once per spec
local PackageBytecode: { [string]: luau.Bytecode } = {}
-- And a request from inside one resolves the same way all run, by requesting file then request
local PackageResolutions: { [string]: { [string]: string } } = {}

local function Fail(Code: string, Message: string): never
	error(`{Code}: {Message}`, 0)
end

local function CanonicalPath(Path: string): string
	local Canonical = string.gsub(Path, "\\", "/")
	-- Windows drive letters ignore case, so one spelling keeps one module identity
	if string.match(Canonical, "^%l:/") ~= nil then
		Canonical = string.upper(string.sub(Canonical, 1, 1)) .. string.sub(Canonical, 2)
	end
	return Canonical
end

local function EndsWithKey(Path: string, Key: string): boolean
	return #Path > #Key and string.sub(Path, -#Key) == Key and string.sub(Path, -#Key - 1, -#Key - 1) == "/"
end

-- A preloaded copy has no file of its own, so its host takes the root from the preloaded initializer instead
local function LocatePackagesRoot(): string?
	local Ok, Resolved = pcall(luau.resolveModule, "@self", debug.info(1, "s"))
	if not Ok then
		return nil
	end
	local SelfPath = CanonicalPath(tostring(Resolved))
	if not EndsWithKey(SelfPath, SELF_KEY) then
		return nil
	end
	return string.sub(SelfPath, 1, #SelfPath - #SELF_KEY)
end

local PackagesRoot = LocatePackagesRoot()

local function AssertActive(self: PrivateHost)
	if self.IsDisposed then
		Fail("module-host.disposed", "the Lute module host has been disposed")
	end
end

local function IsNative(Request: string): boolean
	return string.sub(Request, 1, 5) == "@std/" or string.sub(Request, 1, 6) == "@lute/"
end

local function Authored(SourcePath: string): ResolvedModule
	return table.freeze({
		Key = SourcePath,
		Kind = "authored",
		Reference = SourcePath,
		SourceLabel = SourcePath,
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

local function Preloaded(self: PrivateHost, PackageKey: string): ResolvedModule
	local SourcePath = (self.PreloadedRoot :: string) .. PackageKey
	return table.freeze({
		Key = SourcePath,
		Kind = "preloaded",
		Reference = PackageKey,
		SourceLabel = SourcePath,
	})
end

local function PackageKey(self: PrivateHost, SourcePath: string): string?
	local Root = self.PreloadedRoot or PackagesRoot
	if Root == nil or #SourcePath <= #Root or string.sub(SourcePath, 1, #Root) ~= Root then
		return nil
	end
	return string.sub(SourcePath, #Root + 1)
end

local function ResolvePath(self: PrivateHost, Request: string, FromPath: string): string
	local Known = PackageResolutions[FromPath]
	local Cached = if Known == nil then nil else Known[Request]
	if Cached ~= nil then
		return Cached
	end
	local Ok, Result = pcall(luau.resolveModule, Request, FromPath)
	if not Ok then
		Fail("module-host.resolve", `{Request} from {FromPath}: {tostring(Result)}`)
	end
	local Path = CanonicalPath(tostring(Result))
	if PackageKey(self, FromPath) ~= nil then
		local Paths = Known or {}
		Paths[Request] = Path
		PackageResolutions[FromPath] = Paths
	end
	return Path
end

local function PreloadedOrAuthored(self: PrivateHost, SourcePath: string): ResolvedModule
	local Key = PackageKey(self, SourcePath)
	if self.PreloadedRoot ~= nil and Key ~= nil and PreloadedFactories[Key] ~= nil then
		return Preloaded(self, Key)
	end
	return Authored(SourcePath)
end

local function PreloadedKeyOrAuthored(self: PrivateHost, Key: string): ResolvedModule
	if PreloadedFactories[Key] ~= nil then
		return Preloaded(self, Key)
	end
	return Authored((self.PreloadedRoot :: string) .. Key)
end

local function PreloadedRoot(InitializerPath: string?): string?
	if InitializerPath == nil then
		return nil
	end
	if typeof(InitializerPath) ~= "string" or InitializerPath == "" then
		Fail("module-host.preloaded-path", "preloaded initializer path must be a non-empty string")
	end
	if typeof(PreloadedMetadata.InitializerKey) ~= "string" or PreloadedMetadata.InitializerKey == "" then
		Fail("module-host.preloaded-unavailable", "this Jest-Portable build has no preloaded module graph")
	end
	local InitializerCanonicalPath = CanonicalPath(InitializerPath)
	local Key: string = PreloadedMetadata.InitializerKey :: any
	if not EndsWithKey(InitializerCanonicalPath, Key) then
		Fail("module-host.preloaded-path", "preloaded initializer path has an unexpected package identity")
	end
	return string.sub(InitializerCanonicalPath, 1, #InitializerCanonicalPath - #Key)
end

local function CopySourceOverrides(SourceOverrides: { [string]: string }?): { [string]: string }
	if SourceOverrides == nil then
		return {}
	end
	if typeof(SourceOverrides) ~= "table" then
		Fail("module-host.source-overrides", "source overrides must be a string map")
	end
	local Output: { [string]: string } = {}
	for Path, Source in SourceOverrides do
		if typeof(Path) ~= "string" or Path == "" or typeof(Source) ~= "string" then
			Fail("module-host.source-overrides", "source overrides must contain non-empty string paths and string source")
		end
		Output[CanonicalPath(Path)] = Source
	end
	return Output
end

function Host.new(PreloadedInitializerPath: string?, SourceOverrides: { [string]: string }?): ModuleHost
	local self: PrivateHost = setmetatable({
		Compiled = {},
		IsDisposed = false,
		PreloadedRoot = PreloadedRoot(PreloadedInitializerPath),
		SourceOverrides = CopySourceOverrides(SourceOverrides),
	}, Host) :: any
	return self
end

function Host:CanonicalizeEntry(SourcePath: string): ResolvedModule
	local self = self :: PrivateHost
	AssertActive(self)
	if typeof(SourcePath) ~= "string" or SourcePath == "" then
		Fail("module-host.entry", "entry source path must be a non-empty string")
	end
	SourcePath = CanonicalPath(SourcePath)
	local Key = PackageKey(self, SourcePath)
	if self.PreloadedRoot ~= nil and Key ~= nil and PreloadedFactories[Key] ~= nil then
		return Preloaded(self, Key)
	end
	if string.match(SourcePath, "^%a:/") ~= nil or string.sub(SourcePath, 1, 1) == "/" then
		return Authored(SourcePath)
	end
	return PreloadedOrAuthored(self, ResolvePath(self, "@self", SourcePath))
end

-- Circus names its initializer by its path in the tree: a preloaded module in a payload, a file in an installed tree
function Host:CanonicalizeFramework(Path: string): ResolvedModule
	local self = self :: PrivateHost
	AssertActive(self)
	if typeof(Path) ~= "string" or Path == "" then
		Fail("module-host.framework", "framework module path must be a non-empty string")
	end
	local Key = Path .. ".luau"
	if self.PreloadedRoot ~= nil and PreloadedFactories[Key] ~= nil then
		return Preloaded(self, Key)
	end
	local Root = self.PreloadedRoot or PackagesRoot
	if Root == nil then
		Fail("module-host.framework", `{Path} has no package tree to load from`)
	end
	return Authored((Root :: string) .. Key)
end

function Host:Resolve(From: ResolvedModule, Request: string): ResolvedModule
	local self = self :: PrivateHost
	AssertActive(self)
	if typeof(Request) ~= "string" or Request == "" then
		Fail("module-host.resolve", "module request must be a non-empty string")
	end
	if IsNative(Request) then
		return Native(Request)
	end
	if From.Kind ~= "authored" and From.Kind ~= "preloaded" then
		Fail("module-host.resolve", `authored request {Request} has native caller {From.SourceLabel}`)
	end
	if self.PreloadedRoot ~= nil then
		local FromKey = if From.Kind == "preloaded" then From.Reference else PackageKey(self, From.Reference)
		local Resolutions = if FromKey == nil then nil else PreloadedResolutions[FromKey]
		local TargetKey = if Resolutions == nil then nil else Resolutions[Request]
		if TargetKey ~= nil then
			return PreloadedKeyOrAuthored(self, TargetKey)
		end
	end
	local FromPath = if From.Kind == "preloaded"
		then (self.PreloadedRoot :: string) .. From.Reference
		else From.Reference
	return PreloadedOrAuthored(self, ResolvePath(self, Request, FromPath))
end

local function Read(SourcePath: string): string
	local Ok, Result = pcall(function()
		local Handle = fs.open(SourcePath, "r")
		local Source = fs.read(Handle)
		fs.close(Handle)
		return Source
	end)
	if not Ok then
		Fail("module-host.read", `{SourcePath}: {tostring(Result)}`)
	end
	return Result :: string
end

local function Compile(Module: ResolvedModule, Source: string): luau.Bytecode
	local Ok, Bytecode = pcall(luau.compile, Source)
	if not Ok then
		Fail("module-host.compile", `{Module.SourceLabel}: {tostring(Bytecode)}`)
	end
	return Bytecode :: luau.Bytecode
end

function Host:Execute(Module: ResolvedModule, Environment: { [any]: any }): { [number]: any, n: number }
	local self = self :: PrivateHost
	AssertActive(self)
	if Module.Kind == "preloaded" then
		local Factory = PreloadedFactories[Module.Reference]
		if self.PreloadedRoot == nil or Factory == nil then
			Fail("module-host.preloaded", `{Module.SourceLabel} is not an admitted preloaded module`)
		end
		return table.pack(Factory(Environment))
	end
	if Module.Kind ~= "authored" then
		Fail("module-host.execute", `{Module.SourceLabel} is not an authored module`)
	end
	local Source = self.SourceOverrides[Module.Reference]
	local Bytecode: luau.Bytecode
	if Source == nil and PackageKey(self, Module.Reference) ~= nil then
		local Shared = PackageBytecode[Module.Key]
		if Shared == nil then
			Shared = Compile(Module, Read(Module.Reference))
			PackageBytecode[Module.Key] = Shared
		end
		Bytecode = Shared
	else
		Source = Source or Read(Module.Reference)
		local Compiled = self.Compiled[Module.Key]
		if Compiled == nil or Compiled.Source ~= Source then
			Compiled = {
				Bytecode = Compile(Module, Source),
				Source = Source,
			}
			self.Compiled[Module.Key] = Compiled
		end
		Bytecode = Compiled.Bytecode
	end
	local Ok, Chunk = pcall(luau.load, Bytecode, Module.SourceLabel, Environment)
	if not Ok then
		Fail("module-host.load", `{Module.SourceLabel}: {tostring(Chunk)}`)
	end
	return table.pack((Chunk :: any)())
end

function Host:LoadNative(Module: ResolvedModule): any
	local self = self :: PrivateHost
	AssertActive(self)
	if Module.Kind ~= "native" or not IsNative(Module.Reference) then
		Fail("module-host.native", `{Module.SourceLabel} is not an admitted native module`)
	end
	return NativeRequire(Module.Reference)
end

function Host:Dispose()
	local self = self :: PrivateHost
	if self.IsDisposed then
		return
	end
	self.IsDisposed = true
	table.clear(self.Compiled)
	table.clear(self.SourceOverrides)
	self.PreloadedRoot = nil
end

return table.freeze({
	new = Host.new,
})

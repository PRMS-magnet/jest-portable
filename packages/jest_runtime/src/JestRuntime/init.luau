--!nonstrict

local LuauPolyfill = require("../../luau_polyfill/src")
local Error = LuauPolyfill.Error
local Object = LuauPolyfill.Object
local JestFakeTimers = require("../../jest_fake_timers/src")
local JestMock = require("../../jest_mock/src")
local JestMockGenv = require("../../jest_mock_genv/src")
local JestSnapshot = require("../../jest_snapshot/src")
local JestExpect = require("../../jest_expect/src")
local PortableGlobals = require("./Compatibility/FakeTimersGlobals")

local PortableRuntime = require("./Runtime")

-- Each host's module is required only on its own host: the Lute one loads Lute's native libraries
local ModuleHosts = table.freeze({
	Lute = function()
		return require("./Runtime/ModuleHost/Lute")
	end,
	Roblox = function()
		return require("./Runtime/ModuleHost/Roblox")
	end,
})

local function NewModuleHost(Config)
	local Name = PortableRuntime.Get().ModuleHost
	local Load = if Name == nil then nil else ModuleHosts[Name]
	if Load == nil then
		error(Error.new("the Jest-Portable runtime provider names no module host"))
	end
	return Load().new(
		if typeof(Config) == "table" then Config.jestPortablePreloadedInitializerPath else nil,
		if typeof(Config) == "table" and typeof(Config.jestPortableSourceOverrides) == "table"
			then Config.jestPortableSourceOverrides
			else nil,
		if typeof(Config) == "table" then Config.jestPortableRobloxModuleHost else nil
	)
end

export type Jest = any
export type Runtime = any

local GlobalModules = {}

local Runtime = {}
Runtime.__index = Runtime

local function ResolveSurfacePolicy(Config)
	local Policy = if typeof(Config) == "table" then Config.jestPortableSurfacePolicy else nil
	if Policy == nil then
		return {
			JestPackage = if typeof(Config) == "table" then Config.jestPortablePackage else nil,
			LoadJestPackage = if typeof(Config) == "table" then Config.jestPortablePackageLoader else nil,
			Name = "full",
		}
	end
	if typeof(Policy) ~= "table" or (Policy.Name ~= "full" and Policy.Name ~= "test-globals") then
		error(Error.new("jestPortableSurfacePolicy must select full or test-globals"))
	end
	if Policy.LoadJestPackage ~= nil and typeof(Policy.LoadJestPackage) ~= "function" then
		error(Error.new("jestPortableSurfacePolicy.LoadJestPackage must be a function"))
	end
	if Policy.Name == "test-globals" and typeof(Policy.OnMissingJestExport) ~= "function" then
		error(Error.new("jestPortableSurfacePolicy test-globals requires OnMissingJestExport to be a function"))
	elseif Policy.OnMissingJestExport ~= nil and typeof(Policy.OnMissingJestExport) ~= "function" then
		error(Error.new("jestPortableSurfacePolicy.OnMissingJestExport must be a function"))
	end
	return Policy
end

local function IsResolvedModule(Value)
	return typeof(Value) == "table"
		and (Value.Kind == "authored" or Value.Kind == "native" or Value.Kind == "preloaded")
		and Value.Key ~= nil
		and typeof(Value.SourceLabel) == "string"
end

local function IsJestGlobalsRequest(Request)
	return Request == "@JestGlobals" or Request == "@jest/globals"
end

local function IsJestPackageRequest(Request)
	return Request == "@jest"
end

local function TryRequireUserSurface(self, From, Request, IsInternal)
	if
		IsInternal
		or self.SurfacePolicy.Name ~= "test-globals"
		or (not IsJestPackageRequest(Request) and not IsJestGlobalsRequest(Request))
	then
		return false, nil
	end
	return true, self:_globalsWithJest(From)
end

local function IsGlobalModule(SourceLabel)
	return string.sub(SourceLabel, -7) == ".global"
		or string.sub(SourceLabel, -11) == ".global.lua"
		or string.sub(SourceLabel, -12) == ".global.luau"
end

local function BaseEnvironment()
	local Ok, Environment = pcall(getfenv, 0)
	if Ok and typeof(Environment) == "table" then
		return Environment
	end
	return _G
end

local function Canonicalize(self, Source)
	if IsResolvedModule(Source) then
		return Source
	end
	return self.ModuleHost:CanonicalizeEntry(Source)
end

local function ResolveRequest(self, From, Request)
	if IsResolvedModule(Request) then
		return Request
	end
	if typeof(Request) == "string" then
		local Alias = self.ModuleAliases[Request]
		if Alias ~= nil then
			return Canonicalize(self, Alias)
		end
		return self.ModuleHost:Resolve(From, Request)
	end
	return self.ModuleHost:CanonicalizeEntry(Request)
end

local function Registry(self, IsInternal)
	if IsInternal then
		return self.InternalModules
	end
	return self.IsolatedModules or self.Modules
end

local function MockRegistry(self)
	return self.IsolatedMocks or self.Mocks
end

local SandboxTaskNames = table.freeze({ cancel = true, defer = true, delay = true, spawn = true, wait = true })

local function IsNativeTaskLibrary(Module)
	return Module.Kind == "native" and (Module.Reference == "@lute/task" or Module.Reference == "@std/task")
end

-- A spec's own task library schedules through the sandbox's task, so fake timers and the attempt's async scope see it
local function SandboxTaskLibrary(self, Module)
	local Existing = self.TaskLibraries[Module.Key]
	if Existing ~= nil then
		return Existing
	end
	local TaskOverride = self.FakeTimers.taskOverride
	local Library = {}
	for Name, Value in self:_requireResolved(Module, false) do
		if SandboxTaskNames[Name] then
			local Sandboxed = TaskOverride[Name]
			Library[Name] = function(...)
				return Sandboxed(...)
			end
		else
			Library[Name] = Value
		end
	end
	table.freeze(Library)
	self.TaskLibraries[Module.Key] = Library
	return Library
end

local function SetUpAutomocks(Automocks, SourceEnvironment, Destination)
	for Name, Automock in Automocks do
		if Automock._isGlobalAutomockFn then
			Destination[Name] = function(...)
				if Automock._maybeMock == nil then
					error(Error.new("Code should not run when globalEnv is uninitialized"))
				end
				return Automock._maybeMock(...)
			end
		else
			local Source = SourceEnvironment[Name]
			local Child = setmetatable({}, { __index = Source })
			Destination[Name] = Child
			SetUpAutomocks(Automock, Source, Child)
		end
	end
end

local function ExecuteModule(self, Module, IsInternal, NoModuleReturnRequired)
	local Sandbox = setmetatable({}, { __index = BaseEnvironment() })
	Sandbox.DateTime = PortableGlobals.DateTime
	Sandbox.JestPortableHostTask = PortableGlobals.Task
	Sandbox.JestPortableProvider = self.PortableProvider
	-- Per runtime: each spec's Circus keeps its state here under a symbol of its own, so a shared table would keep every spec alive
	Sandbox.JestPortableState = self.PortableState
	if self.JestGlobals ~= nil then
		Sandbox.JestPortableAttemptContextRegistry = (self.JestGlobals :: any).JestPortableAttemptContextRegistry
	end
	Sandbox.delay = PortableGlobals.Task.delay
	if typeof(Module.Reference) == "Instance" then
		Sandbox.script = Module.Reference
	end
	Sandbox.task = PortableGlobals.Task
	Sandbox.tick = PortableGlobals.Tick
	Sandbox.time = PortableGlobals.Time
	if not IsInternal and self.Config.injectGlobals == true and self.JestGlobals ~= nil then
		for Name, Value in self.JestGlobals do
			Sandbox[Name] = Value
		end
		Sandbox.jest = self:_createJestObjectFor(Module)
	end
	Sandbox.require = function(Request)
		local IsSurfaceBound, SurfaceValue = TryRequireUserSurface(self, Module, Request, IsInternal)
		if IsSurfaceBound then
			return SurfaceValue
		end
		if IsJestGlobalsRequest(Request) then
			return self:_globalsWithJest(Module)
		end
		if not IsInternal and IsJestPackageRequest(Request) then
			local Package = self.JestPackage
			if Package == nil and self.JestPackageLoader ~= nil then
				Package = self.JestPackageLoader()
			elseif Package == nil then
				local Resolved = ResolveRequest(self, Module, Request)
				Package = self:_requireOrMockResolved(Resolved)
			end
			return self:_globalsWithJest(Module, Package)
		end
		local Resolved = ResolveRequest(self, Module, Request)
		if IsInternal then
			return self:_requireResolved(Resolved, true)
		end
		if IsNativeTaskLibrary(Resolved) and self.ExplicitShouldMock[Resolved.Key] ~= true then
			return SandboxTaskLibrary(self, Resolved)
		end
		return self:_requireOrMockResolved(Resolved)
	end

	if not IsInternal then
		local FakeTimers = self.FakeTimers
		Sandbox.delay = FakeTimers.delayOverride
		Sandbox.tick = FakeTimers.tickOverride
		Sandbox.time = FakeTimers.timeOverride
		Sandbox.DateTime = FakeTimers.dateTimeOverride
		Sandbox.os = FakeTimers.osOverride
		Sandbox.task = FakeTimers.taskOverride
	end

	local MockedEnvironment = setmetatable({}, { __index = Sandbox })
	SetUpAutomocks(self.GlobalMocker.automocks, Sandbox, MockedEnvironment)
	local Result = self.ModuleHost:Execute(Module, MockedEnvironment)
	if Result.n ~= 1 and NoModuleReturnRequired ~= true then
		error(
			("[Module Error]: %s did not return a valid result\n\tModuleScripts must return exactly one value"):format(
				Module.SourceLabel
			),
			0
		)
	end
	return Result[1]
end

function Runtime.new(Config, _LoadedModuleFunctions, ModuleHost)
	local SurfacePolicy = ResolveSurfacePolicy(Config)
	local self = setmetatable({
		Config = Config,
		ExplicitShouldMock = {},
		FakeTimers = JestFakeTimers.new(),
		InternalModules = {},
		IsolatedMocks = nil,
		IsolatedModules = nil,
		IsTornDown = false,
		JestGlobals = nil,
		JestGlobalsFacades = {},
		JestObjects = {},
		JestPackage = if SurfacePolicy.Name == "full" then SurfacePolicy.JestPackage else nil,
		JestPackageFacades = {},
		JestPackageLoader = if SurfacePolicy.Name == "full" then SurfacePolicy.LoadJestPackage else nil,
		MockFactories = {},
		Mocks = {},
		ModuleAliases = if typeof(Config) == "table" and typeof(Config.jestPortableModuleAliases) == "table"
			then table.clone(Config.jestPortableModuleAliases)
			else {},
		Modules = {},
		ModuleHost = ModuleHost or NewModuleHost(Config),
		OnMissingJestExport = if SurfacePolicy.Name == "test-globals" then SurfacePolicy.OnMissingJestExport else nil,
		PortableState = {},
		SurfacePolicy = SurfacePolicy,
		TaskLibraries = {},
	}, Runtime)

	self.ModuleMocker = JestMock.ModuleMocker.new(Config)
	self.GlobalMocker = JestMockGenv.GlobalMocker.new()
	self.PortableProvider = PortableRuntime.Provider()
	local Roblox = PortableRuntime.ResolveRoblox().Capability
	if Roblox ~= nil then
		self.ModuleMocker:protectDataModel(function(Instance, Method)
			return Roblox.IsInstance(Instance) and Method == "GetService" and Instance:IsA("DataModel")
		end)
	end
	self.ModuleMocker:mockGlobals(self.GlobalMocker, BaseEnvironment())
	return self
end

function Runtime:_requireResolved(Module, IsInternal, NoModuleReturnRequired)
	if self.IsTornDown then
		error(Error.new("Cannot require a module after the Jest runtime has been torn down"))
	end
	if Module.Kind == "native" then
		return self.ModuleHost:LoadNative(Module)
	end

	local Modules = Registry(self, IsInternal)
	if IsGlobalModule(Module.SourceLabel) then
		Modules = GlobalModules
	end
	local Existing = Modules[Module.Key]
	if Existing ~= nil then
		return Existing.Exports
	end

	local Record = { Exports = {}, Loaded = false }
	Modules[Module.Key] = Record
	local Ok, Result = pcall(ExecuteModule, self, Module, IsInternal, NoModuleReturnRequired)
	if not Ok then
		Modules[Module.Key] = nil
		error(Result, 0)
	end
	Record.Exports = Result
	Record.Loaded = true
	return Result
end

function Runtime:requireModule(From, ModuleName, Options, _IsRequireActual, NoModuleReturnRequired)
	if self.IsTornDown then
		error(Error.new("Cannot require a module after the Jest runtime has been torn down"))
	end
	local FromModule = Canonicalize(self, From)
	local IsInternal = typeof(Options) == "table" and Options.isInternalModule == true
	local IsSurfaceBound, SurfaceValue = TryRequireUserSurface(self, FromModule, ModuleName, IsInternal)
	if IsSurfaceBound then
		return SurfaceValue
	end
	local Module = if ModuleName == nil then FromModule else ResolveRequest(self, FromModule, ModuleName)
	return self:_requireResolved(Module, IsInternal, NoModuleReturnRequired)
end

function Runtime:requireInternalModule(From, To)
	return self:requireModule(From, To, { isInternalModule = true })
end

-- Circus names its initializer by its path in the package tree, which only the module host can turn into a module
function Runtime:requireFrameworkModule(Path)
	return self:requireInternalModule(self.ModuleHost:CanonicalizeFramework(Path))
end

function Runtime:requireActual(From, ModuleName)
	if self.IsTornDown then
		error(Error.new("Cannot require a module after the Jest runtime has been torn down"))
	end
	local FromModule = Canonicalize(self, From)
	local IsSurfaceBound, SurfaceValue = TryRequireUserSurface(self, FromModule, ModuleName, false)
	if IsSurfaceBound then
		return SurfaceValue
	end
	return self:_requireResolved(ResolveRequest(self, FromModule, ModuleName), false)
end

function Runtime:requireMock(From, ModuleName)
	if self.IsTornDown then
		error(Error.new("Cannot require a module after the Jest runtime has been torn down"))
	end
	local FromModule = Canonicalize(self, From)
	local IsSurfaceBound, SurfaceValue = TryRequireUserSurface(self, FromModule, ModuleName, false)
	if IsSurfaceBound then
		return SurfaceValue
	end
	local Module = ResolveRequest(self, FromModule, ModuleName)
	local Existing = MockRegistry(self)[Module.Key]
	if Existing ~= nil then
		return Existing.Value
	end
	local Factory = self.MockFactories[Module.Key]
	if Factory == nil then
		error(Error.new("manual mocks not implemented yet"))
	end
	local Value = Factory()
	MockRegistry(self)[Module.Key] = { Value = Value }
	return Value
end

function Runtime:_requireOrMockResolved(Module)
	if self.ExplicitShouldMock[Module.Key] == true then
		return self:requireMock(Module, Module)
	end
	return self:_requireResolved(Module, false)
end

function Runtime:requireModuleOrMock(ModuleName)
	if self.IsTornDown then
		error(Error.new("Cannot require a module after the Jest runtime has been torn down"))
	end
	local Module = Canonicalize(self, ModuleName)
	return self:_requireOrMockResolved(Module)
end

function Runtime:setMock(From, ModuleName, MockFactory, Options)
	if typeof(Options) == "table" and Options.virtual == true then
		error(Error.new("virtual mocks not supported"))
	end
	local FromModule = Canonicalize(self, From)
	local Module = ResolveRequest(self, FromModule, ModuleName)
	self.ExplicitShouldMock[Module.Key] = true
	self.MockFactories[Module.Key] = MockFactory
end

function Runtime:isolateModules(Callback)
	if self.IsolatedModules ~= nil or self.IsolatedMocks ~= nil then
		error(Error.new("isolateModules cannot be nested inside another isolateModules."))
	end
	self.IsolatedModules = {}
	self.IsolatedMocks = {}
	local Ok, Result = pcall(Callback)
	if self.IsolatedModules ~= nil then
		table.clear(self.IsolatedModules)
	end
	if self.IsolatedMocks ~= nil then
		table.clear(self.IsolatedMocks)
	end
	self.IsolatedModules = nil
	self.IsolatedMocks = nil
	if not Ok then
		error(Result, 0)
	end
end

function Runtime:resetModules()
	if self.IsolatedModules ~= nil then
		table.clear(self.IsolatedModules)
	end
	if self.IsolatedMocks ~= nil then
		table.clear(self.IsolatedMocks)
	end
	self.IsolatedModules = nil
	self.IsolatedMocks = nil
	table.clear(self.Mocks)
	table.clear(self.Modules)
	table.clear(self.JestGlobalsFacades)
	table.clear(self.JestPackageFacades)
end

function Runtime:restoreAllMocks()
	self.ModuleMocker:restoreAllMocks()
end

function Runtime:resetAllMocks()
	self.ModuleMocker:unmockGlobals(self.GlobalMocker)
	self.ModuleMocker:resetAllMocks()
	self.ModuleMocker:mockGlobals(self.GlobalMocker, BaseEnvironment())
end

function Runtime:clearAllMocks()
	self.ModuleMocker:clearAllMocks()
end

function Runtime:_createJestObjectFor(From)
	local Existing = self.JestObjects[From.Key]
	if Existing ~= nil then
		return Existing
	end

	local JestObject
	local function Resolve(ModuleName)
		return ResolveRequest(self, From, ModuleName)
	end
	local function SetMockFactory(ModuleName, Factory, Options)
		self:setMock(From, ModuleName, Factory, Options)
		return JestObject
	end
	local function Mock(ModuleName, Factory, Options)
		if Factory ~= nil then
			return SetMockFactory(ModuleName, Factory, Options)
		end
		self.ExplicitShouldMock[Resolve(ModuleName).Key] = true
		return JestObject
	end
	local function Unmock(ModuleName)
		self.ExplicitShouldMock[Resolve(ModuleName).Key] = false
		return JestObject
	end
	local function FakeTimers()
		return self.FakeTimers
	end

	JestObject = {
		advanceTimersByTime = function(Milliseconds)
			return FakeTimers():advanceTimersByTime(Milliseconds)
		end,
		advanceTimersToNextTimer = function(Steps)
			return FakeTimers():advanceTimersToNextTimer(Steps)
		end,
		clearAllMocks = function()
			self:clearAllMocks()
			return JestObject
		end,
		clearAllTimers = function()
			return FakeTimers():clearAllTimers()
		end,
		doMock = Mock,
		dontMock = Unmock,
		fn = function(...)
			return self.ModuleMocker:fn(...)
		end,
		getEngineFrameTime = function()
			return FakeTimers():getEngineFrameTime()
		end,
		getRealSystemTime = function()
			return FakeTimers():getRealSystemTime()
		end,
		getTimerCount = function()
			return FakeTimers():getTimerCount()
		end,
		globalEnv = self.GlobalMocker.envObject,
		isMockFunction = self.ModuleMocker.isMockFunction,
		isolateModules = function(Callback)
			self:isolateModules(Callback)
			return JestObject
		end,
		mock = Mock,
		requireActual = function(ModuleName)
			return self:requireActual(From, ModuleName)
		end,
		requireMock = function(ModuleName)
			return self:requireMock(From, ModuleName)
		end,
		resetAllMocks = function()
			self:resetAllMocks()
			return JestObject
		end,
		resetModules = function()
			self:resetModules()
			return JestObject
		end,
		restoreAllMocks = function()
			self:restoreAllMocks()
			return JestObject
		end,
		retryTimes = function(Count, Options)
			local PortableState = self.PortableState
			PortableState.RetryTimes = Count
			PortableState.LogErrorsBeforeRetry = if Options then Options.logErrorsBeforeRetry else nil
			PortableState.WaitBeforeRetry = if Options then Options.waitBeforeRetry else nil
			PortableState.RetryImmediately = if Options then Options.retryImmediately else nil
			return JestObject
		end,
		runAllTimers = function()
			return FakeTimers():runAllTimers()
		end,
		runOnlyPendingTimers = function()
			return FakeTimers():runOnlyPendingTimers()
		end,
		setEngineFrameTime = function(Milliseconds)
			return FakeTimers():setEngineFrameTime(Milliseconds)
		end,
		setMock = function(ModuleName, Value)
			return SetMockFactory(ModuleName, function()
				return Value
			end)
		end,
		setSystemTime = function(Now)
			return FakeTimers():setSystemTime(Now)
		end,
		spyOn = function(...)
			return self.ModuleMocker:spyOn(...)
		end,
		unmock = Unmock,
		useFakeTimers = function()
			FakeTimers():useFakeTimers()
			return JestObject
		end,
		useRealTimers = function()
			FakeTimers():useRealTimers()
			return JestObject
		end,
		jestTimers = FakeTimers(),
	}
	self.JestObjects[From.Key] = JestObject
	return JestObject
end

function Runtime:getGlobalsFromEnvironment()
	if self.JestGlobals ~= nil then
		return table.clone(self.JestGlobals)
	end
	return {
		expect = JestExpect,
		expectExtended = JestExpect,
		jestSnapshot = {
			toMatchSnapshot = JestSnapshot.toMatchSnapshot,
			toThrowErrorMatchingSnapshot = JestSnapshot.toThrowErrorMatchingSnapshot,
		},
	}
end

function Runtime:_globalsWithJest(From, Package)
	local IsReduced = self.SurfacePolicy.Name == "test-globals"
	local Facades = if IsReduced or Package == nil then self.JestGlobalsFacades else self.JestPackageFacades
	local Existing = Facades[From.Key]
	if Existing ~= nil then
		return Existing
	end
	local Facade = Object.assign({}, Package or {}, self:getGlobalsFromEnvironment(), {
		jest = self:_createJestObjectFor(From),
	})
	if IsReduced and self.OnMissingJestExport ~= nil then
		setmetatable(Facade, {
			__index = function(_Target, Name)
				return self.OnMissingJestExport(Name)
			end,
		})
	elseif Package == nil and self.JestPackageLoader ~= nil then
		setmetatable(Facade, {
			__index = function(Target, Name)
				local Loaded = self.JestPackageLoader()
				for Key, Value in Loaded do
					if rawget(Target, Key) == nil then
						rawset(Target, Key, Value)
					end
				end
				setmetatable(Target, nil)
				return rawget(Target, Name)
			end,
		})
	end
	Facades[From.Key] = Facade
	return Facade
end

function Runtime:setGlobalsForRuntime(Globals)
	self.JestGlobals = Globals
	table.clear(self.JestGlobalsFacades)
	table.clear(self.JestPackageFacades)
end

function Runtime:teardown()
	if self.IsTornDown then
		return
	end
	table.clear(self.PortableState)
	self.ModuleMocker:unmockGlobals(self.GlobalMocker)
	self.ModuleMocker:restoreAllMocks()
	self.ModuleMocker:resetAllMocks()
	self:resetModules()
	table.clear(self.InternalModules)
	table.clear(self.MockFactories)
	table.clear(self.ExplicitShouldMock)
	table.clear(self.JestGlobalsFacades)
	table.clear(self.JestObjects)
	table.clear(self.JestPackageFacades)
	table.clear(self.ModuleAliases)
	self.ModuleHost:Dispose()
	self.IsTornDown = true
end

return Runtime

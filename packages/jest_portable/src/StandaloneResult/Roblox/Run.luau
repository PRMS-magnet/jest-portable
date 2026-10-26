--!strict

local JestCircus = require("../../../../jest_circus/src")
local JestConfig = require("../../../../jest_config/src")
local JestEnvironment = require("../../../../jest_environment_luau/src")
local JestRuntime = require("../../../../jest_runtime/src")
local CircusCore = require("../CircusCore")
local StrictResult = require("../../Bootstrap/StrictResult")

export type Options = {
	GlobalConfig: { [string]: any }?,
	JestPackage: any,
	LogicalPath: string,
	ModuleHost: {
		Resolutions: { [ModuleScript]: { [string]: ModuleScript } }?,
		SourceLabels: { [ModuleScript]: string }?,
		Sources: { [ModuleScript]: string }?,
	}?,
	ProjectConfig: { [string]: any }?,
	RootDirectory: string,
}

export type RunResult = CircusCore.RunResult

local function Configuration(Defaults: { [string]: any }, Overrides: { [string]: any }?): { [string]: any }
	local Result = table.clone(Defaults)
	if Overrides ~= nil then
		if typeof(Overrides) ~= "table" then
			error("JEST_CIRCUS_INPUT: configuration overrides must be tables", 3)
		end
		for Key, Value in Overrides do
			Result[Key] = Value
		end
	end
	return Result
end

local function RunResult(TestModule: ModuleScript, OptionsValue: Options): RunResult
	if typeof(TestModule) ~= "Instance" or not TestModule:IsA("ModuleScript") then
		error("JEST_CIRCUS_INPUT: test entry must be a ModuleScript", 2)
	end
	if typeof(OptionsValue) ~= "table" or typeof(OptionsValue.JestPackage) ~= "table" then
		error("JEST_CIRCUS_INPUT: options must provide the already-loaded Jest package", 2)
	end
	if typeof(OptionsValue.LogicalPath) ~= "string" or typeof(OptionsValue.RootDirectory) ~= "string" then
		error("JEST_CIRCUS_INPUT: logical path and root directory must be strings", 2)
	end
	local ProjectDefaults = Configuration(JestConfig.projectDefaults, OptionsValue.ProjectConfig)
	ProjectDefaults.jestPortableRobloxModuleHost = OptionsValue.ModuleHost
	return CircusCore.Run({
		EnvironmentModule = JestEnvironment,
		GlobalDefaults = Configuration(JestConfig.globalDefaults, OptionsValue.GlobalConfig),
		ProjectDefaults = ProjectDefaults,
		Runner = function(GlobalConfig, ProjectConfig, Environment, Runtime, _TestPath)
			return JestCircus.runner(GlobalConfig, ProjectConfig, Environment, Runtime, TestModule)
		end,
		RuntimeModule = JestRuntime,
		SurfacePolicy = { JestPackage = OptionsValue.JestPackage, Name = "full" },
	}, OptionsValue.LogicalPath, OptionsValue.RootDirectory)
end

local function Run(TestModule: ModuleScript, Context: any, OptionsValue: Options): any
	local BoundContext = StrictResult.SnapshotContext(Context)
	return StrictResult.Build(BoundContext, RunResult(TestModule, OptionsValue))
end

return table.freeze({
	Run = Run,
	RunResult = RunResult,
})

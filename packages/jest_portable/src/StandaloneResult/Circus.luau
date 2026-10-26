--!strict

local JestCircus = require("../../../jest_circus/src")
local JestConfig = require("../../../jest_config/src")
local JestEnvironment = require("../../../jest_environment_luau/src")
local JestRuntime = require("../../../jest_runtime/src")

local CircusCore = require("./CircusCore")
local LoadJestPackage = require("./Lute/JestPackageLoader")

export type CaseResult = CircusCore.CaseResult
export type RunResult = CircusCore.RunResult

local function Run(
	TestPath: string,
	RootDirectory: string,
	PreloadedInitializerPath: string?,
	JestPackage: any?,
	SourceOverrides: { [string]: string }?
): RunResult
	return CircusCore.Run({
		EnvironmentModule = JestEnvironment,
		GlobalDefaults = JestConfig.globalDefaults,
		ProjectDefaults = JestConfig.projectDefaults,
		Runner = JestCircus.runner,
		RuntimeModule = JestRuntime,
		SurfacePolicy = {
			JestPackage = JestPackage,
			LoadJestPackage = if JestPackage == nil then LoadJestPackage else nil,
			Name = "full",
		},
	}, TestPath, RootDirectory, PreloadedInitializerPath, SourceOverrides)
end

return table.freeze({
	Run = Run,
})

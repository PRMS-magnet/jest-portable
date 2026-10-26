-- ROBLOX upstream: https://github.com/facebook/jest/blob/v28.0.0/packages/jest-runner/src/runTest.ts
--[[*
 * Copyright (c) Facebook, Inc. and its affiliates. All Rights Reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *
 ]]

                                     
local Promise = require("../../../promise/src")
local RuntimeCapabilities = require("../Runtime").Get()
local getRelativePath = require("../../../jest_roblox_shared/src").getRelativePath
local getDataModelService = require("../../../jest_roblox_shared/src").getDataModelService
local CoreScriptSyncService = getDataModelService("CoreScriptSyncService")

local chalk = require("../../../chalk_lua/src")
local consoleModule = require("../../../jest_console/src")
local BufferedConsole = consoleModule.BufferedConsole
type BufferedConsole = consoleModule.BufferedConsole
local CustomConsole = consoleModule.CustomConsole
type CustomConsole = consoleModule.CustomConsole
type LogMessage = consoleModule.LogMessage
type LogType = consoleModule.LogType
local NullConsole = consoleModule.NullConsole
type NullConsole = consoleModule.NullConsole
local getConsoleOutput = consoleModule.getConsoleOutput
local environmentModule = require("../../../jest_environment/src")
type JestEnvironment = environmentModule.JestEnvironment
local test_resultModule = require("../../../jest_test_result/src")
type TestResult = test_resultModule.TestResult
local jestTypesModule = require("../../../jest_types/src")
type Promise<T> = jestTypesModule.Promise<T>
type Config_GlobalConfig = jestTypesModule.Config_GlobalConfig
type Config_ProjectConfig = jestTypesModule.Config_ProjectConfig
type RuntimeClass = typeof(require("../../../jest_runtime/src"))
local jest_utilModule = require("../../../jest_util/src")
local setGlobal = jest_utilModule.setGlobal
local typesModule = require("./types")
type TestFramework = typesModule.TestFramework
type TestRunnerContext = typesModule.TestRunnerContext

local Writeable = require("../../../jest_roblox_shared/src").Writeable

local function freezeConsole(testConsole: BufferedConsole | CustomConsole | NullConsole, config: Config_ProjectConfig)
	local function fakeConsolePush(self: any, _type: LogType, message: LogMessage)
		RuntimeCapabilities.WriteWarning(
			('%s\nAttempted to log "%s".'):format(
				chalk.red(
					("%s Did you forget to wait for something async in your test?"):format(
						chalk.bold("Cannot log after tests are done.")
					)
				),
				message
			)
		)
	end
	(testConsole :: any)._log = fakeConsolePush
end

local function runTestInternal(
	path: any         ,
	globalConfig: Config_GlobalConfig,
	projectConfig: Config_ProjectConfig,
	resolver: any,
	context: TestRunnerContext,
	loadedModuleFns: { [any         ]: { any } }
): Promise<TestResult>
	return Promise.resolve():andThen(function()
		local testEnvironment = projectConfig.testEnvironment

		local TestEnvironment: JestEnvironment = (require :: any)(testEnvironment)
		local testFramework: TestFramework = require("../../../jest_circus/src").runner
		local Runtime: RuntimeClass = require("../../../jest_runtime/src")

		local consoleOut = Writeable.new()
		local function consoleFormatter(type_, message: LogMessage)
			return getConsoleOutput(
				-- 4 = the console call is buried 4 stack frames deep
				BufferedConsole.write({}, type_, message, 4),
				projectConfig,
				globalConfig
			)
		end

		local testConsole

		if globalConfig.silent then
			testConsole = NullConsole.new(consoleOut, consoleOut, consoleFormatter)
		elseif globalConfig.verbose then
			testConsole = CustomConsole.new(consoleOut, consoleOut, consoleFormatter)
		else
			testConsole = BufferedConsole.new()
		end

		local environment = TestEnvironment.new(projectConfig, {
			console = testConsole,
			testPath = path,
		})

		if typeof(environment.getVmContext) ~= "function" then
			RuntimeCapabilities.WriteWarning(
				('Test environment found at "%s" does not export a "getVmContext" method, which is mandatory from Jest 27. This method is a replacement for "runScript".'):format(
					tostring(testEnvironment)
				)
			)
			error(1)
		end

		setGlobal((environment.global :: unknown) :: typeof(_G), "console", testConsole)

		local runtime = Runtime.new(projectConfig, loadedModuleFns)

		local start = os.clock() * 1000                   

		for _, path_ in projectConfig.setupFiles do
			runtime:requireModule(path_)
		end

		local ok, result = pcall(function()
			environment:setup():expect()
			local result: TestResult

			local ok_, result_ = pcall(function()
				result = testFramework(globalConfig, projectConfig, environment, runtime, path):expect()
			end)
			if not ok_ then
				local err = result_
				error(err)
			end

			freezeConsole(testConsole, projectConfig)

			local testCount = result.numPassingTests
				+ result.numFailingTests
				+ result.numPendingTests
				+ result.numTodoTests

			local end_ = os.clock() * 1000                   
			local testRuntime = end_ - start
			result.perfStats = {
				["end"] = end_,
				runtime = testRuntime,
				slow = testRuntime / 1000 > projectConfig.slowTestThreshold,
				start = start,
			}
			if CoreScriptSyncService then
				result.testFilePath = CoreScriptSyncService:GetScriptFilePath(path)
			else
				result.testFilePath = getRelativePath(path, projectConfig.rootDir)
			end
			result.console = testConsole:getBuffer()
			result.skipped = testCount == result.numPendingTests
			result.displayName = projectConfig.displayName

			-- Delay the resolution to allow log messages to be output.
			return Promise.new(function(resolve)
				RuntimeCapabilities.Task.Delay(0, function()
					resolve(result)
				end)
			end)
		end)
		runtime:teardown()
		environment:teardown():expect()

		if not ok then
			error(result)
		end
		return result
	end)
end

local function runTest(
	path: any         ,
	globalConfig: Config_GlobalConfig,
	config: Config_ProjectConfig,
	resolver: any,
	context: TestRunnerContext,
	loadedModuleFns: { [any         ]: { any } }
): Promise<TestResult>
	return Promise.resolve():andThen(function()
		local result = runTestInternal(path, globalConfig, config, resolver, context, loadedModuleFns):expect()
		result.leaks = false
		return result
	end)
end

return runTest

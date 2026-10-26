--!strict

local Failure = require("../Bootstrap/Failure")

type Diagnostic = Failure.Diagnostic

export type Surface = "full" | "test-globals"

export type SurfacePolicy = {
	Name: Surface,
	JestPackage: any?,
	LoadJestPackage: ((Name: unknown?) -> any)?,
	OnMissingJestExport: ((Name: unknown) -> any)?,
}

export type Dependencies = {
	EnvironmentModule: { new: (ProjectConfig: any) -> any },
	GlobalDefaults: { [string]: any },
	ProjectDefaults: { [string]: any },
	Runner: (GlobalConfig: any, ProjectConfig: any, Environment: any, Runtime: any, TestPath: string) -> any,
	RuntimeModule: { new: (ProjectConfig: any) -> any },
	SurfacePolicy: SurfacePolicy,
}

export type CaseResult = {
	Cleanup: { Cancelled: number },
	Diagnostics: { Diagnostic },
	NamePath: { string },
	Ordinal: number,
	Status: "failed" | "passed" | "skipped",
}

export type RunResult = {
	Cases: { CaseResult },
	Counts: {
		Failed: number,
		Passed: number,
		Selected: number,
		Skipped: number,
	},
	Diagnostics: { Diagnostic },
	Status: "failed" | "no-tests" | "passed" | "skipped",
}

local function TextDiagnostic(Value: unknown, Code: string, Kind: Failure.Kind): Diagnostic
	return {
		Code = Code,
		Kind = Kind,
		Message = Failure.StripControlSequences(tostring(Value)),
	}
end

local function Capture(Value: unknown, Code: string, Kind: Failure.Kind, StartLevel: number): Diagnostic
	return Failure.Capture(Value, Code, Kind, StartLevel, true)
end

local function Failed(Diagnostics: { Diagnostic }): RunResult
	return {
		Cases = {},
		Counts = { Failed = 0, Passed = 0, Selected = 0, Skipped = 0 },
		Diagnostics = Diagnostics,
		Status = "failed",
	}
end

local function NamePath(TestResult: any): { string }
	local Ancestors = TestResult.ancestorTitles
	if typeof(Ancestors) ~= "table" then
		error("JEST_CIRCUS_RESULT: ancestorTitles must be an array", 0)
	end
	local Output = table.create(#Ancestors + 1)
	for Index, Name in Ancestors do
		if typeof(Name) ~= "string" then
			error("JEST_CIRCUS_RESULT: ancestor title must be a string", 0)
		end
		Output[Index] = Name
	end
	if typeof(TestResult.title) ~= "string" then
		error("JEST_CIRCUS_RESULT: title must be a string", 0)
	end
	Output[#Ancestors + 1] = TestResult.title
	return Output
end

local function FailureDiagnostics(TestResult: any): { Diagnostic }
	local Diagnostics: { Diagnostic } = {}
	local Details = TestResult.failureDetails
	local Frames = TestResult.failureFrames
	if typeof(Details) == "table" and #Details > 0 then
		for Index, Detail in Details do
			local RetainedFrames = if typeof(Frames) == "table" and typeof(Frames[Index]) == "table"
				then Frames[Index]
				else {}
			table.insert(Diagnostics, Failure.Capture(Detail, "test.throw", "throw", 5, true, RetainedFrames))
		end
	else
		local Messages = TestResult.failureMessages
		if typeof(Messages) == "table" then
			for _, Message in Messages do
				table.insert(Diagnostics, TextDiagnostic(Message, "test.throw", "throw"))
			end
		end
	end
	if #Diagnostics == 0 then
		table.insert(Diagnostics, TextDiagnostic("Jest test failed without failure details", "test.throw", "throw"))
	end
	return Diagnostics
end

local function Normalize(Result: any): RunResult
	if typeof(Result) ~= "table" or typeof(Result.testResults) ~= "table" then
		error("JEST_CIRCUS_RESULT: runner result is invalid", 0)
	end
	local Cases = table.create(#Result.testResults) :: { CaseResult }
	local FailedCount = 0
	local PassedCount = 0
	local SkippedCount = 0
	for Index, TestResult in Result.testResults do
		if typeof(TestResult) ~= "table" then
			error("JEST_CIRCUS_RESULT: test result is invalid", 0)
		end
		local Status: "failed" | "passed" | "skipped"
		local Diagnostics: { Diagnostic }
		if TestResult.status == "failed" then
			Status = "failed"
			Diagnostics = FailureDiagnostics(TestResult)
			FailedCount += 1
		elseif TestResult.status == "passed" then
			Status = "passed"
			Diagnostics = {}
			PassedCount += 1
		elseif TestResult.status == "pending" or TestResult.status == "todo" then
			Status = "skipped"
			Diagnostics = {}
			SkippedCount += 1
		else
			error(`JEST_CIRCUS_RESULT: unsupported test status {tostring(TestResult.status)}`, 0)
		end
		Cases[Index] = {
			Cleanup = { Cancelled = 0 },
			Diagnostics = Diagnostics,
			NamePath = NamePath(TestResult),
			Ordinal = Index - 1,
			Status = Status,
		}
	end

	if
		Result.numFailingTests ~= FailedCount
		or Result.numPassingTests ~= PassedCount
		or Result.numPendingTests + Result.numTodoTests ~= SkippedCount
	then
		error("JEST_CIRCUS_RESULT: runner counts are inconsistent", 0)
	end

	local Diagnostics: { Diagnostic } = {}
	if Result.testExecError ~= nil then
		table.insert(Diagnostics, Failure.Capture(Result.testExecError, "suite.execution", "throw", 4, true, {}))
	end
	local Status = if #Diagnostics > 0 or FailedCount > 0
		then "failed"
		elseif #Cases == 0 then "no-tests"
		elseif SkippedCount == #Cases then "skipped"
		else "passed"
	return {
		Cases = Cases,
		Counts = {
			Failed = FailedCount,
			Passed = PassedCount,
			Selected = #Cases,
			Skipped = SkippedCount,
		},
		Diagnostics = Diagnostics,
		Status = Status,
	}
end

local function Run(
	DependenciesValue: Dependencies,
	TestPath: string,
	RootDirectory: string,
	PreloadedInitializerPath: string?,
	SourceOverrides: { [string]: string }?
): RunResult
	if TestPath == "" or RootDirectory == "" then
		error("JEST_CIRCUS_INPUT: test path and root directory are required", 2)
	end
	local Environment: any = nil
	local Runtime: any = nil
	local Result: any = nil
	local ExecutionDiagnostics: { Diagnostic } = {}
	local Executed = xpcall(function()
		local ProjectConfig = table.clone(DependenciesValue.ProjectDefaults)
		ProjectConfig.rootDir = RootDirectory
		local MutableProjectConfig: any = ProjectConfig
		MutableProjectConfig.jestPortablePackage = DependenciesValue.SurfacePolicy.JestPackage
		MutableProjectConfig.jestPortablePackageLoader = DependenciesValue.SurfacePolicy.LoadJestPackage
		MutableProjectConfig.jestPortablePreloadedInitializerPath = PreloadedInitializerPath
		MutableProjectConfig.jestPortableSourceOverrides = SourceOverrides
		MutableProjectConfig.jestPortableSurfacePolicy = DependenciesValue.SurfacePolicy
		local GlobalConfig = table.clone(DependenciesValue.GlobalDefaults)
		Environment = DependenciesValue.EnvironmentModule.new(ProjectConfig)
		Environment:setup():expect()
		Runtime = DependenciesValue.RuntimeModule.new(ProjectConfig)
		Result = DependenciesValue.Runner(GlobalConfig, ProjectConfig, Environment, Runtime, TestPath):expect()
	end, function(Value)
		table.insert(ExecutionDiagnostics, Capture(Value, "suite.execution", "throw", 5))
	end)

	local CleanupDiagnostics: { Diagnostic } = {}
	if Runtime ~= nil then
		xpcall(function()
			Runtime:teardown()
		end, function(Value)
			table.insert(CleanupDiagnostics, Capture(Value, "test.cleanup", "cleanup", 5))
		end)
	end
	if Environment ~= nil then
		xpcall(function()
			Environment:teardown():expect()
		end, function(Value)
			table.insert(CleanupDiagnostics, Capture(Value, "test.cleanup", "cleanup", 5))
		end)
	end
	for _, Diagnostic in CleanupDiagnostics do
		table.insert(ExecutionDiagnostics, Diagnostic)
	end
	if not Executed then
		return Failed(ExecutionDiagnostics)
	end

	local Normalized: RunResult? = nil
	local NormalizedSuccessfully = xpcall(function()
		Normalized = Normalize(Result)
	end, function(Value)
		table.insert(ExecutionDiagnostics, Capture(Value, "suite.result-invalid", "throw", 5))
	end)
	if not NormalizedSuccessfully then
		return Failed(ExecutionDiagnostics)
	end
	local Output = Normalized :: RunResult
	for _, Diagnostic in CleanupDiagnostics do
		table.insert(Output.Diagnostics, Diagnostic)
	end
	if #CleanupDiagnostics > 0 then
		Output.Status = "failed"
	end
	return Output
end

return table.freeze({
	Run = Run,
})

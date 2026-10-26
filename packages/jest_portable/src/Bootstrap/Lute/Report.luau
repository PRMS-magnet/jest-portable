--!strict

local fs = require("@std/fs")
local json = require("@std/json")
local process = require("@std/process")

local ResultArtifact = require("./ResultArtifact")
local StrictResult = require("../StrictResult")

type RunResult = any

local MAXIMUM_CONTEXT_BYTES = 262_144
local MAXIMUM_RESULT_BYTES = 1_048_576

local FileSystem: ResultArtifact.FileSystem = {
	Close = function(File: unknown) fs.close(File :: any) end,
	Open = function(Path: string, Mode: string): unknown return fs.open(Path, Mode :: any) end,
	Read = function(File: unknown): string return fs.read(File :: any) end,
	Write = function(File: unknown, Contents: string) fs.write(File :: any, Contents) end,
}

local function RequiredEnvironment(Name: string): string
	local Value = process.env[Name]
	if Value == nil or Value == "" then error(`{Name} is required`, 0) end
	return Value
end

local function ReadContext(Path: string): any
	local Text = ResultArtifact.ReadBounded(FileSystem, Path, MAXIMUM_CONTEXT_BYTES)
	return json.deserialize(Text)
end

local function Report(Result: RunResult): never
	local ContextPath = RequiredEnvironment("LUAU_RUN_CONTEXT_PATH")
	local ResultPath = RequiredEnvironment("LUAU_RUN_RESULT_PATH")
	local Context = ReadContext(ContextPath)
	local Output = StrictResult.Build(Context, Result)
	local Serialized = json.serialize(Output)
	if #Serialized > MAXIMUM_RESULT_BYTES then error("JEST_RESULT_TOO_LARGE: result exceeds its byte limit", 0) end
	ResultArtifact.WriteExclusive(FileSystem, ResultPath, Serialized)
	return process.exit(if Result.Status == "passed" or Result.Status == "skipped" then 0 else 1)
end

return Report

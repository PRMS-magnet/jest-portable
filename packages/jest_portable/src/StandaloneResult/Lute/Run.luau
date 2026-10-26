--!strict

local Report = require("../../Bootstrap/Lute/Report")
local Circus = require("../Circus")

local function Run(
	TestPath: string,
	RootDirectory: string,
	PreloadedInitializerPath: string?,
	JestPackage: any?,
	SourceOverrides: { [string]: string }?
): never
	return Report(Circus.Run(TestPath, RootDirectory, PreloadedInitializerPath, JestPackage, SourceOverrides))
end

return Run

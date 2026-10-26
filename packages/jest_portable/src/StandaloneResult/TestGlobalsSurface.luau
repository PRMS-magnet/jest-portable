--!strict

local SurfaceDiagnostic = require("../Bootstrap/SurfaceDiagnostic")

local SURFACE = "test-globals"

local FullOnlyExports = SurfaceDiagnostic.FullOnlyExports

local function OnMissingJestExport(Name: unknown): any
	if typeof(Name) ~= "string" or FullOnlyExports[Name] ~= true then
		return nil
	end
	local ErrorValue = SurfaceDiagnostic.Create(Name)
	if ErrorValue == nil then
		return nil
	end
	error(ErrorValue, 0)
end

local Policy = table.freeze({
	Name = SURFACE,
	OnMissingJestExport = OnMissingJestExport,
})

return table.freeze({
	FullOnlyExports = FullOnlyExports,
	Policy = Policy,
})

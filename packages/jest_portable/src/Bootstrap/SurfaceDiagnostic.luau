--!strict

local CanonicalText = require("./CanonicalText")

local CODE = "jest.surface-unavailable"
local SURFACE = "test-globals"
local REMEDIATION = 'surface = "full"'

local FullOnlyExports = table.freeze({
	SearchSource = true,
	TestWatcher = true,
	args = true,
	createTestScheduler = true,
	runCLI = true,
})
local Owned = setmetatable({}, { __mode = "k" })

local function Create(Name: unknown): { [string]: any }?
	if typeof(Name) ~= "string" or FullOnlyExports[Name] ~= true then
		return nil
	end
	local Value = table.freeze({
		code = CODE,
		message = CanonicalText.Sanitize(`Jest export {Name} is unavailable on surface {SURFACE}; set {REMEDIATION}`),
		remediation = REMEDIATION,
		requestedExport = Name,
		surface = SURFACE,
	})
	Owned[Value] = true
	return Value
end

local function CaptureCode(Value: unknown): string?
	if typeof(Value) == "table" and Owned[Value] == true then
		return CODE
	end
	return nil
end

return table.freeze({
	CaptureCode = CaptureCode,
	Create = Create,
	FullOnlyExports = FullOnlyExports,
})

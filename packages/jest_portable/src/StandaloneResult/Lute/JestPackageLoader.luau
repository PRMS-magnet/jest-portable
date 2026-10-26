--!strict

local Package: any = nil

local function Load(): any
	if Package == nil then Package = require("../../Jest") end
	return Package
end

return Load

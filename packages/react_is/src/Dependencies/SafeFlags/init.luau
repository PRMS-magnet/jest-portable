--!strict

local function CreateGetter(_Name: string, Default: any?): () -> any
	return function() return Default end
end

return table.freeze({
	createGetFFlag = CreateGetter,
	createGetFInt = CreateGetter,
})

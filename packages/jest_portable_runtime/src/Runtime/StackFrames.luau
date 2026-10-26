--!strict

export type Frame = {
	FunctionName: string?,
	Line: number?,
	Source: string,
}

local MAXIMUM_FRAMES = 64

local function Capture(StartLevel: number): { Frame }
	local Frames: { Frame } = {}
	for Level = StartLevel, StartLevel + MAXIMUM_FRAMES - 1 do
		local Source, Line, FunctionName = debug.info(Level, "sln")
		if Source == nil then
			break
		end
		if Source ~= "" then
			table.insert(Frames, {
				FunctionName = if FunctionName == "" then nil else FunctionName,
				Line = if Line > 0 then Line else nil,
				Source = Source,
			})
		end
	end
	return Frames
end

return table.freeze({ Capture = Capture })

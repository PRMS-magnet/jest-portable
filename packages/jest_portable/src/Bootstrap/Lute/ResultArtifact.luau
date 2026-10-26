--!strict

export type FileSystem = {
	Close: (File: unknown) -> (),
	Open: (Path: string, Mode: string) -> unknown,
	Read: (File: unknown) -> string,
	Write: (File: unknown, Contents: string) -> (),
}

local function Close(FileSystemValue: FileSystem, File: unknown): (boolean, unknown)
	local Failure: unknown = nil
	local Success = xpcall(function()
		FileSystemValue.Close(File)
	end, function(Message)
		Failure = Message
	end)
	return Success, Failure
end

local function ReadBounded(FileSystemValue: FileSystem, Path: string, MaximumBytes: number): string
	local File = FileSystemValue.Open(Path, "r")
	local Contents: string? = nil
	local ReadFailure: unknown = nil
	local ReadSuccess = xpcall(function()
		Contents = FileSystemValue.Read(File)
	end, function(Message)
		ReadFailure = Message
	end)
	local CloseSuccess, CloseFailure = Close(FileSystemValue, File)
	if not ReadSuccess then error(ReadFailure, 0) end
	if not CloseSuccess then error(CloseFailure, 0) end
	local Text = assert(Contents)
	if #Text > MaximumBytes then error("JEST_RESULT_CONTEXT: launch context exceeds its byte limit", 0) end
	return Text
end

local function WriteExclusive(FileSystemValue: FileSystem, Path: string, Contents: string)
	local File = FileSystemValue.Open(Path, "x+")
	local WriteFailure: unknown = nil
	local WriteSuccess = xpcall(function()
		FileSystemValue.Write(File, Contents)
	end, function(Message)
		WriteFailure = Message
	end)
	local CloseSuccess, CloseFailure = Close(FileSystemValue, File)
	if not WriteSuccess then error(WriteFailure, 0) end
	if not CloseSuccess then error(CloseFailure, 0) end
end

return table.freeze({
	ReadBounded = ReadBounded,
	WriteExclusive = WriteExclusive,
})

--!strict

local CanonicalText = require("./CanonicalText")
local SurfaceDiagnostic = require("./SurfaceDiagnostic")
local StackFrames = require("../Runtime/StackFrames")

export type Kind = "assertion" | "cleanup" | "rejection" | "throw"

export type StackFrame = StackFrames.Frame

export type Diagnostic = {
	Code: string,
	Kind: Kind,
	Matcher: {
		Name: string,
	}?,
	Message: string,
	Stack: {
		Frames: { StackFrame },
		Raw: string?,
	}?,
}

local MAX_STACK_FRAMES = 64

local Failure = {}

function Failure.StripControlSequences(Value: string): string
	return CanonicalText.Sanitize(Value)
end

local function Stringify(Value: unknown): string
	local ValueType = typeof(Value)
	if ValueType == "table" or ValueType == "function" or ValueType == "thread" or ValueType == "userdata" then
		return `<{ValueType} thrown value>`
	end
	local Success, Result = pcall(tostring, Value)
	if Success then
		return Failure.StripControlSequences(Result)
	end
	return "Unprintable thrown value"
end

local function ReadErrorField(Value: unknown, Field: string): unknown
	if typeof(Value) ~= "table" then
		return nil
	end
	return rawget(Value :: { [string]: unknown }, Field)
end

local function CopyFrames(SourceFrames: { StackFrame }): { StackFrame }
	local Frames = table.create(math.min(#SourceFrames, MAX_STACK_FRAMES))
	for Index = 1, math.min(#SourceFrames, MAX_STACK_FRAMES) do
		local Frame = SourceFrames[Index]
		Frames[Index] = {
			FunctionName = if Frame.FunctionName == nil then nil else Failure.StripControlSequences(Frame.FunctionName),
			Line = Frame.Line,
			Source = Failure.StripControlSequences(Frame.Source),
		}
	end
	return Frames
end

function Failure.Capture(
	Value: unknown,
	Code: string,
	KindValue: Kind,
	StartLevel: number,
	AllowMatcherPromotion: boolean?,
	RetainedFrames: { StackFrame }?
): Diagnostic
	local ErrorMessage = ReadErrorField(Value, "message")
	local PromiseError = ReadErrorField(Value, "error")
	local Message = if typeof(ErrorMessage) == "string" and ErrorMessage ~= ""
		then ErrorMessage
		elseif typeof(PromiseError) == "string" and PromiseError ~= "" then PromiseError
		else Stringify(Value)
	Message = Failure.StripControlSequences(Message)
	local StructuredCode = SurfaceDiagnostic.CaptureCode(Value)
	if StructuredCode ~= nil then
		Code = "jest.surface-unavailable"
	end

	local Matcher = nil
	local MatcherResult = ReadErrorField(Value, "matcherResult")
	if typeof(MatcherResult) == "table" and (KindValue == "assertion" or AllowMatcherPromotion == true) then
		-- Every matcher failure carries a result; only the equality matchers name themselves in it
		Code = "test.assertion"
		KindValue = "assertion"
		local MatcherName = rawget(MatcherResult :: { [string]: unknown }, "name")
		if typeof(MatcherName) == "string" and MatcherName ~= "" then
			Matcher = {
				Name = Failure.StripControlSequences(MatcherName),
			}
		end
	end

	local ErrorStack = ReadErrorField(Value, "stack")
	local Raw = if typeof(ErrorStack) == "string" and ErrorStack ~= ""
		then Failure.StripControlSequences(ErrorStack)
		else nil
	local Frames = if RetainedFrames ~= nil
		then CopyFrames(RetainedFrames)
		elseif KindValue == "rejection" then {}
		else CopyFrames(StackFrames.Capture(StartLevel))
	if Raw == nil and KindValue ~= "rejection" and RetainedFrames == nil then
		Raw = Failure.StripControlSequences(debug.traceback(Message, StartLevel))
	end

	return {
		Code = Code,
		Kind = KindValue,
		Matcher = Matcher,
		Message = Message,
		Stack = if Raw == nil and #Frames == 0
			then nil
			else {
				Frames = Frames,
				Raw = Raw,
			},
	}
end

function Failure.WithLiveStack(Value: unknown, StartLevel: number): unknown
	local ErrorMessage = ReadErrorField(Value, "message")
	local Message = if typeof(ErrorMessage) == "string" and ErrorMessage ~= "" then ErrorMessage else Stringify(Value)
	Message = Failure.StripControlSequences(Message)
	return {
		message = Message,
		stack = Failure.StripControlSequences(debug.traceback(Message, StartLevel)),
	}
end

function Failure.LegacyMessage(Diagnostics: { Diagnostic }): string?
	if #Diagnostics == 0 then
		return nil
	end

	local Messages = table.create(#Diagnostics)
	for Index, Diagnostic in Diagnostics do
		local Stack = Diagnostic.Stack
		Messages[Index] = if Stack ~= nil and Stack.Raw ~= nil then Stack.Raw else Diagnostic.Message
	end
	return table.concat(Messages, "\n\n")
end

return table.freeze(Failure)

--!strict

local CanonicalText = require("./CanonicalText")
local Failure = require("./Failure")

type Diagnostic = Failure.Diagnostic
type RunResult = {
	Cases: {
		{
			Cleanup: { Cancelled: number },
			Diagnostics: { Diagnostic },
			NamePath: { string },
			Ordinal: number,
			Status: "failed" | "passed" | "skipped",
		}
	},
	Counts: {
		Failed: number,
		Passed: number,
		Selected: number,
		Skipped: number,
	},
	Diagnostics: { Diagnostic },
	Status: "failed" | "no-tests" | "passed" | "skipped",
}

local FEATURE = "jest-portable.t1.expect-v1"
local PROTOCOL = "org.luau-run.standalone-result"
local MAXIMUM_CASES = 1_024
local MAXIMUM_DIAGNOSTICS = 1_024
local MAXIMUM_FRAMEWORK_STACK_FRAMES = 1_024
local MAXIMUM_FRAMEWORK_TEXT_BYTES = 786_432
local MAXIMUM_NAME_SEGMENTS = 4_096
local MAXIMUM_MESSAGE_BYTES = 65_536
local MAXIMUM_RENDERED_STACK_BYTES = 65_536 -- The protocol allows 262,144, but Luau Run's receipt keeps no longer framework string
local MAXIMUM_STACK_FRAMES = 256
local MAXIMUM_DOCUMENT_BYTES = 1_048_064 -- The host's 1 MiB less 512: the suite journal escapes this again, at most doubling it, and its own fields fit what is left of its 2 MiB event
local MAXIMUM_FRAMEWORK_DETAIL_BYTES = 524_288 -- Luau Run's receipt keeps no larger framework section
local MINIMUM_CUT_BYTES = 128
local MAXIMUM_CUT_STEPS = 8
local CUT_PRECISION = 256 -- The search ends within 1/256 of the allowance

type FrameworkBudget = {
	NameSegments: number,
	TextBytes: number,
}

-- A failure text sanitized whole, or only its two ends when it passed its own limit
type CutText = {
	Encoded: number?, -- Of the whole text, once measured
	Head: string,
	Marker: string,
	Tail: string?,
}

type Cut = {
	Framework: any,
	Message: CutText,
	MessageCopies: number,
	Outer: any,
	Raw: CutText?,
}

local function ContextError(Message: string): never
	error(`JEST_RESULT_CONTEXT: {Message}`, 3)
end

local function ResultError(Message: string): never
	error(`JEST_RESULT_INVALID: {Message}`, 3)
end

-- A result past a limit Luau Run can hold, as opposed to a malformed one: the spec is still reported, with why
local LIMIT = table.freeze({})
local function LimitError(Message: string): never
	error(setmetatable({ Message = Message }, LIMIT), 0)
end

local function IsInteger(Value: unknown): boolean
	return typeof(Value) == "number" and Value >= 0 and Value % 1 == 0
end

local function IsPrintableAscii(Value: string): boolean
	if Value == "" then
		return false
	end
	for Index = 1, #Value do
		local Byte = string.byte(Value, Index) :: number
		if Byte < 0x20 or Byte > 0x7E then
			return false
		end
	end
	return true
end

local function ContextString(Value: unknown, Label: string, MaximumBytes: number, Pattern: string?): string
	if typeof(Value) ~= "string" then
		ContextError(`{Label} must be bounded printable ASCII`)
	end
	local StringValue = Value :: string
	if #StringValue > MaximumBytes or not IsPrintableAscii(StringValue) then
		ContextError(`{Label} must be bounded printable ASCII`)
	end
	if Pattern ~= nil and string.match(StringValue, Pattern) == nil then
		ContextError(`{Label} has invalid syntax`)
	end
	return StringValue
end

local function Text(Value: string, Label: string, MaximumBytes: number?, Budget: FrameworkBudget?): string
	local Sanitized = CanonicalText.Sanitize(Value)
	if #Sanitized > (MaximumBytes or MAXIMUM_MESSAGE_BYTES) then
		LimitError(`a {Label} is longer than {MaximumBytes or MAXIMUM_MESSAGE_BYTES} bytes`)
	end
	if Budget ~= nil then
		Budget.TextBytes += #Sanitized
		if Budget.TextBytes > MAXIMUM_FRAMEWORK_TEXT_BYTES then
			LimitError(`its test names and stack frames pass {MAXIMUM_FRAMEWORK_TEXT_BYTES} bytes in all`)
		end
	end
	return Sanitized
end

local function IsContinuation(Byte: number?): boolean
	return Byte ~= nil and Byte >= 0x80 and Byte <= 0xBF
end

local function Prefix(Value: string, Bytes: number): string
	if #Value <= Bytes then
		return Value
	end
	local Last = Bytes
	while Last > 0 and IsContinuation(string.byte(Value, Last + 1)) do
		Last -= 1
	end
	return string.sub(Value, 1, Last)
end

local function Suffix(Value: string, Bytes: number): string
	if #Value <= Bytes then
		return Value
	end
	local First = #Value - Bytes + 1
	while First <= #Value and IsContinuation(string.byte(Value, First)) do
		First += 1
	end
	return string.sub(Value, First)
end

local function Cuttable(Value: string, Limit: number): CutText
	local Marker = `\n[... cut from {#Value} bytes ...]\n`
	if #Value <= Limit then
		return { Head = CanonicalText.Sanitize(Value), Marker = Marker }
	end
	local HeadBytes = Limit // 2
	return {
		Head = CanonicalText.Sanitize(Prefix(Value, HeadBytes)),
		Marker = Marker,
		Tail = CanonicalText.Sanitize(Suffix(Value, Limit - HeadBytes)),
	}
end

-- Whole when it fits, else its head and tail around a marker, so a stack keeps both its message and its frames
local function Render(Text: CutText, Allowance: number): string
	if Text.Tail == nil and #Text.Head <= Allowance then
		return Text.Head
	end
	local Marker = Text.Marker
	local Room = math.max(Allowance - #Marker, 0)
	local HeadBytes = Room // 2
	return Prefix(Text.Head, HeadBytes) .. Marker .. Suffix(Text.Tail or Text.Head, Room - HeadBytes)
end

-- Exact for the pinned Lute and HttpService, which write raw UTF-8 and escape only tab, newline, quote and backslash. Lute 1.0.0 wrote \u escapes, so recheck on any Lute pin change: an undercount fails LongFailures.test.luau
local function EncodedBytes(Value: string): number
	local _, Escapes = string.gsub(Value, '[\t\n"\\]', "")
	return #Value + Escapes
end

local function RenderedBytes(Text: CutText, Rendered: string): number
	if Rendered ~= Text.Head then
		return EncodedBytes(Rendered)
	end
	local Bytes = Text.Encoded or EncodedBytes(Rendered)
	Text.Encoded = Bytes
	return Bytes
end

local function DocumentBytes(Value: unknown): number
	if typeof(Value) == "string" then
		return EncodedBytes(Value) + 2
	elseif typeof(Value) == "number" then
		return #tostring(Value)
	elseif typeof(Value) == "boolean" then
		return if Value then 4 else 5
	elseif typeof(Value) ~= "table" then
		return 4
	end
	local Bytes = 1
	for Key, Entry in Value :: { [any]: unknown } do
		Bytes += 1 + DocumentBytes(Entry) + (if typeof(Key) == "string" then EncodedBytes(Key) + 3 else 0)
	end
	return math.max(Bytes, 2)
end

-- A text at an allowance, its encoded bytes, and what each further byte of allowance adds: half a byte per end with more to keep
local function Measure(Text: CutText, Allowance: number, Cap: number): (string, number, number)
	Allowance = math.min(Allowance, Cap)
	local Rendered = Render(Text, Allowance)
	local Bytes = RenderedBytes(Text, Rendered)
	if Rendered == Text.Head or Allowance == Cap then
		return Rendered, Bytes, 0
	end
	local Room = math.max(Allowance - #Text.Marker, 0)
	local Ends = (if #Text.Head > Room // 2 then 0.5 else 0)
		+ (if #(Text.Tail or Text.Head) > Room - Room // 2 then 0.5 else 0)
	local Density = (Bytes - EncodedBytes(Text.Marker)) / math.max(#Rendered - #Text.Marker, 1)
	return Rendered, Bytes, Ends * Density
end

-- Sets every failure text at one allowance, returning the room the document and framework section have left and how fast each shrinks
local function Place(Cuts: { Cut }, DocumentRoom: number, FrameworkRoom: number, Allowance: number): (number, number, number, number)
	local DocumentGrowth, FrameworkGrowth = 0, 0
	for _, Cut in Cuts do
		local Message, MessageBytes, MessageGrowth = Measure(Cut.Message, Allowance, MAXIMUM_MESSAGE_BYTES)
		DocumentRoom -= Cut.MessageCopies * MessageBytes
		DocumentGrowth += Cut.MessageCopies * MessageGrowth
		FrameworkRoom -= MessageBytes
		FrameworkGrowth += MessageGrowth
		Cut.Framework.message = Message
		Cut.Outer.message = Message
		if Cut.Raw ~= nil then
			local Raw, RawBytes, RawGrowth = Measure(Cut.Raw, Allowance, MAXIMUM_RENDERED_STACK_BYTES)
			DocumentRoom -= 2 * RawBytes
			DocumentGrowth += 2 * RawGrowth
			FrameworkRoom -= RawBytes
			FrameworkGrowth += RawGrowth
			Cut.Framework.stack.raw = Raw
			Cut.Outer.stack.rendered = Raw
		end
	end
	return DocumentRoom, FrameworkRoom, DocumentGrowth, FrameworkGrowth
end

-- The fewest bytes a text renders to at its cap, since a cut backs off at most one character at each end
local function Floor(Text: CutText, Cap: number): number
	if Text.Tail == nil then
		return math.min(#Text.Head, Cap - 64)
	end
	return math.min(#Text.Head, Cap // 2 - 64) + math.min(#Text.Tail, Cap // 2 - 64)
end

-- One allowance for all failure texts, near the largest that fits: Newton steps aimed a little under, halving instead when a step leaves the range between the largest fit and smallest miss. Only a fit is kept
local function PlaceCuts(Cuts: { Cut }, DocumentRoom: number, FrameworkRoom: number)
	local DocumentFloor, FrameworkFloor = 0, 0
	for _, Cut in Cuts do
		local Message = Floor(Cut.Message, MAXIMUM_MESSAGE_BYTES)
		local Raw = if Cut.Raw == nil then 0 else Floor(Cut.Raw, MAXIMUM_RENDERED_STACK_BYTES)
		DocumentFloor += Cut.MessageCopies * Message + 2 * Raw
		FrameworkFloor += Message + Raw
	end
	if DocumentFloor <= DocumentRoom and FrameworkFloor <= FrameworkRoom then
		local DocumentLeft, FrameworkLeft = Place(Cuts, DocumentRoom, FrameworkRoom, MAXIMUM_RENDERED_STACK_BYTES)
		if DocumentLeft >= 0 and FrameworkLeft >= 0 then
			return
		end
	end
	local Low, High = MINIMUM_CUT_BYTES, MAXIMUM_RENDERED_STACK_BYTES
	local Allowance = Low
	local DocumentLeft, FrameworkLeft, DocumentGrowth, FrameworkGrowth = Place(Cuts, DocumentRoom, FrameworkRoom, Allowance)
	if DocumentLeft < 0 or FrameworkLeft < 0 then
		LimitError("its failures cannot fit even cut short")
	end
	local Placed = true
	for _ = 1, MAXIMUM_CUT_STEPS do
		if Placed and FrameworkGrowth == 0 then
			break
		end
		local Next = (Low + High) // 2
		if FrameworkGrowth > 0 then
			local Target = Allowance + math.min(DocumentLeft / DocumentGrowth, FrameworkLeft / FrameworkGrowth)
			Next = (Target - Target / (4 * CUT_PRECISION)) // 1
		end
		if Placed and Next - Low <= Low // CUT_PRECISION or High - Low <= Low // CUT_PRECISION then
			break
		end
		if Next <= Low or Next >= High then
			Next = (Low + High) // 2
		end
		Allowance = Next
		DocumentLeft, FrameworkLeft, DocumentGrowth, FrameworkGrowth = Place(Cuts, DocumentRoom, FrameworkRoom, Allowance)
		Placed = DocumentLeft >= 0 and FrameworkLeft >= 0
		if Placed then
			Low = Allowance
		else
			High = Allowance
		end
	end
	if not Placed then
		Place(Cuts, DocumentRoom, FrameworkRoom, Low)
	end
end

local function CopyStringArray(Value: unknown, Label: string): { string }
	if typeof(Value) ~= "table" then
		ContextError(`{Label} must be a bounded array`)
	end
	local ArrayValue = Value :: { unknown }
	if #ArrayValue > MAXIMUM_CASES then
		ContextError(`{Label} must be a bounded array`)
	end
	local Output = table.create(#ArrayValue) :: { string }
	for Index, Entry in ArrayValue do
		Output[Index] = ContextString(Entry, `{Label}[{Index}]`, 256)
	end
	return Output
end

local function CopyContext(Context: any): (any, any, any)
	if typeof(Context) ~= "table" then
		ContextError("launch context must be an object")
	end
	CopyStringArray(Context.artifactIds, "artifactIds")
	CopyStringArray(Context.mappingIds, "mappingIds")

	local AttemptValue = Context.attempt
	if typeof(AttemptValue) ~= "table" then
		ContextError("attempt must be an object")
	end
	local AttemptNumber = AttemptValue.attemptNumber
	if not IsInteger(AttemptNumber) or AttemptNumber < 1 then
		ContextError("attempt.attemptNumber must be a positive integer")
	end
	local Attempt = {
		attemptNumber = AttemptNumber,
		jobId = ContextString(AttemptValue.jobId, "attempt.jobId", 256, "^[a-z0-9][a-z0-9+%._:%-]*$"),
		materializationId = ContextString(
			AttemptValue.materializationId,
			"attempt.materializationId",
			256,
			"^[a-z0-9][a-z0-9+%._:%-]*$"
		),
		nonce = ContextString(AttemptValue.nonce, "attempt.nonce", 43, "^[A-Za-z0-9_-]+$"),
		operationId = ContextString(AttemptValue.operationId, "attempt.operationId", 256, "^[a-z0-9][a-z0-9+%._:%-]*$"),
		providerId = ContextString(AttemptValue.providerId, "attempt.providerId", 256, "^[a-z0-9][a-z0-9+%._:%-]*$"),
		runtimeId = ContextString(AttemptValue.runtimeId, "attempt.runtimeId", 256, "^[a-z0-9][a-z0-9+%._:%-]*$"),
		selectionId = ContextString(AttemptValue.selectionId, "attempt.selectionId", 256, "^[a-z0-9][a-z0-9+%._:%-]*$"),
		sourceId = ContextString(AttemptValue.sourceId, "attempt.sourceId", 256, "^[a-z0-9][a-z0-9+%._:%-]*$"),
	}
	if #Attempt.nonce ~= 43 then
		ContextError("attempt.nonce must contain 43 characters")
	end

	local ProducerValue = Context.producer
	if typeof(ProducerValue) ~= "table" then
		ContextError("producer must be an object")
	end
	local Producer = {
		name = ContextString(ProducerValue.name, "producer.name", 256),
		runtime = ContextString(ProducerValue.runtime, "producer.runtime", 256),
		runtimeVersion = ContextString(ProducerValue.runtimeVersion, "producer.runtimeVersion", 256),
		version = ContextString(ProducerValue.version, "producer.version", 256),
	}

	local ProtocolValue = Context.protocol
	if typeof(ProtocolValue) ~= "table" then
		ContextError("protocol must be an object")
	end
	if ProtocolValue.name ~= PROTOCOL or ProtocolValue.major ~= 1 or ProtocolValue.minor ~= 1 then
		ContextError("protocol must be org.luau-run.standalone-result 1.1")
	end
	local RequiredFeatures = CopyStringArray(ProtocolValue.requiredFeatures, "protocol.requiredFeatures")
	if #RequiredFeatures ~= 1 or RequiredFeatures[1] ~= FEATURE then
		ContextError(`protocol must require exactly {FEATURE}`)
	end
	local Protocol = {
		major = 1,
		minor = 1,
		name = PROTOCOL,
		requiredFeatures = RequiredFeatures,
	}
	return Attempt, Producer, Protocol
end

-- The most frames each diagnostic keeps, innermost first, so all of them fit the aggregate: one allowance, the largest that
-- fits, so a short stack stays whole and long ones share the rest
local function FrameAllowance(Result: RunResult): number
	local Counts = {}
	local function Add(DiagnosticValue: Diagnostic)
		if DiagnosticValue.Stack ~= nil then
			table.insert(Counts, math.min(#DiagnosticValue.Stack.Frames, MAXIMUM_STACK_FRAMES))
		end
	end
	for _, DiagnosticValue in Result.Diagnostics do
		Add(DiagnosticValue)
	end
	for _, Case in Result.Cases do
		for _, DiagnosticValue in Case.Diagnostics do
			Add(DiagnosticValue)
		end
	end
	local function Fits(Allowance: number): boolean
		local Total = 0
		for _, Count in Counts do
			Total += math.min(Count, Allowance)
		end
		return Total <= MAXIMUM_FRAMEWORK_STACK_FRAMES
	end
	local Low, High = 0, MAXIMUM_STACK_FRAMES
	while Low < High do
		local Middle = (Low + High + 1) // 2
		if Fits(Middle) then
			Low = Middle
		else
			High = Middle - 1
		end
	end
	return Low
end

local function FrameworkDiagnostic(DiagnosticValue: Diagnostic, Budget: FrameworkBudget, FrameLimit: number): any
	local Stack = DiagnosticValue.Stack
	local Frames = if Stack == nil then nil else table.create(math.min(#Stack.Frames, FrameLimit))
	if Stack ~= nil and Frames ~= nil then
		for Index = 1, math.min(#Stack.Frames, FrameLimit) do
			local Frame = Stack.Frames[Index]
			if Frame.Line ~= nil and (not IsInteger(Frame.Line) or Frame.Line < 1) then
				ResultError("stack line must be a positive integer")
			end
			Frames[Index] = {
				functionName = if Frame.FunctionName == nil
					then nil
					else Text(Frame.FunctionName, "stack function", nil, Budget),
				line = Frame.Line,
				source = Text(Frame.Source, "stack source", nil, Budget),
			}
		end
	end
	return {
		code = Text(DiagnosticValue.Code, "diagnostic code", 64, Budget),
		kind = DiagnosticValue.Kind,
		matcher = if DiagnosticValue.Matcher == nil
			then nil
			else { name = Text(DiagnosticValue.Matcher.Name, "matcher name", 64, Budget) },
		message = "",
		stack = if Stack == nil then nil else { frames = Frames, raw = if Stack.Raw == nil then nil else "" },
	}
end

local function DiagnosticContract(DiagnosticValue: Diagnostic): (string, string, string)
	if DiagnosticValue.Code == "jest.surface-unavailable" then
		return "jest-surface-unavailable", "user", "body"
	elseif DiagnosticValue.Code == "suite.registration" then
		return "jest-registration-failed", "user", "bootstrap"
	elseif DiagnosticValue.Code == "test.assertion" or DiagnosticValue.Kind == "assertion" then
		return "jest-assertion-failed", "assertion", "body"
	elseif DiagnosticValue.Code == "test.rejection" or DiagnosticValue.Kind == "rejection" then
		return "jest-promise-rejected", "user", "body"
	elseif DiagnosticValue.Code == "test.cleanup" or DiagnosticValue.Kind == "cleanup" then
		return "jest-cleanup-failed", "cleanup", "cleanup"
	end
	return "jest-test-threw", "user", "body"
end

local function OuterDiagnostic(DiagnosticValue: Diagnostic, Id: string, FrameLimit: number): any
	local Code, Kind, Phase = DiagnosticContract(DiagnosticValue)
	local StackValue = DiagnosticValue.Stack
	local Stack = nil
	if StackValue ~= nil then
		local Frames = table.create(math.min(#StackValue.Frames, FrameLimit))
		for Index = 1, math.min(#StackValue.Frames, FrameLimit) do
			local Frame = StackValue.Frames[Index]
			Frames[Index] = {
				["function"] = if Frame.FunctionName == nil then nil else Text(Frame.FunctionName, "stack function"),
				origin = "debug-info",
			}
		end
		Stack = {
			frames = Frames,
			order = "innermost-first",
			rendered = if StackValue.Raw == nil then nil else "",
		}
	end
	return {
		code = Code,
		id = Id,
		kind = Kind,
		message = "",
		phase = Phase,
		severity = "error",
		stack = Stack,
	}
end

-- The message and rendered stack both copies of a diagnostic take once the allowance is known
local function DiagnosticCut(DiagnosticValue: Diagnostic, Framework: any, Outer: any): Cut
	local Stack = DiagnosticValue.Stack
	return {
		Framework = Framework,
		Message = Cuttable(DiagnosticValue.Message, MAXIMUM_MESSAGE_BYTES),
		MessageCopies = 2,
		Outer = Outer,
		Raw = if Stack == nil or Stack.Raw == nil then nil else Cuttable(Stack.Raw, MAXIMUM_RENDERED_STACK_BYTES),
	}
end

local function ExpectedStatus(
	SuiteDiagnostics: number,
	Failed: number,
	Passed: number,
	Selected: number,
	Skipped: number
): string
	if SuiteDiagnostics > 0 or Failed > 0 then
		return "failed"
	end
	if Selected == 0 then
		return "no-tests"
	end
	if Skipped == Selected then
		return "skipped"
	end
	if Passed > 0 then
		return "passed"
	end
	return ResultError("result status cannot be derived")
end

local function AssertCounts(Result: RunResult, Failed: number, Passed: number, Skipped: number)
	local Counts = Result.Counts
	if
		Counts.Failed ~= Failed
		or Counts.Passed ~= Passed
		or Counts.Selected ~= #Result.Cases
		or Counts.Skipped ~= Skipped
	then
		ResultError("runner counts are inconsistent")
	end
end

local function BuildWhole(Context: any, Result: RunResult): any
	local Attempt, Producer, Protocol = CopyContext(Context)
	if #Result.Cases > MAXIMUM_CASES then
		LimitError(`it has more than {MAXIMUM_CASES} tests`)
	end
	local DiagnosticCount = #Result.Diagnostics
	for _, Case in Result.Cases do
		DiagnosticCount += #Case.Diagnostics
	end
	if DiagnosticCount > MAXIMUM_DIAGNOSTICS then
		LimitError(`it has more than {MAXIMUM_DIAGNOSTICS} failures`)
	end
	local FrameLimit = FrameAllowance(Result)
	local Budget: FrameworkBudget = { NameSegments = 0, TextBytes = 0 }

	local Cuts: { Cut } = {}
	local OuterDiagnostics = {}
	local SuiteDiagnostics = table.create(#Result.Diagnostics)
	for Index, DiagnosticValue in Result.Diagnostics do
		local Framework = FrameworkDiagnostic(DiagnosticValue, Budget, FrameLimit)
		local Outer = OuterDiagnostic(DiagnosticValue, `suite-{Index - 1}`, FrameLimit)
		SuiteDiagnostics[Index] = Framework
		table.insert(OuterDiagnostics, Outer)
		table.insert(Cuts, DiagnosticCut(DiagnosticValue, Framework, Outer))
	end

	local Cases = table.create(#Result.Cases)
	local Failed = 0
	local Passed = 0
	local Skipped = 0
	for Index, Case in Result.Cases do
		if Case.Ordinal ~= Index - 1 then
			ResultError("case ordinals must be dense and zero-based")
		end
		local NamePath = table.create(#Case.NamePath)
		Budget.NameSegments += #Case.NamePath
		if Budget.NameSegments > MAXIMUM_NAME_SEGMENTS then
			LimitError(`its test names pass {MAXIMUM_NAME_SEGMENTS} parts in all`)
		end
		for NameIndex, Name in Case.NamePath do
			NamePath[NameIndex] = Text(Name, "case name", nil, Budget)
		end
		local Diagnostics = table.create(#Case.Diagnostics)
		for DiagnosticIndex, DiagnosticValue in Case.Diagnostics do
			local Framework = FrameworkDiagnostic(DiagnosticValue, Budget, FrameLimit)
			local Outer = OuterDiagnostic(DiagnosticValue, `case-{Case.Ordinal}-{DiagnosticIndex - 1}`, FrameLimit)
			Diagnostics[DiagnosticIndex] = Framework
			table.insert(OuterDiagnostics, Outer)
			table.insert(Cuts, DiagnosticCut(DiagnosticValue, Framework, Outer))
		end
		if Case.Status == "failed" then
			Failed += 1
			if #Diagnostics == 0 then
				ResultError("a failed case must have a diagnostic")
			end
		elseif Case.Status == "passed" then
			Passed += 1
		elseif Case.Status == "skipped" then
			Skipped += 1
		else
			ResultError("case status is invalid")
		end
		if not IsInteger(Case.Cleanup.Cancelled) or Case.Cleanup.Cancelled > 0x7FFFFFFF then
			ResultError("cleanup cancellation count must be a bounded nonnegative integer")
		end
		Cases[Index] = {
			cleanup = { cancelled = Case.Cleanup.Cancelled },
			diagnostics = Diagnostics,
			namePath = NamePath,
			ordinal = Case.Ordinal,
			status = Case.Status,
		}
	end

	AssertCounts(Result, Failed, Passed, Skipped)
	local Status = ExpectedStatus(#Result.Diagnostics, Failed, Passed, #Result.Cases, Skipped)
	if Result.Status ~= Status then
		ResultError("runner status is inconsistent")
	end
	local Counts = {
		failed = Failed,
		passed = Passed,
		selected = #Result.Cases,
		skipped = Skipped,
	}
	local Primary = OuterDiagnostics[1]
	local Outcome
	local Summary
	if Status == "passed" then
		Outcome = { status = "passed" }
		Summary = { executed = 1, failed = 0, passed = 1, selected = 1, skipped = 0 }
	elseif Status == "skipped" then
		Outcome = { reasonCode = "jest-all-skipped", status = "skipped" }
		Summary = { executed = 0, failed = 0, passed = 0, selected = 1, skipped = 1 }
	elseif Status == "no-tests" then
		Outcome = { reasonCode = "jest-no-tests", status = "no-tests" }
		Summary = { executed = 0, failed = 0, passed = 0, selected = 0, skipped = 0 }
	else
		if Primary == nil then
			ResultError("a failed result must have a diagnostic")
		end
		Cuts[1].MessageCopies = 3
		Outcome = { message = "", reasonCode = Primary.code, status = "failed" }
		Summary = { executed = 1, failed = 1, passed = 0, selected = 1, skipped = 0 }
	end

	local Output = {
		attempt = Attempt,
		diagnostics = OuterDiagnostics,
		framework = {
			feature = FEATURE,
			payload = {
				cases = Cases,
				counts = Counts,
				diagnostics = SuiteDiagnostics,
				status = Status,
			},
			schemaVersion = 1,
		},
		kind = "complete",
		outcome = Outcome,
		producer = Producer,
		protocol = Protocol,
		settlement = { state = "quiescent" },
		summary = Summary,
	}
	PlaceCuts(
		Cuts,
		MAXIMUM_DOCUMENT_BYTES - DocumentBytes(Output),
		MAXIMUM_FRAMEWORK_DETAIL_BYTES - DocumentBytes(Output.framework)
	)
	if Status == "failed" then
		Outcome.message = Primary.message
	end
	return Output
end

-- The spec's result in place of one no limit can hold: failed, saying why and what it counted
local function Bounded(Result: RunResult, Reason: string): RunResult
	local Counts = Result.Counts
	return {
		Cases = {},
		Counts = { Failed = 0, Passed = 0, Selected = 0, Skipped = 0 },
		Diagnostics = {
			{
				Code = "suite.result-limit",
				Kind = "throw",
				Message = `This spec's result is too large to keep whole: {Reason}. It had {#Result.Cases} tests: {Counts.Failed} failed, {Counts.Passed} passed, {Counts.Skipped} skipped. Split it into smaller specs to see each result.`,
			},
		},
		Status = "failed",
	}
end

local function Build(Context: any, Result: RunResult): any
	local Built, Output = pcall(BuildWhole, Context, Result)
	if Built then
		return Output
	end
	if getmetatable(Output) ~= LIMIT then
		error(Output, 0)
	end
	return BuildWhole(Context, Bounded(Result, Output.Message))
end

return table.freeze({
	Build = Build,
	SnapshotContext = function(Context: any): any
		local Attempt, Producer, Protocol = CopyContext(Context)
		return {
			artifactIds = CopyStringArray(Context.artifactIds, "artifactIds"),
			attempt = Attempt,
			mappingIds = CopyStringArray(Context.mappingIds, "mappingIds"),
			producer = Producer,
			protocol = Protocol,
		}
	end,
})

--!strict

local Contract = require("./Contract")
type TaskCapabilities = Contract.TaskCapabilities
type TaskRoutine = Contract.TaskRoutine

type Failure = {
	message: string,
	stack: string,
	value: unknown,
}

type PackedArguments = {
	[any]: any,
	n: number,
}

type AttemptContext = {
	Owner: unknown,
}

type ContextCallback = (...any) -> ...any

type Scope = {
	Errors: { unknown },
	Handles: { [thread]: true },
	Promises: { [any]: true },
	Revision: number,
}

export type FinishResult = {
	Cancelled: number,
	Errors: { unknown },
}

local ProviderTask: TaskCapabilities? = nil
local Current: Scope? = nil
local MaximumDrainTurns = 64
local RequiredStableTurns = 2
local ContextRegistry = JestPortableAttemptContextRegistry
if typeof(ContextRegistry) ~= "table" or typeof(ContextRegistry.ContextByThread) ~= "table" then
	ContextRegistry = {
		ContextByThread = setmetatable({}, { __mode = "k" }),
	}
end
local ContextByThread: { [thread]: AttemptContext } = ContextRegistry.ContextByThread

local function CaptureContext(): AttemptContext?
	return ContextByThread[coroutine.running()]
end

local function RunWithContext(Context: AttemptContext?, Callback: ContextCallback, ...: any): ...any
	if Context == nil then
		return Callback(...)
	end
	local Thread = coroutine.running()
	local Previous = ContextByThread[Thread]
	ContextByThread[Thread] = Context
	local Arguments = table.pack(...)
	local Results = table.pack(xpcall(function()
		return Callback(table.unpack(Arguments, 1, Arguments.n))
	end, function(Message)
		return Message
	end))
	ContextByThread[Thread] = Previous
	if not Results[1] then
		error(Results[2], 0)
	end
	return table.unpack(Results, 2, Results.n)
end

local function BindContext(Callback: ContextCallback, ContextOverride: AttemptContext?): ContextCallback
	local Context = ContextOverride or CaptureContext()
	return function(...: any): ...any
		return RunWithContext(Context, Callback, ...)
	end
end

local function RunAttempt(Owner: unknown, Callback: ContextCallback, ...: any): ...any
	return RunWithContext({ Owner = Owner }, Callback, ...)
end

local function GetAttemptOwner(): unknown
	local Context = CaptureContext()
	return if Context == nil then nil else Context.Owner
end

local function FailureFrom(Message: unknown): Failure
	local Success, Rendered = pcall(function()
		return tostring(Message :: any)
	end)
	local Text = if Success then Rendered else "Unprintable thrown value"
	return {
		message = Text,
		stack = debug.traceback(Text, 3),
		value = Message,
	}
end

local function Touch(ScopeValue: Scope)
	ScopeValue.Revision += 1
end

local function RecordError(ScopeValue: Scope, Message: unknown)
	table.insert(ScopeValue.Errors, Message)
	Touch(ScopeValue)
end

local function Track(Launch: (Routine: TaskRoutine, ...any) -> thread, Routine: TaskRoutine, ...: any): thread
	local ScopeValue = Current
	local Context = CaptureContext()
	if ScopeValue == nil then
		if typeof(Routine) == "thread" then
			local Arguments = table.pack(...)
			return Launch(function()
				local Previous = ContextByThread[Routine]
				if Context ~= nil then ContextByThread[Routine] = Context end
				local ResumeSuccess, Message = coroutine.resume(Routine, table.unpack(Arguments, 1, Arguments.n))
				-- A thread that yielded is still running its test, and its context must survive until the scheduler resumes it
				if coroutine.status(Routine) == "dead" then ContextByThread[Routine] = Previous end
				if not ResumeSuccess then error(Message, 0) end
			end)
		end
		return Launch(BindContext(Routine :: ContextCallback), ...)
	end

	local Completed = false
	local Handle: thread? = nil
	local function Wrapped(...: any)
		local Arguments = {
			n = select("#", ...),
			...,
		} :: PackedArguments
		local FailureValue: unknown = nil
		local Success = xpcall(function()
			if typeof(Routine) == "thread" then
				-- A thread with no frame at level 1 has never been resumed, so this call starts it; a scheduler continuation is already running and may yield again
				local Starting = select("#", debug.info(Routine, 1, "f")) == 0
				local Previous = ContextByThread[Routine]
				if Context ~= nil then ContextByThread[Routine] = Context end
				local ResumeSuccess, Message = coroutine.resume(Routine, table.unpack(Arguments, 1, Arguments.n))
				if coroutine.status(Routine) == "dead" then
					ContextByThread[Routine] = Previous
				end
				if not ResumeSuccess then
					error(Message, 0)
				end
				if Starting and coroutine.status(Routine) ~= "dead" then
					local CancelSuccess, CancelMessage = pcall(assert(ProviderTask).Cancel, Routine)
					if not CancelSuccess then
						error(CancelMessage, 0)
					end
					error("async-scope.thread-yield-unsupported: scoped thread routines must not yield; pass a function instead", 0)
				end
			else
				RunWithContext(Context, Routine, table.unpack(Arguments, 1, Arguments.n))
			end
		end, function(Message)
			FailureValue = FailureFrom(Message)
		end)
		if not Success then
			RecordError(ScopeValue, FailureValue)
		end
		Completed = true
		if Handle ~= nil and ScopeValue.Handles[Handle] then
			ScopeValue.Handles[Handle] = nil
			Touch(ScopeValue)
		end
	end

	Handle = Launch(Wrapped, ...)
	if not Completed then
		ScopeValue.Handles[Handle] = true
		Touch(ScopeValue)
	end
	return Handle
end

local function Configure(Task: TaskCapabilities): TaskCapabilities
	if ProviderTask ~= nil then
		assert(ProviderTask == Task, "Async scope was configured with a different task provider")
	else
		ProviderTask = Task
	end

	return table.freeze({
		Cancel = function(Thread: thread)
			local ScopeValue = Current
			if ScopeValue ~= nil and ScopeValue.Handles[Thread] then
				ScopeValue.Handles[Thread] = nil
				Touch(ScopeValue)
			end
			Task.Cancel(Thread)
		end,
		Defer = function(Routine: TaskRoutine, ...: any): thread
			return Track(function(Wrapped, ...: any): thread
				return Task.Defer(Wrapped, ...)
			end, Routine, ...)
		end,
		Delay = function(Seconds: number, Routine: TaskRoutine, ...: any): thread
			return Track(function(Wrapped, ...: any): thread
				return Task.Delay(Seconds, Wrapped, ...)
			end, Routine, ...)
		end,
		Spawn = function(Routine: TaskRoutine, ...: any): thread
			return Track(function(Wrapped, ...: any): thread
				return Task.Spawn(Wrapped, ...)
			end, Routine, ...)
		end,
		Wait = Task.Wait,
	})
end

local function Begin()
	assert(Current == nil, "An asynchronous test scope is already active")
	Current = {
		Errors = {},
		Handles = {},
		Promises = {},
		Revision = 0,
	}
end

local function TrackPromise(Promise: any)
	local ScopeValue = Current
	if ScopeValue ~= nil and not ScopeValue.Promises[Promise] then
		ScopeValue.Promises[Promise] = true
		Touch(ScopeValue)
	end
end

local function CompletePromise(Promise: any)
	local ScopeValue = Current
	if ScopeValue ~= nil and ScopeValue.Promises[Promise] then
		ScopeValue.Promises[Promise] = nil
		Touch(ScopeValue)
	end
end

local function DrainUntilStable(ScopeValue: Scope, Task: TaskCapabilities)
	local PreviousRevision = ScopeValue.Revision
	local StableTurns = 0
	for _ = 1, MaximumDrainTurns do
		Task.Wait(0)
		local Revision = ScopeValue.Revision
		if Revision == PreviousRevision then
			StableTurns += 1
			if StableTurns == RequiredStableTurns then
				return
			end
		else
			PreviousRevision = Revision
			StableTurns = 0
		end
	end
end

local function CancelPending(ScopeValue: Scope, Task: TaskCapabilities): number
	local Cancelled = 0
	local Promises = {}
	for Promise in ScopeValue.Promises do
		table.insert(Promises, Promise)
	end
	for _, Promise in Promises do
		if ScopeValue.Promises[Promise] then
			ScopeValue.Promises[Promise] = nil
			Touch(ScopeValue)
			Cancelled += 1
			local CancelFailure: unknown = nil
			local CancelSuccess = xpcall(function()
				Promise:cancel()
			end, function(Message)
				CancelFailure = FailureFrom(Message)
			end)
			if not CancelSuccess then
				RecordError(ScopeValue, CancelFailure)
			end
		end
	end

	local Handles = {}
	for Handle in ScopeValue.Handles do
		table.insert(Handles, Handle)
	end
	for _, Handle in Handles do
		if ScopeValue.Handles[Handle] then
			ScopeValue.Handles[Handle] = nil
			Touch(ScopeValue)
			Cancelled += 1
			local CancelFailure: unknown = nil
			local CancelSuccess = xpcall(function()
				Task.Cancel(Handle)
			end, function(Message)
				CancelFailure = FailureFrom(Message)
			end)
			if not CancelSuccess then
				RecordError(ScopeValue, CancelFailure)
			end
		end
	end
	return Cancelled
end

local function Finish(): FinishResult
	local ScopeValue = assert(Current, "No asynchronous test scope is active")
	local Task = assert(ProviderTask, "Async scope has no task provider")
	local Result: FinishResult? = nil
	local FailureValue: unknown = nil
	local Success = xpcall(function()
		DrainUntilStable(ScopeValue, Task)
		local Cancelled = CancelPending(ScopeValue, Task)
		DrainUntilStable(ScopeValue, Task)

		Result = {
			Cancelled = Cancelled,
			Errors = ScopeValue.Errors,
		}
	end, function(Message)
		FailureValue = Message
	end)
	Current = nil
	if not Success then
		error(FailureValue, 0)
	end
	return assert(Result)
end

return table.freeze({
	Begin = Begin,
	BindContext = BindContext,
	CaptureContext = CaptureContext,
	CompletePromise = CompletePromise,
	Configure = Configure,
	ContextRegistry = ContextRegistry,
	Finish = Finish,
	GetAttemptOwner = GetAttemptOwner,
	RunAttempt = RunAttempt,
	TrackPromise = TrackPromise,
})

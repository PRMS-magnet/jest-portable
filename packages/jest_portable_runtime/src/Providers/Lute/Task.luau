--!strict

local LuteTask = require("@std/task")
local Time = require("@lute/time")

local Contract = require("../../Runtime/Contract")
type TaskCapabilities = Contract.TaskCapabilities

type PackedArguments = {
	[any]: any,
	n: number,
}

type DelayedTask = {
	Arguments: PackedArguments,
	Due: number,
	Index: number,
	Sequence: number,
	Thread: thread,
}

local MaximumWait = 0.01
-- Each scheduler owns its clock, heap and driver, so one spec runtime's delays never run in another's
local function New(): TaskCapabilities
	local Epoch = Time.now()
	local DelayedByThread: { [thread]: DelayedTask } = {}
	local Heap: { DelayedTask } = {}
	local NextSequence = 0
	local DriverRunning = false

	local function Now(): number
		return Epoch:elapsed()
	end

	local function Earlier(Left: DelayedTask, Right: DelayedTask): boolean
		return Left.Due < Right.Due or (Left.Due == Right.Due and Left.Sequence < Right.Sequence)
	end

	local function Swap(LeftIndex: number, RightIndex: number)
		local Left = Heap[LeftIndex]
		local Right = Heap[RightIndex]
		Heap[LeftIndex] = Right
		Heap[RightIndex] = Left
		Left.Index = RightIndex
		Right.Index = LeftIndex
	end

	local function BubbleUp(Index: number)
		while Index > 1 do
			local ParentIndex = math.floor(Index / 2)
			if not Earlier(Heap[Index], Heap[ParentIndex]) then
				return
			end
			Swap(Index, ParentIndex)
			Index = ParentIndex
		end
	end

	local function BubbleDown(Index: number)
		while true do
			local LeftIndex = Index * 2
			if LeftIndex > #Heap then
				return
			end
			local RightIndex = LeftIndex + 1
			local EarlierIndex = if RightIndex <= #Heap and Earlier(Heap[RightIndex], Heap[LeftIndex])
				then RightIndex
				else LeftIndex
			if not Earlier(Heap[EarlierIndex], Heap[Index]) then
				return
			end
			Swap(Index, EarlierIndex)
			Index = EarlierIndex
		end
	end

	local function RemoveAt(Index: number): DelayedTask
		local Removed = assert(Heap[Index])
		local Last = assert(table.remove(Heap))
		if Index <= #Heap then
			Heap[Index] = Last
			Last.Index = Index
			if Index > 1 and Earlier(Last, Heap[math.floor(Index / 2)]) then
				BubbleUp(Index)
			else
				BubbleDown(Index)
			end
		end
		Removed.Index = 0
		return Removed
	end

	local function RunDriver()
		while #Heap > 0 do
			local First = Heap[1]
			local Remaining = First.Due - Now()
			if Remaining > 0 then
				LuteTask.wait(math.min(Remaining, MaximumWait))
			elseif Heap[1] == First then
				RemoveAt(1)
				if DelayedByThread[First.Thread] == First then
					DelayedByThread[First.Thread] = nil
				end
				LuteTask.spawn(First.Thread, table.unpack(First.Arguments, 1, First.Arguments.n))
			end
		end
		DriverRunning = false
	end

	local function StartDriver()
		if DriverRunning then
			return
		end
		DriverRunning = true
		LuteTask.defer(RunDriver)
	end

	local function Cancel(Thread: thread)
		local Delayed = DelayedByThread[Thread]
		if Delayed ~= nil then
			DelayedByThread[Thread] = nil
			RemoveAt(Delayed.Index)
			return
		end
		LuteTask.cancel(Thread)
	end

	local function Wait(Seconds: number?): number
		if Seconds == nil or Seconds <= 0 then
			return LuteTask.wait(Seconds)
		end
		local Started = Now()
		local Remaining = Seconds
		repeat
			LuteTask.wait(Remaining)
			Remaining = Seconds - (Now() - Started)
		until Remaining <= 0
		return Now() - Started
	end

	local function Delay(Seconds: number, Routine: ((...any) -> ...any) | thread, ...: any): thread
		if typeof(Routine) == "thread" then
			assert(coroutine.status(Routine) ~= "dead", "task.delay cannot schedule a dead thread")
			assert(DelayedByThread[Routine] == nil, "task.delay thread is already scheduled")
		end
		local Thread = if typeof(Routine) == "thread" then Routine else coroutine.create(Routine)
		NextSequence += 1
		local Arguments = {
			n = select("#", ...),
			...,
		} :: PackedArguments
		local Delayed = {
			Arguments = Arguments,
			Due = Now() + math.max(Seconds, 0),
			Index = #Heap + 1,
			Sequence = NextSequence,
			Thread = Thread,
		}
		Heap[Delayed.Index] = Delayed
		DelayedByThread[Thread] = Delayed
		BubbleUp(Delayed.Index)
		StartDriver()
		return Thread
	end

	return table.freeze({
		Cancel = Cancel,
		Defer = LuteTask.defer,
		Delay = Delay,
		Spawn = LuteTask.spawn,
		Wait = Wait,
	})
end

return table.freeze({
	New = New,
})

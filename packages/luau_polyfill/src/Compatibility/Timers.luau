--!strict

local Task = require("../Runtime").Get().Task

local State = newproxy(false)

local Scheduled = 1
local Done = 2
local Cancelled = 3
local MinimumDelaySeconds = 0.001
local MaximumDelayMilliseconds = 2_147_483_647

type Timer = {
	[typeof(State)]: {
		Handle: thread?,
		Status: number,
	},
}

type PackedArguments = {
	[any]: any,
	n: number,
}

export type Interval = Timer
export type Timeout = Timer

local function Pack<Arguments...>(...: Arguments...): PackedArguments
	return {
		n = select("#", ...),
		...,
	}
end

local function Cancel(TimerValue: Timer?)
	if TimerValue == nil or TimerValue[State].Status ~= Scheduled then
		return
	end
	local TimerState = TimerValue[State]
	TimerState.Status = Cancelled
	local Thread = TimerState.Handle
	TimerState.Handle = nil
	if Thread ~= nil then
		Task.Cancel(Thread)
	end
end

local function DelaySeconds(DelayMilliseconds: number?): number
	if
		DelayMilliseconds == nil
		or DelayMilliseconds ~= DelayMilliseconds
		or DelayMilliseconds < 1
		or DelayMilliseconds > MaximumDelayMilliseconds
	then
		return MinimumDelaySeconds
	end
	return DelayMilliseconds / 1000
end

local function setTimeout<Arguments...>(Callback: (Arguments...) -> (), DelayMilliseconds: number?, ...: Arguments...): Timeout
	local Arguments = Pack(...)
	local TimerValue: Timer = {
		[State] = {
			Handle = nil,
			Status = Scheduled,
		},
	}
	local TimerState = TimerValue[State]
	TimerState.Handle = Task.Delay(DelaySeconds(DelayMilliseconds), function()
		TimerState.Handle = nil
		if TimerState.Status ~= Scheduled then
			return
		end
		local Success, Message = pcall(Callback, table.unpack(Arguments, 1, Arguments.n))
		TimerState.Status = Done
		if not Success then
			error(Message, 0)
		end
	end)
	return TimerValue
end

local function setInterval<Arguments...>(Callback: (Arguments...) -> (), DelayMilliseconds: number?, ...: Arguments...): Interval
	local Arguments = Pack(...)
	local TimerValue: Timer = {
		[State] = {
			Handle = nil,
			Status = Scheduled,
		},
	}
	local TimerState = TimerValue[State]
	local Delay = DelaySeconds(DelayMilliseconds)

	local function Schedule()
		if TimerState.Status ~= Scheduled then
			return
		end
		TimerState.Handle = Task.Delay(Delay, function()
			TimerState.Handle = nil
			if TimerState.Status ~= Scheduled then
				return
			end
			local Success, Message = pcall(Callback, table.unpack(Arguments, 1, Arguments.n))
			if not Success then
				TimerState.Status = Done
				error(Message, 0)
			end
			Schedule()
		end)
	end
	Schedule()
	return TimerValue
end

return table.freeze({
	clearInterval = Cancel,
	clearTimeout = Cancel,
	setInterval = setInterval,
	setTimeout = setTimeout,
})

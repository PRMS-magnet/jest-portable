--!strict

local Runtime = require("../Runtime").Get()

local function FromUnixTimestamp(Seconds: number)
	return table.freeze({
		UnixTimestamp = math.floor(Seconds),
		UnixTimestampMillis = math.floor(Seconds * 1000),
	})
end

local DateTime = table.freeze({
	fromIsoDate = function(Source: string)
		local Year, Month, Day, Hour, Minute, Second = string.match(
			Source,
			"^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)"
		)
		if Year == nil then
			return nil
		end
		return FromUnixTimestamp(os.time({
			year = tonumber(Year) :: number,
			month = tonumber(Month) :: number,
			day = tonumber(Day) :: number,
			hour = tonumber(Hour) :: number,
			min = tonumber(Minute) :: number,
			sec = tonumber(Second) :: number,
		}))
	end,
	fromLocalTime = function(Year: number, Month: number, Day: number, Hour: number?, Minute: number?, Second: number?)
		return FromUnixTimestamp(os.time({
			year = Year,
			month = Month,
			day = Day,
			hour = Hour or 0,
			min = Minute or 0,
			sec = Second or 0,
		}))
	end,
	fromUnixTimestamp = FromUnixTimestamp,
	fromUnixTimestampMillis = function(Milliseconds: number)
		return FromUnixTimestamp(Milliseconds / 1000)
	end,
	fromUniversalTime = function(Year: number, Month: number, Day: number, Hour: number?, Minute: number?, Second: number?)
		return FromUnixTimestamp(os.time({
			year = Year,
			month = Month,
			day = Day,
			hour = Hour or 0,
			min = Minute or 0,
			sec = Second or 0,
		}))
	end,
	now = function()
		return FromUnixTimestamp(os.time())
	end,
})

local Task = table.freeze({
	cancel = Runtime.Task.Cancel,
	defer = Runtime.Task.Defer,
	delay = Runtime.Task.Delay,
	spawn = Runtime.Task.Spawn,
	wait = Runtime.Task.Wait,
})

return table.freeze({
	DateTime = DateTime,
	Task = Task,
	Tick = os.clock,
	Time = os.clock,
	WriteWarning = Runtime.WriteWarning,
})

--!strict
local PortableTimers = require("../Compatibility/Timers")






export type Timeout = PortableTimers.Timeout
export type Interval = PortableTimers.Interval

return PortableTimers

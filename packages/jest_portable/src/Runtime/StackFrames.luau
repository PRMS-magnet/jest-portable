--!strict

local Runtime = require("../../../jest_portable_runtime/src")
export type Frame = Runtime.StackFrame
return Runtime.StackFrames

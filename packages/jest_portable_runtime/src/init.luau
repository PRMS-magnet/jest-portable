--!strict

local Runtime = require("./src/Runtime")
export type StackFrame = Runtime.StackFrame
-- A spec's runtime loads its own copy of this package; its sandbox carries the host's provider and the spec's task library
if JestPortableProvider ~= nil then
	Runtime.Initialize(JestPortableProvider, JestPortableHostTask)
end

return Runtime

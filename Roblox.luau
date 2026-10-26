--!strict

local Runtime = require("./packages/jest_portable_runtime/src")
-- A spec's sandbox brings the host's provider, which its copy of the runtime took on load
if JestPortableProvider == nil then
	Runtime.Initialize(require("./packages/jest_portable_runtime/src/Providers/Roblox"))
end

return require("./packages/jest_portable/src")

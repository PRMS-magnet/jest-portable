local RobloxCapabilities = require("../Runtime").ResolveRoblox().Capability
return function(service: string)
	local success, result = pcall(function()
		local service = assert(RobloxCapabilities).GetService(service)
		local _ = service.Name
		return service
	end)

	return success and result or nil
end

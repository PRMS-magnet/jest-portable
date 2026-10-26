--!strict

local AsyncScope = require("../../../promise/src")._portableAsyncScope

local function NewState(Source: { [any]: any }?): { [any]: any }
	local State = if Source == nil then {} else table.clone(Source)
	State.assertionCalls = 0
	State.currentTestName = nil
	State.expectedAssertionsNumber = nil
	State.expectedAssertionsNumberError = nil
	State.isExpectingAssertions = false
	State.isExpectingAssertionsError = nil
	State.suppressedErrors = {}
	return State
end

local RootState = NewState(nil)
local StatesByAttempt: { [any]: { [any]: any } } = setmetatable({}, { __mode = "k" }) :: any

local function CurrentState(): { [any]: any }
	local Attempt = AsyncScope.CaptureContext()
	if Attempt == nil then
		return RootState
	end
	local State = StatesByAttempt[Attempt]
	if State == nil then
		State = table.clone(RootState)
		StatesByAttempt[Attempt] = State
		RootState = NewState(RootState)
	end
	return State
end

local MatcherState = setmetatable({
	matchers = {},
}, {
	__index = function(_Self, Key)
		if Key == "state" then
			return CurrentState()
		end
		return nil
	end,
})

return MatcherState

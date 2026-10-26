-- ROBLOX upstream: https://github.com/facebook/jest/blob/v28.0.0/packages/jest/src/jest.ts
--[[*
 * Copyright (c) Facebook, Inc. and its affiliates. All Rights Reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 ]]

                              

local coreModule = require("../../jest_core/src")

return {
	SearchSource = coreModule.SearchSource,
	TestWatcher = coreModule.TestWatcher,
	createTestScheduler = coreModule.createTestScheduler,
	runCLI = coreModule.runCLI,
	-- args handles arg parsing from ProcessService
	args = require("./Jest/args.roblox"),
}

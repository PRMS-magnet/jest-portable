-- ROBLOX upstream: https://github.com/facebook/jest/blob/v28.0.0/packages/jest-core/src/jest.ts
--[[*
 * Copyright (c) Facebook, Inc. and its affiliates. All Rights Reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 ]]

local exports = {}

exports.SearchSource = require("./JestCore/SearchSource").default
exports.createTestScheduler = require("./JestCore/TestScheduler").createTestScheduler
exports.TestWatcher = require("./JestCore/TestWatcher").default
exports.runCLI = require("./JestCore/cli").runCLI
-- ROBLOX deviation START: not needed
-- exports.getVersion = require(script.version).default
-- ROBLOX deviation END
return exports

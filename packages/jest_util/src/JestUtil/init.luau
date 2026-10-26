-- ROBLOX upstream: https://github.com/facebook/jest/tree/v28.0.0/packages/jest-util/src/index.ts

--[[*
 * Copyright (c) Facebook, Inc. and its affiliates. All Rights Reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 ]]

local LuauPolyfill = require("../../luau_polyfill/src")
local Object = LuauPolyfill.Object

local exports = {}

exports.clearLine = require("./JestUtil/clearLine").default
exports.createDirectory = require("./JestUtil/createDirectory").default
local ErrorWithStackModule = require("./JestUtil/ErrorWithStack")
exports.ErrorWithStack = ErrorWithStackModule.default
export type ErrorWithStack = ErrorWithStackModule.ErrorWithStack
-- ROBLOX deviation: need to execute the module explicitly
exports.installCommonGlobals = require("./JestUtil/installCommonGlobals")().default
-- ROBLOX deviation not ported as it doesn't seem necessary in Lua
-- exports.interopRequireDefault = require(script.interopRequireDefault).default
exports.isInteractive = require("./JestUtil/isInteractive").default
exports.isPromise = require("./JestUtil/isPromise").default
exports.setGlobal = require("./JestUtil/setGlobal").default
exports.deepCyclicCopy = require("./JestUtil/deepCyclicCopy").default
exports.convertDescriptorToString = require("./JestUtil/convertDescriptorToString").default
local specialCharsModule = require("./JestUtil/specialChars")
Object.assign(exports, specialCharsModule)
exports.specialChars = specialCharsModule
-- ROBLOX deviation START: additional assignments for Lua type inferrence to work
exports.ARROW = specialCharsModule.ARROW
exports.ICONS = specialCharsModule.ICONS
exports.CLEAR = specialCharsModule.CLEAR
-- ROBLOX deviation END
-- ROBLOX deviation: not ported as it doesn't seem necessary in Lua
-- exports.replacePathSepForGlob = require(script.replacePathSepForGlob).default
exports.testPathPatternToRegExp = require("./JestUtil/testPathPatternToRegExp").default
exports.globsToMatcher = require("./JestUtil/globsToMatcher").default
local preRunMessageModule = require("./JestUtil/preRunMessage")
exports.preRunMessage = preRunMessageModule
-- ROBLOX deviation START: additional assignments for Lua type inferrence to work
exports.print = preRunMessageModule.print
exports.remove = preRunMessageModule.remove
-- ROBLOX deviation END
exports.pluralize = require("./JestUtil/pluralize").default
exports.formatTime = require("./JestUtil/formatTime").default
-- ROBLOX deviation START: not ported as it doesn't seem necessary in Lua
-- exports.tryRealpath = require(script.tryRealpath).default
-- exports.requireOrImportModule = require(script.requireOrImportModule).default
-- ROBLOX deviation END
return exports

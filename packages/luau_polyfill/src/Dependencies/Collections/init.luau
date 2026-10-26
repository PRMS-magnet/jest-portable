--!strict
                              

local Array = require("./Collections/Array")
local Map = require("./Collections/Map")
local Object = require("./Collections/Object")
local Set = require("./Collections/Set")
local WeakMap = require("./Collections/WeakMap")
local inspect = require("./Collections/inspect")

local types = require("./ES7Types")

export type Array<T> = types.Array<T>
export type Map<T, V> = types.Map<T, V>
export type Object = types.Object
export type Set<T> = types.Set<T>
export type WeakMap<T, V> = types.WeakMap<T, V>

return {
	Array = Array,
	Object = Object,
	Map = Map.Map,
	coerceToMap = Map.coerceToMap,
	coerceToTable = Map.coerceToTable,
	Set = Set,
	WeakMap = WeakMap,
	inspect = inspect,
}

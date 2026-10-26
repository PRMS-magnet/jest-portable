                                     

local ES7Types = require("../ES7Types")

local Map = require("./Map/Map")
local coerceToMap = require("./Map/coerceToMap")
local coerceToTable = require("./Map/coerceToTable")

export type Map<K, V> = ES7Types.Map<K, V>

return {
	Map = Map,
	coerceToMap = coerceToMap,
	coerceToTable = coerceToTable,
}

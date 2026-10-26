--!strict
                                     
local ES7Types = require("../ES7Types")

export type Array<T> = ES7Types.Array<T>

return {
	concat = require("./Array/concat"),
	every = require("./Array/every"),
	filter = require("./Array/filter"),
	find = require("./Array/find"),
	findIndex = require("./Array/findIndex"),
	flat = require("./Array/flat"),
	flatMap = require("./Array/flatMap"),
	forEach = require("./Array/forEach"),
	from = require("./Array/from"),
	includes = require("./Array/includes"),
	indexOf = require("./Array/indexOf"),
	isArray = require("./Array/isArray"),
	join = require("./Array/join"),
	map = require("./Array/map"),
	reduce = require("./Array/reduce"),
	reverse = require("./Array/reverse"),
	shift = require("./Array/shift"),
	slice = require("./Array/slice"),
	some = require("./Array/some"),
	sort = require("./Array/sort"),
	splice = require("./Array/splice"),
	unshift = require("./Array/unshift"),
}

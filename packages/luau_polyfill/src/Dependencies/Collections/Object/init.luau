--!strict

return {
	assign = require("./Object/assign"),
	entries = require("./Object/entries"),
	freeze = require("./Object/freeze"),
	is = require("./Object/is"),
	isFrozen = require("./Object/isFrozen"),
	keys = require("./Object/keys"),
	preventExtensions = require("./Object/preventExtensions"),
	seal = require("./Object/seal"),
	values = require("./Object/values"),
	-- Special marker type used in conjunction with `assign` to remove values
	-- from tables, since nil cannot be stored in a table
	None = require("./Object/None"),
}

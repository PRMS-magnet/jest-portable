--!strict
                           
                                    
local types = require("../../ES7Types")
type Array<T> = types.Array<T>
local indexOf = require("./indexOf")

return function<T>(array: Array<T>, searchElement: T, fromIndex: number?): boolean
	return indexOf(array, searchElement, fromIndex) ~= -1
end

--!strict


local CanonicalText = {}

local function IsContinuation(Byte: number): boolean
	return Byte >= 0x80 and Byte <= 0xBF
end

local function EscapeCodepoint(Codepoint: number): string
	return string.format("\\u{%04X}", Codepoint)
end

local function IsFormatControl(Codepoint: number): boolean
	return (Codepoint >= 0x80 and Codepoint <= 0x9F)
		or Codepoint == 0x061C
		or Codepoint == 0x200E
		or Codepoint == 0x200F
		or (Codepoint >= 0x2028 and Codepoint <= 0x202E)
		or (Codepoint >= 0x2066 and Codepoint <= 0x2069)
end

local function IsNoncharacter(Codepoint: number): boolean
	return Codepoint >= 0xFDD0 and Codepoint <= 0xFDEF or bit32.band(Codepoint, 0xFFFF) >= 0xFFFE
end

local function Decode(Value: string, Index: number): (number?, number)
	local First = string.byte(Value, Index)
	if First == nil then
		return nil, 0
	end

	if First >= 0xC2 and First <= 0xDF then
		local Second = string.byte(Value, Index + 1)
		if Second ~= nil and IsContinuation(Second) then
			return (First - 0xC0) * 0x40 + (Second - 0x80), 2
		end
	elseif First >= 0xE0 and First <= 0xEF then
		local Second = string.byte(Value, Index + 1)
		local Third = string.byte(Value, Index + 2)
		if
			Second ~= nil
			and Third ~= nil
			and IsContinuation(Second)
			and IsContinuation(Third)
			and not (First == 0xE0 and Second < 0xA0)
			and not (First == 0xED and Second > 0x9F)
		then
			return (First - 0xE0) * 0x1000 + (Second - 0x80) * 0x40 + (Third - 0x80), 3
		end
	elseif First >= 0xF0 and First <= 0xF4 then
		local Second = string.byte(Value, Index + 1)
		local Third = string.byte(Value, Index + 2)
		local Fourth = string.byte(Value, Index + 3)
		if
			Second ~= nil
			and Third ~= nil
			and Fourth ~= nil
			and IsContinuation(Second)
			and IsContinuation(Third)
			and IsContinuation(Fourth)
			and not (First == 0xF0 and Second < 0x90)
			and not (First == 0xF4 and Second > 0x8F)
		then
			return (First - 0xF0) * 0x40000 + (Second - 0x80) * 0x1000 + (Third - 0x80) * 0x40 + (Fourth - 0x80), 4
		end
	end

	return nil, 1
end

function CanonicalText.Sanitize(Value: string): string
	local Normalized = Value
	if string.find(Normalized, "\r", 1, true) ~= nil then
		Normalized = string.gsub(Normalized, "\r\n", "\n")
		Normalized = string.gsub(Normalized, "\r", "\n")
	end
	if string.find(Normalized, "\27", 1, true) ~= nil then
		Normalized = string.gsub(Normalized, "\27%][^\7]*\7", "")
		Normalized = string.gsub(Normalized, "\27%][^\27]*\27\\", "")
		Normalized = string.gsub(Normalized, "\27%[[0-?]*[ -/]*[@-~]", "")
	end

	local Parts = {}
	local Index = 1
	while Index <= #Normalized do
		-- Printable ASCII, tabs and newlines pass through a run at a time
		local Stop = string.find(Normalized, "[^\t\n -~]", Index)
		if Stop == nil then
			table.insert(Parts, string.sub(Normalized, Index))
			break
		elseif Stop > Index then
			table.insert(Parts, string.sub(Normalized, Index, Stop - 1))
		end
		Index = Stop
		local Byte = string.byte(Normalized, Index) :: number
		if Byte < 0x80 then
			table.insert(Parts, string.format("\\x%02X", Byte))
			Index += 1
		else
			local Codepoint, Length = Decode(Normalized, Index)
			if Codepoint == nil then
				table.insert(Parts, string.format("\\x%02X", Byte))
				Index += 1
			elseif IsFormatControl(Codepoint) or IsNoncharacter(Codepoint) then
				table.insert(Parts, EscapeCodepoint(Codepoint))
				Index += Length
			else
				table.insert(Parts, string.sub(Normalized, Index, Index + Length - 1))
				Index += Length
			end
		end
	end
	return table.concat(Parts)
end

return table.freeze(CanonicalText)

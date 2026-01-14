TOGBankClassic_Output = {}

-- Current log level (default to INFO)
TOGBankClassic_Output.level = LOG_LEVEL.INFO

function TOGBankClassic_Output:Init()
	-- Level will be set from Options after DB is loaded
end

function TOGBankClassic_Output:SetLevel(level)
	self.level = level
end

function TOGBankClassic_Output:GetLevel()
	return self.level
end

-- Core logging function
-- If fmt contains %, uses string.format with varargs
-- Otherwise concatenates all arguments with spaces
local function Log(level, prefix, fmt, ...)
	if level < TOGBankClassic_Output.level and level ~= LOG_LEVEL.RESPONSE then
		return false
	end

	local message
	local numArgs = select("#", ...)
	if numArgs > 0 and fmt:find("%%") then
		-- Format string detected, use string.format
		message = string.format(fmt, ...)
	elseif numArgs > 0 then
		-- No format specifiers, concatenate all args with spaces
		local parts = { tostring(fmt) }
		for i = 1, numArgs do
			local arg = select(i, ...)
			parts[#parts + 1] = tostring(arg)
		end
		message = table.concat(parts, " ")
	else
		message = fmt
	end

	if prefix then
		TOGBankClassic_Core:Print(prefix, message)
	else
		TOGBankClassic_Core:Print(message)
	end
	return true
end

-- Debug: development/troubleshooting details
function TOGBankClassic_Output:Debug(fmt, ...)
	return Log(LOG_LEVEL.DEBUG, "|cff888888[DEBUG]|r", fmt, ...)
end

-- Info: sync status, normal operations
function TOGBankClassic_Output:Info(fmt, ...)
	return Log(LOG_LEVEL.INFO, nil, fmt, ...)
end

-- Warn: something unexpected but recoverable
function TOGBankClassic_Output:Warn(fmt, ...)
	return Log(LOG_LEVEL.WARN, "|cffffcc00[WARN]|r", fmt, ...)
end

-- Error: something failed
function TOGBankClassic_Output:Error(fmt, ...)
	return Log(LOG_LEVEL.ERROR, "|cffff4444[ERROR]|r", fmt, ...)
end

-- Response: response to user commands (always shown)
function TOGBankClassic_Output:Response(fmt, ...)
	return Log(LOG_LEVEL.RESPONSE, nil, fmt, ...)
end

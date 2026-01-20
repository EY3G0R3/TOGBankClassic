TOGBankClassic_Output = {}

-- Current log level (default to INFO)
TOGBankClassic_Output.level = LOG_LEVEL.INFO

-- Dedicated chat frame for debug output
TOGBankClassic_Output.debugFrame = nil
TOGBankClassic_Output.debugMessageBuffer = {}
TOGBankClassic_Output.maxBufferSize = 1000

function TOGBankClassic_Output:Init()
	-- Level will be set from Options after DB is loaded
end

function TOGBankClassic_Output:SetLevel(level)
	self.level = level
end

function TOGBankClassic_Output:GetLevel()
	return self.level
end

-- Store message in buffer
function TOGBankClassic_Output:BufferDebugMessage(message)
	table.insert(self.debugMessageBuffer, message)
	
	-- Keep buffer size manageable
	while #self.debugMessageBuffer > self.maxBufferSize do
		table.remove(self.debugMessageBuffer, 1)
	end
end

-- Redraw all buffered messages to debug frame
function TOGBankClassic_Output:RedrawDebugMessages()
	if not self.debugFrame then return end
	
	self.debugFrame:Clear()
	for _, msg in ipairs(self.debugMessageBuffer) do
		self.debugFrame:AddMessage(msg)
	end
end

-- Create or get dedicated debug chat frame
function TOGBankClassic_Output:GetDebugFrame()
	-- Return cached frame if we have it
	if self.debugFrame then
		return self.debugFrame
	end
	
	-- Try to find existing TOGBank Debug tab (even if hidden)
	for i = 1, NUM_CHAT_WINDOWS do
		local name = GetChatWindowInfo(i)
		if name == "TOGBank Debug" then
			self.debugFrame = _G["ChatFrame"..i]
			
			-- Ensure OnShow hook is set to redraw messages when tab becomes visible
			if not self.debugFrame.togbankHooked then
				self.debugFrame:HookScript("OnShow", function()
					TOGBankClassic_Output:RedrawDebugMessages()
				end)
				self.debugFrame.togbankHooked = true
			end
			
			-- Restore buffered messages when frame is found
			self:RedrawDebugMessages()
			return self.debugFrame
		end
	end
	
	return nil
end

-- Create dedicated debug chat tab
function TOGBankClassic_Output:CreateDebugTab()
	-- Check if tab already exists
	for i = 1, NUM_CHAT_WINDOWS do
		local name = GetChatWindowInfo(i)
		if name == "TOGBank Debug" then
			self.debugFrame = _G["ChatFrame"..i]
			-- Reconfigure and show existing frame
			self.debugFrame:SetMaxLines(1000)
			self.debugFrame:SetFading(false)
			FCF_SetLocked(self.debugFrame, false)
			-- Remove all message filters
			ChatFrame_RemoveAllMessageGroups(self.debugFrame)
			ChatFrame_RemoveAllChannels(self.debugFrame)
			
			-- Hook OnShow to redraw messages when tab becomes visible
			if not self.debugFrame.togbankHooked then
				self.debugFrame:HookScript("OnShow", function()
					TOGBankClassic_Output:RedrawDebugMessages()
				end)
				self.debugFrame.togbankHooked = true
			end
			
			self.debugFrame:Show()
			FCF_DockFrame(self.debugFrame)
			
			-- Initial draw of buffered messages
			self:RedrawDebugMessages()
			
			TOGBankClassic_Core:Print("TOGBank Debug tab found and shown (ChatFrame"..i..")")
			return true
		end
	end
	
	-- Find first available chat frame slot
	local frameIndex = nil
	for i = 1, NUM_CHAT_WINDOWS do
		local frame = _G["ChatFrame"..i]
		if frame then
			local name = GetChatWindowInfo(i)
			if not name or name == "" or not frame:IsShown() then
				frameIndex = i
				break
			end
		end
	end
	
	if not frameIndex then
		TOGBankClassic_Core:Print("|cffff0000Failed to create debug tab: no available chat frames|r")
		TOGBankClassic_Core:Print("Try using an existing chat frame instead")
		return false
	end
	
	-- Configure the frame
	local frame = _G["ChatFrame"..frameIndex]
	
	-- Reset frame completely
	FCF_ResetChatWindows()
	FCF_SetWindowName(frame, "TOGBank Debug", frameIndex)
	FCF_SetWindowColor(frame, 0.3, 0.3, 0.3)
	
	-- Clear all message groups and channels
	ChatFrame_RemoveAllMessageGroups(frame)
	ChatFrame_RemoveAllChannels(frame)
	
	-- Configure message history
	frame:SetMaxLines(1000)
	frame:SetFading(false)
	frame:SetTimeVisible(120)
	frame:SetIndentedWordWrap(false)
	
	-- Hook OnShow to redraw messages when tab becomes visible
	frame:HookScript("OnShow", function()
		TOGBankClassic_Output:RedrawDebugMessages()
	end)
	frame.togbankHooked = true
	
	-- Make it visible and unlocked so user can move/resize/close it
	FCF_SetLocked(frame, false)
	frame:Show()
	FCF_DockFrame(frame)
	
	self.debugFrame = frame
	
	-- Initial draw of buffered messages
	self:RedrawDebugMessages()
	
	TOGBankClassic_Core:Print("Created TOGBank Debug chat tab (ChatFrame"..frameIndex..")")
	TOGBankClassic_Core:Print("You can now right-click the tab to customize or close it")
	return true
end

-- Remove debug tab
function TOGBankClassic_Output:RemoveDebugTab()
	for i = 1, NUM_CHAT_WINDOWS do
		local name = GetChatWindowInfo(i)
		if name == "TOGBank Debug" then
			local frame = _G["ChatFrame"..i]
			-- Reset the frame completely
			FCF_SetWindowName(frame, "Combat Log", i)
			FCF_ResetChatWindows()
			frame:Hide()
			self.debugFrame = nil
			TOGBankClassic_Core:Print("Removed TOGBank Debug tab - please /reload to complete removal")
			return true
		end
	end
	
	TOGBankClassic_Core:Print("TOGBank Debug tab not found")
	return false
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

	-- If debug level and we have a debug frame, use it
	if level == LOG_LEVEL.DEBUG then
		local debugFrame = TOGBankClassic_Output:GetDebugFrame()
		if debugFrame then
			local fullMessage = "TOGBankClassic: "
			if prefix then
				fullMessage = fullMessage .. prefix .. " " .. message
			else
				fullMessage = fullMessage .. message
			end
			
			-- Store in buffer for persistence
			TOGBankClassic_Output:BufferDebugMessage(fullMessage)
			
			-- Add to frame
			debugFrame:AddMessage(fullMessage)
			return true
		end
	end
	
	-- Otherwise use normal print
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

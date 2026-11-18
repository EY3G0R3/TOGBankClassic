-- ICON-CROP-001 -- the minimap icon's crop is MEASURED from the art, the way Ultimate Tools' is
-- (TOGTools Tests/icon_spec.lua). TOGTools, 2026-11-17: its minimap button bag has a Square icons
-- mode that hides LibDBIcon's ring and draws each icon with the addon's own iconCoords, and the
-- operator's screenshots showed the Ultimate Bank coin cut flat at its edges there. The old crop
-- had been fitted for the round slot, where the ring hides the coin's rim. These read
-- Textures/UB-MMB-Icon.tga and check that the window the data object hands LibDBIcon holds the
-- whole drawn coin.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

-- io is plain Lua 5.1; the language server's WoW-only globals list does not have it.
---@diagnostic disable: undefined-global

-- Uncompressed (type 2) or RLE (type 10) true-colour TGA -> width, height, pixel(x, y) giving
-- r, g, b, a with (0, 0) the TOP-LEFT pixel.
local function readTGA(path)
	local fh = assert(io.open(path, "rb"), path .. " is missing")
	local data = fh:read("*a")
	fh:close()
	local idLen, imgType = data:byte(1), data:byte(3)
	local w = data:byte(13) + data:byte(14) * 256
	local h = data:byte(15) + data:byte(16) * 256
	local bpp, desc = data:byte(17), data:byte(18)
	assert(imgType == 2 or imgType == 10, "unsupported TGA image type " .. imgType)
	assert(bpp == 24 or bpp == 32, "unsupported TGA depth " .. bpp)
	local bytes = bpp / 8
	local pos = 19 + idLen
	local px = {}
	if imgType == 2 then
		for i = 0, w * h - 1 do
			px[i] = { data:byte(pos + i * bytes, pos + i * bytes + bytes - 1) }
		end
	else
		local i = 0
		while i < w * h do
			local head = data:byte(pos); pos = pos + 1
			local n = (head % 128) + 1
			if head >= 128 then
				local p = { data:byte(pos, pos + bytes - 1) }; pos = pos + bytes
				for _ = 1, n do px[i] = p; i = i + 1 end
			else
				for _ = 1, n do
					px[i] = { data:byte(pos, pos + bytes - 1) }; pos = pos + bytes; i = i + 1
				end
			end
		end
	end
	local topOrigin = math.floor(desc / 32) % 2 == 1
	return w, h, function(x, y)
		local row = topOrigin and y or (h - 1 - y)
		local p = px[row * w + x]
		return p[3], p[2], p[1], p[4] or 255
	end
end

-- The drawn part of the icon: every pixel that is neither transparent nor near-white background.
local function contentBounds(w, h, pixel)
	local minX, minY, maxX, maxY = w, h, -1, -1
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local r, g, b, a = pixel(x, y)
			if a >= 128 and not (r > 235 and g > 235 and b > 235) then
				if x < minX then minX = x end
				if x > maxX then maxX = x end
				if y < minY then minY = y end
				if y > maxY then maxY = y end
			end
		end
	end
	return minX, minY, maxX, maxY
end

describe("ICON-CROP-001: the Ultimate Bank minimap icon crop", function()
	local w, h, pixel = readTGA("Textures/UB-MMB-Icon.tga")
	local minX, minY, maxX, maxY = contentBounds(w, h, pixel)
	local measured = string.format("art %dx%d, drawn pixels x %d..%d, y %d..%d", w, h, minX, maxX, minY, maxY)

	-- Read the way LibDBIcon reads it: the data object's iconCoords, captured from the
	-- NewDataObject call Init makes. LibStub is stood in for this one call rather than the real
	-- LibDataBroker used, because that library survives env.reset and refuses a second
	-- NewDataObject under a name browse_spec has already registered in the same run.
	local function minimapCoords()
		env.reset()
		TOGBankClassic_Options = { db = { char = { minimap = { enabled = true } } } }
		env.loadFile("Modules/UI/Minimap.lua")
		local realLibStub = _G.LibStub
		local captured
		_G.LibStub = function(name)
			if name == "LibDataBroker-1.1" then
				return { NewDataObject = function(_, _, obj) captured = obj; return obj end }
			elseif name == "AceDB-3.0" then
				return { New = function() return { profile = { minimap = {} } } end }
			end
			return { Register = function() end }
		end
		local ok, err = pcall(TOGBankClassic_UI_Minimap.Init, TOGBankClassic_UI_Minimap)
		_G.LibStub = realLibStub
		assert(ok, err)
		assert.is_table(captured, "Init registered no data object with LibDataBroker")
		return captured.iconCoords
	end

	local function crop(c)
		return string.format("; crop %.4f %.4f %.4f %.4f", c[1], c[2], c[3], c[4])
	end

	-- A square slot draws a square window undistorted; LibDBIcon's button and the square bag are both
	-- square.
	it("is square", function()
		local c = minimapCoords()
		local windowAspect = ((c[2] - c[1]) * w) / ((c[4] - c[3]) * h)
		assert.is_true(math.abs(windowAspect - 1) < 0.001, measured .. string.format("; window aspect %.3f", windowAspect))
	end)

	-- The ask: no part of the coin is outside the window. TOGTools' half-pixel tolerance is kept, but
	-- not its 1.5px -- that slack would let a flat edge show on a 64px coin drawn large in the bag.
	it("keeps the whole coin inside the window, so the square bag shows no flat edge", function()
		local c = minimapCoords()
		local slack = 0.5 / w
		assert.is_true(c[1] <= minX / w + slack and c[2] >= (maxX + 1) / w - slack
			and c[3] <= minY / h + slack and c[4] >= (maxY + 1) / h - slack,
			measured .. crop(c))
	end)

	it("shows no more than three pixels of margin outside the coin on any side", function()
		local c = minimapCoords()
		local margin = 3 / w
		assert.is_true(minX / w - c[1] <= margin and c[2] - (maxX + 1) / w <= margin
			and minY / h - c[3] <= margin and c[4] - (maxY + 1) / h <= margin,
			measured .. crop(c))
	end)

	it("stays inside the file", function()
		local c = minimapCoords()
		assert.is_true(c[1] >= 0 and c[3] >= 0 and c[2] <= 1 and c[4] <= 1, measured .. crop(c))
	end)
end)

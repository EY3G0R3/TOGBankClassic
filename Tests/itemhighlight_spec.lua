-- ItemHighlight -- resolving which ContainerFrame is rendering a bag.
--
-- AUDIT FINDING 29 (HIGH). Both call sites derived the frame name arithmetically --
-- `containerID = (bag == 0) and 1 or (bag + 1)` -- which assumes a fixed bag-to-frame mapping.
-- CLASSIC ERA HAS NO SUCH MAPPING, and this is Blizzard's own code for this flavour rather than an
-- inference (Blizzard_UIPanels_Game/Classic/ContainerFrame_Shared.lua):
--
--   * `ContainerFrame_GetOpenFrame` (:476-481) returns the first frame that is NOT SHOWN, and that
--     is the frame a bag is rendered into (:138, :339).
--   * Blizzard never derives the name anywhere. `ToggleBag` (:126-138), `OpenBag` (:331-341),
--     `CloseBag` (:351-358) and `IsBagOpen` (:361-369) all SEARCH, comparing
--     `frame:IsShown() and frame:GetID() == id`.
--
-- So the arithmetic held only when bags happened to be opened in ascending order from the backpack,
-- and the failure was SILENT: the derived frame is not shown, so ApplyOverlay bails on its
-- IsVisible guard and nothing is highlighted, with no error. That signature was already on record
-- and attributed to ElvUI (the ELVUI-001 note, "the checkbox ticks and nothing happens") -- ElvUI is
-- a real cause of it, but it was not the only one.
--
-- FRAMES ARE HAND-BUILT HERE, and that is sufficient rather than a shortcut: the addon's entire
-- contract with a container frame is IsShown(), GetID(), GetName() and the `size` field that
-- ContainerFrame_GenerateFrame stamps on it (:713-714). A richer fake would test the fake.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local H

local function load()
	env.stubOutput()
	env.loadModules({
		"Modules/Constants.lua",
		"Modules/ItemHighlight.lua",
	})
	H = TOGBankClassic_ItemHighlight
	return H
end

--- Render `bag` into ContainerFrame`index` with `size` slots, exactly as the client would.
local function renderBagInto(index, bag, size)
	local name = "ContainerFrame" .. index
	local frame = {
		size = size,
		IsShown = function() return true end,
		GetID   = function() return bag end,
		GetName = function() return name end,
	}
	_G[name] = frame
	for slot = 1, size do
		_G[name .. "Item" .. slot] = { name = name .. "Item" .. slot }
	end
	return frame
end

local function emptyFrame(index)
	local name = "ContainerFrame" .. index
	_G[name] = {
		size = 0,
		IsShown = function() return false end,
		GetID   = function() return -99 end,
		GetName = function() return name end,
	}
end

describe("ItemHighlight: resolving a bag's container frame (finding 29)", function()
	before_each(function()
		env.reset()
		load()
		_G.NUM_CONTAINER_FRAMES = 5
		for i = 1, 5 do emptyFrame(i) end
	end)

	-- The finding's own failure scenario: open bag 1 with the backpack closed.
	it("finds a bag rendered into a frame the arithmetic would not predict", function()
		renderBagInto(1, 1, 4)   -- bag 1 went into ContainerFrame1, not ContainerFrame2
		local button = H:GetBagSlotButton(1, 1)
		assert.is_not_nil(button,
			"bag 1 rendered into ContainerFrame1 was not found -- the old code looked up " ..
			"ContainerFrame2, which is not shown, so ApplyOverlay bailed on its IsVisible guard " ..
			"and NOTHING was highlighted, silently")
		assert.equal("ContainerFrame1Item4", button.name)
	end)

	-- Worse than nothing: two bags whose frames are crossed relative to the arithmetic.
	it("keeps two out-of-order bags on their own frames", function()
		renderBagInto(1, 2, 6)   -- bag 2 opened first
		renderBagInto(2, 1, 4)   -- bag 1 opened second

		local b2 = H:GetBagSlotButton(2, 1)
		assert.is_not_nil(b2, "bag 2 was not found on ContainerFrame1")
		assert.equal("ContainerFrame1Item6", b2.name,
			"bag 2's button was resolved on the wrong frame, or with another bag's slot count")

		local b1 = H:GetBagSlotButton(1, 1)
		assert.is_not_nil(b1, "bag 1 was not found on ContainerFrame2")
		assert.equal("ContainerFrame2Item4", b1.name)
	end)

	-- The slot count must come from the FRAME, not the bag: the reversal below is relative to the
	-- frame that is actually rendering, and taking the two from different places is how a reversal
	-- lands on the wrong button. This is the half that subsumes finding 9.
	it("reverses using the rendering frame's own slot count", function()
		renderBagInto(3, 4, 8)
		assert.equal("ContainerFrame3Item8", H:GetBagSlotButton(4, 1).name)
		assert.equal("ContainerFrame3Item1", H:GetBagSlotButton(4, 8).name)
		assert.equal("ContainerFrame3Item5", H:GetBagSlotButton(4, 4).name)
	end)

	it("returns nothing for a bag that is not currently open", function()
		renderBagInto(1, 0, 16)
		assert.is_nil(H:GetBagSlotButton(3, 1),
			"a closed bag resolved to a frame anyway, which is how the old code addressed " ..
			"buttons belonging to a different bag of a different size")
	end)

	-- Bank bags (5-11) go through the same resolution, which is the point of having one helper:
	-- finding 9 was that this path and the bag path disagreed about the reversal, and they cannot
	-- disagree any more because there is only one of each.
	it("resolves a bank bag the same way as a carried bag", function()
		renderBagInto(4, 7, 10)
		local button = H:GetBagSlotButton(7, 2)
		assert.is_not_nil(button, "a bank bag was not resolved by the shared helper")
		assert.equal("ContainerFrame4Item9", button.name,
			"the bank path applied a different reversal from the bag path -- the divergence " ..
			"HIGHLIGHT-001 was filed for")
	end)

	it("does not mistake a shown frame holding a different bag", function()
		renderBagInto(1, 0, 16)
		renderBagInto(2, 3, 4)
		assert.equal("ContainerFrame2Item4", H:GetBagSlotButton(3, 1).name)
		assert.equal("ContainerFrame1Item16", H:GetBagSlotButton(0, 1).name)
	end)
end)

-- AUDIT FINDING 10 (HIGHLIGHT-002) -- anonymous buttons.
--
-- The finding names two defects. They are two branches of ONE predicate, and the reviewer's sharp
-- half is which of them actually fires:
--
--   * anonymous button WITH `.icon` (the near-universal convention) -- no crash, because `or`
--     short-circuits before the name concatenation. But the overlay is keyed by `tostring(button)`,
--     and the old ClearAllOverlays recovered the button with `_G[key] or key`: "table: 0x..." is not
--     a global, so it got the key string back, skipped it on a type test, and THE ITEM STAYED
--     DIMMED FOR THE SESSION. This is the common branch.
--   * anonymous button with NEITHER `.icon` nor `.Icon` -- the concatenation raises. Rarer.
--
-- The finding asserted the crash was the reachable one ("a Lua error on every highlight attempt"),
-- which is overstated, and acting on that would have added a GetName guard for the rare branch while
-- leaving the un-clearable overlays in place.
--
-- BUTTONS ARE HAND-BUILT for the same reason the frames above are: the addon's whole contract with a
-- slot button is IsVisible(), GetName() and an icon carrying SetVertexColor.
--- A NAMED button is also published into `_G` under its own name, exactly as the client does. That
--- is load-bearing for these specs rather than set dressing: the OLD ClearAllOverlays recovered a
--- button with `_G[key]`, so a named button that is not a global would fail under the old code for a
--- reason that has nothing to do with this finding -- and the named examples below would then look
--- like they prove something they do not. Registered here, the named path PASSES under the old code
--- and only the anonymous path fails, which is exactly the discrimination the finding is about.
local function slotButton(name, withIcon)
	local button = {
		IsVisible = function() return true end,
		GetName   = function() return name end,
	}
	if withIcon ~= false then
		button.icon = {
			r = 1, g = 1, b = 1,
			SetVertexColor = function(self, r, g, b) self.r, self.g, self.b = r, g, b end,
		}
	end
	if name then _G[name] = button end
	return button
end

describe("ItemHighlight: clearing overlays on anonymous buttons (finding 10)", function()
	before_each(function()
		env.reset()
		load()
		H.overlays = {}
	end)

	it("un-dims an ANONYMOUS button, which it could never do before", function()
		local button = slotButton(nil)

		H:ApplyOverlay(button)
		assert.equal(0.2, button.icon.r,
			"precondition: the button was never dimmed, so the clear below proves nothing")

		H:ClearAllOverlays()

		assert.equal(1, button.icon.r,
			"an anonymous button stayed dimmed after ClearAllOverlays -- its key is " ..
			"tostring(button), which is not a global, so the old code could never recover the " ..
			"button and the item stayed greyed out for the rest of the session")
		assert.is_nil(next(H.overlays), "the overlay registry was not emptied")
	end)

	it("still un-dims a NAMED button", function()
		local button = slotButton("ContainerFrame1Item1")

		H:ApplyOverlay(button)
		assert.equal(0.2, button.icon.r, "precondition: the named button was never dimmed")

		H:ClearAllOverlays()

		assert.equal(1, button.icon.r,
			"the named-button path regressed while fixing the anonymous one")
	end)

	it("clears a MIXTURE, so a named button cannot mask an anonymous one", function()
		local named     = slotButton("ContainerFrame1Item2")
		local anonymous = slotButton(nil)

		H:ApplyOverlay(named)
		H:ApplyOverlay(anonymous)
		H:ClearAllOverlays()

		assert.equal(1, named.icon.r, "the named button stayed dimmed")
		assert.equal(1, anonymous.icon.r, "the anonymous button stayed dimmed")
	end)

	-- The rarer branch: no `.icon`, no `.Icon`, no name -- so the old code reached
	-- `_G[nil .. "IconTexture"]` and raised.
	it("does not raise for an anonymous button carrying no icon at all", function()
		local button = slotButton(nil, false)

		assert.has_no_error(function() H:ApplyOverlay(button) end,
			"applying an overlay to an anonymous button with no icon field raised -- the name " ..
			"concatenation is reached only when both .icon and .Icon are absent")
		assert.has_no_error(function() H:ClearAllOverlays() end,
			"clearing overlays raised for an anonymous button with no icon field")
	end)

	it("does not raise when REMOVING an overlay from an anonymous button directly", function()
		local button = slotButton(nil, false)

		assert.has_no_error(function() H:RemoveOverlay(button) end,
			"RemoveOverlay repeats the same undefended concatenation as ApplyOverlay, five " ..
			"lines apart -- fixing only one leaves the other live")
	end)
end)

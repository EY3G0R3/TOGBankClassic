-- ENV-SWEEP-LIB-001 (Peer Review bf89d59d B3; self-audit 9da6eefd F5): env.reset sweeps the handler
-- registries of the once-loaded Ace libraries so an earlier example's addon is not kept alive or
-- handed later traffic -- but a LIBRARY that registers once per run (VersionCheck-1.0 on AceComm
-- itself) must survive it. Measured 2026-10-15: the whole forward suite passed with the sparing
-- switched off, so nothing else pins it.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

describe("ENV-SWEEP-LIB-001: env.reset sweeps addon handlers and spares library ones", function()
	local LIB = "TOGBankEnvResetSpecLib-1.0"
	local PREFIX = "togbank-envspec"

	-- The installed AceComm, loaded once per run the way the real addon's specs meet it.
	local function aceComm()
		env.reset()
		require("env.ace").load("AceComm-3.0")
		return assert(LibStub.libs["AceComm-3.0"], "AceComm-3.0 failed to register with LibStub")
	end

	after_each(function()
		LibStub.libs[LIB], LibStub.minors[LIB] = nil, nil
	end)

	it("keeps a LibStub library's comm handler and drops a plain addon's", function()
		local AceComm = aceComm()
		local lib = assert(LibStub:NewLibrary(LIB, 1))
		local addon = {}
		local function handler() end
		AceComm.RegisterComm(lib, PREFIX, handler)
		AceComm.RegisterComm(addon, PREFIX, handler)
		local handlers = AceComm.callbacks.events[PREFIX]
		assert.equal(handler, handlers[lib], "precondition: the library's handler registered")
		assert.equal(handler, handlers[addon], "precondition: the addon's handler registered")

		env.reset()

		handlers = AceComm.callbacks.events[PREFIX]
		assert.is_table(handlers, "the prefix was removed with a library still registered on it")
		assert.equal(handler, handlers[lib], "the library's handler was swept")
		local survivors = {}
		for owner in pairs(handlers) do survivors[#survivors + 1] = owner end
		assert.same({ lib }, survivors, "an addon's handler survived the reset")
	end)

	it("removes an event that is left with no handlers, so the next registration counts as the first", function()
		local AceComm = aceComm()
		local addon = {}
		AceComm.RegisterComm(addon, PREFIX, function() end)
		assert.is_table(AceComm.callbacks.events[PREFIX], "precondition: the addon's handler registered")

		env.reset()

		local left = {}
		for event in pairs(AceComm.callbacks.events) do
			if event == PREFIX then left[#left + 1] = event end
		end
		assert.same({}, left, "an emptied event stayed in the registry")
	end)
end)

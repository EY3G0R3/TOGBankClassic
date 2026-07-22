-- API compatibility shim.
--
-- Recent Classic Era client updates removed a batch of legacy bare global
-- functions, migrating them into C_* namespaces. Some are gone outright (no
-- fallback); others survive only through Blizzard's own deprecation shim addons
-- (Blizzard_DeprecatedItemScript, Blizzard_DeprecatedCurrencyScript, ...), which
-- are gated behind the `loadDeprecationFallbacks` CVar and are explicitly slated
-- for removal ("deprecated and will be removed in the future"). Calling a missing
-- bare global throws "attempt to call a nil value 'X'".
--
-- Rather than editing every call site (GetItemInfo alone has ~20), we re-establish
-- each removed global from its C_* namespace here, exactly as Blizzard's deprecation
-- addons do -- but UNCONDITIONALLY (independent of the CVar), so the addon keeps
-- working whether or not the fallback shim is loaded. This file is the single
-- authoritative map of "APIs Blizzard removed and where they went."
--
-- Loaded FIRST in the .toc so the globals exist before any runtime call. The
-- functions themselves are non-secure, so aliasing them raises no taint concerns.
--
-- Ticket IDs are greppable against CHANGELOG.md:
--   ROSTER-001    GuildRoster          -> C_GuildInfo.GuildRoster       (removed, no shim)
--   METADATA-001  GetAddOnMetadata     -> C_AddOns.GetAddOnMetadata     (removed, no shim)
--   OFFNOTE-001   CanViewOfficerNote   -> C_GuildInfo.CanViewOfficerNote (removed, no shim)
--   ITEMAPI-001   GetItemInfo/...      -> C_Item.*                       (shim-gated)
--   COINAPI-001   GetCoinTextureString -> C_CurrencyInfo.*              (shim-gated)

TOGBankClassic_Compat = {}

-- Fill a bare global from a C_* namespace only when the global is missing (nil).
-- If Blizzard's deprecation shim already defined it, this is a harmless no-op; if
-- the client removed it, we restore it pointing at the identical namespaced function.
local function alias(globalName, namespace, fieldName)
	if _G[globalName] == nil and namespace and namespace[fieldName] then
		_G[globalName] = namespace[fieldName]
	end
end

-- Guild (C_GuildInfo)
alias("GuildRoster",          C_GuildInfo,     "GuildRoster")          -- ROSTER-001
alias("CanViewOfficerNote",   C_GuildInfo,     "CanViewOfficerNote")   -- OFFNOTE-001

-- AddOns (C_AddOns)
alias("GetAddOnMetadata",     C_AddOns,        "GetAddOnMetadata")     -- METADATA-001

-- Items (C_Item)
alias("GetItemInfo",          C_Item,          "GetItemInfo")          -- ITEMAPI-001
alias("GetItemInfoInstant",   C_Item,          "GetItemInfoInstant")   -- ITEMAPI-001
alias("GetItemQualityColor",  C_Item,          "GetItemQualityColor")  -- ITEMAPI-001
alias("PickupItem",           C_Item,          "PickupItem")           -- ITEMAPI-001

-- Currency (C_CurrencyInfo)
alias("GetCoinTextureString", C_CurrencyInfo,  "GetCoinTextureString") -- COINAPI-001

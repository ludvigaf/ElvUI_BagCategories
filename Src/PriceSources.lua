-- Reads a total bag/bank value from a third-party pricing addon, if one of
-- the supported ones is installed and the selected source is available.
-- Every source here is READ-ONLY against that addon's own public data -- we
-- never touch, require, or write to any of them.
--
-- Verification note: Auctionator's real API (Auctionator.API.v1.*) and TSM's
-- TSM_API.GetCustomPriceValue convention were both confirmed against actual
-- source/documentation. Auctionator has no concept called "AtrValue" -- its
-- own last-scanned-price API is used for that entry instead, since "Atr" is
-- Auctionator's own long-standing slash-command shorthand (/atr). The AHDB
-- and Auc-Advanced ("AucMarket") integrations below are best-effort, written
-- from long-standing community convention for those older addons, and could
-- NOT be verified against real source since neither is installed in this
-- environment -- if either errors or shows an obviously wrong value, that's
-- why; report it and the exact field/API names can be corrected.
local E = unpack(ElvUI)
local BF = E:GetModule('BagCategories')

local _G = _G
local ipairs = ipairs
local GetItemInfo = C_Item.GetItemInfo

local function IsAtrValueAvailable()
	return _G.Auctionator and _G.Auctionator.API and _G.Auctionator.API.v1
		and _G.Auctionator.API.v1.GetAuctionPriceByItemLink and true or false
end

local function GetAtrValue(itemLink)
	return _G.Auctionator.API.v1.GetAuctionPriceByItemLink('ElvUIBagCategories', itemLink)
end

-- AHDB ("Auction House DataBase") historically saves its scan results keyed
-- by item name. Best-effort -- see file header.
local function IsAHDBAvailable()
	return _G.AHDB ~= nil
end

local function GetAHDBEntry(itemLink)
	local name = GetItemInfo(itemLink)
	return name and _G.AHDB and _G.AHDB[name]
end

-- Auc-Advanced ("Auctioneer"). Best-effort -- see file header.
local function IsAucAdvancedAvailable()
	return _G.AucAdvanced and _G.AucAdvanced.API and _G.AucAdvanced.API.GetPrice and true or false
end

local function IsTSMAvailable()
	return _G.TSM_API and _G.TSM_API.GetCustomPriceValue and _G.TSM_API.ToItemString and true or false
end

-- Ordered so the default selection (AtrValue) is first in the dropdown too.
BF.PriceSources = {
	{
		key = 'atrvalue',
		label = 'AtrValue (Auctionator)',
		isAvailable = IsAtrValueAvailable,
		getPrice = GetAtrValue,
	},
	{
		key = 'ahdbminbid',
		label = 'AHDB Min Bid',
		isAvailable = IsAHDBAvailable,
		getPrice = function(itemLink)
			local entry = GetAHDBEntry(itemLink)
			return entry and entry.MinBid
		end,
	},
	{
		key = 'ahdbminbuyout',
		label = 'AHDB Min Buyout',
		isAvailable = IsAHDBAvailable,
		getPrice = function(itemLink)
			local entry = GetAHDBEntry(itemLink)
			return entry and entry.MinBuyout
		end,
	},
	{
		key = 'aucmarket',
		label = 'AucMarket (Auctioneer)',
		isAvailable = IsAucAdvancedAvailable,
		getPrice = function(itemLink)
			return _G.AucAdvanced.API.GetPrice(nil, itemLink)
		end,
	},
	{
		key = 'tsmdbmarket',
		label = 'TSM Market Value',
		isAvailable = IsTSMAvailable,
		getPrice = function(itemLink)
			local itemString = _G.TSM_API.ToItemString(itemLink)
			return itemString and _G.TSM_API.GetCustomPriceValue('dbmarket', itemString)
		end,
	},
}

function BF:GetPriceSource(key)
	for _, source in ipairs(BF.PriceSources) do
		if source.key == key then return source end
	end
	return nil
end

function BF:GetSelectedPriceSource()
	return BF:GetPriceSource(BF.db.priceSource)
end

-- Every call below reaches into another addon's own code, which is a black
-- box to us -- a partially-loaded or unusual third-party addon erroring
-- inside its own API isn't something that should be able to break our layout.
function BF:IsPriceSourceAvailable(source)
	if not source then return false end
	local ok, available = pcall(source.isAvailable)
	return ok and available or false
end

function BF:GetItemPrice(source, itemLink)
	if not source or not itemLink then return nil end
	local ok, price = pcall(source.getPrice, itemLink)
	if ok and type(price) == 'number' and price > 0 then
		return price
	end
	return nil
end

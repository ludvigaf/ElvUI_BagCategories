-- Display strings for every category. Prefers Blizzard's own localized
-- globals where a matching one exists, falling back to a plain English label
-- otherwise -- safe either way, since indexing a missing global just yields
-- nil rather than erroring.
local E, L = unpack(ElvUI)
local BF = E:GetModule('BagCategories')

local _G = _G

BF.Labels = {
	Toys = _G.TOYS or 'Toys',
	Quest = _G.AUCTION_CATEGORY_QUEST_ITEMS or _G.BAG_FILTER_QUEST_ITEMS or 'Quest Items',
	Currency = 'Currency',
	BoE = L["BoE"] or 'Bind on Equip',
	TradeGoods = _G.BAG_FILTER_TRADE_GOODS or 'Trade Goods',
	Reagents = 'Reagents',
	Recipes = 'Recipes',
	Ammo = (_G.AMMOSLOT and (_G.AMMOSLOT..' & Quivers')) or 'Ammo & Quivers',
	Keys = 'Keys',
	Gems = _G.BAG_FILTER_GEM or 'Gems',
	Bags = _G.BAGSLOT or 'Bags',
	Soulbound = _G.ITEM_SOULBOUND or 'Soulbound',
	Equipment = 'Equipment',
	Mounts = _G.MOUNTS or 'Mounts',
	Flying = 'Flying',
	Ground = 'Ground',
	Pets = 'Companion Pets',
	Consumable = 'Potions & Consumables',
	Food = 'Food & Water',
	Trash = _G.BAG_FILTER_JUNK or 'Trash',
	Other = _G.MISCELLANEOUS or 'Miscellaneous',
}

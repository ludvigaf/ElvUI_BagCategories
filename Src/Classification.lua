-- Decides which category path a single bag slot belongs to. BF:ClassifySlot
-- is the public entry point (used by Layout.lua's BF:GatherSlots); everything
-- else here is a private implementation detail of that decision.
local E = unpack(ElvUI)
local BF = E:GetModule('BagCategories')

local GetItemInfo = C_Item.GetItemInfo

local BIND_ON_EQUIP = (Enum.ItemBind and Enum.ItemBind.OnEquip) or 2
local KEYRING_CONTAINER = Enum.BagIndex and Enum.BagIndex.Keyring

local ITEM_CLASS_CONSUMABLE = 0
local ITEM_CLASS_CONTAINER = 1
local ITEM_CLASS_GEM = 3
local ITEM_CLASS_REAGENT = 5
local ITEM_CLASS_PROJECTILE = 6
local ITEM_CLASS_TRADEGOODS = 7
local ITEM_CLASS_RECIPE = 9
local ITEM_CLASS_QUIVER = 11
local ITEM_CLASS_QUEST = 12
local ITEM_CLASS_KEY = 13
local ITEM_CLASS_MISCELLANEOUS = 15
local ITEM_SUBCLASS_MOUNT = 5
local ITEM_SUBCLASS_COMPANION_PET = 2
local ITEM_SUBCLASS_FOOD_DRINK = 5

-- Best-effort mount-type IDs known (from years of community/addon documentation)
-- to be flying mounts. This can't be verified against this specific client without
-- in-game testing, so an unrecognized/unmatched mount always defaults to Ground
-- rather than risk mislabeling -- report any mislabeled mount so this list can be corrected.
local FLYING_MOUNT_TYPES = {
	[232] = true, [248] = true, [254] = true, [269] = true, [407] = true,
}

local function GetMountFlightPath(slot)
	if E.MountIDs and slot.spellID then
		local mountID = E.MountIDs[slot.spellID]
		if mountID and C_MountJournal and C_MountJournal.GetMountInfoExtraByID then
			local _, _, _, _, mountTypeID = C_MountJournal.GetMountInfoExtraByID(mountID)
			if FLYING_MOUNT_TYPES[mountTypeID] then
				return 'soulbound.mounts.flying'
			end
		end
	end

	return 'soulbound.mounts.ground'
end

-- C_ToyBox.GetToyInfo(itemID) returns data only if the item is a registered toy,
-- regardless of whether the player has collected it -- exactly the "is this a
-- toy" signal we want. Best-effort like the mount-type table above: I can't
-- verify from here whether every classic-era toy is registered in this
-- client's Toy Box data, so an item just falls through to its normal
-- category (e.g. Potions & Consumables) if it isn't recognized here.
local function IsToyItem(itemID)
	return itemID and C_ToyBox and C_ToyBox.GetToyInfo and (C_ToyBox.GetToyInfo(itemID) and true or false)
end

local function RawClassifyPath(slot, bagID)
	if IsToyItem(slot.itemID) then
		return 'toys'
	end

	-- A deliberate, player-curated classification (this exact item was
	-- assigned to a named ItemRack gear set), so it's checked early enough to
	-- win over the generic Soulbound/BoE/Trade Goods bucketing that would
	-- otherwise apply to the same piece of equipment. Filed under Soulbound ->
	-- Equipment -> <set name> regardless of the item's actual bind state --
	-- gear built into a set is realistically almost always soulbound anyway.
	if BF.ItemRackLookup and slot.itemID then
		local setName = BF.ItemRackLookup[slot.itemID]
		if setName then
			return 'soulbound.equipment.'..BF:Slugify(setName)
		end
	end

	if slot.isQuestItem or slot.QuestID then
		return 'quest'
	end

	if slot.isJunk then
		return 'trash'
	end

	if slot.itemLink then
		-- Single GetItemInfo call reused below for bind type and, for Trade
		-- Goods/Recipes, the real subtype text (e.g. "Cloth", "Blacksmithing").
		local _, _, _, _, _, _, itemSubType, _, _, _, _, _, _, bindType = GetItemInfo(slot.itemLink)

		if not slot.isBound then
			if bindType == BIND_ON_EQUIP then
				return 'boe'
			end
		else
			if slot.isEquipment or slot.itemEquipLoc == 'INVTYPE_RELIC' then
				return 'soulbound.equipment'
			end

			if slot.itemClassID == ITEM_CLASS_MISCELLANEOUS and slot.itemSubClassID == ITEM_SUBCLASS_MOUNT then
				return GetMountFlightPath(slot)
			end
		end

		local path
		if slot.itemClassID == ITEM_CLASS_TRADEGOODS then
			local subKey = itemSubType and BF.TradegoodsSubtypeKey[itemSubType]
			path = subKey and ('tradegoods.'..subKey) or 'tradegoods.other'
		elseif slot.itemClassID == ITEM_CLASS_REAGENT then
			path = 'reagents'
		elseif slot.itemClassID == ITEM_CLASS_RECIPE then
			local subKey = itemSubType and BF.RecipeSubtypeKey[itemSubType]
			path = subKey and ('recipes.'..subKey) or 'recipes.other'
		elseif slot.itemClassID == ITEM_CLASS_PROJECTILE or slot.itemClassID == ITEM_CLASS_QUIVER then
			-- Quiver (11) is the ammo pouch/quiver container itself, distinct from
			-- Projectile (6) which is the arrows/bullets that go inside it -- both
			-- read as "ammo stuff" to a player, so they share one category.
			path = 'ammo'
		elseif slot.itemClassID == ITEM_CLASS_GEM then
			path = 'gems'
		elseif slot.itemClassID == ITEM_CLASS_CONTAINER then
			-- A spare/unequipped bag sitting in your inventory (regular or a
			-- profession-specific one like a Soul Bag or Herb Bag).
			path = 'bags'
		elseif slot.itemClassID == ITEM_CLASS_KEY then
			-- Only bag keys get their own section; keys living on the Keyring stay out of it.
			if bagID ~= KEYRING_CONTAINER then
				path = 'keys'
			end
		elseif slot.itemClassID == ITEM_CLASS_MISCELLANEOUS and slot.itemSubClassID == ITEM_SUBCLASS_COMPANION_PET then
			-- Checked regardless of bind state, unlike mounts/equipment, since caged
			-- companion pets are commonly unbound until used.
			path = 'pets'
		elseif slot.itemClassID == ITEM_CLASS_QUEST then
			-- Reached only when NOT tied to an active quest (that's caught above) --
			-- this is the static Quest item class, which is also where reputation/
			-- faction tokens like Mark of Thrallmar or Obsidian Warbeads live.
			path = 'currency'
		elseif slot.itemClassID == ITEM_CLASS_CONSUMABLE then
			if slot.itemSubClassID == ITEM_SUBCLASS_FOOD_DRINK then
				path = 'food'
			else
				path = 'consumable'
			end
		end

		-- A bound item that didn't land anywhere specific -- or only in a generic
		-- "Miscellaneous" sub-bucket of Trade Goods/Recipes -- is grouped under
		-- Soulbound instead. Not being tradable is the more useful fact about it
		-- than its raw item class in that case.
		if slot.isBound and (not path or path == 'tradegoods.other' or path == 'recipes.other') then
			return 'soulbound.other'
		end

		if path then
			return path
		end
	end

	return 'other'
end

function BF:IsCategoryEnabled(path)
	local value = BF.db.categories[path]
	if value == nil then return true end
	return value
end

-- Walks from the matched (sub)category up toward the root, returning the
-- first ancestor (inclusive) that's still enabled. Falls back to 'other'
-- if the whole chain, including the top-level category, is disabled.
function BF:ResolveEnabledPath(rawPath)
	local segments = BF:SplitPath(rawPath)
	for i = #segments, 1, -1 do
		local candidate = table.concat(segments, '.', 1, i)
		if BF:IsCategoryEnabled(candidate) then
			return candidate
		end
	end

	return 'other'
end

function BF:ClassifySlot(slot, bagID)
	local rawPath = RawClassifyPath(slot, bagID)
	if rawPath == 'other' then return 'other' end
	return BF:ResolveEnabledPath(rawPath)
end

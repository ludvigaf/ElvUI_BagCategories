-- ItemRack integration: reads that addon's per-character saved equipment sets
-- (if ItemRack is installed and enabled) and attaches each one as a
-- Soulbound -> Equipment subcategory. Entirely optional and read-only -- we
-- never touch ItemRack's own data.
local E = unpack(ElvUI)
local BF = E:GetModule('BagCategories')

local _G = _G
local ipairs, pairs = ipairs, pairs

local function CountSetItems(set)
	local count = 0
	if set and set.equip then
		for _ in pairs(set.equip) do
			count = count + 1
		end
	end
	return count
end

local function GetItemRackSetNames()
	if not (_G.ItemRackUser and _G.ItemRackUser.Sets) then return nil end

	local names
	for name in pairs(_G.ItemRackUser.Sets) do
		-- ItemRack prefixes its own internal/hidden sets with '~' (e.g. "~Unequip").
		if name:sub(1, 1) ~= '~' then
			names = names or {}
			names[#names + 1] = name
		end
	end

	-- Default order: fullest sets first (most likely to be your "main" sets),
	-- alphabetical among ties. This is only ever the *fallback* order though --
	-- GetOrderedChildren prefers a saved BF.db.order[path] once you've dragged
	-- these into a custom order from the options panel, same as every other
	-- reorderable category.
	if names then
		local Sets = _G.ItemRackUser.Sets
		table.sort(names, function(a, b)
			local countA, countB = CountSetItems(Sets[a]), CountSetItems(Sets[b])
			if countA ~= countB then return countA > countB end
			return a < b
		end)
	end
	return names
end

-- Builds { [baseItemID] = setName } from every equipped slot in every set, so
-- classification is an O(1) lookup per item instead of re-scanning ItemRack's
-- data for every bag slot. ItemRack.GetIRString(value, true, false) extracts
-- the base item ID (ignoring enchant/gem/suffix variations) from whatever
-- format ItemRack stored that slot's item in.
local function BuildItemRackLookup(setNames)
	local lookup = {}
	local GetIRString = _G.ItemRack and _G.ItemRack.GetIRString

	for _, name in ipairs(setNames) do
		local set = _G.ItemRackUser.Sets[name]
		if set and set.equip then
			for _, equipValue in pairs(set.equip) do
				local baseID = GetIRString and tonumber(GetIRString(equipValue, true, false))
				if baseID and baseID > 0 and not lookup[baseID] then
					lookup[baseID] = name
				end
			end
		end
	end

	return lookup
end

-- Rebuilds the ItemRack lookup table and attaches one Equipment subcategory
-- per current ItemRack set directly onto BF.EquipmentNode (part of the static
-- BF.CategoryTree) -- called at the top of every BF:Layout pass and before
-- rebuilding options, since sets can be added, renamed, or edited in ItemRack
-- at any time. Re-running BF:DecorateTree afterward keeps every .path field
-- (including the newly (re)attached set children) correct and is cheap/
-- idempotent for the rest of the tree.
function BF:RefreshItemRackData()
	BF.ItemRackLookup = nil
	BF.EquipmentNode.children = BF.EquipmentSlotTypeChildren

	if BF.db.itemRackSetsEnabled then
		local setNames = GetItemRackSetNames()
		if setNames then
			BF.ItemRackLookup = BuildItemRackLookup(setNames)

			-- Set-name subcategories are appended after the fixed Armor/Weapons/
			-- Accessories split (BF.EquipmentSlotTypeChildren), which must survive
			-- every refresh since sets can come and go at any time.
			local children = { unpack(BF.EquipmentSlotTypeChildren) }
			for _, name in ipairs(setNames) do
				children[#children + 1] = { key = BF:Slugify(name), label = name }
			end
			BF.EquipmentNode.children = children
		end
	end

	BF:DecorateTree(BF.CategoryTree)
end

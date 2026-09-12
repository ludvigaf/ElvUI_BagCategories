-- ItemRack integration: reads that addon's per-character saved equipment sets
-- (if ItemRack is installed and enabled) and attaches each one as a
-- Soulbound -> Equipment subcategory. Entirely optional and read-only -- we
-- never touch ItemRack's own data.
local E = unpack(ElvUI)
local BF = E:GetModule('BagCategories')

local _G = _G
local ipairs, pairs = ipairs, pairs

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

	if names then table.sort(names) end
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
	BF.EquipmentNode.children = nil

	if BF.db.itemRackSetsEnabled then
		local setNames = GetItemRackSetNames()
		if setNames then
			BF.ItemRackLookup = BuildItemRackLookup(setNames)

			local children = {}
			for _, name in ipairs(setNames) do
				children[#children + 1] = { key = BF:Slugify(name), label = name }
			end
			BF.EquipmentNode.children = children
		end
	end

	BF:DecorateTree(BF.CategoryTree)
end

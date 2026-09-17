-- The category tree: its data (BF.CategoryTree) and the utility functions
-- for walking, decorating, and reordering it. Every node's dot-joined path
-- (e.g. 'soulbound.mounts.flying') is both its options-panel toggle key and
-- its bucket key during layout. 'other' (BF.OtherNode) is intentionally not
-- part of this tree: it's the always-on catch-all that unmatched items, and
-- items whose category has been unchecked, fall back into.
local E = unpack(ElvUI)
local BF = E:GetModule('BagCategories')

local ipairs = ipairs
local Labels = BF.Labels

function BF:Slugify(text)
	return text:lower():gsub('[^%w]', '')
end

-- Trade Goods and Recipes are split by their real item subtype text (the same
-- string shown in tooltips/AH, read live via GetItemInfo) rather than a hardcoded
-- numeric ID table -- this is the same data Blizzard itself uses, so it can't drift.
-- Trade Goods splits by material type (materials are shared across professions,
-- e.g. Ore is used by Mining/Blacksmithing/Engineering/Jewelcrafting alike), while
-- Recipes splits cleanly by profession since each recipe subtype IS a profession name.
-- Anything reported that isn't in these lists still gets grouped, under a
-- Miscellaneous child of that parent, instead of being lost.
-- The full TBC Trade Goods subtype list is Cloth, Leather, Metal & Stone, Herb,
-- Meat, Elemental, Enchanting, Jewelcrafting, Parts, Devices, Explosives,
-- Materials, and Other (confirmed against Wowhead's TBC item-browser category
-- tree) -- everything but Other is matched here, since Other alone has no
-- subtype text to key display off of.
local TRADEGOODS_MATERIALS = { 'Cloth', 'Leather', 'Metal & Stone', 'Herb', 'Meat', 'Elemental', 'Enchanting', 'Jewelcrafting', 'Parts', 'Devices', 'Explosives', 'Materials' }
local RECIPE_PROFESSIONS = { 'Alchemy', 'Blacksmithing', 'Cooking', 'Enchanting', 'Engineering', 'First Aid', 'Leatherworking', 'Tailoring', 'Fishing', 'Jewelcrafting', 'Poisons' }

-- Display-only overrides for subtype names above that read confusingly as
-- category labels -- the match name itself must stay the exact string
-- GetItemInfo reports (and the node's key, derived from it, must stay stable
-- for existing SavedVariables), so only the label shown to the user changes.
local TRADEGOODS_MATERIAL_LABELS = { Meat = 'Cooking' }

-- Builds {key,label} child nodes for each name plus a trailing 'other' catch-all,
-- and returns a name -> key lookup used to classify items at runtime.
local function BuildSubtypeChildren(names, labelOverrides)
	local children = {}
	local nameToKey = {}

	for _, name in ipairs(names) do
		local key = BF:Slugify(name)
		local label = (labelOverrides and labelOverrides[name]) or name
		children[#children + 1] = { key = key, label = label }
		nameToKey[name] = key
	end

	children[#children + 1] = { key = 'other', label = Labels.Other }

	return children, nameToKey
end

local TRADEGOODS_CHILDREN, TRADEGOODS_SUBTYPE_KEY = BuildSubtypeChildren(TRADEGOODS_MATERIALS, TRADEGOODS_MATERIAL_LABELS)
local RECIPE_CHILDREN, RECIPE_SUBTYPE_KEY = BuildSubtypeChildren(RECIPE_PROFESSIONS)

-- Same idea as BuildSubtypeChildren above, but keyed by a numeric ID (gem
-- subclass, consumable subclass, item quality) that ElvUI already reads onto
-- the slot object (slot.itemSubClassID/slot.rarity) rather than by subtype
-- text -- used where the split is driven by a numeric field instead of a
-- GetItemInfo subtype string.
local function BuildIdChildren(entries)
	local children = {}
	local idToKey = {}

	for _, entry in ipairs(entries) do
		local key = BF:Slugify(entry.name)
		children[#children + 1] = { key = key, label = entry.name }
		idToKey[entry.id] = key
	end

	children[#children + 1] = { key = 'other', label = Labels.Other }

	return children, idToKey
end

-- Gem subclass IDs confirmed against Wowhead's TBC per-color gem listings
-- (each color page's items all reported the matching subclass consistently).
local GEM_COLORS = {
	{ id = 0, name = 'Red' }, { id = 1, name = 'Blue' }, { id = 2, name = 'Yellow' },
	{ id = 3, name = 'Purple' }, { id = 4, name = 'Green' }, { id = 5, name = 'Orange' },
	{ id = 6, name = 'Meta' }, { id = 7, name = 'Simple' }, { id = 8, name = 'Prismatic' },
}
local GEM_CHILDREN, GEM_SUBCLASS_KEY = BuildIdChildren(GEM_COLORS)
BF.GemSubclassKey = GEM_SUBCLASS_KEY

-- Consumable subclass IDs 1/2/3 (Potion/Elixir/Flask) cross-checked directly
-- against real TBC item data. Food & Drink (5) stays its own separate
-- top-level category as before, not part of this split. Scroll (4) confirmed
-- live in-game via a Scroll of Agility V GetItemInfo print (2026-09-17).
-- Item Enhancement (6, weapon oils/stones and fishing lures -- anything
-- applied to grant a temporary buff) is still best-effort like
-- FLYING_MOUNT_TYPES in Classification.lua: two spot-checked items (Brilliant
-- Wizard Oil, Shiny Bauble) both reported it consistently, but the exact ID
-- has a documented Classic-era discrepancy from retail that isn't fully
-- verifiable without in-game testing -- report any oil/stone/lure that lands
-- in Miscellaneous instead so this can be corrected. Bandage is left out
-- entirely for the same reason, pending a similar spot-check.
local CONSUMABLE_TYPES = {
	{ id = 1, name = 'Potions' }, { id = 2, name = 'Elixirs' }, { id = 3, name = 'Flasks' },
	{ id = 4, name = 'Scrolls' }, { id = 6, name = 'Item Enhancements' },
}
local CONSUMABLE_CHILDREN, CONSUMABLE_SUBCLASS_KEY = BuildIdChildren(CONSUMABLE_TYPES)
BF.ConsumableSubclassKey = CONSUMABLE_SUBCLASS_KEY

-- BoE split by rarity tier -- off by default (see BF.DefaultDisabledPaths).
local BOE_QUALITIES = {
	{ id = 2, name = 'Uncommon' }, { id = 3, name = 'Rare' }, { id = 4, name = 'Epic' },
}
local BOE_CHILDREN, BOE_QUALITY_KEY = BuildIdChildren(BOE_QUALITIES)
BF.BoEQualityKey = BOE_QUALITY_KEY

-- Soulbound Equipment split by broad slot kind -- off by default (see
-- BF.DefaultDisabledPaths). Kept separate from BF.EquipmentNode.children
-- itself since ItemRackIntegration.lua rebuilds that list from scratch every
-- layout pass (equipment sets can change at any time) and must preserve
-- these three alongside whatever set names it finds.
BF.EquipmentSlotTypeChildren = {
	{ key = 'armor', label = 'Armor' },
	{ key = 'weapons', label = 'Weapons' },
	{ key = 'accessories', label = 'Accessories' },
}

-- Some Trade Goods items report a useless real subtype ("Other") but are
-- still clearly earmarked for one profession by what they're a reagent for
-- (per Wowhead's "Reagent for" data, since the game itself exposes no such
-- link) -- keyed by itemID, not name, both for stability and because these
-- are curated one at a time rather than read from a live list like the
-- subtypes above. Checked in Classification.lua ahead of the normal subtype
-- lookup. Add more items here as they come up.
BF.TradegoodsItemOverride = {
	[1475] = 'firstaid', -- Small Venom Sac -- reagent for Anti-Venom (First Aid)
	[1288] = 'firstaid', -- Large Venom Sac -- reagent for Strong Anti-Venom (First Aid)
	[19441] = 'firstaid', -- Huge Venom Sac -- reagent for Powerful Anti-Venom (First Aid)
}
table.insert(TRADEGOODS_CHILDREN, #TRADEGOODS_CHILDREN, { key = 'firstaid', label = 'First Aid' })
BF.TradegoodsSubtypeKey = TRADEGOODS_SUBTYPE_KEY
BF.RecipeSubtypeKey = RECIPE_SUBTYPE_KEY

-- PvP Marks of Honor report Blizzard's generic Consumable/Consumable
-- (itemClassID 0 / itemSubClassID 0) on this client, a bucket shared with too
-- many unrelated items to key off by subclass, so these are pinned by itemID
-- instead -- checked in Classification.lua ahead of the normal classID
-- lookup. Add the other battleground marks here once their itemIDs are
-- confirmed in-game (see CLAUDE.md session notes for how Alterac Valley's was found).
BF.CurrencyItemOverride = {
	[20560] = true, -- Alterac Valley Mark of Honor
}

-- Captured so ItemRack integration can attach dynamic set children to it
-- later (see ItemRackIntegration.lua) without having to search the tree for it.
BF.EquipmentNode = { key = 'equipment', label = Labels.Equipment, children = BF.EquipmentSlotTypeChildren }

-- Default order: time-sensitive/important stuff first (Quest, Currency, BoE,
-- Soulbound gear), then things used constantly while playing (Consumables,
-- Food), then profession-related bulk items (Reagents, Trade Goods, Recipes),
-- then the smaller niche categories (Ammo, Keys, Pets, Toys), with Trash last
-- since it's the "about to vendor" pile and least worth looking at. This is
-- just the starting point -- every level can be freely reordered from the
-- options panel (see GetOrderedChildren/BF.db.order below).
BF.CategoryTree = {
	{ key = 'quest', label = Labels.Quest },
	-- Static Quest-class items (itemClassID 12) that aren't tied to any quest
	-- currently in your log -- reputation/faction tokens like Mark of Thrallmar,
	-- Halaa Research Token, or Obsidian Warbeads. They function like a stackable
	-- currency (gather, turn in repeatedly for reputation) even though the game
	-- files still classify them under the Quest item class.
	{ key = 'currency', label = Labels.Currency },
	{ key = 'boe', label = Labels.BoE, children = BOE_CHILDREN },
	{
		key = 'soulbound', label = Labels.Soulbound,
		children = {
			BF.EquipmentNode,
			{
				key = 'mounts', label = Labels.Mounts,
				children = {
					{ key = 'flying', label = Labels.Flying },
					{ key = 'ground', label = Labels.Ground },
				},
			},
			-- Catches bound items that don't fit anywhere more specific -- being
			-- unable to trade it is the more useful fact about such an item than
			-- its raw item class, so it lands here instead of in Miscellaneous
			-- (or a generic Trade Goods/Recipes "Miscellaneous" sub-bucket).
			{ key = 'other', label = Labels.Other },
		},
	},
	{ key = 'consumable', label = Labels.Consumable, children = CONSUMABLE_CHILDREN },
	{ key = 'food', label = Labels.Food },
	{ key = 'reagents', label = Labels.Reagents },
	{ key = 'gems', label = Labels.Gems, children = GEM_CHILDREN },
	{ key = 'tradegoods', label = Labels.TradeGoods, children = TRADEGOODS_CHILDREN },
	{ key = 'recipes', label = Labels.Recipes, children = RECIPE_CHILDREN },
	{ key = 'ammo', label = Labels.Ammo },
	{ key = 'bags', label = Labels.Bags },
	{ key = 'keys', label = Labels.Keys },
	{ key = 'pets', label = Labels.Pets },
	-- Checked ahead of everything else during classification (see Classification.lua),
	-- but displayed here by default since it's a fun/novelty category, not an
	-- urgent one -- classification priority and display order are independent.
	{ key = 'toys', label = Labels.Toys },
	{ key = 'trash', label = Labels.Trash },
}

BF.OtherNode = { key = 'other', path = 'other', label = Labels.Other }

-- Categories that start unchecked instead of the usual enabled-by-default;
-- everything else defaults to on.
BF.DefaultDisabledPaths = {
	['soulbound.mounts'] = true,
	['soulbound.mounts.flying'] = true,
	['soulbound.mounts.ground'] = true,
	['boe.uncommon'] = true,
	['boe.rare'] = true,
	['boe.epic'] = true,
	['boe.other'] = true,
	['soulbound.equipment.armor'] = true,
	['soulbound.equipment.weapons'] = true,
	['soulbound.equipment.accessories'] = true,
}

function BF:DecorateTree(nodes, parentPath)
	for _, node in ipairs(nodes) do
		node.path = parentPath and (parentPath..'.'..node.key) or node.key
		if node.children then
			BF:DecorateTree(node.children, node.path)
		end
	end
end
BF:DecorateTree(BF.CategoryTree)

function BF:CollectPaths(nodes, out)
	for _, node in ipairs(nodes) do
		out[#out + 1] = node.path
		if node.children then
			BF:CollectPaths(node.children, out)
		end
	end
	return out
end

function BF:SplitPath(path)
	local segments = {}
	for seg in path:gmatch('[^.]+') do
		segments[#segments + 1] = seg
	end
	return segments
end

-- Root-level siblings are keyed under this in BF.db.order, since they have no
-- shared parent path of their own.
BF.RootOrderKey = 'root'

-- Returns `nodes` rearranged per the user's saved order for this sibling group
-- (groupKey = the parent's path, or BF.RootOrderKey for the top-level list),
-- falling back to the tree's default order for any node not yet mentioned in
-- the saved order -- which also keeps this safe if a future update adds a new
-- category, since it simply appends at the end instead of vanishing.
function BF:GetOrderedChildren(nodes, groupKey)
	local customOrder = BF.db.order[groupKey]
	if not customOrder then return nodes end

	local byKey = {}
	for _, node in ipairs(nodes) do
		byKey[node.key] = node
	end

	local ordered, seen = {}, {}
	for _, key in ipairs(customOrder) do
		local node = byKey[key]
		if node and not seen[key] then
			ordered[#ordered + 1] = node
			seen[key] = true
		end
	end

	for _, node in ipairs(nodes) do
		if not seen[node.key] then
			ordered[#ordered + 1] = node
			seen[node.key] = true
		end
	end

	return ordered
end

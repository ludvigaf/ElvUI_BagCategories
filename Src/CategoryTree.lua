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
local TRADEGOODS_MATERIALS = { 'Cloth', 'Leather', 'Metal & Stone', 'Herb', 'Meat', 'Elemental', 'Enchanting', 'Jewelcrafting' }
local RECIPE_PROFESSIONS = { 'Alchemy', 'Blacksmithing', 'Cooking', 'Enchanting', 'Engineering', 'First Aid', 'Leatherworking', 'Tailoring', 'Fishing', 'Jewelcrafting', 'Poisons' }

-- Builds {key,label} child nodes for each name plus a trailing 'other' catch-all,
-- and returns a name -> key lookup used to classify items at runtime.
local function BuildSubtypeChildren(names)
	local children = {}
	local nameToKey = {}

	for _, name in ipairs(names) do
		local key = BF:Slugify(name)
		children[#children + 1] = { key = key, label = name }
		nameToKey[name] = key
	end

	children[#children + 1] = { key = 'other', label = Labels.Other }

	return children, nameToKey
end

local TRADEGOODS_CHILDREN, TRADEGOODS_SUBTYPE_KEY = BuildSubtypeChildren(TRADEGOODS_MATERIALS)
local RECIPE_CHILDREN, RECIPE_SUBTYPE_KEY = BuildSubtypeChildren(RECIPE_PROFESSIONS)
BF.TradegoodsSubtypeKey = TRADEGOODS_SUBTYPE_KEY
BF.RecipeSubtypeKey = RECIPE_SUBTYPE_KEY

-- Captured so ItemRack integration can attach dynamic set children to it
-- later (see ItemRackIntegration.lua) without having to search the tree for it.
BF.EquipmentNode = { key = 'equipment', label = Labels.Equipment }

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
	{ key = 'boe', label = Labels.BoE },
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
	{ key = 'consumable', label = Labels.Consumable },
	{ key = 'food', label = Labels.Food },
	{ key = 'reagents', label = Labels.Reagents },
	{ key = 'gems', label = Labels.Gems },
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

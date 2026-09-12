-- Builds the ElvUI options panel for this addon: the per-category enable
-- toggles, the drag-and-drop reorder list for each sibling group, and the
-- top-level "Options" panel (Enable / Show Bag Space Count / ItemRack).
-- BF:BuildOptions is the entry point, called from Init.lua and re-run
-- whenever something changes the tree's shape (a toggle, a reorder, or new
-- ItemRack data).
local E = unpack(ElvUI)
local BF = E:GetModule('BagCategories')

local _G = _G
local ipairs = ipairs

-- AceConfig has no padding/margin property for groups, so a blank full-width
-- description row is the standard way to add breathing room between widgets.
local function Spacer(order)
	return { type = 'description', name = '', order = order, width = 'full' }
end

-- Rebuilds the options table and, since AceConfigDialog caches the structure
-- it last drew, tells it the table changed so any open window (embedded in
-- ElvUI's config, or our standalone one) redraws with the new order.
function BF:RefreshOptions()
	BF:BuildOptions()

	local ACR = E.Libs and E.Libs.AceConfigRegistry
	if ACR then
		ACR:NotifyChange('ElvUI')
		ACR:NotifyChange(BF.StandaloneApp)
	end
end

-- Moves `fromKey` to the position `toKey` currently occupies within the
-- sibling group, shifting the rest to make room -- the usual "drop onto this
-- item" reorder semantics.
function BF:ReorderCategory(groupKey, orderedSiblings, fromKey, toKey)
	if not fromKey or not toKey or fromKey == toKey then return end

	local keys = {}
	for _, node in ipairs(orderedSiblings) do
		keys[#keys + 1] = node.key
	end

	local fromIndex, toIndex
	for idx, key in ipairs(keys) do
		if key == fromKey then fromIndex = idx end
		if key == toKey then toIndex = idx end
	end
	if not fromIndex or not toIndex then return end

	table.remove(keys, fromIndex)
	table.insert(keys, toIndex, fromKey)

	BF.db.order[groupKey] = keys

	BF:RefreshOptions()
	-- Sort order is shared between bag and bank, so both need to reflect it.
	BF:ScheduleLayout(false)
	BF:ScheduleLayout(true)
end

-- Builds ElvUI's own drag-and-drop reorder widget -- the same one used under
-- UnitFrames -> Auras -> Filters: Legacy -> Filter Priority. It's a plain
-- AceConfig 'multiselect' arg with dragdrop=true; AceConfigDialog then renders
-- one draggable "Button-ElvUI" per entry and drives the drag*/get callbacks
-- below (see AceConfigDialog-3.0.lua's multiselect+dragdrop handling and
-- AceGUIWidget-Button-ElvUI.lua for exactly how those fire).
--
-- IMPORTANT: `values` must use plain sequential integer keys (1..N) with
-- `sortByValue` left unset -- AceConfigDialog sorts those ascending by key,
-- which is what preserves our custom order. Setting sortByValue=true would
-- instead sort alphabetically by the displayed label text, undoing it.
function BF:BuildDragDropOrderArg(ordered, groupKey, order)
	local values = {}
	for i, node in ipairs(ordered) do
		values[i] = node.label
	end

	local dragFromKey, dragToKey

	return {
		type = 'multiselect',
		name = 'Drag to Reorder',
		desc = 'Drag one category onto another to swap their positions.',
		order = order,
		width = 'full',
		dragdrop = true,
		values = values,
		get = function(_, i) return ordered[i].key end,
		dragGetTitle = function(_, text) return text end,
		dragOnLeave = E.noop, -- required for the widget to arm itself while dragging
		dragOnMouseDown = function(frame) dragFromKey = frame.obj.value end,
		dragOnEnter = function(frame) dragToKey = frame.obj.value end,
		dragOnMouseUp = function()
			BF:ReorderCategory(groupKey, ordered, dragFromKey, dragToKey)
			dragFromKey, dragToKey = nil, nil
		end,
	}
end

-- A leaf category (no subcategories) is just a toggle sitting directly in its
-- parent's flat list. `argKey` is the args-table key prefix
-- (usually just `path`, but 'enable' when this is embedded as the first row
-- of a category's own panel -- see below); `path` is always the real
-- category path used to read/write BF.db.categories, regardless of argKey.
-- Reordering is handled entirely by the drag-and-drop list (see
-- BuildDragDropOrderArg) -- this is just the enable/disable checkbox.
function BF:BuildLeafArgs(args, node, argKey, path, order)
	args[argKey] = {
		type = 'toggle',
		name = node.label,
		order = order,
		width = 'full',
		get = function() return BF:IsCategoryEnabled(path) end,
		set = function(_, value)
			BF.db.categories[path] = value
			-- Category enable/disable is shared between bag and bank, so both
			-- need to reflect it.
			BF:ScheduleLayout(false)
			BF:ScheduleLayout(true)
		end,
	}
end

function BF:BuildCategoryArgs(nodes, groupKey)
	local ordered = BF:GetOrderedChildren(nodes, groupKey)
	-- A top spacer inside every panel this builds -- since this function also
	-- builds each nested subcategory's own panel (Soulbound, Mounts, Trade
	-- Goods, Recipes), this gives all of them consistent top padding, not just
	-- the root "Categories & Sort Order" list.
	local args = { topSpacer = Spacer(0) }

	-- Ordered 4.5/5/6 so that, for a nested panel, this lands after the
	-- "Enable X" row and "Subcategories" header a caller injects afterward
	-- (orders 1-4) but before the individual items (orders 10+).
	if #ordered > 1 then
		args.dragOrderDesc = {
			type = 'description',
			name = 'Drag a category below onto another to swap their positions in the bag.',
			order = 4.5,
		}
		args.dragOrder = BF:BuildDragDropOrderArg(ordered, groupKey, 5)
		args.dragOrderSpacer = Spacer(6)
	end

	for i, node in ipairs(ordered) do
		local path = node.path

		if node.children then
			local childArgs = BF:BuildCategoryArgs(node.children, path)

			-- A category with its own panel doesn't also get a row in the parent
			-- list -- that used to leave "Soulbound" showing up twice (once as a
			-- flat row, once as a whole separate panel) and broke up the flat
			-- list of simple categories. Instead, its enable toggle becomes the
			-- first row INSIDE its own panel.
			BF:BuildLeafArgs(childArgs, node, 'enable', path, 1)
			childArgs.enable.name = 'Enable '..node.label

			-- Full-width "header" widgets always force a line break before and
			-- after themselves, so this guarantees the subcategories below can't
			-- visually run together with the Enable row above it.
			childArgs.subcategoriesHeader = {
				type = 'header',
				name = 'Subcategories',
				order = 4,
			}

			-- Not inline: AceConfig renders a non-inline nested group as its own
			-- expandable/collapsible tree node (exactly how the rest of ElvUI's
			-- own settings window nests things), rather than always-open inline
			-- content -- the closest native equivalent to an accordion section.
			args[path..'Group'] = {
				type = 'group',
				name = node.label,
				order = i * 10,
				args = childArgs,
			}
		else
			BF:BuildLeafArgs(args, node, path, path, i * 10)
		end
	end
	return args
end

-- Builds a plain AceConfig options table and attaches it to E.Options.args,
-- which ElvUI's core (not the optional ElvUI_Options addon) already exposes
-- as an empty table -- so this works without editing any ElvUI file, and
-- without requiring ElvUI_Options to be present or loaded first. The same
-- table is also registered as a standalone AceConfig app (see Init.lua) so
-- it's reachable via `/bagcategories config` without opening ElvUI's own
-- settings window.
function BF:BuildOptions()
	if not E.Options then return end

	-- Normally refreshed on every bag Layout pass, but the options panel can
	-- be opened before the bags ever have been this session, so refresh here
	-- too -- otherwise a freshly logged-in character wouldn't see their
	-- ItemRack sets listed until after opening their bags once.
	BF:RefreshItemRackData()

	E.Options.args.bagCategories = {
		type = 'group',
		name = 'Bag Categories',
		order = 100,
		args = {
			nameHeader = {
				type = 'header',
				name = 'ElvUI Bag Categories',
				order = 1,
			},
			description = {
				type = 'description',
				name = 'Groups items in the ElvUI bag and bank windows into categories -- Quest Items, Currency, Trade Goods, Soulbound gear, and more -- with per-category toggles, a custom sort order, and collapsible sections.',
				order = 2,
			},
			credit = {
				type = 'description',
				name = '|cff888888Made by: ludvigaf  --  https://github.com/ludvigaf/ElvUI_BagCategories|r',
				order = 2.4,
			},
			optionsSpacer = Spacer(2.5),
			options = {
				type = 'group',
				inline = true,
				name = 'Options',
				order = 3,
				args = {
					topSpacer = Spacer(0),
					enable = {
						type = 'toggle',
						name = _G.ENABLE or 'Enable',
						desc = 'Group items into categories in the bag window.',
						order = 1,
						width = 'full',
						get = function() return BF.db.enable end,
						set = function(_, value) BF:SetEnabled(value, false) end,
					},
					enableBank = {
						type = 'toggle',
						name = 'Enable for Bank',
						desc = 'Also group items into the same categories in the bank window.',
						order = 2,
						width = 'full',
						get = function() return BF.db.enableBank end,
						set = function(_, value) BF:SetEnabled(value, true) end,
					},
					showSlotCount = {
						type = 'toggle',
						name = 'Show Bag/Bank Space Count',
						desc = 'Show a used/total slot count (e.g. 74/89) in the top-left corner of the bag and bank windows. Excludes the Keyring.',
						order = 3,
						width = 'full',
						get = function() return BF.db.showSlotCount end,
						set = function(_, value)
							BF.db.showSlotCount = value
							BF:ScheduleLayout(false)
							BF:ScheduleLayout(true)
						end,
					},
					itemRackSetsEnabled = {
						type = 'toggle',
						name = 'Use ItemRack Categories',
						desc = 'If ItemRack is installed, add each of your saved ItemRack equipment sets as a Soulbound -> Equipment subcategory -- e.g. a "Tank Set" or "PvP Set" you built in ItemRack shows up as a matching subcategory there, grouping that gear together.',
						order = 4,
						width = 'full',
						get = function() return BF.db.itemRackSetsEnabled end,
						set = function(_, value)
							BF.db.itemRackSetsEnabled = value
							BF:RefreshOptions()
							BF:ScheduleLayout(false)
							BF:ScheduleLayout(true)
						end,
					},
					valueSpacer = Spacer(4.5),
					showBagValue = {
						type = 'toggle',
						name = 'Show Bag/Bank Value',
						desc = 'Show the total value of your bag/bank contents (using the price source below) next to the slot count.',
						order = 5,
						width = 'full',
						get = function() return BF.db.showBagValue end,
						set = function(_, value)
							BF.db.showBagValue = value
							BF:ScheduleLayout(false)
							BF:ScheduleLayout(true)
						end,
					},
					priceSource = {
						type = 'select',
						name = 'Price Source',
						desc = 'Which addon\'s price data to total up. Only sources from an addon you actually have installed will produce a value -- see the warning below if the selected one isn\'t available.',
						order = 6,
						width = 'full',
						values = function()
							local values = {}
							for _, source in ipairs(BF.PriceSources) do
								values[source.key] = source.label
							end
							return values
						end,
						get = function() return BF.db.priceSource end,
						set = function(_, value)
							BF.db.priceSource = value
							BF:ScheduleLayout(false)
							BF:ScheduleLayout(true)
						end,
						disabled = function() return not BF.db.showBagValue end,
					},
					priceSourceWarning = {
						type = 'description',
						name = function()
							local source = BF:GetSelectedPriceSource()
							return '|cffff5555'..(source and source.label or 'The selected price source')..' isn\'t available -- install that addon (or pick a different source above) to see a bag/bank value.|r'
						end,
						order = 7,
						hidden = function()
							return not BF.db.showBagValue or BF:IsPriceSourceAvailable(BF:GetSelectedPriceSource())
						end,
					},
				},
			},
			categoriesSpacer = Spacer(3.5),
			categoriesDesc = {
				type = 'description',
				name = 'Choose which categories to group. Unchecking a subcategory falls back to its parent category; unchecking a top-level category falls back to Miscellaneous. Drag categories in the list below (and inside each category\'s own panel) to reorder how they\'re stacked in the bag.',
				order = 4,
			},
			categories = {
				type = 'group',
				inline = true,
				name = 'Categories & Sort Order',
				order = 5,
				args = BF:BuildCategoryArgs(BF.CategoryTree, BF.RootOrderKey),
			},
		},
	}
end

-- Renders the categorized bag AND bank windows: gathering slots into buckets,
-- drawing headers/backgrounds, and positioning item buttons and category
-- sections (including the side-by-side grid for sibling categories).
-- BF:Layout(isBank) is the single entry point everything else in this file
-- builds up to. Bag and bank can be open at the same time, so every cached
-- UI piece (headers, row backgrounds, the slot-count text) is kept in its
-- own bag/bank sub-table and looked up through a `context` key ('bag' or
-- 'bank') threaded through the layout functions -- reusing the same frame
-- for both would mean a header could only ever be anchored to one of them.
local E = unpack(ElvUI)
local B = E:GetModule('Bags')
local BF = E:GetModule('BagCategories')

local next, ipairs, pairs = next, ipairs, pairs
local floor = floor
local min = math.min
local tinsert = tinsert
local tconcat = table.concat
local CreateFrame = CreateFrame
local GetContainerItemInfo = C_Container.GetContainerItemInfo

local KEYRING_CONTAINER = Enum.BagIndex and Enum.BagIndex.Keyring

-- Below this holder width, the slot-count line and the value line no longer
-- comfortably fit side by side, so the value drops to its own row instead.
local SLOT_COUNT_SPLIT_WIDTH = 500

-- Extra vertical room to reserve above the item grid when our slot-count text
-- needs a second row -- see the topOffset handling in BF:Layout. Search box
-- and item grid are anchored below and shift down; our top row alone doesn't
-- have anything below it to push, so a fixed line-height guess is fine here.
local EXTRA_TOP_OFFSET_FOR_VALUE_ROW = 18

BF.HeaderHeight = 18
BF.HeaderSpacing = 4
BF.Headers = { bag = {}, bank = {} }
BF.RowBackgrounds = { bag = {}, bank = {} }
BF.SlotCountText = { bag = nil, bank = nil }
-- ElvUI's own untouched topOffset for each frame, captured the first time we
-- see it so we always know what to restore when a second text row isn't needed.
BF.BaseTopOffset = { bag = nil, bank = nil }

local function GetContextFrame(context)
	return (context == 'bank') and B.BankFrame or B.BagFrame
end

function BF:IsCollapsed(path)
	return BF.db.collapsed[path] == true
end

function BF:ToggleCollapsed(path)
	BF.db.collapsed[path] = not BF:IsCollapsed(path)
	BF:ScheduleLayout(false)
	BF:ScheduleLayout(true)
end

function BF:GetHeader(context, path, depth)
	local header = BF.Headers[context][path]
	if header then return header end

	local f = GetContextFrame(context)
	header = CreateFrame('Button', 'ElvUIBagCategoriesHeader'..context..path, f.holderFrame)
	header:SetTemplate('Default')
	header:SetFrameLevel(f.holderFrame:GetFrameLevel() + 2)
	header:StyleButton(nil, true, true) -- hover highlight only, no pushed/checked look
	header:SetScript('OnClick', function()
		BF:ToggleCollapsed(path)
	end)

	header.text = header:CreateFontString(nil, 'OVERLAY')
	header.text:FontTemplate(nil, (depth and depth > 0) and 11 or 12, 'OUTLINE')
	header.text:Point('LEFT', 6 + ((depth or 0) * 14), 0)
	header.text:SetJustifyH('LEFT')

	BF.Headers[context][path] = header
	return header
end

-- Anchored to the bag/bank frame itself (not the scrolling holderFrame) so it
-- stays put in the top-left corner regardless of how tall the categorized
-- layout gets.
function BF:GetSlotCountText(context)
	if BF.SlotCountText[context] then return BF.SlotCountText[context] end

	local f = GetContextFrame(context)
	local text = f:CreateFontString(nil, 'OVERLAY')
	text:FontTemplate()
	text:Point('TOPLEFT', f, 'TOPLEFT', 8, -8)
	text:SetJustifyH('LEFT')

	BF.SlotCountText[context] = text
	return text
end

function BF:HideUnusedHeaders(context, used)
	for key, header in pairs(BF.Headers[context]) do
		if not used[key] then
			header:Hide()
		end
	end
end

-- A background "card" behind a column's header+items, used only when that
-- column sits side by side with siblings (see BF:LayoutChildren) so a short
-- section can be stretched to visually match a taller neighbor instead of
-- leaving a ragged gap next to it. One level behind the header so it never
-- covers the header's own background or the item buttons on top of it.
function BF:GetRowBackground(context, path)
	local bg = BF.RowBackgrounds[context][path]
	if bg then return bg end

	local f = GetContextFrame(context)
	bg = CreateFrame('Frame', 'ElvUIBagCategoriesRowBG'..context..path, f.holderFrame)
	bg:SetTemplate('Transparent')
	bg:SetFrameLevel(f.holderFrame:GetFrameLevel() + 1)

	BF.RowBackgrounds[context][path] = bg
	return bg
end

function BF:HideUnusedRowBackgrounds(context, used)
	for key, bg in pairs(BF.RowBackgrounds[context]) do
		if not used[key] then
			bg:Hide()
		end
	end
end

function BF:GatherSlots(f)
	local itemsByPath = {}
	local emptySlots = {}
	local usedSlots, totalSlots = 0, 0
	local totalValue = 0

	local function GetBucket(path)
		local bucket = itemsByPath[path]
		if not bucket then
			bucket = { items = {}, total = 0 }
			itemsByPath[path] = bucket
		end
		return bucket
	end

	-- Priced once per pass, not per item, since it reaches into another
	-- addon's API -- BF.db.showBagValue off, or no usable source selected,
	-- just skips pricing entirely.
	local priceSource = BF.db.showBagValue and BF:GetSelectedPriceSource()
	local canPrice = priceSource and BF:IsPriceSourceAvailable(priceSource)

	for _, bagID in next, f.BagIDs do
		local bag = f.Bags[bagID]
		if bag and bag.numSlots and bag.numSlots > 0 and bag:IsShown() then
			-- The Keyring has its own separate capacity and isn't really "bag
			-- space" in the sense most players mean, so it's left out of the count.
			-- (Only relevant for the bag frame -- the bank's BagIDs never include it.)
			local countable = bagID ~= KEYRING_CONTAINER

			for slotID = 1, bag.numSlots do
				local slot = bag[slotID]
				if slot then
					if countable then totalSlots = totalSlots + 1 end

					if not slot.hasItem then
						tinsert(emptySlots, slot)
					else
						if countable then usedSlots = usedSlots + 1 end

						local path = BF:ClassifySlot(slot, bagID)
						tinsert(GetBucket(path).items, slot)

						-- Every ancestor's total includes this item, so a parent header
						-- shows the full count even while some of its children are collapsed into it.
						local segments = BF:SplitPath(path)
						for i = 1, #segments do
							local bucket = GetBucket(tconcat(segments, '.', 1, i))
							bucket.total = bucket.total + 1
						end

						if canPrice and slot.itemLink then
							local price = BF:GetItemPrice(priceSource, slot.itemLink)
							if price then
								local info = GetContainerItemInfo(bagID, slotID)
								totalValue = totalValue + (price * ((info and info.stackCount) or 1))
							end
						end
					end
				end
			end
		end
	end

	return itemsByPath, emptySlots, usedSlots, totalSlots, totalValue, priceSource, canPrice
end

-- A side-by-side column is never let shrink below this width -- it's what
-- caps how many categories share a row. At the default 500px bag width this
-- works out to 2 columns per row; narrower panels drop to 1 (stacked), wider
-- ones fit progressively more.
local MIN_GRID_COLUMN_WIDTH = 220
local GRID_COLUMN_GUTTER = 6

function BF:PlaceGrid(items, f, xBase, yOffset, buttonSize, buttonSpacing, numColumns)
	local col, row = 0, 0
	for _, slot in ipairs(items) do
		slot:Show()
		slot:ClearAllPoints()

		local x = xBase + col * (buttonSize + buttonSpacing)
		local y = yOffset + row * (buttonSize + buttonSpacing)
		slot:Point('TOPLEFT', f.holderFrame, 'TOPLEFT', x, -y)

		col = col + 1
		if col >= numColumns then
			col = 0
			row = row + 1
		end
	end

	local numRows = row + ((col > 0) and 1 or 0)
	return yOffset + (numRows * (buttonSize + buttonSpacing)) - buttonSpacing
end

-- When a node is collapsed, its own slot buttons (and everything under any
-- descendant) need to be explicitly hidden -- unlike headers, which are simply
-- left untouched and swept up by HideUnusedHeaders, item buttons are real,
-- persistent frames that would otherwise keep showing at their last position.
function BF:HideNodeContents(node, itemsByPath)
	local bucket = itemsByPath[node.path]
	if bucket and bucket.items then
		for _, slot in ipairs(bucket.items) do
			slot:Hide()
		end
	end

	if node.children then
		for _, child in ipairs(node.children) do
			BF:HideNodeContents(child, itemsByPath)
		end
	end
end

function BF:LayoutNode(context, node, depth, itemsByPath, f, xOffset, yOffset, width, buttonSize, buttonSpacing, usedHeaders, usedBGs)
	local bucket = itemsByPath[node.path]
	local total = bucket and bucket.total or 0
	if total == 0 then return yOffset end

	local numColumns = floor(width / (buttonSize + buttonSpacing))
	if numColumns < 1 then numColumns = 1 end

	local collapsed = BF:IsCollapsed(node.path)

	local header = BF:GetHeader(context, node.path, depth)
	header:ClearAllPoints()
	header:SetSize(width, BF.HeaderHeight)
	header:Point('TOPLEFT', f.holderFrame, 'TOPLEFT', xOffset, -yOffset)
	header.text:SetText((collapsed and '[+] ' or '[-] ')..node.label..' ('..total..')')
	header:Show()
	usedHeaders[node.path] = true

	yOffset = yOffset + BF.HeaderHeight + BF.HeaderSpacing

	if collapsed then
		BF:HideNodeContents(node, itemsByPath)
		return yOffset
	end

	if bucket.items and #bucket.items > 0 then
		yOffset = BF:PlaceGrid(bucket.items, f, xOffset, yOffset, buttonSize, buttonSpacing, numColumns) + BF.HeaderSpacing
	end

	if node.children then
		yOffset = BF:LayoutChildren(context, node.children, node.path, depth + 1, itemsByPath, f, xOffset, yOffset, width, buttonSize, buttonSpacing, usedHeaders, usedBGs)
	end

	return yOffset
end

-- Lays out a node's children in a grid: as many per row as comfortably fit at
-- the current width (see MIN_GRID_COLUMN_WIDTH), wrapping to further rows
-- instead of ever cramming everything into one row. Only children that
-- actually have items to show are counted, so the split reflects what's
-- really visible right now, not the full possible list.
function BF:LayoutChildren(context, children, groupKey, depth, itemsByPath, f, xOffset, yOffset, width, buttonSize, buttonSpacing, usedHeaders, usedBGs)
	local ordered = BF:GetOrderedChildren(children, groupKey)

	local active = {}
	for _, child in ipairs(ordered) do
		local bucket = itemsByPath[child.path]
		if bucket and bucket.total > 0 then
			active[#active + 1] = child
		end
	end

	if #active == 0 then
		return yOffset
	elseif #active == 1 then
		return BF:LayoutNode(context, active[1], depth, itemsByPath, f, xOffset, yOffset, width, buttonSize, buttonSpacing, usedHeaders, usedBGs)
	end

	local maxColumnsForWidth = floor((width + GRID_COLUMN_GUTTER) / (MIN_GRID_COLUMN_WIDTH + GRID_COLUMN_GUTTER))
	if maxColumnsForWidth < 1 then maxColumnsForWidth = 1 end

	local columnsPerRow = min(#active, maxColumnsForWidth)
	if columnsPerRow <= 1 then
		-- Not even room for two comfortable columns -- stack full width instead.
		local y = yOffset
		for _, child in ipairs(active) do
			y = BF:LayoutNode(context, child, depth, itemsByPath, f, xOffset, y, width, buttonSize, buttonSpacing, usedHeaders, usedBGs)
		end
		return y
	end

	local columnWidth = floor((width - (GRID_COLUMN_GUTTER * (columnsPerRow - 1))) / columnsPerRow)

	local rowY = yOffset
	for rowStart = 1, #active, columnsPerRow do
		local rowEnd = min(rowStart + columnsPerRow - 1, #active)
		local rowMaxY = rowY
		local rowColumnX = {}

		for i = rowStart, rowEnd do
			local columnX = xOffset + (i - rowStart) * (columnWidth + GRID_COLUMN_GUTTER)
			rowColumnX[i] = columnX

			local columnY = BF:LayoutNode(context, active[i], depth, itemsByPath, f, columnX, rowY, columnWidth, buttonSize, buttonSpacing, usedHeaders, usedBGs)
			if columnY > rowMaxY then rowMaxY = columnY end
		end

		-- Stretch every column in this row to match the tallest one, so a short
		-- section (e.g. "Miscellaneous") doesn't leave a ragged gap next to a
		-- taller neighbor (e.g. "Equipment"). Only meaningful with more than one
		-- column, which is always true here since this loop only runs when
		-- columnsPerRow > 1.
		local rowHeight = (rowMaxY - BF.HeaderSpacing) - rowY
		for i = rowStart, rowEnd do
			local path = active[i].path
			local bg = BF:GetRowBackground(context, path)
			bg:ClearAllPoints()
			bg:SetPoint('TOPLEFT', f.holderFrame, 'TOPLEFT', rowColumnX[i], -rowY)
			bg:SetSize(columnWidth, rowHeight)
			bg:Show()
			usedBGs[path] = true
		end

		rowY = rowMaxY
	end

	return rowY
end

function BF:Layout(isBank)
	if not (E.private.bags and E.private.bags.enable) then return end
	if isBank and not BF.db.enableBank then return end
	if not isBank and not BF.db.enable then return end

	local f = isBank and B.BankFrame or B.BagFrame
	if not f or not f:IsShown() then return end

	local context = isBank and 'bank' or 'bag'
	local db = B.db
	local buttonSpacing = isBank and db.bankButtonSpacing or db.bagButtonSpacing
	local buttonSize = E:Scale(isBank and db.bankSize or db.bagSize)
	local containerWidth = isBank and db.bankWidth or db.bagWidth
	local numColumns = floor(containerWidth / (buttonSize + buttonSpacing))
	if numColumns < 1 then numColumns = 1 end

	local holderWidth = f.holderFrame:GetWidth()
	if not holderWidth or holderWidth <= 0 then
		holderWidth = ((buttonSize + buttonSpacing) * numColumns) - buttonSpacing
	end

	-- Whether our slot-count text will need a second row (see BF.db.showSlotCount
	-- handling below) -- decided here since ElvUI's search box is anchored
	-- directly above the item grid's top edge, in the same fixed top margin
	-- our text lives in. A single line clears it; a second one would clip
	-- straight into it unless that margin grows to make room.
	local needsExtraTopRow = BF.db.showSlotCount and BF.db.showBagValue and holderWidth < SLOT_COUNT_SPLIT_WIDTH

	if BF.BaseTopOffset[context] == nil then
		BF.BaseTopOffset[context] = f.topOffset
	end

	local desiredTopOffset = BF.BaseTopOffset[context] + (needsExtraTopRow and EXTRA_TOP_OFFSET_FOR_VALUE_ROW or 0)
	if f.topOffset ~= desiredTopOffset then
		f.topOffset = desiredTopOffset
		-- ElvUI only sets these two points once, at construction, and never
		-- revisits them -- safe for us to own re-anchoring from here on. The
		-- search box (anchored to holderFrame's TOPLEFT) and everything below
		-- shift down with it, so nothing else needs to move.
		f.holderFrame:ClearAllPoints()
		f.holderFrame:Point('TOP', f, 'TOP', 0, -f.topOffset)
		f.holderFrame:Point('BOTTOM', f, 'BOTTOM', 0, f.bottomOffset)
	end

	-- Refreshed regardless of which frame is being laid out -- an ItemRack set
	-- applies to a piece of gear wherever it happens to be sitting, bag or bank.
	BF:RefreshItemRackData()

	local itemsByPath, emptySlots, usedSlots, totalSlots, totalValue, priceSource, canPrice = BF:GatherSlots(f)
	local usedHeaders = {}
	local usedBGs = {}
	local yOffset = 0

	if BF.db.showSlotCount then
		local slotsLine = (isBank and 'Bank slots used: ' or 'Bag slots used: ')..usedSlots..'/'..totalSlots
		local valueLine

		if BF.db.showBagValue then
			local valueLabel = isBank and 'Total bank value: ' or 'Total bag value: '

			if canPrice then
				valueLine = valueLabel..E:FormatMoney(totalValue, 'SMART', false)
			elseif priceSource then
				valueLine = valueLabel..'|cffff5555'..priceSource.label..' unavailable|r'
			else
				valueLine = valueLabel..'|cffff5555No price source selected|r'
			end
		end

		local line = slotsLine
		if valueLine then
			-- Both pieces read fine side by side on a wide bag/bank panel, but
			-- get cramped on a narrow one -- drop the value onto its own row
			-- below the slot count instead of squeezing them onto one line.
			-- Either way this is our own text; ElvUI's own gold text (f.goldText,
			-- top-right corner) is a separate FontString we never touch.
			local separator = (holderWidth < SLOT_COUNT_SPLIT_WIDTH) and '\n' or '  |  '
			line = line..separator..valueLine
		end

		local slotCountText = BF:GetSlotCountText(context)
		slotCountText:SetText(line)
		slotCountText:Show()
	elseif BF.SlotCountText[context] then
		BF.SlotCountText[context]:Hide()
	end

	for _, node in ipairs(BF:GetOrderedChildren(BF.CategoryTree, BF.RootOrderKey)) do
		yOffset = BF:LayoutNode(context, node, 0, itemsByPath, f, 0, yOffset, holderWidth, buttonSize, buttonSpacing, usedHeaders, usedBGs)
	end

	yOffset = BF:LayoutNode(context, BF.OtherNode, 0, itemsByPath, f, 0, yOffset, holderWidth, buttonSize, buttonSpacing, usedHeaders, usedBGs)

	if #emptySlots > 0 then
		yOffset = BF:PlaceGrid(emptySlots, f, 0, yOffset, buttonSize, buttonSpacing, numColumns)
	else
		yOffset = yOffset - BF.HeaderSpacing
	end

	if yOffset < 0 then yOffset = 0 end

	BF:HideUnusedHeaders(context, usedHeaders)
	BF:HideUnusedRowBackgrounds(context, usedBGs)

	f:SetSize(containerWidth, yOffset + f.topOffset + f.bottomOffset)
end

-- Runs synchronously (not deferred) so the regroup lands in the same frame as
-- ElvUI's own content/texture updates, instead of one frame later, which is
-- what caused the visible flicker back to native positions.
function BF:ScheduleLayout(isBank)
	BF:Layout(isBank)
end

function BF:SetEnabled(value, isBank)
	if isBank then
		BF.db.enableBank = value
	else
		BF.db.enable = value
	end

	if value then
		BF:ScheduleLayout(isBank)
	else
		local context = isBank and 'bank' or 'bag'
		BF:HideUnusedHeaders(context, {})
		BF:HideUnusedRowBackgrounds(context, {})
		if BF.SlotCountText[context] then BF.SlotCountText[context]:Hide() end
		B:Layout(isBank)
	end
end

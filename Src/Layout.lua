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
local ceil = math.ceil
local sqrt = math.sqrt
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

local GRID_COLUMN_GUTTER = 6

-- A side-by-side section's own item grid is capped at this many columns, so
-- a category with a lot of items still packs its own box into a reasonably
-- compact, roughly-square shape (growing downward instead of dominating the
-- whole row's width) rather than expanding indefinitely and crowding out
-- its siblings.
local MAX_SECTION_COLUMNS = 6

-- A section's box is never let shrink narrower than this, even a 1-item one
-- -- otherwise its header label (e.g. "Restoration") would clip against a
-- box sized for barely one icon.
local MIN_SECTION_WIDTH = 140

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

-- Lays out a node's children as a packed grid of boxes: each child's own box
-- is sized to just fit its own item count (capped at MAX_SECTION_COLUMNS
-- columns, and roughly square -- see naturalWidth below), and boxes are
-- packed left-to-right, wrapping to a new row whenever the next one doesn't
-- fit in the remaining width. A category with 1 item no longer claims the
-- same width as a 9-item neighbor sharing its row -- the smaller box just
-- leaves room for another section (or the next row) to start sooner. Only
-- children that actually have items to show are counted, so the packing
-- reflects what's really visible right now, not the full possible list.
function BF:LayoutChildren(context, children, groupKey, depth, itemsByPath, f, xOffset, yOffset, width, buttonSize, buttonSpacing, usedHeaders, usedBGs)
	local ordered = BF:GetOrderedChildren(children, groupKey)
	local unit = buttonSize + buttonSpacing

	local active = {}
	for _, child in ipairs(ordered) do
		local bucket = itemsByPath[child.path]
		if bucket and bucket.total > 0 then
			local naturalColumns = ceil(sqrt(bucket.total))
			if naturalColumns < 1 then naturalColumns = 1 end
			if naturalColumns > MAX_SECTION_COLUMNS then naturalColumns = MAX_SECTION_COLUMNS end

			local naturalWidth = (naturalColumns * unit) - buttonSpacing
			if naturalWidth < MIN_SECTION_WIDTH then naturalWidth = MIN_SECTION_WIDTH end

			active[#active + 1] = {
				node = child,
				width = min(width, naturalWidth),
			}
		end
	end

	if #active == 0 then
		return yOffset
	elseif #active == 1 then
		return BF:LayoutNode(context, active[1].node, depth, itemsByPath, f, xOffset, yOffset, width, buttonSize, buttonSpacing, usedHeaders, usedBGs)
	end

	-- Greedily pack sections into rows: keep adding to the current row while
	-- it still fits, otherwise start a new one.
	local rows = { {} }
	local rowWidth = 0
	for _, entry in ipairs(active) do
		local row = rows[#rows]
		local needed = entry.width + ((#row > 0) and GRID_COLUMN_GUTTER or 0)
		if #row > 0 and rowWidth + needed > width then
			row = {}
			rows[#rows + 1] = row
			rowWidth = 0
			needed = entry.width
		end
		row[#row + 1] = entry
		rowWidth = rowWidth + needed
	end

	-- A lone section left over in a row (nothing else fit next to it) takes
	-- the full width; a row with several sections grows each one, proportional
	-- to its own natural size, to use up whatever width packing left unclaimed
	-- -- so the row's own content (e.g. an item grid that can now fit an extra
	-- column) fills the space instead of leaving it blank to the right.
	for _, row in ipairs(rows) do
		if #row == 1 then
			row[1].width = width
		else
			local naturalTotal = 0
			for _, entry in ipairs(row) do naturalTotal = naturalTotal + entry.width end

			local leftover = width - naturalTotal - (GRID_COLUMN_GUTTER * (#row - 1))
			if leftover > 0 then
				local distributed = 0
				for i, entry in ipairs(row) do
					local extra
					if i == #row then
						extra = leftover - distributed
					else
						extra = floor(leftover * (entry.width / naturalTotal))
						distributed = distributed + extra
					end
					entry.width = entry.width + extra
				end
			end
		end
	end

	local rowY = yOffset
	for _, row in ipairs(rows) do
		if #row == 1 then
			rowY = BF:LayoutNode(context, row[1].node, depth, itemsByPath, f, xOffset, rowY, row[1].width, buttonSize, buttonSpacing, usedHeaders, usedBGs)
		else
			local rowMaxY = rowY
			local rowColumnX = {}
			local x = xOffset

			for i, entry in ipairs(row) do
				rowColumnX[i] = x
				local columnY = BF:LayoutNode(context, entry.node, depth, itemsByPath, f, x, rowY, entry.width, buttonSize, buttonSpacing, usedHeaders, usedBGs)
				if columnY > rowMaxY then rowMaxY = columnY end
				x = x + entry.width + GRID_COLUMN_GUTTER
			end

			-- Stretch every column's background in this row to match the tallest
			-- one, so a short section doesn't leave a ragged gap next to a taller
			-- neighbor -- widths stay content-sized, only the height is matched.
			local rowHeight = (rowMaxY - BF.HeaderSpacing) - rowY
			for i, entry in ipairs(row) do
				local path = entry.node.path
				local bg = BF:GetRowBackground(context, path)
				bg:ClearAllPoints()
				bg:SetPoint('TOPLEFT', f.holderFrame, 'TOPLEFT', rowColumnX[i], -rowY)
				bg:SetSize(entry.width, rowHeight)
				bg:Show()
				usedBGs[path] = true
			end

			rowY = rowMaxY
		end
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

	-- The root Miscellaneous catch-all (BF.OtherNode) doesn't get its own
	-- headed section -- it's the permanent fallback for items that don't match
	-- any category at all, so giving it a header made it look like just
	-- another category instead of the "everything else" leftovers it actually
	-- is. Folded into the same plain, unlabeled trailing grid as the empty
	-- slots instead -- the closest this addon's category-stack layout can get
	-- to leaving them in a plain, uncategorized ElvUI-style grid, since the
	-- slot buttons are repositioned every pass regardless (real native bag
	-- coordinates would land on top of the categorized sections above).
	local otherBucket = itemsByPath[BF.OtherNode.path]
	if otherBucket and otherBucket.items and #otherBucket.items > 0 then
		-- Items first, empty gaps after -- matching how every other category
		-- section lays out its own contents before whatever follows it.
		local trailingSlots = {}
		for _, slot in ipairs(otherBucket.items) do
			trailingSlots[#trailingSlots + 1] = slot
		end
		for _, slot in ipairs(emptySlots) do
			trailingSlots[#trailingSlots + 1] = slot
		end
		emptySlots = trailingSlots
	end

	if #emptySlots > 0 then
		-- holderWidth-based, like every categorized section computes its own
		-- column count (see LayoutNode) -- not the `numColumns` above, which is
		-- derived from the *configured* bag width (db.bagWidth/db.bankWidth).
		-- That setting doesn't always match the holder frame's actual rendered
		-- width, so using it here wrapped this trailing grid at a different
		-- column count than the categorized grid above it, making it look like
		-- a separate, oddly-proportioned block instead of a continuation of
		-- the same uniform grid.
		local trailingColumns = floor(holderWidth / (buttonSize + buttonSpacing))
		if trailingColumns < 1 then trailingColumns = 1 end

		yOffset = BF:PlaceGrid(emptySlots, f, 0, yOffset, buttonSize, buttonSpacing, trailingColumns)
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

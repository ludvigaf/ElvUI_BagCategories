-- Wires everything together and starts the module: saved-variable defaults
-- and migrations, the hooks into ElvUI's Bags module that trigger our
-- relayout, the standalone options window, and the /bagcategories slash
-- command. Loaded last so every piece it references (BF:BuildOptions,
-- BF:ScheduleLayout, BF.CategoryTree, ...) already exists.
local E = unpack(ElvUI)
local B = E:GetModule('Bags')
local BF = E:GetModule('BagCategories')

local ipairs, pairs = ipairs, pairs
local hooksecurefunc = hooksecurefunc
local strtrim = strtrim

function BF:Initialize()
	BF.db = ElvUIBagCategoriesDB
	if type(BF.db) ~= 'table' then
		BF.db = {}
		ElvUIBagCategoriesDB = BF.db
	end

	if BF.db.enable == nil then
		BF.db.enable = true
	end

	if BF.db.enableBank == nil then
		BF.db.enableBank = true
	end

	if BF.db.showSlotCount == nil then
		BF.db.showSlotCount = true
	end

	if BF.db.itemRackSetsEnabled == nil then
		BF.db.itemRackSetsEnabled = true
	end

	if BF.db.showBagValue == nil then
		BF.db.showBagValue = true
	end

	if BF.db.priceSource == nil then
		BF.db.priceSource = 'atrvalue'
	end

	if type(BF.db.categories) ~= 'table' then
		BF.db.categories = {}
	end

	if type(BF.db.collapsed) ~= 'table' then
		BF.db.collapsed = {}
	end

	if type(BF.db.order) ~= 'table' then
		BF.db.order = {}
	end

	for _, path in ipairs(BF:CollectPaths(BF.CategoryTree, {})) do
		if BF.db.categories[path] == nil then
			BF.db.categories[path] = not BF.DefaultDisabledPaths[path]
		end
	end

	-- One-time migration: Mounts/Flying/Ground used to default to enabled, so anyone
	-- who already ran an earlier version has them saved as true. Force them off once;
	-- afterward the user's own toggling is left alone.
	if not BF.db.mountsDefaultMigrated then
		for path in pairs(BF.DefaultDisabledPaths) do
			BF.db.categories[path] = false
		end
		BF.db.mountsDefaultMigrated = true
	end

	hooksecurefunc(B, 'Layout', function(_, isBank)
		BF:ScheduleLayout(isBank)
	end)

	hooksecurefunc(B, 'UpdateSlot', function(_, frame)
		if frame == B.BagFrame then
			BF:ScheduleLayout(false)
		elseif frame == B.BankFrame then
			BF:ScheduleLayout(true)
		end
	end)

	B.BagFrame:HookScript('OnShow', function()
		BF:ScheduleLayout(false)
	end)

	B.BankFrame:HookScript('OnShow', function()
		BF:ScheduleLayout(true)
	end)

	BF:BuildOptions()

	-- Registering the same table (fetched live via this function, so it stays in
	-- sync with every later BF:BuildOptions() rebuild) under its own AceConfig
	-- app name gives it a standalone settings window, independent of ElvUI's
	-- own big config frame.
	BF.StandaloneApp = 'ElvUIBagCategories'
	local ACR = E.Libs.AceConfigRegistry
	if ACR then
		ACR:RegisterOptionsTable(BF.StandaloneApp, function() return E.Options.args.bagCategories end)
	end

	SLASH_ELVUIBAGCATEGORIES1 = '/bagcategories'
	SlashCmdList['ELVUIBAGCATEGORIES'] = function(msg)
		msg = strtrim(msg or ''):lower()

		if msg == 'config' or msg == 'options' then
			E.Libs.AceConfigDialog:Open(BF.StandaloneApp)
		else
			-- Quick-toggles the bag window only; the bank has its own separate
			-- checkbox ("Enable for Bank") in the options panel.
			BF:SetEnabled(not BF.db.enable, false)
			print('|cff1784d1ElvUI Bag Categories|r: '..(BF.db.enable and 'Enabled' or 'Disabled')..' (use /bagcategories config to open settings)')
		end
	end
end

E:RegisterModule(BF:GetName())

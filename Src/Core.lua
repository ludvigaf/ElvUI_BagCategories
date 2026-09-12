-- Bootstraps the addon module. Every other file in this addon fetches this
-- same module object via E:GetModule('BagCategories') and attaches its own
-- pieces to it (data, methods, state) -- see Init.lua for where everything
-- gets wired together and actually started.
local E = unpack(ElvUI)

E:NewModule('BagCategories')

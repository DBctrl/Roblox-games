--!strict
-- Client-only signals between UI controllers (helper, not a controller). Owned by systems-programmer.
-- Controllers have no public functions (architecture 1d), so they talk through these BindableEvents.
-- Nothing here reaches the server.

local UiEvents = {}

local tapped = Instance.new("BindableEvent")
local openPanel = Instance.new("BindableEvent")
local openRobuxEgg = Instance.new("BindableEvent")

-- Fired by TapController for every locally accepted tap. (screenPosition: Vector2)
UiEvents.Tapped = tapped.Event
function UiEvents.fireTapped(position: Vector2)
	tapped:Fire(position)
end

-- Asks a panel controller to open. (panel: "Tools")
UiEvents.OpenPanel = openPanel.Event
function UiEvents.fireOpenPanel(panel: string)
	openPanel:Fire(panel)
end

-- Asks EggController to open the Robux egg screen for `eggId` (from the Robux shop, T-057/T-058). (eggId: string)
UiEvents.OpenRobuxEgg = openRobuxEgg.Event
function UiEvents.fireOpenRobuxEgg(eggId: string)
	openRobuxEgg:Fire(eggId)
end

return table.freeze(UiEvents)

--!strict
-- Small UI toolkit shared by the UI controllers (helper module, not a controller: it lives in UI/Util, so the
-- bootstrap does not run it). Owned by systems-programmer.
-- Layout rules (agent file, GDD 9): scale-based sizes, every touch target >= 44 x 44 px (UISizeConstraint),
-- ScreenGuis inside the device safe area (ScreenInsets = CoreUISafeInsets keeps clear of the notch and Roblox's
-- own top-bar buttons).

local Players = game:GetService("Players")

local Ui = {}

Ui.MIN_TOUCH_PX = 44

Ui.Theme = table.freeze({
	font = Enum.Font.FredokaOne,
	text = Color3.fromRGB(255, 255, 255),
	textDim = Color3.fromRGB(205, 210, 230),
	stroke = Color3.fromRGB(25, 20, 45),
	panel = Color3.fromRGB(40, 32, 72),
	panelLight = Color3.fromRGB(62, 52, 104),
	accent = Color3.fromRGB(255, 196, 46), -- MP / glow
	coins = Color3.fromRGB(255, 221, 87),
	good = Color3.fromRGB(80, 214, 120),
	bad = Color3.fromRGB(235, 87, 87),
	grey = Color3.fromRGB(120, 120, 135),
	meterBack = Color3.fromRGB(28, 24, 52),
})

-- Creates an instance, applies `props` (Parent last), and parents `children` to it.
function Ui.new(className: string, props: { [string]: any }?, children: { Instance }?): any
	local instance = Instance.new(className) :: any
	local parent = nil
	if props then
		for key, value in props do
			if key == "Parent" then
				parent = value
			else
				instance[key] = value
			end
		end
	end
	if children then
		for _, child in children do
			child.Parent = instance
		end
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

function Ui.corner(radiusScale: number?): UICorner
	return Ui.new("UICorner", { CornerRadius = UDim.new(radiusScale or 0.25, 0) })
end

function Ui.stroke(thickness: number?): UIStroke
	return Ui.new("UIStroke", {
		Color = Ui.Theme.stroke,
		Thickness = thickness or 2,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function Ui.textStroke(): UIStroke
	return Ui.new("UIStroke", { Color = Ui.Theme.stroke, Thickness = 2 })
end

-- Size limits in pixels; min defaults to the 44 px touch target.
function Ui.sizeLimit(minX: number?, minY: number?, maxX: number?, maxY: number?): UISizeConstraint
	return Ui.new("UISizeConstraint", {
		MinSize = Vector2.new(minX or Ui.MIN_TOUCH_PX, minY or Ui.MIN_TOUCH_PX),
		MaxSize = Vector2.new(maxX or math.huge, maxY or math.huge),
	})
end

function Ui.textLimit(maxSize: number, minSize: number?): UITextSizeConstraint
	return Ui.new("UITextSizeConstraint", { MaxTextSize = maxSize, MinTextSize = minSize or 10 })
end

-- A ScreenGui in PlayerGui that survives respawns and stays inside the safe area.
function Ui.screen(name: string, displayOrder: number): ScreenGui
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	return Ui.new("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = displayOrder,
		Parent = playerGui,
	})
end

function Ui.label(props: { [string]: any }): TextLabel
	local defaults: { [string]: any } = {
		BackgroundTransparency = 1,
		Font = Ui.Theme.font,
		TextColor3 = Ui.Theme.text,
		TextScaled = true,
		Text = "",
	}
	for key, value in props do
		defaults[key] = value
	end
	local label = Ui.new("TextLabel", defaults)
	Ui.textStroke().Parent = label
	return label
end

-- A rounded text button that never shrinks below 44 x 44 px.
function Ui.button(props: { [string]: any }): TextButton
	local defaults: { [string]: any } = {
		AutoButtonColor = true,
		BackgroundColor3 = Ui.Theme.panelLight,
		Font = Ui.Theme.font,
		TextColor3 = Ui.Theme.text,
		TextScaled = true,
		Text = "",
	}
	for key, value in props do
		defaults[key] = value
	end
	local button = Ui.new("TextButton", defaults)
	Ui.corner().Parent = button
	Ui.stroke().Parent = button
	Ui.sizeLimit().Parent = button
	Ui.new("UIPadding", {
		PaddingLeft = UDim.new(0.06, 0),
		PaddingRight = UDim.new(0.06, 0),
		PaddingTop = UDim.new(0.1, 0),
		PaddingBottom = UDim.new(0.1, 0),
		Parent = button,
	})
	return button
end

-- A horizontal progress bar: returns the frame, its fill and its centred text label.
function Ui.meter(props: { [string]: any }, fillColor: Color3): (Frame, Frame, TextLabel)
	local defaults: { [string]: any } = { BackgroundColor3 = Ui.Theme.meterBack, BorderSizePixel = 0 }
	for key, value in props do
		defaults[key] = value
	end
	local frame = Ui.new("Frame", defaults)
	Ui.corner(0.5).Parent = frame
	Ui.stroke().Parent = frame
	local fill = Ui.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = fillColor,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		Parent = frame,
	})
	Ui.corner(0.5).Parent = fill
	local text = Ui.label({
		Name = "Text",
		Size = UDim2.fromScale(0.94, 0.8),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 2,
		Parent = frame,
	})
	return frame, fill, text
end

-- Yields until the server has loaded this player's profile (DataLoaded attribute).
function Ui.waitForData(dataLoadedAttr: string)
	local player = Players.LocalPlayer
	while player:GetAttribute(dataLoadedAttr) ~= true do
		player:GetAttributeChangedSignal(dataLoadedAttr):Wait()
	end
end

-- Reads a number attribute from the local player; non-numbers and NaN read as `default`.
function Ui.numAttr(name: string, default: number): number
	local value = Players.LocalPlayer:GetAttribute(name)
	if type(value) ~= "number" or value ~= value then
		return default
	end
	return value
end

function Ui.boolAttr(name: string): boolean
	return Players.LocalPlayer:GetAttribute(name) == true
end

return table.freeze(Ui)

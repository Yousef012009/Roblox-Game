--!strict
--[[
	Palette  (ModuleScript)  ·  ServerScriptService/MapGen/Palette

	Every colour, material and font the map generator uses. PS1 retro noir:
	flat, slightly desaturated surfaces (charcoal, faded institutional green,
	dirty beige concrete, muted brown wood, oxidised metal, desaturated red),
	with saturated colour reserved for emissive things (neon tubes, CRT
	phosphor, status lights) so they read as the only "live" objects.

	A Swatch is the pair (Color, Material) applied to a part. Builder takes a
	swatch everywhere, so restyling the whole map is a matter of editing this
	file.
]]

export type Swatch = {
	Color: Color3,
	Material: Enum.Material,
}

local function swatch(r: number, g: number, b: number, material: Enum.Material): Swatch
	return table.freeze({ Color = Color3.fromRGB(r, g, b), Material = material })
end

local M = Enum.Material

local Palette = {}

----------------------------------------------------------------------------
-- Structure
----------------------------------------------------------------------------
Palette.ConcreteBeige = swatch(146, 136, 114, M.Concrete) -- dirty beige walls
Palette.ConcreteLight = swatch(164, 156, 136, M.Concrete) -- pillar shafts, lintels
Palette.ConcreteDark = swatch(92, 89, 82, M.Concrete) -- plinths, beams
Palette.ConcreteFloor = swatch(98, 95, 87, M.Concrete) -- main floors
Palette.ConcreteStained = swatch(78, 76, 70, M.Concrete) -- interrogation floor
Palette.Ceiling = swatch(58, 60, 58, M.Concrete)
Palette.Exterior = swatch(30, 31, 34, M.Concrete) -- the building across the alley
Palette.Asphalt = swatch(22, 23, 25, M.Concrete)

----------------------------------------------------------------------------
-- Paint / trim
----------------------------------------------------------------------------
Palette.Charcoal = swatch(40, 41, 44, M.SmoothPlastic)
Palette.CharcoalDeep = swatch(22, 23, 25, M.SmoothPlastic)
Palette.FadedGreen = swatch(70, 88, 74, M.SmoothPlastic) -- institutional wainscot
Palette.GreenDeep = swatch(42, 56, 47, M.SmoothPlastic)
Palette.RedDesat = swatch(118, 44, 40, M.SmoothPlastic)
Palette.RedDark = swatch(72, 30, 28, M.SmoothPlastic)
Palette.Hazard = swatch(168, 138, 52, M.SmoothPlastic)
Palette.Stain = swatch(44, 42, 36, M.SmoothPlastic)

----------------------------------------------------------------------------
-- Wood
----------------------------------------------------------------------------
Palette.Wood = swatch(96, 68, 48, M.Wood)
Palette.WoodDark = swatch(60, 43, 32, M.Wood)
Palette.WoodPlanks = swatch(82, 60, 44, M.WoodPlanks)

----------------------------------------------------------------------------
-- Metal
----------------------------------------------------------------------------
Palette.Metal = swatch(108, 112, 112, M.Metal)
Palette.MetalDark = swatch(54, 58, 60, M.Metal)
Palette.MetalOxidised = swatch(84, 96, 88, M.CorrodedMetal)
Palette.MetalRust = swatch(98, 70, 54, M.CorrodedMetal)
Palette.DiamondPlate = swatch(92, 96, 96, M.DiamondPlate)
Palette.Brass = swatch(138, 116, 70, M.Metal)
Palette.Chrome = swatch(150, 154, 156, M.Metal)

----------------------------------------------------------------------------
-- Soft goods / small items
----------------------------------------------------------------------------
Palette.Leather = swatch(78, 40, 34, M.Fabric) -- oxblood couches
Palette.FabricGreen = swatch(56, 70, 58, M.Fabric)
Palette.FabricCharcoal = swatch(38, 38, 41, M.Fabric)
Palette.Carpet = swatch(80, 34, 32, M.Fabric)
Palette.CarpetDark = swatch(50, 26, 26, M.Fabric)
Palette.Cork = swatch(120, 90, 60, M.Fabric)
Palette.Paper = swatch(204, 196, 170, M.SmoothPlastic)
Palette.PaperOld = swatch(176, 160, 120, M.SmoothPlastic)
Palette.Manila = swatch(170, 140, 90, M.SmoothPlastic)
Palette.Cardboard = swatch(122, 96, 66, M.SmoothPlastic)
Palette.CaseBeige = swatch(160, 152, 130, M.SmoothPlastic) -- CRT / terminal plastic
Palette.CaseDark = swatch(50, 49, 46, M.SmoothPlastic)
Palette.Rubber = swatch(16, 16, 18, M.SmoothPlastic)
Palette.Ceramic = swatch(170, 166, 152, M.SmoothPlastic)
Palette.Soil = swatch(40, 32, 26, M.SmoothPlastic)
Palette.DeadLeaf = swatch(74, 78, 50, M.SmoothPlastic)

----------------------------------------------------------------------------
-- Glass
----------------------------------------------------------------------------
Palette.ScreenOff = swatch(22, 30, 26, M.SmoothPlastic) -- CRT glass (the client draws static on it)
Palette.GlassDark = swatch(34, 44, 50, M.Glass) -- windows
Palette.GlassMirror = swatch(28, 32, 36, M.Glass) -- two-way mirror tint
Palette.GlassWired = swatch(30, 34, 36, M.Glass) -- opaque door glass
Palette.GlassFrosted = swatch(150, 140, 110, M.SmoothPlastic) -- lit office-door glass

----------------------------------------------------------------------------
-- Emissive colours (used with Neon or as SurfaceGui text)
----------------------------------------------------------------------------
Palette.Neon = table.freeze({
	Tube = Color3.fromRGB(214, 232, 220),
	Bulb = Color3.fromRGB(255, 214, 150),
	Phosphor = Color3.fromRGB(130, 255, 150),
	PhosphorDim = Color3.fromRGB(64, 150, 88),
	Amber = Color3.fromRGB(255, 172, 60),
	AmberDim = Color3.fromRGB(150, 96, 36),
	StatusGreen = Color3.fromRGB(90, 255, 120),
	StatusRed = Color3.fromRGB(255, 52, 40),
	AlarmDim = Color3.fromRGB(62, 14, 12),
	FloorMark = Color3.fromRGB(176, 150, 58),
	WindowWarm = Color3.fromRGB(150, 112, 60),
	WindowCold = Color3.fromRGB(70, 92, 110),
	RoomFill = Color3.fromRGB(120, 140, 136),
	LoungeLamp = Color3.fromRGB(96, 116, 150),
	Exit = Color3.fromRGB(190, 40, 34),
})

----------------------------------------------------------------------------
-- Light colours
----------------------------------------------------------------------------
Palette.Light = table.freeze({
	Fluorescent = Color3.fromRGB(206, 228, 216),
	Warm = Color3.fromRGB(255, 198, 132),
	Bulb = Color3.fromRGB(255, 196, 130),
	Cool = Color3.fromRGB(150, 172, 190),
	Moon = Color3.fromRGB(132, 154, 196),
	TV = Color3.fromRGB(120, 220, 160),
	Alarm = Color3.fromRGB(255, 36, 28),
	Elevator = Color3.fromRGB(190, 214, 200),
	ExitRed = Color3.fromRGB(255, 70, 60),
})

----------------------------------------------------------------------------
-- Text
----------------------------------------------------------------------------
Palette.Font = table.freeze({
	Sign = Enum.Font.SpecialElite, -- typewriter / stencil signage
	Display = Enum.Font.Arcade, -- LED counters, TV headlines
	Terminal = Enum.Font.Code, -- CRT terminals
	Mono = Enum.Font.RobotoMono,
	Plaque = Enum.Font.Antique,
})

Palette.Text = table.freeze({
	Cream = Color3.fromRGB(222, 206, 166),
	Brass = Color3.fromRGB(200, 170, 104),
	Ink = Color3.fromRGB(26, 24, 22),
	Stencil = Color3.fromRGB(196, 190, 170),
	ScreenBg = Color3.fromRGB(6, 10, 8),
})

return table.freeze(Palette)

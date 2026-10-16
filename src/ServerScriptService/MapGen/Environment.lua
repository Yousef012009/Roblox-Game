--!strict
--[[
	Environment  (ModuleScript)  ·  ServerScriptService/MapGen/Environment

	Night-time noir lighting for the whole place. Idempotent: running it again
	re-applies the same values and reuses the single colour-grading effect.

	  • Night (ClockTime 0.4) with a dim, slightly green ambient so interiors
	    are moody but every surface stays readable on a phone screen.
	  • Classic distance fog (FogStart/FogEnd/FogColor). An Atmosphere object
	    overrides classic fog, so any Atmosphere is first neutralised
	    (Density 0, no haze/glare) and then removed from Lighting: its mere
	    presence disables the fog properties.
	  • Exactly one ColorCorrectionEffect ("C64Grade"): mild desaturation, a
	    touch of contrast and a faint green tint.
	  • No Bloom, DepthOfField, SunRays or Blur: existing ones are disabled
	    (left in place so a designer can re-enable them by hand).
]]

local Lighting = game:GetService("Lighting")

local Environment = {}

Environment.GradeName = "C64Grade"

Environment.Settings = table.freeze({
	ClockTime = 0.4,
	GeographicLatitude = 41.8,
	Brightness = 0.6,
	Ambient = Color3.fromRGB(70, 75, 72),
	OutdoorAmbient = Color3.fromRGB(44, 48, 56),
	EnvironmentDiffuseScale = 0.15,
	EnvironmentSpecularScale = 0.3,
	ExposureCompensation = 0.15,
	FogColor = Color3.fromRGB(14, 16, 18),
	FogStart = 55,
	FogEnd = 320,
	ShadowSoftness = 0.3,
})

local function neutraliseAtmosphere(atmosphere: Atmosphere)
	atmosphere.Density = 0
	atmosphere.Haze = 0
	atmosphere.Glare = 0
	atmosphere.Offset = 0
	atmosphere:Destroy()
end

local function disableUnwantedEffects()
	for _, child in Lighting:GetChildren() do
		if child:IsA("Atmosphere") then
			neutraliseAtmosphere(child)
		elseif child:IsA("BloomEffect") or child:IsA("DepthOfFieldEffect") or child:IsA("SunRaysEffect") or child:IsA("BlurEffect") then
			child.Enabled = false
		elseif child:IsA("ColorCorrectionEffect") and child.Name ~= Environment.GradeName then
			child.Enabled = false
		end
	end
end

local function ensureGrade(): ColorCorrectionEffect
	local existing = Lighting:FindFirstChild(Environment.GradeName)
	local grade: ColorCorrectionEffect
	if existing and existing:IsA("ColorCorrectionEffect") then
		grade = existing
	else
		grade = Instance.new("ColorCorrectionEffect")
		grade.Name = Environment.GradeName
	end
	grade.Enabled = true
	grade.Saturation = -0.28
	grade.Contrast = 0.12
	grade.Brightness = 0.02
	grade.TintColor = Color3.fromRGB(228, 242, 230)
	grade.Parent = Lighting
	return grade
end

function Environment.Apply()
	local s = Environment.Settings
	Lighting.ClockTime = s.ClockTime
	Lighting.GeographicLatitude = s.GeographicLatitude
	Lighting.Brightness = s.Brightness
	Lighting.Ambient = s.Ambient
	Lighting.OutdoorAmbient = s.OutdoorAmbient
	Lighting.EnvironmentDiffuseScale = s.EnvironmentDiffuseScale
	Lighting.EnvironmentSpecularScale = s.EnvironmentSpecularScale
	Lighting.ExposureCompensation = s.ExposureCompensation
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = s.ShadowSoftness
	Lighting.ColorShift_Top = Color3.new(0, 0, 0)
	Lighting.ColorShift_Bottom = Color3.new(0, 0, 0)

	disableUnwantedEffects()
	-- Fog is set after the Atmosphere is gone so the values take effect.
	Lighting.FogColor = s.FogColor
	Lighting.FogStart = s.FogStart
	Lighting.FogEnd = s.FogEnd

	ensureGrade()
end

return Environment

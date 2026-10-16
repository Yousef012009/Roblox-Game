--!strict
--[[
	TextFX  (ModuleScript)  ·  StarterPlayerScripts/Client/TextFX

	Typewriter + glitch reveal for TextLabels (answers, case-file lines,
	"ELIMINATED"). Entries are keyed by label, so typing a new string into the
	same label simply restarts it. ClientManager calls TextFX.step() once per
	frame; a label is written only when its visible text actually changes,
	and finished entries are dropped (no work when nothing is typing).

	UTF-8 safe: the reveal counts characters, never bytes.
]]

local TextFX = {}

local GLYPHS = { "#", "%", "&", "*", "/", "\\", "|", "<", ">", "?", "=", "+", "0", "1" }

export type Options = {
	cps: number?, -- characters per second (default 28)
	delay: number?, -- seconds before the first character
	cursor: boolean?, -- show "_" while typing
	glitch: boolean?, -- scramble the not-yet-typed tail and settle afterwards
	glitchSeconds: number?, -- how long the settle-scramble lasts after typing (default 0.25)
}

type Entry = {
	label: TextLabel,
	text: string,
	chars: number,
	startedAt: number,
	cps: number,
	delay: number,
	cursor: boolean,
	glitch: boolean,
	glitchSeconds: number,
	lastShown: string,
}

local entries: { [TextLabel]: Entry } = {}
local random = Random.new()

local function prefix(text: string, count: number): string
	if count <= 0 then
		return ""
	end
	local byteEnd = utf8.offset(text, count + 1)
	if byteEnd == nil then
		return text
	end
	return string.sub(text, 1, byteEnd - 1)
end

local function noise(count: number): string
	local out = table.create(count)
	for i = 1, count do
		out[i] = GLYPHS[random:NextInteger(1, #GLYPHS)]
	end
	return table.concat(out)
end

local function render(entry: Entry, now: number): (string, boolean)
	local elapsed = now - entry.startedAt - entry.delay
	if elapsed < 0 then
		return if entry.cursor then "_" else "", false
	end
	local count = math.floor(elapsed * entry.cps)
	if count < entry.chars then
		local shown = prefix(entry.text, count)
		if entry.glitch then
			shown ..= noise(math.min(2, entry.chars - count))
		elseif entry.cursor then
			shown ..= "_"
		end
		return shown, false
	end
	local settle = elapsed - entry.chars / entry.cps
	if entry.glitch and settle < entry.glitchSeconds and entry.chars > 0 then
		-- Flicker one random character for a moment, then lock in.
		local index = random:NextInteger(1, entry.chars)
		return prefix(entry.text, index - 1) .. noise(1) .. string.sub(entry.text, utf8.offset(entry.text, index + 1) or (#entry.text + 1)),
			false
	end
	return entry.text, true
end

-- Starts typing `text` into `label` (restarts if it is already typing).
function TextFX.type(label: TextLabel, text: string, options: Options?)
	local opts: Options = options or {}
	local chars = utf8.len(text)
	if chars == nil then
		-- Invalid UTF-8: show it as-is rather than slicing mid-character.
		TextFX.cancel(label)
		label.Text = text
		return
	end
	entries[label] = {
		label = label,
		text = text,
		chars = chars,
		startedAt = os.clock(),
		cps = math.max(1, opts.cps or 28),
		delay = math.max(0, opts.delay or 0),
		cursor = opts.cursor == true,
		glitch = opts.glitch == true,
		glitchSeconds = opts.glitchSeconds or 0.25,
		lastShown = "\0",
	}
	TextFX.step()
end

-- Types `text` only if the label is not already showing / typing it.
function TextFX.typeIfChanged(label: TextLabel, text: string, options: Options?)
	local entry = entries[label]
	if (entry and entry.text == text) or (not entry and label.Text == text) then
		return
	end
	TextFX.type(label, text, options)
end

-- Stops typing and (optionally) snaps the label to `final`.
function TextFX.cancel(label: TextLabel, final: string?)
	entries[label] = nil
	if final ~= nil and label.Text ~= final then
		label.Text = final
	end
end

function TextFX.isTyping(label: TextLabel): boolean
	return entries[label] ~= nil
end

function TextFX.step()
	if next(entries) == nil then
		return
	end
	local now = os.clock()
	for label, entry in entries do
		local shown, done = render(entry, now)
		if shown ~= entry.lastShown then
			entry.lastShown = shown
			if label.Text ~= shown then
				label.Text = shown
			end
		end
		if done or not label.Parent then
			entries[label] = nil
		end
	end
end

return TextFX

# 🕵️ Concentration 64: a detective word game for Roblox

A stylized, mobile-first take on the playground game **"Concentration 64"**. Up to four suspects sit in an interrogation room and clap along to a beat while the chant plays:

> *"Concentration, sixty-four, no repeats, or hesitation…"*
> *"I'll go first, to my left, the category is…"*

Then everyone takes turns naming things in the category, on the beat. **Hesitate** (run out of time) or **repeat** a word and you're sent behind the **two-way mirror** to the Spectator Lounge. Last suspect standing cracks the case.

Everything is modern, strict-typed Luau (`--!strict`), server-authoritative, and split into small modules.

---

## Features

| | |
|---|---|
| 🥁 **Shared beat** | One `RhythmSync` table; every client derives the beat from `workspace:GetServerTimeNow()`. Visual metronome, ticks, the beat-by-beat chant and turn deadlines line up on every device whatever its ping. The tempo rises each lap around the table. |
| ⌨️ **Custom answer box** | Floating bottom-centre text box (never the Roblox chat). Auto-focuses on your turn, streams live typing to the **TV SurfaceGui** in the room, and submits with Enter, the phone's Done key, or SEND. |
| ⏱️ **No hesitation** | Each turn opens on a beat and lasts N beats (minimum 3.5 s). The server enforces the deadline, with a small latency grace. |
| 🔁 **No repeats** | Words are compared by a canonical key, so `Ice-Cream`, `ice cream!` and `the ice creams` all count as the same word. |
| 🪞 **Two-way mirror** | Eliminated, benched (5th and 6th in a full server) and late-joining players watch from a dark lounge. The mirror is restyled locally per client: a mirror for suspects, glass for spectators. |
| 💰 **Monetization** | Custom Category (Game Pass), Skip Turn, Bribe the Detective (revive) and Force Caller (Developer Products), all validated server-side, idempotent, and never losing a player's Robux. |
| 🛡️ **Safe by default** | All player text is filtered with TextService. Every remote is type-checked and rate-limited, and the client only ever *requests*. |
| 📱 **Mobile UX** | High-contrast "case file" UI, 44 px+ touch targets, safe-area insets, touch controls hidden while seated, and the camera FOV adapts to portrait screens. |
| 🧱 **Graybox included** | Press Play on an empty Baseplate and a working map is built for you. |

---

## Project layout

```
src/
├── ReplicatedStorage/Shared/          (shared by server + client)
│   ├── Config.lua                     every tunable: timings, BPM, product IDs, audio
│   ├── Categories.lua                 preset categories for free players
│   ├── Remotes.lua                    network contract: creates/fetches remotes + payload types
│   ├── Rhythm.lua                     beat math + chant lyrics (pure functions)
│   └── WordRules.lua                  answer cleaning, validation, "no repeats" key
├── ServerScriptService/
│   ├── GameManager.server.lua         ★ round loop / phase machine / remote handlers
│   └── Server/
│       ├── MonetizationService.lua    ProcessReceipt, pass ownership, server-side prompts
│       ├── PlayerDataService.lua      DataStore tokens + wins (atomic, idempotent)
│       ├── TextFilterService.lua      TextService filtering + live-typing coalescer
│       ├── RoomService.lua            seats, teleports, TV + lobby board text
│       ├── MapBuilder.lua             graybox map (only if none exists)
│       └── RateLimiter.lua            token-bucket limiter for remotes
└── StarterPlayer/StarterPlayerScripts/
    ├── ClientManager.client.lua       ★ client entry: state mirror + event routing
    └── Client/
        ├── UIKit.lua                  design system (colours, fonts, components)
        ├── HUDController.lua          header, turn indicator, timer, roster, banners
        ├── RhythmController.lua       metronome, ticks, chant, music speed
        ├── CameraController.lua       room / spectator cameras + mirror trick
        ├── AnswerController.lua       answer box, live typing, Skip button
        ├── CategoryController.lua     the Caller's picker (+ custom entry)
        └── PurchaseController.lua     bribe modal, Force Caller, prices
docs/STUDIO_SETUP.md                   install, Workspace guide, monetization, testing
default.project.json                   Rojo project
```

**Install:** `rojo serve` (or `rojo build -o Concentration64.rbxlx`), or copy the files by hand using the table in **[docs/STUDIO_SETUP.md](docs/STUDIO_SETUP.md)**.

---

## The round loop

```
Lobby ─► Intermission ─► Seating ─► Chant ─► CategoryPick ─► Turns ─► RoundOver ─► (Lobby)
```

| Phase | Server (GameManager) | Client |
|---|---|---|
| **Lobby** | waits for `MinToStart` players (1 in Studio) | lobby dock, Force Caller button |
| **Intermission** | 15 s countdown, cancelled if players drop | countdown |
| **Seating** | picks up to 4 (Force Caller first, then last round's bench, then random), seats them, sends the rest to the lounge | camera blends to the room or lounge shot |
| **Chant** | chooses the Caller, starts the beat, mirrors the chant on the TV | count-in, then the chant syllable-by-syllable on the beat |
| **CategoryPick** | offers 8 random presets (or custom text with the pass); random pick on timeout | picker for the Caller, "THE CATEGORY IS…" for everyone else |
| **Turns** | Caller first, then to the left; validates, filters, repeat-checks; timeout means hesitation; bribe window; elimination and teleport | answer box, live TV, timer, results |
| **RoundOver** | winner gets +1 saved Win, then everyone returns to the lobby | "CASE CLOSED" |

---

## ReplicatedStorage setup: the remote contract

`Shared/Remotes.lua` creates these under `ReplicatedStorage.Remotes` at server start. Payload types are exported from the same module.

| Remote | Type | Direction | Payload | Purpose |
|---|---|---|---|---|
| `PhaseChanged` | RemoteEvent | S → all | `(phase, data)` | phase machine |
| `RhythmSync` | RemoteEvent | S → all | `{bpm, startTime, beatsPerBar}?` | **rhythm sync**: start, retime or stop the beat |
| `RosterChanged` | RemoteEvent | S → all | `{userId, name, seat, status}[]` | seats and statuses |
| `TurnStarted` | RemoteEvent | S → all | `{userId, startsAt, endsAt, …}` | whose turn, and its deadline |
| `AnswerResult` | RemoteEvent | S → all | `{result, word?, saidBy?, bribeEndsAt?}` | Accepted / Repeat / Timeout / Skipped / Revived / Eliminated |
| `AnswerRejected` | RemoteEvent | S → typist | `reason` | invalid or filtered; timer keeps running |
| `CategoryPrompt` | RemoteEvent | S → Caller | `{options, endsAt, canCustom}?` | open or close the picker |
| `CategoryChosen` | RemoteEvent | S → all | `{category, callerName, custom}` | |
| `BribeOffer` | RemoteEvent | S → failed player | `{endsAt, reason}?` | open or close the bribe modal |
| `WalletChanged` | RemoteEvent | S → owner | tokens, enabled products, pass, armed | button labels |
| `Notify` | RemoteEvent | S → player(s) | `(message, kind)` | toasts |
| `TypingUpdate` | **UnreliableRemoteEvent** | C → S | `(seq, draft)` | **live typing** (newest wins) |
| `SubmitAnswer` | RemoteEvent | C → S | `answer` | |
| `SubmitCategory` | RemoteEvent | C → S | `("Preset", index)` / `("Custom", text)` | |
| `RequestPurchase` | RemoteEvent | C → S | `"SkipTurn" \| "Revive" \| "ForceCaller" \| "CustomCategory"` | **purchase validation** |
| `DeclineBribe` | RemoteEvent | C → S | none | "Accept fate" |
| `GetSnapshot` | RemoteFunction | C → S | returns full state | late joiners catch up |

### How the beat stays in sync
The server sends **one** table per tempo: `{ bpm = 104, startTime = <server clock>, beatsPerBar = 4 }`. Every client computes `beat = (GetServerTimeNow() − startTime) · bpm / 60` each frame. Turn deadlines are server-clock timestamps too, so the timer you see is the timer the server enforces. A tempo change is scheduled on the next beat of the old tempo, so the groove never stutters.

---

## Monetization flow

```
[Client button] ─RequestPurchase(key)─► GameManager validates context (your turn? your bribe? not seated?)
                                          ├─ owns a token? ─► spend it now (no prompt)
                                          └─ else ─► MonetizationService.promptProduct (server-side prompt)
                                                       │  deadline HELD while the dialog is open
Roblox ─ProcessReceipt─► PlayerDataService.grantPurchase: token +1 & PurchaseId saved in ONE UpdateAsync
                         └─► TokenGranted ─► still relevant? apply (skip / revive / arm) : keep for later
```

| Product | Where | When it's allowed |
|---|---|---|
| **Custom Category** (pass) | Caller's picker ("🔓 TYPE YOUR OWN CATEGORY") | any time; unlocks live mid-pick |
| **Skip Turn** | "⏭ SKIP" above the answer box | only during your own turn |
| **Bribe the Detective** | modal with a 5 s fuse after you fail | only during your bribe window |
| **Force Caller** | "📣 CALL NEXT" in the lobby or lounge dock | when you're not seated in a live round |

---

## Configuration highlights (`Shared/Config.lua`)

| Setting | Default | |
|---|---|---|
| `Players.MaxActive` / `MinToStart` | 4 / 2 | seats; players needed to start |
| `Rhythm.StartBpmChoices` | 88–112 | random tempo per round |
| `Rhythm.BpmIncreasePerLap` / `MaxBpm` | +6 / 140 | speeds up each lap |
| `Turn.Beats` / `Turn.MinSeconds` | 10 / 3.5 s | turn length |
| `Words.TreatPluralsAsRepeats` | true | `cat` → `cats` is a repeat |
| `Bribe.WindowSeconds` | 5 | revive offer |
| `Audio.*` | built-in sounds | swap in your own beat, or add a backing loop (`Music.SoundId`, played at the round's BPM) |

---

## Verified

- Strict type checking (`luau-lsp analyze`, Roblox API definitions): **0 errors**.
- `rojo build` produces a valid place.
- Headless simulation: the real server and client scripts were run against a mock engine (fake clock, network latency, DataStore, receipts, text filter) through full rounds. That covered Force Caller, repeat → bribe → revive with the deadline held, filtered words, timeout → lounge, paid skip, wins persisted, duplicate receipt ignored, a 6-player server with bench priority, players leaving mid-turn and mid-pick, late joiners, respawns, and spoofed remote arguments.

## Ideas for next steps

- **"Objection!" vote**: let players challenge an answer that doesn't fit the category.
- **ProfileStore** for session-locked data in large live games.
- Cosmetic rewards: detective hats, badges for 10 or 100 wins.
- A real recorded clapping loop in `Config.Audio.Music`.

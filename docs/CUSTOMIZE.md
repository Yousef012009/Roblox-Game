# Customizing Concentration 64

## 1. The baked place file (start here)

`Concentration64_Baked.rbxl` already contains the whole map, so you can see and edit it **without pressing Play**:

| What | Where in the Explorer | Notes |
|---|---|---|
| Lobby, elevators | `Workspace › Map › Lobby`, `Workspace › Map › Queues › Queue01…04` | Move, recolour, delete or add anything |
| Interrogation room + spectator lounge | `ServerStorage › InterrogationModuleTemplate` | Every match clones this, so edit it once and every room changes. To see it, drag it into Workspace, edit it, then drag it back into ServerStorage |
| Lighting / fog / colour grade | `Lighting` (+ `Lighting › C64Grade`) | Plain Roblox properties |

The map is **locked** (the attribute `Locked = true` on `Workspace.Map`). Pressing Play keeps your edits, and future script updates never regenerate it.

**Keep these names**, because the scripts find these objects by name (full list in `ReplicatedStorage › Shared › Names`):
- `LobbySpawn`, `LobbyReturnPoints`, `Queue01…04` and every `Queue0N_…` part inside them
- In the template: `ModuleRoot`, `Seats › SeatAnchor01…04`, `TVScreen` (and its `TVGui` labels `Header`, `Category`, `Speaker`, `Answer`, `Footer`), `BulbPivot`, `BulbAssembly › Bulb › BulbLight`, `TwoWayMirror`, `RoomLights`, `SpectatorSpawns › SpectatorSpawn01…04`, `CameraAnchors › …`

Everything else (props, walls, signs, lights) is decoration: change it freely.

Handy tips:
- **Moving a camera shot:** fly the Studio camera to the view you want, then run this in the Command Bar (View → Command Bar):
  `game.ServerStorage.InterrogationModuleTemplate.CameraAnchors.InterrogationCamera.CFrame = workspace.CurrentCamera.CFrame`
  (with the template dragged into Workspace at the time). The same works for any anchor.
- **Starting over:** to throw away your map edits and regenerate, run this in the Command Bar, then save:
  `require(game.ServerScriptService.MapGen.MapBuilder).Bake()`
- **Colours of a freshly generated map:** `ServerScriptService › MapGen › Palette`.

## 2. Gameplay settings: `ReplicatedStorage › Shared › Config`

| Setting | What it does |
|---|---|
| `Queue.Capacity`, `Queue.MinPlayersToStart` | Players per elevator / needed to start (Studio allows 3) |
| `Match.RoundsPerMatch` | `0` = everyone is Caller once; `1` = single round |
| `Match.CategoryTimeoutSeconds`, `Match.FallbackCategories` | Caller's time to type a category / what's used if they don't |
| `Turn.BeatsPerTurn`, `Turn.MinTurnSeconds` | How long each answer turn is |
| `Judging.TimeoutSeconds` | How long the Caller has to press VALID / GIBBERISH |
| `Text.*Length` | Character limits for categories and answers |
| `Music.SoundId` | Your uploaded song: `"rbxassetid://123…"` |
| `Chant` | The chant syllables and which beat each one lands on |
| `Camera.*`, `Visual.*` | FOV, bulb swing size, flicker, static |

## 3. Changing the words on screen

| Text | File | Search for |
|---|---|---|
| TV screen in the room ("IS THE CALLER", "ELIMINATED", "CASE CLOSED"…) | `ServerScriptService › Server › Match` | `setTV` / the quoted words |
| Popups, notices ("Caller didn't judge in time"…) | `ServerScriptService › Server › Match` | `Notice` |
| Chant words | `ReplicatedStorage › Shared › Config` → `Chant`, `ChantStingText` | |
| Intro "INTERROGATION ROOM n" | `StarterPlayerScripts › Client › IntroOverlay` | `INTERROGATION ROOM` |
| Caller reveal, winner toast | `StarterPlayerScripts › ClientManager` | `IS THE CALLER`, `CASE CLOSED` |
| Category box | `Client › CategoryPanel` | |
| Answer box | `Client › AnswerBox` | `YOUR TURN` |
| VALID / GIBBERISH panel | `Client › JudgePanel` | |
| Top HUD | `Client › GameHUD` | |
| ELIMINATED overlay | `Client › EliminationOverlay` | |
| Spectator bar | `Client › SpectatorHUD` | |
| Winner screen | `Client › VictoryScreen` | |
| Queue popup in the elevator (party menu: players / bots, START NOW, LEAVE) | `Client › PartyMenu` | |
| Signs in the map | the baked parts themselves (select a sign → its `SurfaceGui › TextLabel` → `Text`) | |

Only change text inside quotes `"…"`. If a line has `{something}` inside backticks, keep the `{…}` part: that's where a name or number gets inserted.

UI colours and fonts for the whole interface: `StarterPlayerScripts › Client › UIKit`.

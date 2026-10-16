# Studio Setup Guide

This guide covers four things: getting the scripts into Studio, building (or keeping) the map, wiring up monetization, and testing.

> **Fastest path:** install the scripts (section 1) and press **Play** on an empty Baseplate. With `Config.Map.AutoBuildGraybox = true` the server builds a working graybox lobby, interrogation room, two-way mirror, spectator lounge and camera points, all with the names below. Decorate from there.

---

## 1. Installing the scripts

### Option A: Rojo (recommended)

```bash
rojo serve           # then click "Connect" in the Rojo Studio plugin
# or build a place file:
rojo build -o Concentration64.rbxlx
```

### Option B: Manual copy and paste

Create each object in Studio (right-click the parent, then **Insert Object**), name it exactly as shown, and paste in the file's contents.

| Roblox location | Object type | Name | Source file |
|---|---|---|---|
| ReplicatedStorage | **Folder** | `Shared` | |
| ReplicatedStorage › Shared | ModuleScript | `Config` | `src/ReplicatedStorage/Shared/Config.lua` |
| ReplicatedStorage › Shared | ModuleScript | `Categories` | `…/Shared/Categories.lua` |
| ReplicatedStorage › Shared | ModuleScript | `Remotes` | `…/Shared/Remotes.lua` |
| ReplicatedStorage › Shared | ModuleScript | `Rhythm` | `…/Shared/Rhythm.lua` |
| ReplicatedStorage › Shared | ModuleScript | `WordRules` | `…/Shared/WordRules.lua` |
| ServerScriptService | **Script** | `GameManager` | `src/ServerScriptService/GameManager.server.lua` |
| ServerScriptService | **Folder** | `Server` | |
| ServerScriptService › Server | ModuleScript | `PlayerDataService` | `…/Server/PlayerDataService.lua` |
| ServerScriptService › Server | ModuleScript | `MonetizationService` | `…/Server/MonetizationService.lua` |
| ServerScriptService › Server | ModuleScript | `TextFilterService` | `…/Server/TextFilterService.lua` |
| ServerScriptService › Server | ModuleScript | `RoomService` | `…/Server/RoomService.lua` |
| ServerScriptService › Server | ModuleScript | `MapBuilder` | `…/Server/MapBuilder.lua` |
| ServerScriptService › Server | ModuleScript | `RateLimiter` | `…/Server/RateLimiter.lua` |
| StarterPlayer › StarterPlayerScripts | **LocalScript** | `ClientManager` | `src/StarterPlayer/StarterPlayerScripts/ClientManager.client.lua` |
| StarterPlayer › StarterPlayerScripts | **Folder** | `Client` | |
| StarterPlayerScripts › Client | ModuleScript | `UIKit` | `…/Client/UIKit.lua` |
| StarterPlayerScripts › Client | ModuleScript | `HUDController` | `…/Client/HUDController.lua` |
| StarterPlayerScripts › Client | ModuleScript | `RhythmController` | `…/Client/RhythmController.lua` |
| StarterPlayerScripts › Client | ModuleScript | `CameraController` | `…/Client/CameraController.lua` |
| StarterPlayerScripts › Client | ModuleScript | `AnswerController` | `…/Client/AnswerController.lua` |
| StarterPlayerScripts › Client | ModuleScript | `CategoryController` | `…/Client/CategoryController.lua` |
| StarterPlayerScripts › Client | ModuleScript | `PurchaseController` | `…/Client/PurchaseController.lua` |

**ReplicatedStorage › Remotes needs no setup.** `Shared/Remotes` creates every RemoteEvent and RemoteFunction when the server starts. If you make them by hand, it reuses yours.

### Game Settings

- **Places → Max Players:** `6`
- **Security → Enable Studio Access to API Services:** on, if you want saved tokens and wins while testing. Off is fine: the game falls back to memory-only data and says so in the Output window.
- **Avatar:** R15 or R6 both work.

---

## 2. Workspace setup

The scripts look objects up **by name**. Keep this exact hierarchy:

```
Workspace
├── Lobby                       (Model)
│   ├── LobbySpawn              (SpawnLocation)  Neutral ✓, Duration 0
│   └── StatusBoard             (Part, optional) live "NEXT CASE IN 12" text on its Front face
├── InterrogationRoom           (Model)
│   ├── Seats                   (Folder)
│   │   ├── Seat1               (Seat)  ← the Caller can be any seat; play continues to the left
│   │   ├── Seat2               (Seat)
│   │   ├── Seat3               (Seat)
│   │   └── Seat4               (Seat)
│   ├── TVScreen                (Part)  Front face toward the seats and camera
│   └── TwoWayMirror            (Part)  the window between the room and the lounge
├── SpectatorLounge             (Model)
│   └── SpectatorSpawns         (Folder) 1–6 Parts, invisible, Front face toward the mirror
└── CameraPoints                (Folder)
    ├── RoomCam                 (Part)  invisible; its CFrame IS the seated players' camera
    └── SpectatorCam            (Part)  invisible; the spectators' camera, looking through the mirror
```

Anything else (walls, props, lights, decals) can be named however you like.

### Lobby
- **LobbySpawn** must be the only enabled `SpawnLocation` in the game. Set `Neutral = true` and `Duration = 0` (no force field).
- **StatusBoard** (optional): any Part. The server adds a SurfaceGui to its **Front** face showing "WAITING FOR SUSPECTS 1/2" or "NEXT CASE IN 12". To style it yourself, add a `SurfaceGui` named `BoardGui` that contains a `TextLabel` named `Status`.

### Interrogation Room
- **Seats.** Use `Seat` objects, **Anchored**, named `Seat1`…`Seat4`. The number is the **turn order**: each player's next turn goes to the seat on their **left**. Around a table, that means numbering the seats **clockwise when viewed from above**. In a row facing the mirror (like the graybox), number them left to right *as seen from the mirror*.
- Fewer than 4 seats works too. Rounds then use at most that many players.
- Seated players are locked in (`WalkSpeed`, `JumpPower` and `JumpHeight` set to 0) and re-seated automatically if they jump out or respawn. Anyone else who sits in a seat is kicked out of it.
- **TVScreen.** A flat Part around 14 × 7.9 studs (16:9). Make sure its **Front** face points at the players and the camera. Quick check: the `TVGui` the server adds shows on the Front face, so if your TV looks blank in Play mode, rotate the part 180°. To restyle it, add a `SurfaceGui` named `TVGui` with four `TextLabel`s named **Header**, **Speaker**, **Body** and **Footer**. The server writes text into them; you control the look.
- **TwoWayMirror.** A Part filling the window between the room and the lounge (`Material = Glass`). Each client restyles it **locally**: seated players see an opaque, shiny mirror, spectators see dim, see-through glass. For the best illusion, light the room brightly and keep the lounge dark.

### Spectator Lounge
- Build it behind the mirror. **SpectatorSpawns** holds invisible, non-colliding, Anchored Parts placed on the floor. Eliminated players, benched players (5th and 6th in a full server) and late joiners are teleported to a random one.
- Add a railing a few studs back from the glass so spectators can't crowd in front of the spectator camera.

### CameraPoints
Both cameras are fixed shots, which works well on mobile because nobody has to fight a camera while typing.

The easy way to place them:
1. In Studio, fly the editor camera to the exact shot you want.
2. In the **Command Bar** run:
   ```lua
   workspace.CameraPoints.RoomCam.CFrame = workspace.CurrentCamera.CFrame
   ```
   (and the same with `SpectatorCam` from inside the lounge, looking through the mirror).
3. Make both parts `Transparency = 1`, `CanCollide = false`, `CanQuery = false`, `Anchored = true`.

**RoomCam** should show all four seats plus the TV. On narrow or portrait phones the client widens the field of view automatically to keep the same horizontal framing.

### Using the graybox as a template
Press **Play**, then select `Lobby`, `InterrogationRoom`, `SpectatorLounge` and `CameraPoints` in the Explorer and copy them (Ctrl+C). Press **Stop** and paste them into Workspace (Ctrl+V). Then set `Config.Map.AutoBuildGraybox = false` and start decorating.

---

## 3. Monetization setup

| Config key | Create in Creator Dashboard as | What it does |
|---|---|---|
| `GamePasses.CustomCategory` | **Pass** | Caller can type any category (it is filtered before anyone sees it) |
| `Products.SkipTurn` | **Developer Product** | Skip your turn safely. Button above the answer box |
| `Products.Revive` | **Developer Product** | "Bribe the Detective": 5-second offer after you fail |
| `Products.ForceCaller` | **Developer Product** | Guarantees you are the Caller next round. Button in the lobby or lounge |

1. Creator Dashboard → your experience → **Monetization → Passes / Developer Products** → create each one.
2. Copy each ID into `ReplicatedStorage/Shared/Config.lua`.
3. Publish.

How purchases flow:
- The client button only *asks* (`Remotes.RequestPurchase`). The server checks the request is legal right now (your turn, your bribe window, or not seated) and then either spends a saved token or opens the Robux prompt itself.
- `ProcessReceipt` turns each purchase into a **saved token**. The token and the PurchaseId are written in one atomic `UpdateAsync`, so a re-delivered receipt can never grant twice.
- If the purchase still applies when the receipt lands, it is used straight away. If it is too late (the turn ended), the token stays in the player's wallet and the button shows `×1` next time. **Nobody ever loses Robux.**
- While a server-opened purchase dialog is on screen, a running turn or bribe deadline is **held** (up to `Config.Purchases.PromptHoldMaxSeconds`), so a slow dialog never costs a paying player their seat. Late answers are still rejected, so the hold gives no extra thinking time.

> Only one script in a game may set `MarketplaceService.ProcessReceipt`. Here that is `MonetizationService`. If you add more products, add them to its handler rather than setting the callback a second time.

**Testing before the products exist:** while an ID is still `0`, Studio "buys" it instantly for free (`Config.Debug.SimulateMissingProductsInStudio`). Live servers hide any button whose ID is `0`. Once real IDs are set, Studio shows Roblox's real test-purchase dialog (no Robux is charged).

---

## 4. Testing checklist

1. **Play Solo.** With `AllowSoloInStudio`, a 1-player round starts after the 15-second intermission. Check the chant, the category picker, typing, a repeat, a timeout and the lounge teleport.
2. **Test → Clients and Servers → Local Server, 3 players.** Check the turn order goes left, the live typing on the TV, the spectator view through the mirror, and the bribe and skip flows.
3. **Phone emulator** (Test → Device): check portrait and landscape. The answer box sits bottom-centre, the thumbstick and jump button hide while you're seated, and the HUD stays clear of the notch.
4. **Publish and test in a live server.** Text filtering only works there (Studio returns text unchanged).

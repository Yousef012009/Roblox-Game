# Install & test in Roblox Studio

## With Rojo
1. `git pull` on branch `claude/roblox-detective-game-arch-pl3b8l`.
2. Studio: **File → New → Baseplate**.
3. In the project folder: `rojo serve`. In Studio: **Plugins → Rojo → Connect**.
4. Press **Play**. `MapGenerator` builds the lobby, 4 elevator queues and the interrogation room template. Takes a few seconds the first time.

Optional: to keep the map in the place file (faster startup), stop playing and run this in the Command Bar:
`require(game.ServerScriptService.MapGen.MapBuilder).Build(true)` then save.

## Settings
- Home → Game Settings → Places → **Max Players: 16** (up to 4 matches at once).
- Music: Creator Dashboard → Audio → upload the mp3 → paste the id into
  `ReplicatedStorage/Shared/Config` → `Config.Music.SoundId = "rbxassetid://<id>"`.
  Empty = silent mode (everything else still works).

## Multiplayer test
Test tab → Clients and Servers → **Local Server**, 3 or 4 players → Start.
(Studio starts a match with 3 players; live servers need 4.)

Checklist:
1. Walk players into **Queue01**: display counts 1/4, 2/4… Walk one out: count drops.
2. Full queue → doors close → everyone appears seated in their own room.
3. A Caller is picked and types any category.
4. Chant plays on the beat, bulb swings, then the category is revealed.
5. Answerers type in the bottom box on their turn; the answer shows on the TV.
6. Caller taps **VALID** or **GIBBERISH / WRONG**.
7. Repeat an accepted answer (e.g. "Apple" then "apple!") → auto-eliminated.
8. Let the timer run out → eliminated for hesitation.
9. Eliminated players land behind the mirror; spectator camera buttons work.
10. Last answerer wins the round; Caller rotates; winner screen; everyone returns to the lobby.
11. Fill Queue01 and Queue02 at the same time → two separate rooms run.
12. Device emulator (Test → Device) for phone layout.

Tune anything in `Shared/Config` (turn length, rounds per match, timeouts).

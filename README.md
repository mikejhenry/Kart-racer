# Kart Racer

An arcade kart racer made with **Godot 4.5** (GDScript). It runs on desktop, in the browser, and on phones.

**Play in your browser:** https://mikejhenry.github.io/kart-racer/

## What's in it

- One closed-loop track with curbs, barriers, a start gate and trees
- Arcade kart handling, with drifting. Hold a drift until the sparks turn blue, then orange, and let go for a mini-turbo.
- 5 AI racers. They ease off for corners, use items, and get unstuck by themselves. Light rubber-banding keeps races close.
- **Power-ups** from item boxes. Karts further back get better odds.
  - **Nitro**: a speed boost that also ignores the off-road slowdown
  - **Missile**: follows the track and homes in on the next kart ahead
  - **Oil slick**: dropped behind you, and spins out whoever hits it
- 3-lap races with a countdown, positions, lap and final-lap callouts, a wrong-way warning and a results screen

## Controls

| Action | Keyboard | Gamepad | Touch |
|---|---|---|---|
| Accelerate | W / ↑ | A / RT | automatic |
| Brake / reverse | S / ↓ | B / LT | BRAKE |
| Steer | A D / ← → | Left stick / D-pad | ◀ ▶ (slide between them) |
| Drift | Space / Shift | RB | DRIFT |
| Use item | E / Ctrl | X / LB | ITEM |
| Reset to track | R | Y | — |

Touch controls appear automatically on touch screens. To preview them on desktop, set `FORCE_TOUCH_UI = true` in `scripts/game_input.gd`.

## Running it

1. Install [Godot 4.5](https://godotengine.org/download). Use the standard build, not .NET, because C# can't export to the web.
2. In Godot, choose **Import** and pick `project.godot`.
3. Press **F5**.

## Exporting

- **Web:** Every push to `main` builds the web version and publishes it to GitHub Pages (`.github/workflows/web-demo.yml`). To export by hand, go to **Editor > Manage Export Templates**, install the templates, then use **Project > Export > Web**. The export is single-threaded, so it runs on any static host, including itch.io and GitHub Pages, without special server headers.
- **Android:** Install the Android SDK and JDK 17 and set their paths under **Editor Settings > Export > Android**. Then use **Project > Export > Android**. The preset builds an APK signed with Godot's debug key.
- **iOS:** Requires a Mac with Xcode. Add an iOS preset and export an Xcode project.

## Project layout

All game objects are built in code, so there is only one scene file.

| File | Purpose |
|---|---|
| `main.tscn` / `scripts/main.gd` | Race setup, countdown, laps, positions, finish |
| `scripts/track.gd` | Generates the track from `CONTROL_POINTS`: road, walls, ground, gate, item boxes, trees |
| `scripts/kart.gd` | Kart physics, drifting, boosts, items, spin-outs and visuals |
| `scripts/player_brain.gd` / `scripts/ai_brain.gd` | Turn player input or AI decisions into kart inputs |
| `scripts/item_box.gd`, `missile.gd`, `oil_slick.gd` | Power-ups |
| `scripts/chase_camera.gd` | Follow camera |
| `scripts/hud.gd` / `scripts/touch_controls.gd` | HUD and on-screen buttons |
| `scripts/game_input.gd` | Autoload: input actions, touch and mobile detection |

## Ideas for next steps

- Sound effects and music
- More tracks (change `CONTROL_POINTS`, or add elevation)
- Character and kart selection, using your own models
- More items: a shield, a lightning-style item for the leader, triple missiles
- Better AI: racing lines and drifting
- Local split-screen or online multiplayer

# Kart Racer

An arcade kart racer made with **Godot 4.5** (GDScript), with a small **Cloudflare** server for online play. It runs on desktop, in the browser, and on phones.

**Play in your browser:** https://mikejhenry.github.io/Kart-racer/

## Modes

- **Grand Prix:** 3 laps against 5 computer karts, with items.
- **Time Trial:** 3 laps solo, with no items. You race a see-through **ghost** of your best run. Your best time and best lap are saved on the device. Finished times go to the online **leaderboard**.
- **Multiplayer:** create a **private lobby** and share its 5-letter code. Up to 6 players can join. The host starts the race, and items work between players. Afterwards everyone returns to the lobby for another race.

## Features

- Start screen with name entry, a mode picker, leaderboards and settings
- Drifting with mini-turbos. Hold a drift until the sparks turn blue, then orange, and let go.
- **Power-ups** from item boxes. Karts further back get better odds.
  - **Nitro:** a speed boost that also ignores the off-road slowdown
  - **Missile:** follows the track and homes in on the next kart ahead
  - **Oil slick:** dropped behind you, and spins out whoever hits it
- **Tilt steering** on phones and tablets. Turn it on in Settings, which also has a sensitivity slider, an invert option and a live tilt meter.
- Countdown, positions, lap and final-lap callouts, a race timer, a wrong-way warning and a pause menu

## Controls

| Action | Keyboard | Gamepad | Touch |
|---|---|---|---|
| Accelerate | W / ↑ | A / RT | automatic |
| Brake / reverse | S / ↓ | B / LT | BRAKE |
| Steer | A D / ← → | Left stick / D-pad | ◀ ▶, or tilt the phone |
| Drift | Space / Shift | RB | DRIFT |
| Use item | E / Ctrl | X / LB | ITEM |
| Reset to track | R | Y | — |
| Pause | Esc / P | Start | II button |

On iPhone and iPad, tilt steering needs permission. After turning it on, tap the screen once and choose **Allow**.

## Setting up online play (one time)

The `Deploy` workflow deploys the server and the game together on every push to `main`. Without the two Cloudflare secrets below, the game still deploys, but with online play turned off.

1. Create a free account at [dash.cloudflare.com](https://dash.cloudflare.com). Open **Workers & Pages** once so Cloudflare sets up your `workers.dev` subdomain.
2. **Account ID:** go to **Workers & Pages** and copy the *Account ID* shown on the right.
3. **API token:** go to **My Profile → API Tokens → Create Token**, choose the **Edit Cloudflare Workers** template, then **Create**, and copy the token.
4. In this repo, go to **Settings → Secrets and variables → Actions → New repository secret** and add:
   - `CLOUDFLARE_ACCOUNT_ID`
   - `CLOUDFLARE_API_TOKEN`
5. Go to **Actions → Deploy → Run workflow**. The server URL is written into the game automatically.

Everything runs on Cloudflare's free plan, which allows roughly 100,000 requests per day. Each kart sends 10 updates per second during a race, which is plenty for playing with friends.

## Running locally

1. Install [Godot 4.5](https://godotengine.org/download). Use the standard build, not .NET.
2. In Godot, choose **Import**, pick `project.godot`, and press **F5**.
3. Optional, for online play: in `server/`, run `npm install` and then `npx wrangler dev`. Start the game with the environment variable `KART_SERVER=http://127.0.0.1:8787`, or put that address in `scripts/server_config.gd`.

## Exporting

- **Web:** handled by the workflow. To export by hand, use **Project → Export → Web**. The export is single-threaded, so it works on any static host.
- **Android:** install the Android SDK and JDK 17, then use **Project → Export → Android**. Tilt steering uses the phone's gravity sensor.
- **iOS:** requires a Mac with Xcode.

## Project layout

| Path | Purpose |
|---|---|
| `menu.tscn` / `scripts/menu.gd` | Start screen, multiplayer lobby, leaderboards, settings |
| `race.tscn` / `scripts/race.gd` | A race in any mode: countdown, laps, positions, ghost, online sync, results |
| `scripts/game.gd` | Autoload: mode, name, personal bests, ghost and settings storage |
| `scripts/net.gd` | Autoload: leaderboard (HTTPS) and lobbies (WebSocket) |
| `scripts/game_input.gd` | Autoload: input actions, touch detection, tilt steering |
| `scripts/track.gd` | Builds the track from `CONTROL_POINTS` |
| `scripts/kart.gd` | Kart physics, drifting, items and visuals, plus remote and ghost karts |
| `scripts/player_brain.gd` / `ai_brain.gd` | Player input and AI driving |
| `scripts/item_box.gd`, `missile.gd`, `oil_slick.gd` | Power-ups |
| `scripts/hud.gd`, `touch_controls.gd`, `chase_camera.gd`, `world.gd` | HUD, touch buttons, camera, sky and light |
| `server/` | Cloudflare Worker: `Lobby` and `Leaderboard` Durable Objects |

### Server API

| Request | What it does |
|---|---|
| `GET /leaderboard?track=circuit_1` | Top 10, best time per name |
| `POST /leaderboard` `{track, name, time}` | Submit a time and get back your rank |
| `POST /lobby` | Create a private lobby and get `{code}` |
| `GET /lobby/CODE` | Check whether a lobby exists, its phase and player count |
| `GET /lobby/CODE/ws?name=…` | WebSocket: lobby updates, race start, kart states, items, finishes |

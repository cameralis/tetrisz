# Tetris

Guideline-style Tetris with 1v1 online multiplayer (WebRTC P2P with backend relay fallback) and a global leaderboard.

## Structure

- `app/` — Flutter app (iOS primary target, Android/web/macOS also build). Pure-Dart game engine in `app/lib/src/game/`, networking in `app/lib/src/net/`, UI in `app/lib/src/ui/`.
- `backend/` — Cloudflare Worker + Durable Objects (TypeScript, pnpm, wrangler). One `RoomDO` per room code: WebRTC signaling, shared-seed issuance, and relay fallback transport. One global `LeaderboardDO`: best-score-per-name top list (honest-client model — scores are self-reported by the app).

Production backend: `https://tetrisz-backend.unknown9806.workers.dev` (baked into the app as the `TETRIS_BACKEND_URL` default).

## Development

App (uses FVM):

```sh
cd app
fvm flutter pub get
fvm flutter test
fvm flutter run
```

Backend:

```sh
cd backend
pnpm install
pnpm dev        # wrangler dev on http://localhost:8787
pnpm test
pnpm deploy     # wrangler deploy (needs Cloudflare auth)
```

## Building releases

`scripts/build.sh` wraps the release flows:

```sh
scripts/build.sh macos              # build the macOS desktop app (App Sandbox off) and install to /Applications
scripts/build.sh ipa                # build + package the iOS App Store IPA (no upload)
scripts/build.sh testflight         # build + package + upload the iOS app to TestFlight
scripts/build.sh testflight --bump  # also bump the build number (X.Y.Z+N -> +N+1) and commit first
```

TestFlight uploads need an app-specific password for `apple@tear.one` — pass it as `ASC_APP_PW=…` or put it in `scripts/.asc_app_pw` (gitignored). The macOS build keeps App Sandbox disabled so WebRTC multiplayer works; the script aborts if the sandbox is ever re-enabled.

## Local 1v1 end-to-end test

1. `cd backend && pnpm dev`
2. `cd app && fvm flutter run -d web-server --web-port 7357 --dart-define=TETRIS_BACKEND_URL=http://localhost:8787`
3. Open `http://localhost:7357` in two Chrome tabs/windows.
4. Tab 1: Versus → Create match → note the code. Tab 2: Versus → Join → enter code.
5. Both tabs count down and start with identical piece sequences; clears send garbage across.

The multiplayer transport starts on relay and promotes to P2P when the WebRTC data channel opens (visible in the in-game transport chip and on the Settings & Diagnostics page).

There is also a headless end-to-end suite that plays a full match (attack, garbage, win, rematch) over a real backend:

```sh
cd app && fvm flutter test test_live --dart-define=TETRIS_BACKEND_URL=http://localhost:8787
```

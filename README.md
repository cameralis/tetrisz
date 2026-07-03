# Tetris

Guideline-style Tetris with 1v1 online multiplayer (WebRTC P2P with backend relay fallback).

## Structure

- `app/` — Flutter app (iOS primary target, Android/web/macOS also build). Pure-Dart game engine in `app/lib/src/game/`, networking in `app/lib/src/net/`, UI in `app/lib/src/ui/`.
- `backend/` — Cloudflare Worker + Durable Object (TypeScript, pnpm, wrangler). One Durable Object per room code: WebRTC signaling, shared-seed issuance, and relay fallback transport.

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

## Local 1v1 end-to-end test

1. `cd backend && pnpm dev`
2. `cd app && fvm flutter run -d web-server --web-port 7357 --dart-define=TETRIS_BACKEND_URL=http://localhost:8787`
3. Open `http://localhost:7357` in two Chrome tabs/windows.
4. Tab 1: Versus → Create match → note the code. Tab 2: Versus → Join → enter code.
5. Both tabs count down and start with identical piece sequences; clears send garbage across.

The multiplayer transport starts on relay and promotes to P2P when the WebRTC data channel opens (visible in the in-game transport chip and on the Settings & Diagnostics page).

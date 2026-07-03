# Tetris Implementation Tasks

## Completed Slices

1. [x] Project setup
   - [x] Initialize git.
   - [x] Install/use latest stable Flutter through FVM.
   - [x] Scaffold Android, iOS, web, and macOS Flutter targets.
   - [x] Add repository hygiene and task tracking.

2. [x] Core game engine
   - [x] Model a 10x20 visible playfield plus 20 hidden buffer rows.
   - [x] Add all seven tetrominoes with guideline colors and spawn states.
   - [x] Implement 7-bag random generation and next queue.
   - [x] Implement SRS rotation and wall kicks.
   - [x] Implement movement, hard drop, soft drop, hold, ghost piece, lock delay, line clears, level progression, scoring, combos, back-to-back, perfect clears, and top-out conditions.
   - [x] Cover the engine with deterministic unit tests.

3. [x] Flutter game surface
   - [x] Render the board using Flutter custom painting.
   - [x] Render active, locked, ghost, hold, and preview pieces.
   - [x] Add score, level, line, combo, and game-over HUD.
   - [x] Add restart/pause controls.

4. [x] Touch controls and audio
   - [x] Swipe left/right to shift.
   - [x] Tap right/left side to rotate clockwise/counter-clockwise.
   - [x] Swipe down for locking hard drop.
   - [x] Long press for non-locking soft drop.
   - [x] Swipe up for hold.
   - [x] Include the Korobeiniki music asset.

5. [x] Verification and release state
   - [x] Run formatting and static analysis.
   - [x] Run Flutter tests.
   - [x] Run at least one real device/emulator smoke test when available.
   - [x] Commit each completed slice with semantic commit messages.

## Verification Log

- `fvm dart format lib test`
- `fvm flutter analyze`
- `fvm flutter test`
- `fvm flutter build web`
- `fvm flutter run -d 097A87F7-D9B9-40D7-93D2-FCDE71516CF8 --debug`
- iOS simulator screenshot: `/tmp/tetris-ios-sim-final.png`

6. [x] 1v1 online multiplayer (monorepo: `backend/` Cloudflare Worker + DOs)
   - [x] Engine: garbage queue, bottom-insert rows with per-chunk hole, attack table (B2B/combo/PC), cancel-then-send, drainable event stream, seed-isolated garbage RNG.
   - [x] Backend: RoomDO per room code — pairing, shared seed issuance, WebRTC signaling passthrough, opaque relay fallback, rematch handshake, expiry alarms (WebSocket Hibernation API).
   - [x] Net layer: RoomClient (reconnect + buffering + RTT), game protocol with seq dedup, RelayTransport + P2pTransport + FailoverTransport (promote/demote), VersusSession orchestrator.
   - [x] WebRTC: host-offers data channel, STUN only (relay IS the fallback; no TURN), ICE-state driven failover.
   - [x] UI: Home menu, lobby (create/join by code), opponent board mirror, garbage meter, transport chip, countdown + win/lose/rematch overlays; versus disables pause/persistence/high score.
   - [x] Diagnostics page: backend reachability + STUN probe ("P2P likely available" / "relay-only likely").
   - [x] Global leaderboard: LeaderboardDO (best per name, top 100), auto-submit on solo game over, leaderboard page with display name.
   - [x] iOS: Podfile/deployment target 14.0, WebRTC usage-description strings.
   - [x] Verification: engine + net unit tests, backend vitest in workerd, live e2e (`app/test_live/`) against local wrangler dev AND deployed production worker.

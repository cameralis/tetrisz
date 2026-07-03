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

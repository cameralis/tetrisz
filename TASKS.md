# Tetris Implementation Tasks

## Completed/Planned Slices

1. Project setup
   - Initialize git.
   - Install/use latest stable Flutter through FVM.
   - Scaffold Android, iOS, web, and macOS Flutter targets.
   - Add repository hygiene and task tracking.

2. Core game engine
   - Model a 10x20 visible playfield plus 20 hidden buffer rows.
   - Add all seven tetrominoes with guideline colors and spawn states.
   - Implement 7-bag random generation and next queue.
   - Implement SRS rotation and wall kicks.
   - Implement movement, hard drop, soft drop, hold, ghost piece, lock delay, line clears, level progression, scoring, combos, back-to-back, perfect clears, and top-out conditions.
   - Cover the engine with deterministic unit tests.

3. Flutter game surface
   - Render the board using Flutter custom painting.
   - Render active, locked, ghost, hold, and preview pieces.
   - Add score, level, line, combo, and game-over HUD.
   - Add restart/pause controls.

4. Touch controls and audio
   - Swipe left/right to shift.
   - Tap right/left side to rotate clockwise/counter-clockwise.
   - Swipe down for locking hard drop.
   - Long press for non-locking soft drop.
   - Swipe up for hold.
   - Include the Korobeiniki music asset.

5. Verification and release state
   - Run formatting and static analysis.
   - Run Flutter tests.
   - Run at least one real device/emulator smoke test when available.
   - Commit each completed slice with semantic commit messages.

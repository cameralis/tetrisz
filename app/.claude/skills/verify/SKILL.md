---
name: verify
description: Build, launch, and drive the tetris Flutter app end-to-end on macOS to verify gameplay changes at runtime. Use after changing engine (lib/src/game) or UI (lib/src/ui) code.
---

# Verify tetris changes end-to-end

Always use `fvm flutter` (bare `flutter` on this machine is an older SDK that
fails `pub get`; the project pins stable via `.fvm/flutter_sdk`).

## Live E2E drive (preferred)

The repo has a real-app integration drive that launches the macOS app on real
vsync and performs actual gestures (tap rotate, long-press soft drop, swipe
up hold, swipe down hard drop, pause/resume), asserting against the HUD:

```bash
cd app
fvm flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/gameplay_e2e_test.dart \
  -d macos \
  --dart-define=E2E_MARKER_DIR=/Users/szabi/Library/Containers/one.tear.tetrisz/Data/tmp/e2e_markers
```

Gotchas learned the hard way:

- `IntegrationTestWidgetsFlutterBinding.framePolicy` must be
  `LiveTestWidgetsFlutterBindingFramePolicy.fullyLive`, or the game ticker
  only advances on test pumps and `TetrisGame.tick` drops deltas > 250ms
  (`_maxTickDelta`) as stale — gravity/soft drop then never run.
- The debug macOS app is **sandboxed**: it can only write inside
  `~/Library/Containers/one.tear.tetrisz/Data/`. Any file the test writes
  (markers, dumps) must go there, not /tmp.
- `binding.takeScreenshot` does not produce files on macOS; capture the
  window from outside instead. A CGWindowID lookup (owner name `tetris`,
  height > 100) + `screencapture -x -o -l<id>` grabs the window layer
  without stealing focus or touching the user's mouse. Pair it with the
  E2E_MARKER_DIR marker files the test drops at each stable stage.
- Window is 800x632 by default → the game page uses the WIDE layout
  (side HUD panels). Compact layout is width < 760 or height < 500.
- **Never drive the host mouse/CGEvents on the main display** — the desktop
  is in active use; a foreground browser stole a click once. Use the
  integration drive instead.

## Quick manual launch

```bash
cd app && fvm flutter run -d macos
```

`TetrisApp(enableAudio: false)` in the drive keeps the run silent; the manual
app plays music at 30% by default.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetris/src/input/control_bindings.dart';
import 'package:tetris/src/ui/leaderboard_page.dart';
import 'package:tetris/src/ui/tetris_app.dart';

/// Performance soak: plays the real app continuously with scripted inputs
/// while recording FrameTiming (build/raster) and RSS into 30-second buckets.
/// Progressive lag shows up as later buckets being slower than the first.
///
/// Run with:
///   fvm flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/perf_soak_test.dart \
///     --profile -d macos \
///     --dart-define=E2E_MARKER_DIR=/Users/szabi/Library/Containers/one.tear.tetrisz/Data/tmp/e2e_markers \
///     --dart-define=SOAK_SECONDS=360
const _markerDir = String.fromEnvironment('E2E_MARKER_DIR');
const _soakSeconds = int.fromEnvironment('SOAK_SECONDS', defaultValue: 360);
// Idle mode: no inputs at all (gravity-only rounds, restart on game over).
// Differential control against the active bot: input-driven accumulation
// disappears here, time-driven accumulation stays.
const _idle = bool.fromEnvironment('SOAK_IDLE');
const _bucketSeconds = 30;

class _FrameSample {
  _FrameSample(this.elapsedMs, this.buildUs, this.rasterUs, this.totalUs);

  final int elapsedMs;
  final int buildUs;
  final int rasterUs;
  final int totalUs;
}

double _percentile(List<int> sorted, double p) {
  if (sorted.isEmpty) {
    return 0;
  }
  final index = ((sorted.length - 1) * p).round();
  return sorted[index] / 1000.0; // us -> ms
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'soak: frame timings and memory stay flat over a long session',
    (tester) async {
      final preferences = await SharedPreferences.getInstance();

      // Snapshot the player's real preferences; the soak must not clobber
      // their saved game or high score, and must never submit bot scores to
      // the leaderboard (name is removed for the duration of the run).
      final savedGame = preferences.getString(tetrisSavedGamePreferenceKey);
      final savedName = preferences.getString(tetrisPlayerNamePreferenceKey);
      final savedHighScore = preferences.getInt(tetrisHighScorePreferenceKey);
      final savedMusic = preferences.getDouble('tetris.musicVolume');
      final savedSfx = preferences.getDouble('tetris.sfxVolume');
      final savedPadBindings = preferences.getString(
        tetrisGamepadBindingsPreferenceKey,
      );
      final savedTouchBindings = preferences.getString(
        tetrisTouchBindingsPreferenceKey,
      );

      await preferences.remove(tetrisSavedGamePreferenceKey);
      await preferences.remove(tetrisPlayerNamePreferenceKey);
      await preferences.remove(tetrisGamepadBindingsPreferenceKey);
      await preferences.remove(tetrisTouchBindingsPreferenceKey);
      // Keep the production audio code path active but quiet.
      await preferences.setDouble('tetris.musicVolume', 0.05);
      await preferences.setDouble('tetris.sfxVolume', 0.15);

      final frames = <_FrameSample>[];
      final rssSamples = <List<int>>[]; // [elapsedMs, rssBytes]
      // [elapsedMs, count]; audioplayers' leaked position pollers each hold
      // one transient frame callback, so growth here = per-frame call storm.
      final transientSamples = <List<int>>[];
      final soakClock = Stopwatch();
      void onTimings(List<ui.FrameTiming> timings) {
        if (!soakClock.isRunning) {
          return;
        }
        final now = soakClock.elapsedMilliseconds;
        for (final t in timings) {
          frames.add(
            _FrameSample(
              now,
              t.buildDuration.inMicroseconds,
              t.rasterDuration.inMicroseconds,
              t.totalSpan.inMicroseconds,
            ),
          );
        }
      }

      binding.addTimingsCallback(onTimings);

      try {
        await tester.pumpWidget(const TetrisApp());
        await tester.pump(const Duration(milliseconds: 800));
        await tester.tap(find.byKey(const ValueKey('home-play')));
        await tester.pump(const Duration(milliseconds: 600));

        final board = find.byKey(const ValueKey('tetris-board'));
        expect(board, findsOneWidget);

        final random = math.Random(42);
        var restarts = 0;
        var lastRssMs = -5000;
        soakClock.start();

        while (soakClock.elapsedMilliseconds < _soakSeconds * 1000) {
          if (soakClock.elapsedMilliseconds - lastRssMs >= 5000) {
            lastRssMs = soakClock.elapsedMilliseconds;
            rssSamples.add([lastRssMs, ProcessInfo.currentRss]);
          }
          transientSamples.add([
            soakClock.elapsedMilliseconds,
            binding.transientCallbackCount,
          ]);

          if (find.text('GAME OVER').evaluate().isNotEmpty) {
            restarts += 1;
            await tester.tap(find.byTooltip('Restart'));
            await tester.pump(const Duration(milliseconds: 300));
            continue;
          }

          if (_idle) {
            await tester.pump(const Duration(milliseconds: 250));
            continue;
          }

          // One "human" action burst per cycle at roughly 3-5 actions/sec.
          final rotations = random.nextInt(3);
          for (var i = 0; i < rotations; i += 1) {
            await tester.tapAt(
              tester.getCenter(board) +
                  Offset(random.nextBool() ? 60 : -60, 0),
            );
            await tester.pump(const Duration(milliseconds: 90));
          }

          final dx = (random.nextInt(9) - 4) * 55.0;
          if (dx != 0) {
            await tester.timedDrag(
              board,
              Offset(dx, 0),
              const Duration(milliseconds: 120),
            );
            await tester.pump(const Duration(milliseconds: 80));
          }

          if (random.nextInt(10) == 0) {
            // Hold via swipe up.
            await tester.timedDrag(
              board,
              const Offset(0, -120),
              const Duration(milliseconds: 160),
            );
            await tester.pump(const Duration(milliseconds: 120));
          }

          if (random.nextInt(10) < 7) {
            // Hard drop via swipe down.
            await tester.timedDrag(
              board,
              const Offset(0, 140),
              const Duration(milliseconds: 140),
            );
            await tester.pump(const Duration(milliseconds: 160));
          } else {
            // Soft drop via long press.
            final press = await tester.startGesture(tester.getCenter(board));
            await tester.pump(const Duration(milliseconds: 1000));
            await press.up();
            await tester.pump(const Duration(milliseconds: 120));
          }
        }
        soakClock.stop();

        // Bucketed report.
        final bucketCount = (_soakSeconds / _bucketSeconds).ceil();
        final report = <Map<String, Object>>[];
        for (var b = 0; b < bucketCount; b += 1) {
          final lo = b * _bucketSeconds * 1000;
          final hi = lo + _bucketSeconds * 1000;
          final inBucket = frames
              .where((f) => f.elapsedMs >= lo && f.elapsedMs < hi)
              .toList();
          final builds = inBucket.map((f) => f.buildUs).toList()..sort();
          final rasters = inBucket.map((f) => f.rasterUs).toList()..sort();
          final totals = inBucket.map((f) => f.totalUs).toList()..sort();
          final janky = inBucket.where((f) => f.totalUs > 17000).length;
          final rssInBucket = rssSamples
              .where((s) => s[0] >= lo && s[0] < hi)
              .map((s) => s[1])
              .toList();
          final transientInBucket = transientSamples
              .where((s) => s[0] >= lo && s[0] < hi)
              .map((s) => s[1])
              .toList();
          report.add({
            'bucket': b,
            'frames': inBucket.length,
            'buildP50Ms': _percentile(builds, 0.5),
            'buildP90Ms': _percentile(builds, 0.9),
            'buildP99Ms': _percentile(builds, 0.99),
            'rasterP50Ms': _percentile(rasters, 0.5),
            'rasterP90Ms': _percentile(rasters, 0.9),
            'rasterP99Ms': _percentile(rasters, 0.99),
            'totalP90Ms': _percentile(totals, 0.9),
            'jankyFrames': janky,
            'rssMb': rssInBucket.isEmpty
                ? 0
                : rssInBucket.last / (1024 * 1024),
            'maxTransientCallbacks': transientInBucket.isEmpty
                ? 0
                : transientInBucket.reduce(math.max),
          });
        }

        final summary = {
          'soakSeconds': _soakSeconds,
          'restarts': restarts,
          'totalFrames': frames.length,
          'buckets': report,
        };

        // One compact line per bucket so the drive console shows the trend.
        debugPrint('SOAK-REPORT-BEGIN');
        for (final b in report) {
          debugPrint(
            'SOAK bucket=${b['bucket']} frames=${b['frames']} '
            'build p50/p90/p99=${(b['buildP50Ms'] as double).toStringAsFixed(1)}/'
            '${(b['buildP90Ms'] as double).toStringAsFixed(1)}/'
            '${(b['buildP99Ms'] as double).toStringAsFixed(1)}ms '
            'raster p50/p90/p99=${(b['rasterP50Ms'] as double).toStringAsFixed(1)}/'
            '${(b['rasterP90Ms'] as double).toStringAsFixed(1)}/'
            '${(b['rasterP99Ms'] as double).toStringAsFixed(1)}ms '
            'jank=${b['jankyFrames']} rss=${(b['rssMb'] as num).toStringAsFixed(0)}MB '
            'transient=${b['maxTransientCallbacks']}',
          );
        }
        debugPrint('SOAK-REPORT-END restarts=$restarts frames=${frames.length}');

        if (_markerDir.isNotEmpty) {
          File('$_markerDir/soak_report.json')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(const JsonEncoder.withIndent(' ').convert(summary));
        }
        binding.reportData = {'soak': summary};
      } finally {
        binding.removeTimingsCallback(onTimings);
        // Restore the player's real preferences.
        Future<void> restoreString(String key, String? value) async {
          if (value == null) {
            await preferences.remove(key);
          } else {
            await preferences.setString(key, value);
          }
        }

        await restoreString(tetrisSavedGamePreferenceKey, savedGame);
        await restoreString(tetrisPlayerNamePreferenceKey, savedName);
        await restoreString(tetrisGamepadBindingsPreferenceKey, savedPadBindings);
        await restoreString(tetrisTouchBindingsPreferenceKey, savedTouchBindings);
        if (savedHighScore == null) {
          await preferences.remove(tetrisHighScorePreferenceKey);
        } else {
          await preferences.setInt(tetrisHighScorePreferenceKey, savedHighScore);
        }
        if (savedMusic == null) {
          await preferences.remove('tetris.musicVolume');
        } else {
          await preferences.setDouble('tetris.musicVolume', savedMusic);
        }
        if (savedSfx == null) {
          await preferences.remove('tetris.sfxVolume');
        } else {
          await preferences.setDouble('tetris.sfxVolume', savedSfx);
        }
      }
    },
    timeout: Timeout(Duration(seconds: _soakSeconds + 600)),
  );
}

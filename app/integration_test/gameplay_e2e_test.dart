import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tetris/src/ui/tetris_app.dart';

/// Live end-to-end drive of the real app: home menu -> game -> gestures.
///
/// Stage markers are written to E2E_MARKER_DIR so an external watcher can
/// capture the actual window at each stable point.
const _markerDir = String.fromEnvironment('E2E_MARKER_DIR');

Future<void> _stage(
  IntegrationTestWidgetsFlutterBinding binding,
  WidgetTester tester,
  String name,
) async {
  if (_markerDir.isNotEmpty) {
    File('$_markerDir/$name').writeAsStringSync('');
  }
  try {
    await binding.takeScreenshot(name);
  } catch (_) {
    // Desktop screenshot support varies; the external watcher still captures.
  }
  // Hold the frame stable long enough for the external capturer.
  await tester.pump(const Duration(milliseconds: 1400));
}

int _hudMetric(WidgetTester tester, String label) {
  final texts = tester
      .widgetList<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('wide-left-panel')),
          matching: find.byType(Text),
        ),
      )
      .toList();
  for (var i = 0; i < texts.length - 1; i += 1) {
    if (texts[i].data == label) {
      return int.parse(texts[i + 1].data!);
    }
  }
  throw StateError('HUD metric $label not found');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Real vsync drives frames continuously, so the game ticker runs exactly
  // like production instead of only advancing when the test pumps.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('guideline gameplay end-to-end on the real app', (tester) async {
    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pump(const Duration(milliseconds: 800));

    await tester.tap(find.byKey(const ValueKey('home-play')));
    await tester.pump(const Duration(milliseconds: 400));

    // Wide-layout HUD: hold, stats, and a six-piece next queue are visible.
    expect(find.byKey(const ValueKey('wide-left-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('wide-right-panel')), findsOneWidget);
    expect(find.text('HOLD'), findsOneWidget);
    expect(find.text('NEXT'), findsOneWidget);
    expect(find.text('SCORE'), findsOneWidget);
    expect(find.text('LEVEL'), findsOneWidget);
    expect(find.text('LINES'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('wide-right-panel')),
        matching: find.byType(CustomPaint),
      ),
      findsNWidgets(6),
    );
    await _stage(binding, tester, 'stage1_wide_hud');

    final board = find.byKey(const ValueKey('tetris-board'));
    expect(board, findsOneWidget);

    // Soft drop via long press: engine-driven fall scoring 1 point per row.
    final scoreBefore = _hudMetric(tester, 'SCORE');
    final press = await tester.startGesture(tester.getCenter(board));
    await tester.pump(const Duration(milliseconds: 2000));
    await press.up();
    await tester.pump(const Duration(milliseconds: 200));
    final scoreAfterSoft = _hudMetric(tester, 'SCORE');
    expect(
      scoreAfterSoft - scoreBefore,
      greaterThanOrEqualTo(10),
      reason: 'long-press soft drop should score ~1 point per fallen row',
    );
    await _stage(binding, tester, 'stage2_soft_dropped');

    // Hold via swipe up: the HOLD slot fills, "-" placeholder disappears.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('wide-left-panel')),
        matching: find.text('-'),
      ),
      findsOneWidget,
    );
    await tester.timedDrag(
      board,
      const Offset(0, -120),
      const Duration(milliseconds: 180),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('wide-left-panel')),
        matching: find.text('-'),
      ),
      findsNothing,
    );
    await _stage(binding, tester, 'stage3_hold_filled');

    // Hard drop via swipe down: score jumps by 2 x drop distance.
    final scoreBeforeHard = _hudMetric(tester, 'SCORE');
    await tester.timedDrag(
      board,
      const Offset(0, 140),
      const Duration(milliseconds: 160),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(_hudMetric(tester, 'SCORE'), greaterThan(scoreBeforeHard));
    await _stage(binding, tester, 'stage4_hard_dropped');

    // Rotate: tap the right half of the play area.
    await tester.tapAt(tester.getCenter(board) + const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 200));

    // Pause and resume through the wide-panel button and overlay.
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('PAUSED'), findsOneWidget);
    await _stage(binding, tester, 'stage5_paused');

    await tester.tap(find.byTooltip('Resume').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('PAUSED'), findsNothing);
    await _stage(binding, tester, 'stage6_resumed');
  });
}

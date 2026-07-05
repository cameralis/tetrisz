import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetris/src/input/control_bindings.dart';
import 'package:tetris/src/ui/tetris_app.dart';

/// Live end-to-end drive of the desktop keyboard controls on the real app:
/// home menu -> game -> physical key events through the production key
/// pipeline (soft drop, hold, hard drop, pause/resume), asserting the HUD.
const _markerDir = String.fromEnvironment('E2E_MARKER_DIR');

Future<void> _stage(
  IntegrationTestWidgetsFlutterBinding binding,
  WidgetTester tester,
  String name,
) async {
  if (_markerDir.isNotEmpty) {
    File('$_markerDir/$name')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('');
  }
  try {
    await binding.takeScreenshot(name);
  } catch (_) {
    // Desktop screenshot support varies; the external watcher still captures.
  }
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

Future<void> _tapKey(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('keyboard controls drive the real app', (tester) async {
    // Start from shipped defaults: a saved game would boot paused, and custom
    // bindings would change the keys under test.
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(tetrisSavedGamePreferenceKey);
    await preferences.remove(tetrisKeyboardBindingsPreferenceKey);

    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pump(const Duration(milliseconds: 800));

    await tester.tap(find.byKey(const ValueKey('home-play')));
    await tester.pump(const Duration(milliseconds: 400));

    final board = find.byKey(const ValueKey('tetris-board'));
    expect(board, findsOneWidget);
    expect(find.byKey(const ValueKey('wide-left-panel')), findsOneWidget);
    await _stage(binding, tester, 'kbd1_in_game');

    // Move left/right a few columns (no HUD metric, just exercises the path).
    for (var i = 0; i < 3; i += 1) {
      await _tapKey(tester, LogicalKeyboardKey.arrowLeft);
    }
    await _tapKey(tester, LogicalKeyboardKey.arrowRight);

    // Hold via C: the HOLD slot fills, its "-" placeholder disappears.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('wide-left-panel')),
        matching: find.text('-'),
      ),
      findsOneWidget,
    );
    await _tapKey(tester, LogicalKeyboardKey.keyC);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('wide-left-panel')),
        matching: find.text('-'),
      ),
      findsNothing,
    );
    await _stage(binding, tester, 'kbd2_hold_filled');

    // Sustained soft drop while ArrowDown is held: engine falls, scoring ~1
    // point per row.
    final scoreBeforeSoft = _hudMetric(tester, 'SCORE');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      _hudMetric(tester, 'SCORE') - scoreBeforeSoft,
      greaterThanOrEqualTo(5),
      reason: 'holding Down should soft drop and score per fallen row',
    );
    await _stage(binding, tester, 'kbd3_soft_dropped');

    // Hard drop via Space: score jumps by the drop distance.
    final scoreBeforeHard = _hudMetric(tester, 'SCORE');
    await _tapKey(tester, LogicalKeyboardKey.space);
    expect(_hudMetric(tester, 'SCORE'), greaterThan(scoreBeforeHard));
    await _stage(binding, tester, 'kbd4_hard_dropped');

    // Pause and resume via Esc, over the pause overlay.
    await _tapKey(tester, LogicalKeyboardKey.escape);
    expect(find.text('PAUSED'), findsOneWidget);
    await _stage(binding, tester, 'kbd5_paused');

    await _tapKey(tester, LogicalKeyboardKey.escape);
    expect(find.text('PAUSED'), findsNothing);
    await _stage(binding, tester, 'kbd6_resumed');
  });
}

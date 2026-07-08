import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tetris/src/ui/components.dart';
import 'package:tetris/src/ui/tetris_app.dart';

/// Live drive of the redesigned menus: hover, press, keyboard focus and
/// navigation across Home / Lobby / Leaderboard / Diagnostics / Controls.
///
/// Stage markers are written to E2E_MARKER_DIR so an external watcher can
/// capture stills and video of the actual window at each stable point.
const _markerDir = String.fromEnvironment('E2E_MARKER_DIR');

Future<void> _stage(WidgetTester tester, String name) async {
  if (_markerDir.isNotEmpty) {
    File('$_markerDir/$name')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('');
  }
  // Hold the frame stable long enough for the external capturer.
  await tester.pump(const Duration(milliseconds: 1400));
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('menu component showcase on the real app', (tester) async {
    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pump(const Duration(milliseconds: 800));
    await _stage(tester, 'menu1_home_idle');

    // Hover sweep with a synthetic mouse: each button lifts and glows.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    for (final (i, key) in const [
      'home-play',
      'home-versus',
      'home-leaderboard',
      'home-diagnostics',
    ].indexed) {
      await mouse.moveTo(tester.getCenter(find.byKey(ValueKey(key))));
      await tester.pump(const Duration(milliseconds: 650));
      if (i == 0) {
        await _stage(tester, 'menu2_home_hover_play');
      }
    }
    await _stage(tester, 'menu3_home_hover_last');
    await mouse.moveTo(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 300));

    // Press-and-hold: the face slams down onto its edge, then we slide off
    // so the tap cancels without navigating.
    final press = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('home-play'))),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await _stage(tester, 'menu4_home_press_play');
    await press.moveBy(const Offset(0, 220));
    await press.up();
    await tester.pump(const Duration(milliseconds: 300));

    // Keyboard traversal: focus ring walks the menu.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump(const Duration(milliseconds: 400));
    await _stage(tester, 'menu5_home_focus_traversal');

    // Lobby: create/join screen with the themed text field.
    await tester.tap(find.byKey(const ValueKey('home-versus')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('lobby-create')), findsOneWidget);
    await _stage(tester, 'menu6_lobby_idle');
    await tester.tap(find.byKey(const ValueKey('lobby-code-field')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(
      find.byKey(const ValueKey('lobby-code-field')),
      'KDX7Q',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await _stage(tester, 'menu7_lobby_code_focused');
    await tester.tap(find.byType(BackButton).first);
    await tester.pump(const Duration(milliseconds: 700));

    // Leaderboard: themed rows, refresh icon button, name field.
    await tester.tap(find.byKey(const ValueKey('home-leaderboard')));
    await tester.pump(const Duration(milliseconds: 2500));
    await _stage(tester, 'menu8_leaderboard');
    await tester.tap(find.byType(BackButton).first);
    await tester.pump(const Duration(milliseconds: 700));

    // Diagnostics -> Controls: list tiles, probes, reset ghost buttons.
    await tester.tap(find.byKey(const ValueKey('home-diagnostics')));
    await tester.pump(const Duration(milliseconds: 2500));
    await _stage(tester, 'menu9_diagnostics');
    await tester.tap(find.byKey(const ValueKey('open-controls')));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byType(TetrisListTile), findsWidgets);
    await _stage(tester, 'menu10_controls');
    // During a page transition both routes are in the tree, so BackButton can
    // match twice; tap the topmost and let each transition fully finish.
    await tester.tap(find.byType(BackButton).first);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.tap(find.byType(BackButton).first);
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.byKey(const ValueKey('home-play')), findsOneWidget);
    await _stage(tester, 'menu11_done');
  });
}

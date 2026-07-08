import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tetris/src/ui/tetris_app.dart';
import 'package:tetris/src/ui/theme.dart';
import 'package:tetris/src/ui/toasts.dart';

/// Live drive of the toast layer on the real app: shows the exact toasts the
/// room events produce (join / disconnect / reconnect) via the production
/// TetrisToastHost API, over both the home menu and a running game.
const _markerDir = String.fromEnvironment('E2E_MARKER_DIR');

Future<void> _stage(WidgetTester tester, String name) async {
  if (_markerDir.isNotEmpty) {
    File('$_markerDir/$name')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('');
  }
  await tester.pump(const Duration(milliseconds: 1400));
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('toast slam-in showcase on the real app', (tester) async {
    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pump(const Duration(milliseconds: 800));

    TetrisToastHost.show(
      'Opponent joined the room',
      icon: Icons.person_add_alt_1_rounded,
      accent: TetrisColors.ok,
      hold: const Duration(milliseconds: 3200),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await _stage(tester, 'toast1_joined');
    await tester.pump(const Duration(milliseconds: 2600));

    TetrisToastHost.show(
      'Opponent disconnected — waiting for them to return',
      icon: Icons.link_off_rounded,
      accent: TetrisColors.danger,
      hold: const Duration(milliseconds: 2800),
    );
    await tester.pump(const Duration(milliseconds: 250));
    TetrisToastHost.show(
      'Opponent reconnected',
      icon: Icons.link_rounded,
      accent: TetrisColors.ok,
      hold: const Duration(milliseconds: 2800),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await _stage(tester, 'toast2_stacked');
    await tester.pump(const Duration(milliseconds: 3400));

    expect(find.text('Opponent reconnected'), findsNothing);
    await _stage(tester, 'toast3_done');
  });
}

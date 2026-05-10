import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tetris/src/ui/tetris_app.dart';

void main() {
  testWidgets('renders the playable Tetris surface', (tester) async {
    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pump();

    expect(find.text('TETRIS'), findsOneWidget);
    expect(find.text('HOLD'), findsOneWidget);
    expect(find.text('NEXT'), findsOneWidget);
    expect(find.text('SCORE'), findsWidgets);
    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.byTooltip('Restart'), findsOneWidget);
  });

  testWidgets('renders without overflow on a phone viewport', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pump();

    expect(find.text('HOLD'), findsOneWidget);
    expect(find.text('NEXT'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tetris/src/game/tetris_game.dart';
import 'package:tetris/src/game/tetromino.dart';
import 'package:tetris/src/ui/tetris_app.dart';

int _visibleLockedCellCount(TetrisGame game) {
  var count = 0;
  for (var y = 0; y < TetrisGame.visibleRows; y += 1) {
    for (var x = 0; x < TetrisGame.width; x += 1) {
      if (game.visibleCellAt(x, y) != null) {
        count += 1;
      }
    }
  }
  return count;
}

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

    final board = find.byKey(const ValueKey('tetris-board'));
    final topBar = find.byKey(const ValueKey('compact-top-bar'));
    final boardRect = tester.getRect(board);
    final topBarRect = tester.getRect(topBar);
    final pauseRect = tester.getRect(find.byTooltip('Pause'));
    final muteRect = tester.getRect(find.byTooltip('Mute'));

    expect(find.text('HOLD'), findsOneWidget);
    expect(find.text('NEXT'), findsOneWidget);
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.byTooltip('Mute'), findsOneWidget);
    expect(find.byTooltip('Rotate clockwise'), findsNothing);
    expect(find.byTooltip('Rotate counter-clockwise'), findsNothing);
    expect(find.byTooltip('Hard drop'), findsNothing);
    expect(find.byTooltip('Hold'), findsNothing);
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(boardRect.left, 0);
    expect(boardRect.right, 390);
    expect(boardRect.top, greaterThanOrEqualTo(0));
    expect(boardRect.bottom, lessThanOrEqualTo(844));
    expect(topBarRect.bottom, lessThanOrEqualTo(boardRect.top));
    expect(pauseRect.bottom, lessThanOrEqualTo(boardRect.top));
    expect(muteRect.bottom, lessThanOrEqualTo(boardRect.top));

    await tester.drag(board, const Offset(0, -160));
    await tester.pump();

    expect(tester.getRect(board), boardRect);
    expect(tester.takeException(), isNull);
  });

  testWidgets('restart does not apply accumulated ticker time', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final game = TetrisGame(
      scriptedPieces: const [Tetromino.z, Tetromino.l, Tetromino.o],
    );

    await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));

    expect(_visibleLockedCellCount(game), greaterThan(0));

    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    await tester.tap(find.byTooltip('Restart'));
    await tester.pump();

    expect(_visibleLockedCellCount(game), 0);
    expect(
      game.activeCells.every((cell) => cell.y < TetrisGame.bufferRows),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}

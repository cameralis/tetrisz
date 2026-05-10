import 'package:flutter_test/flutter_test.dart';
import 'package:tetris/src/game/tetris_game.dart';
import 'package:tetris/src/game/tetromino.dart';

void main() {
  group('TetrisGame', () {
    test('spawns pieces inside the hidden buffer', () {
      final game = TetrisGame(scriptedPieces: [Tetromino.t]);

      expect(game.active?.type, Tetromino.t);
      expect(
        game.activeCells.every((cell) => cell.y < TetrisGame.bufferRows),
        isTrue,
      );
      expect(
        game.activeCells.map((cell) => cell.x),
        everyElement(inInclusiveRange(3, 5)),
      );
    });

    test('uses a seven-bag generator', () {
      final game = TetrisGame(seed: 4);
      final seen = <Tetromino>{game.active!.type};

      for (var i = 0; i < 6; i += 1) {
        game.hardDrop();
        seen.add(game.active!.type);
      }

      expect(seen, hasLength(7));
      expect(seen, containsAll(Tetromino.values));
    });

    test('rotates with SRS wall kicks at the left wall', () {
      final game = TetrisGame(scriptedPieces: [Tetromino.t]);

      while (game.moveLeft()) {}

      expect(game.rotateCounterClockwise(), isTrue);
      expect(game.active!.rotation, 3);
      expect(game.activeCells.every((cell) => cell.x >= 0), isTrue);
    });

    test(
      'hard drop locks, clears a line, scores, and detects perfect clear',
      () {
        final game = TetrisGame(scriptedPieces: [Tetromino.i, Tetromino.o]);
        final bottom = TetrisGame.visibleRows - 1;
        for (var x = 0; x < TetrisGame.width; x += 1) {
          if (x < 3 || x > 6) {
            game.setVisibleCell(x, bottom, Tetromino.z);
          }
        }

        final drop = game.hardDrop();

        expect(drop, greaterThan(0));
        expect(game.lines, 1);
        expect(game.lastClear.lines, 1);
        expect(game.lastClear.perfectClear, isTrue);
        expect(game.score, greaterThanOrEqualTo(900));
        expect(
          List.generate(TetrisGame.width, (x) => game.visibleCellAt(x, bottom)),
          everyElement(isNull),
        );
        final snapshot = game.lastLineClearSnapshot!;
        expect(snapshot.rows, [TetrisGame.bufferRows + bottom]);
        expect(
          List.generate(
            TetrisGame.width,
            (x) => snapshot.board.visibleCellAt(x, bottom),
          ),
          everyElement(isNotNull),
        );
      },
    );

    test('hold swaps once per locked piece', () {
      final game = TetrisGame(
        scriptedPieces: [Tetromino.t, Tetromino.i, Tetromino.o],
      );

      expect(game.hold(), isTrue);
      expect(game.holdPiece, Tetromino.t);
      expect(game.active?.type, Tetromino.i);
      expect(game.hold(), isFalse);

      game.hardDrop();

      expect(game.hold(), isTrue);
      expect(game.holdPiece, Tetromino.o);
      expect(game.active?.type, Tetromino.t);
    });

    test('locks after the guideline lock delay when grounded', () {
      final game = TetrisGame(scriptedPieces: [Tetromino.o, Tetromino.i]);
      while (game.softDropStep()) {}
      final grounded = game.active?.type;

      game.tick(TetrisGame.lockDelay);

      expect(game.active?.type, isNot(grounded));
    });

    test('tops out when a spawned piece overlaps the stack', () {
      final game = TetrisGame(scriptedPieces: [Tetromino.o, Tetromino.t]);
      for (final cell in tetrominoCells(Tetromino.t, 0)) {
        game.setCell(
          3 + cell.x,
          TetrisGame.bufferRows - 2 + cell.y,
          Tetromino.i,
        );
      }

      game.hardDrop();

      expect(game.gameOver, isTrue);
      expect(game.active, isNull);
    });
  });
}

import 'dart:convert';

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
      expect(seen, containsAll(Tetromino.playablePieces));
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

  group('save and restore', () {
    test('round-trips the full game state through JSON', () {
      final game = TetrisGame(seed: 7);
      game.hold();
      game.hardDrop();
      game.moveLeft();
      game.rotateClockwise();
      game.softDropStep();
      game.hardDrop();

      final encoded = jsonEncode(game.toJson());
      final restored = TetrisGame(seed: 99)
        ..restore(jsonDecode(encoded) as Map<String, dynamic>);

      expect(restored.score, game.score);
      expect(restored.lines, game.lines);
      expect(restored.level, game.level);
      expect(restored.lockCount, game.lockCount);
      expect(restored.combo, game.combo);
      expect(restored.backToBack, game.backToBack);
      expect(restored.holdPiece, game.holdPiece);
      expect(restored.canHold, game.canHold);
      expect(restored.gameOver, game.gameOver);
      expect(restored.active?.type, game.active?.type);
      expect(restored.active?.rotation, game.active?.rotation);
      expect(restored.active?.x, game.active?.x);
      expect(restored.active?.y, game.active?.y);
      expect(
        restored.nextQueue.map((piece) => piece),
        game.nextQueue.map((piece) => piece),
      );

      for (var y = 0; y < TetrisGame.totalRows; y += 1) {
        for (var x = 0; x < TetrisGame.width; x += 1) {
          expect(
            restored.cellAt(x, y),
            game.cellAt(x, y),
            reason: 'cell ($x, $y) should match',
          );
        }
      }
    });

    test('restored game keeps playing identically to the original', () {
      final original = TetrisGame(seed: 11);
      for (var i = 0; i < 5; i += 1) {
        original.hardDrop();
      }

      final restored = TetrisGame(seed: 0)..restore(original.toJson());

      for (var i = 0; i < 5; i += 1) {
        original.hardDrop();
        restored.hardDrop();
      }

      expect(restored.score, original.score);
      expect(restored.active?.type, original.active?.type);
      for (var y = 0; y < TetrisGame.totalRows; y += 1) {
        for (var x = 0; x < TetrisGame.width; x += 1) {
          expect(restored.cellAt(x, y), original.cellAt(x, y));
        }
      }
    });

    test('rejects an unsupported save version', () {
      final game = TetrisGame(seed: 1);
      final json = game.toJson()..['version'] = 999;

      expect(() => game.restore(json), throwsFormatException);
    });

    test('rejects a board with the wrong dimensions', () {
      final game = TetrisGame(seed: 1);
      final json = game.toJson()..['board'] = <List<int>>[];

      expect(() => game.restore(json), throwsFormatException);
    });
  });

  group('versus mechanics', () {
    /// Fills the bottom [rows] visible rows, leaving [holeX] empty in each.
    void fillBottomRows(TetrisGame game, int rows, {required int holeX}) {
      for (var i = 0; i < rows; i += 1) {
        final y = TetrisGame.visibleRows - 1 - i;
        for (var x = 0; x < TetrisGame.width; x += 1) {
          if (x != holeX) {
            game.setVisibleCell(x, y, Tetromino.z);
          }
        }
      }
    }

    test('the bag never deals garbage', () {
      final game = TetrisGame(seed: 7);
      var sampled = 0;
      for (var i = 0; i < 30 && !game.gameOver; i += 1) {
        expect(Tetromino.playablePieces, contains(game.active!.type));
        sampled += 1;
        game.hardDrop();
      }
      // Enough draws to cross bag refill boundaries (the queue itself holds
      // seven pieces beyond these samples).
      expect(sampled, greaterThanOrEqualTo(8));
    });

    test('applies queued garbage on a non-clearing lock with one hole', () {
      final game = TetrisGame(seed: 1, scriptedPieces: [
        Tetromino.o,
        Tetromino.o,
      ]);
      game.enqueueGarbage(2);
      expect(game.pendingGarbageLines, 2);

      game.hardDrop();

      expect(game.pendingGarbageLines, 0);
      for (final visibleY in [
        TetrisGame.visibleRows - 1,
        TetrisGame.visibleRows - 2,
      ]) {
        final holes = <int>[];
        for (var x = 0; x < TetrisGame.width; x += 1) {
          final cell = game.visibleCellAt(x, visibleY);
          if (cell == null) {
            holes.add(x);
          } else {
            expect(cell, Tetromino.garbage);
          }
        }
        expect(holes, hasLength(1));
      }
      // Same chunk shares one hole column.
      final holeBottom = List.generate(
        TetrisGame.width,
        (x) => game.visibleCellAt(x, TetrisGame.visibleRows - 1),
      ).indexOf(null);
      final holeAbove = List.generate(
        TetrisGame.width,
        (x) => game.visibleCellAt(x, TetrisGame.visibleRows - 2),
      ).indexOf(null);
      expect(holeBottom, holeAbove);
      // The locked O piece was pushed up by two rows.
      expect(
        game
            .drainEvents()
            .whereType<GarbageAppliedEvent>()
            .single
            .lines,
        2,
      );
    });

    test('clears cancel pending garbage before sending an attack', () {
      final game = TetrisGame(scriptedPieces: [Tetromino.i, Tetromino.o]);
      fillBottomRows(game, 4, holeX: 0);
      // A stray block above the cleared rows keeps this from being a
      // perfect clear (which would add +10 attack).
      game.setVisibleCell(5, TetrisGame.visibleRows - 5, Tetromino.z);
      game.enqueueGarbage(3);

      game.rotateClockwise();
      while (game.moveLeft()) {}
      game.hardDrop();

      expect(game.lastClear.lines, 4);
      expect(game.pendingGarbageLines, 0);
      final event =
          game.drainEvents().whereType<LinesClearedEvent>().single;
      expect(event.garbageCancelled, 3);
      expect(event.attackSent, 1);
      // No garbage rows were inserted, because the lock cleared lines.
      expect(
        game.visibleCellAt(0, TetrisGame.visibleRows - 1),
        isNot(Tetromino.garbage),
      );
    });

    test('caps garbage application per lock and keeps the remainder', () {
      final game = TetrisGame(seed: 1, scriptedPieces: [
        Tetromino.o,
        Tetromino.o,
        Tetromino.o,
      ]);
      game.enqueueGarbage(6);
      game.enqueueGarbage(5);

      game.hardDrop();

      expect(game.pendingGarbageLines, 3);
      game.hardDrop();
      expect(game.pendingGarbageLines, 0);
    });

    test('garbage pushing the stack out of the matrix tops the player out',
        () {
      final game = TetrisGame(seed: 1, scriptedPieces: [
        Tetromino.o,
        Tetromino.o,
      ]);
      // Occupy the very top row of the hidden buffer so any upward shift
      // pushes blocks out.
      game.setCell(4, 0, Tetromino.z);
      game.enqueueGarbage(1);

      game.hardDrop();

      expect(game.gameOver, isTrue);
      expect(game.drainEvents().whereType<ToppedOutEvent>(), isNotEmpty);
    });

    test('attack table matches guideline-lite values', () {
      LineClearResult clear(
        int lines, {
        bool tSpin = false,
        bool b2b = false,
        bool pc = false,
      }) {
        return LineClearResult(
          lines: lines,
          tSpin: tSpin,
          perfectClear: pc,
          backToBack: b2b,
          points: 0,
        );
      }

      expect(TetrisGame.attackForClear(clear(1), 0), 0);
      expect(TetrisGame.attackForClear(clear(2), 0), 1);
      expect(TetrisGame.attackForClear(clear(3), 0), 2);
      expect(TetrisGame.attackForClear(clear(4), 0), 4);
      expect(TetrisGame.attackForClear(clear(1, tSpin: true), 0), 2);
      expect(TetrisGame.attackForClear(clear(2, tSpin: true), 0), 4);
      expect(TetrisGame.attackForClear(clear(3, tSpin: true), 0), 6);
      expect(TetrisGame.attackForClear(clear(4, b2b: true), 0), 5);
      expect(TetrisGame.attackForClear(clear(4, pc: true), 0), 14);
      // Combo bonus ramps with sustained clears.
      expect(TetrisGame.attackForClear(clear(2), 2), 2);
      expect(TetrisGame.attackForClear(clear(2), 11), 6);
      expect(TetrisGame.attackForClear(clear(0), 5), 0);
    });

    test('locks without clears emit PieceLockedEvent', () {
      final game = TetrisGame(seed: 1);
      game.hardDrop();

      final events = game.drainEvents();
      expect(events.whereType<PieceLockedEvent>(), hasLength(1));
      expect(game.drainEvents(), isEmpty);
    });

    test('same seed yields identical pieces even when one side gets garbage',
        () {
      final a = TetrisGame(seed: 42);
      final b = TetrisGame(seed: 42);

      final piecesA = <Tetromino>[];
      final piecesB = <Tetromino>[];
      for (var i = 0; i < 15 && !a.gameOver && !b.gameOver; i += 1) {
        piecesA.add(a.active!.type);
        piecesB.add(b.active!.type);
        if (i.isEven) {
          b.enqueueGarbage(1);
        }
        a.hardDrop();
        b.hardDrop();
      }

      // Enough pieces to cross a bag refill boundary.
      expect(piecesA.length, greaterThanOrEqualTo(8));
      expect(piecesB, piecesA);
    });

    test('round-trips pending garbage through toJson/restore', () {
      final game = TetrisGame(seed: 3);
      game.enqueueGarbage(2);
      game.enqueueGarbage(1);

      final restored = TetrisGame(seed: 9)..restore(game.toJson());

      expect(restored.pendingGarbageLines, 3);
    });

    test('restores saves that predate pending garbage', () {
      final game = TetrisGame(seed: 3);
      final json = game.toJson()..remove('pendingGarbage');

      final restored = TetrisGame(seed: 9)..restore(json);

      expect(restored.pendingGarbageLines, 0);
    });
  });
}

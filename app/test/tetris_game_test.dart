import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tetris/src/game/tetris_game.dart';
import 'package:tetris/src/game/tetromino.dart';

void main() {
  group('TetrisGame', () {
    test('spawns on rows 21-22 and immediately steps down one row', () {
      final game = TetrisGame(scriptedPieces: [Tetromino.t]);

      expect(game.active?.type, Tetromino.t);
      // Spawn row is bufferRows - 2; the guideline spawn drop moves the piece
      // one row down right away when nothing blocks it.
      expect(game.active?.y, TetrisGame.bufferRows - 1);
      expect(
        game.activeCells.every((cell) => cell.y <= TetrisGame.bufferRows),
        isTrue,
      );
      expect(
        game.activeCells.map((cell) => cell.x),
        everyElement(inInclusiveRange(3, 5)),
      );
    });

    test('skips the spawn drop when the row below is blocked', () {
      final game = TetrisGame(
        scriptedPieces: [Tetromino.t, Tetromino.t, Tetromino.t],
      );
      // Block one cell of the would-be dropped position of the next spawn.
      game.setCell(4, TetrisGame.bufferRows, Tetromino.garbage);

      game.hold();

      expect(game.active?.y, TetrisGame.bufferRows - 2);
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
        bool mini = false,
        bool b2b = false,
        bool pc = false,
      }) {
        return LineClearResult(
          lines: lines,
          tSpin: tSpin,
          tSpinMini: mini,
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
      // Minis attack like plain clears of the same size.
      expect(
        TetrisGame.attackForClear(clear(1, tSpin: true, mini: true), 0),
        0,
      );
      expect(
        TetrisGame.attackForClear(clear(2, tSpin: true, mini: true), 0),
        1,
      );
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

  group('guideline compliance', () {
    test('hard drop after an airborne rotation is not a T-spin', () {
      final game = TetrisGame(scriptedPieces: [Tetromino.t, Tetromino.o]);
      // L-shaped wall left of an open column: the T free-falls into a spot
      // with three occupied corners, which must not count as a T-spin.
      game.setVisibleCell(3, 17, Tetromino.z);
      game.setVisibleCell(3, 19, Tetromino.z);
      game.setVisibleCell(5, 19, Tetromino.z);

      expect(game.rotateClockwise(), isTrue);
      final distance = game.hardDrop();

      expect(distance, greaterThan(10));
      expect(game.lastClear.tSpin, isFalse);
      expect(game.score, distance * 2);
    });

    test('hard drop from a grounded rotation keeps the T-spin', () {
      final game = TetrisGame(scriptedPieces: [Tetromino.t, Tetromino.o]);
      // TSD chamber. Row 18: cols 3-5 open. Row 19: col 4 open.
      for (var x = 0; x < TetrisGame.width; x += 1) {
        if (x != 4) game.setVisibleCell(x, 19, Tetromino.z);
        if (x < 3 || x > 5) game.setVisibleCell(x, 18, Tetromino.z);
      }
      game.setVisibleCell(3, 17, Tetromino.z); // roof forcing the down-kick
      game.setVisibleCell(6, 17, Tetromino.z); // blocks in-place rotation

      expect(game.rotateCounterClockwise(), isTrue); // 0 -> L
      expect(game.moveRight(), isTrue); // hang over the slot
      while (game.softDropStep()) {}
      // Last action: L -> 2 rotation; the SRS (-1,+1) kick drops it in. The
      // hard drop travels zero rows, so the T-spin must survive.
      expect(game.rotateCounterClockwise(), isTrue);
      final distance = game.hardDrop();

      expect(distance, 0);
      expect(game.lastClear.lines, 2);
      expect(game.lastClear.tSpin, isTrue);
      expect(game.lastClear.tSpinMini, isFalse);
      expect(game.lastClear.points, 1200);
    });

    test('wall-kick T-spin single is a mini: 200 points, no attack', () {
      final game = TetrisGame(scriptedPieces: [Tetromino.t, Tetromino.o]);
      // Bottom row full except the column hugging the left wall.
      for (var x = 1; x < TetrisGame.width; x += 1) {
        game.setVisibleCell(x, 19, Tetromino.z);
      }

      while (game.moveLeft()) {}
      while (game.softDropStep()) {}
      // 0 -> R against the wall: the (-1, 0) kick tucks the T into the
      // corner. Front corners: one filled; back corners: the wall.
      expect(game.rotateClockwise(), isTrue);
      game.hardDrop();

      expect(game.lastClear.lines, 1);
      expect(game.lastClear.tSpin, isTrue);
      expect(game.lastClear.tSpinMini, isTrue);
      expect(game.lastClear.points, 200);
      expect(TetrisGame.attackForClear(game.lastClear, 0), 0);
    });

    test('rotation stalling cannot postpone lock down forever', () {
      final game = TetrisGame(
        scriptedPieces: [Tetromino.i, Tetromino.i, Tetromino.o],
      );
      game.hardDrop();
      while (game.softDropStep()) {}

      // Alternate floor-kick rotations with sub-lock-delay ticks. Falling
      // back onto already-visited rows must not refill the 15 move resets,
      // so the piece locks once the budget runs out.
      var cycles = 0;
      while (game.lockCount < 2 && cycles < 40) {
        game.tick(const Duration(milliseconds: 400));
        if (game.lockCount >= 2) break;
        game.rotateClockwise();
        game.tick(const Duration(milliseconds: 400));
        if (game.lockCount >= 2) break;
        game.rotateCounterClockwise();
        cycles += 1;
      }

      expect(game.lockCount, greaterThanOrEqualTo(2));
      expect(cycles, lessThan(30));
    });

    test('soft drop falls at 20x gravity and scores one point per row', () {
      final game = TetrisGame(scriptedPieces: [Tetromino.t, Tetromino.i]);
      final startY = game.active!.y;

      game.setSoftDropping(true);
      // Level 1 gravity is 800ms per row; soft drop is 40ms per row.
      game.tick(const Duration(milliseconds: 120));

      expect(game.active!.y, startY + 3);
      expect(game.score, 3);

      game.setSoftDropping(false);
      game.tick(const Duration(milliseconds: 120));

      // Back on normal gravity: 120ms is far below 800ms, so no movement.
      expect(game.active!.y, startY + 3);
      expect(game.score, 3);
    });
  });
}

import 'tetris_game.dart';

/// Discrete engine occurrences drained by callers (e.g. the versus net layer)
/// via [TetrisGame.drainEvents]. Single-player never drains; the engine caps
/// the buffer so that is harmless.
sealed class TetrisEvent {
  const TetrisEvent();
}

/// A piece locked without clearing any lines.
final class PieceLockedEvent extends TetrisEvent {
  const PieceLockedEvent();
}

/// A piece locked and cleared lines. [attackSent] is the garbage that should
/// be sent to the opponent after [garbageCancelled] lines were subtracted
/// from this player's pending queue.
final class LinesClearedEvent extends TetrisEvent {
  const LinesClearedEvent({
    required this.clear,
    required this.attackSent,
    required this.garbageCancelled,
  });

  final LineClearResult clear;
  final int attackSent;
  final int garbageCancelled;
}

/// Pending garbage rows were inserted at the bottom of the board.
final class GarbageAppliedEvent extends TetrisEvent {
  const GarbageAppliedEvent({required this.lines});

  final int lines;
}

/// The game ended for this player (top-out, block-out, or garbage push-out).
final class ToppedOutEvent extends TetrisEvent {
  const ToppedOutEvent();
}

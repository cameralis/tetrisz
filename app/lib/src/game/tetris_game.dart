import 'dart:math';

import 'tetris_events.dart';
import 'tetromino.dart';

export 'tetris_events.dart';

final class LineClearResult {
  const LineClearResult({
    required this.lines,
    required this.tSpin,
    this.tSpinMini = false,
    required this.perfectClear,
    required this.backToBack,
    required this.points,
  });

  static const none = LineClearResult(
    lines: 0,
    tSpin: false,
    perfectClear: false,
    backToBack: false,
    points: 0,
  );

  final int lines;
  final bool tSpin;

  /// True for T-spins where only one of the two corners on the pointing side
  /// is occupied (guideline "T-Spin Mini"); implies [tSpin].
  final bool tSpinMini;
  final bool perfectClear;
  final bool backToBack;
  final int points;
}

/// Guideline T-spin classification for a locking T piece.
enum _TSpinKind { none, mini, full }

final class BoardSnapshot {
  BoardSnapshot._(List<List<Tetromino?>> board)
    : _board = List.unmodifiable(
        board.map((row) => List<Tetromino?>.unmodifiable(row)),
      );

  final List<List<Tetromino?>> _board;

  Tetromino? cellAt(int x, int y) {
    if (x < 0 || x >= TetrisGame.width || y < 0 || y >= TetrisGame.totalRows) {
      return null;
    }
    return _board[y][x];
  }

  Tetromino? visibleCellAt(int x, int visibleY) {
    return cellAt(x, TetrisGame.bufferRows + visibleY);
  }
}

final class LineClearAnimationSnapshot {
  LineClearAnimationSnapshot({required this.board, required Iterable<int> rows})
    : rows = List.unmodifiable(rows);

  final BoardSnapshot board;
  final List<int> rows;

  bool containsVisibleRow(int visibleY) {
    return rows.contains(TetrisGame.bufferRows + visibleY);
  }
}

final class TetrisGame {
  TetrisGame({int? seed, List<Tetromino> scriptedPieces = const []})
    : _random = Random(seed),
      // Garbage holes must never consume _random: the bag shuffle sequence has
      // to stay identical across two same-seed games even when only one of
      // them receives garbage.
      _garbageRandom = Random(seed == null ? null : seed ^ 0x6b8b4567),
      _scriptedPieces = List.of(scriptedPieces) {
    restart();
  }

  static const width = 10;
  static const visibleRows = 20;
  static const bufferRows = 20;
  static const totalRows = visibleRows + bufferRows;
  static const previewCount = 6;
  static const lockDelay = Duration(milliseconds: 500);
  static const moveResetLimit = 15;

  /// Soft drop moves the piece at this multiple of the current gravity, per
  /// the guideline's designated soft drop speed.
  static const softDropSpeedFactor = 20;

  /// SRS kick tables have five tests; a T-spin reached through the fifth
  /// (index 4, the far twist used by T-spin triples) is never a mini.
  static const _tSpinUpgradeKickIndex = 4;
  static const maxGarbagePerLock = 8;
  static const _saveVersion = 1;
  static const _maxBufferedEvents = 64;

  static const _gravityFramesByLevel = <int>[
    48,
    43,
    38,
    33,
    28,
    23,
    18,
    13,
    8,
    6,
    5,
    5,
    5,
    4,
    4,
    4,
    3,
    3,
    3,
    2,
    2,
    2,
    2,
    2,
    1,
  ];

  final Random _random;
  final Random _garbageRandom;
  final List<Tetromino> _scriptedPieces;
  late List<List<Tetromino?>> _board;
  final List<Tetromino> _bag = [];
  final List<Tetromino> _queue = [];
  // Incoming attack chunks (line counts) waiting to be applied to the board.
  final List<int> _pendingGarbage = [];
  final List<TetrisEvent> _events = [];

  int _scriptedIndex = 0;
  Duration _fallAccumulator = Duration.zero;
  Duration _lockElapsed = Duration.zero;
  int _lockResetCount = 0;
  bool _lastActionWasRotation = false;
  // Deepest row the active piece has reached; the move-reset budget only
  // refills when the piece falls below it (guideline Extended Placement).
  int _lowestReachedY = 0;
  // Which SRS kick test placed the piece in its last successful rotation.
  int _lastRotationKickIndex = 0;
  bool _softDropping = false;

  ActivePiece? active;
  Tetromino? holdPiece;
  bool canHold = true;
  bool gameOver = false;
  bool paused = false;
  int score = 0;
  int level = 1;
  int lines = 0;
  int lockCount = 0;
  int combo = -1;
  bool backToBack = false;
  LineClearResult lastClear = LineClearResult.none;
  LineClearAnimationSnapshot? lastLineClearSnapshot;

  Duration get gravityInterval {
    final index = (level - 1).clamp(0, _gravityFramesByLevel.length - 1);
    final frames = _gravityFramesByLevel[index];
    return Duration(milliseconds: max(16, (frames * 1000 / 60).round()));
  }

  /// Whether soft drop is currently engaged; while true the piece falls at
  /// [softDropSpeedFactor] times gravity and scores 1 point per row.
  bool get softDropping => _softDropping;

  void setSoftDropping(bool value) {
    if (_softDropping == value) {
      return;
    }
    _softDropping = value;
    _fallAccumulator = Duration.zero;
  }

  Duration get _fallInterval {
    final gravity = gravityInterval;
    if (!_softDropping) {
      return gravity;
    }
    return Duration(
      microseconds: max(1000, gravity.inMicroseconds ~/ softDropSpeedFactor),
    );
  }

  List<Tetromino> get nextQueue {
    return List.unmodifiable(_queue.take(previewCount));
  }

  /// Total incoming garbage lines waiting to be applied to the board.
  int get pendingGarbageLines =>
      _pendingGarbage.fold(0, (sum, lines) => sum + lines);

  /// Queues an incoming attack. Lines are applied to the bottom of the board
  /// the next time a piece locks without clearing, and can be cancelled by
  /// this player's own clears before that.
  void enqueueGarbage(int lines) {
    if (gameOver || lines <= 0) {
      return;
    }
    _pendingGarbage.add(lines);
  }

  /// Returns and clears the buffered [TetrisEvent]s emitted since the last
  /// drain. Callers that ignore events (single-player) never need this; the
  /// buffer is capped so it cannot grow unbounded.
  List<TetrisEvent> drainEvents() {
    final drained = List<TetrisEvent>.unmodifiable(_events);
    _events.clear();
    return drained;
  }

  /// Garbage lines a clear sends in versus play, before cancellation against
  /// the receiver's own pending queue. [combo] is the engine's combo counter
  /// at the time of the clear (0 = first clear in a chain). T-spin minis
  /// attack like plain clears of the same size.
  static int attackForClear(LineClearResult clear, int combo) {
    if (clear.lines == 0) {
      return 0;
    }
    var attack = clear.tSpin && !clear.tSpinMini
        ? switch (clear.lines) { 1 => 2, 2 => 4, _ => 6 }
        : switch (clear.lines) { 1 => 0, 2 => 1, 3 => 2, _ => 4 };
    if (clear.backToBack) {
      attack += 1;
    }
    attack += _comboAttackBonus[combo.clamp(0, _comboAttackBonus.length - 1)];
    if (clear.perfectClear) {
      attack += 10;
    }
    return attack;
  }

  static const _comboAttackBonus = [0, 0, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5];

  void _emit(TetrisEvent event) {
    if (_events.length >= _maxBufferedEvents) {
      _events.removeAt(0);
    }
    _events.add(event);
  }

  Iterable<MinoCell> get activeCells => active?.cells ?? const [];

  Iterable<MinoCell> get ghostCells => ghostPiece?.cells ?? const [];

  ActivePiece? get ghostPiece {
    final piece = active;
    if (piece == null) {
      return null;
    }

    var ghost = piece;
    while (_canPlace(ghost.copyWith(y: ghost.y + 1))) {
      ghost = ghost.copyWith(y: ghost.y + 1);
    }
    return ghost;
  }

  int get hardDropDistance {
    final piece = active;
    final ghost = ghostPiece;
    if (piece == null || ghost == null) {
      return 0;
    }
    return ghost.y - piece.y;
  }

  Tetromino? cellAt(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= totalRows) {
      return null;
    }
    return _board[y][x];
  }

  Tetromino? visibleCellAt(int x, int visibleY) {
    return cellAt(x, bufferRows + visibleY);
  }

  void setCell(int x, int y, Tetromino? value) {
    if (x < 0 || x >= width || y < 0 || y >= totalRows) {
      throw RangeError('Cell is outside the matrix: ($x, $y)');
    }
    _board[y][x] = value;
  }

  void setVisibleCell(int x, int visibleY, Tetromino? value) {
    setCell(x, bufferRows + visibleY, value);
  }

  void restart() {
    _board = List.generate(
      totalRows,
      (_) => List<Tetromino?>.filled(width, null),
    );
    _bag.clear();
    _queue.clear();
    _scriptedIndex = 0;
    _fallAccumulator = Duration.zero;
    _lockElapsed = Duration.zero;
    _lockResetCount = 0;
    _lastActionWasRotation = false;
    _lowestReachedY = 0;
    _lastRotationKickIndex = 0;
    _softDropping = false;
    active = null;
    holdPiece = null;
    canHold = true;
    gameOver = false;
    paused = false;
    score = 0;
    level = 1;
    lines = 0;
    lockCount = 0;
    combo = -1;
    backToBack = false;
    lastClear = LineClearResult.none;
    lastLineClearSnapshot = null;
    _pendingGarbage.clear();
    _events.clear();
    _ensureQueue();
    _spawnNext();
  }

  /// Serializes the full playable state so it can be written to disk and
  /// restored later with [restore]. The active piece, board, queue, hold slot
  /// and all scoring/lock timing are captured; transient animation snapshots
  /// are intentionally omitted.
  Map<String, dynamic> toJson() {
    return {
      'version': _saveVersion,
      'board': [
        for (final row in _board) [for (final cell in row) cell?.index ?? -1],
      ],
      'bag': [for (final type in _bag) type.index],
      'queue': [for (final type in _queue) type.index],
      'scriptedIndex': _scriptedIndex,
      'active': active == null
          ? null
          : {
              'type': active!.type.index,
              'rotation': active!.rotation,
              'x': active!.x,
              'y': active!.y,
            },
      'holdPiece': holdPiece?.index,
      'canHold': canHold,
      'gameOver': gameOver,
      'paused': paused,
      'score': score,
      'level': level,
      'lines': lines,
      'lockCount': lockCount,
      'combo': combo,
      'backToBack': backToBack,
      'fallAccumulatorUs': _fallAccumulator.inMicroseconds,
      'lockElapsedUs': _lockElapsed.inMicroseconds,
      'lockResetCount': _lockResetCount,
      'lastActionWasRotation': _lastActionWasRotation,
      'lowestReachedY': _lowestReachedY,
      'lastRotationKickIndex': _lastRotationKickIndex,
      'pendingGarbage': List<int>.of(_pendingGarbage),
    };
  }

  /// Restores state previously produced by [toJson]. Throws a [FormatException]
  /// when the payload is missing required fields or has incompatible
  /// dimensions; callers should fall back to [restart] on failure.
  void restore(Map<String, dynamic> json) {
    if (json['version'] != _saveVersion) {
      throw const FormatException('Unsupported saved game version');
    }

    final boardJson = (json['board'] as List?)?.cast<List>();
    if (boardJson == null || boardJson.length != totalRows) {
      throw const FormatException('Saved board has the wrong height');
    }
    final board = <List<Tetromino?>>[];
    for (final rowJson in boardJson) {
      if (rowJson.length != width) {
        throw const FormatException('Saved board has the wrong width');
      }
      board.add([for (final cell in rowJson) _tetrominoFromIndex(cell as int)]);
    }

    _board = board;
    _bag
      ..clear()
      ..addAll([
        for (final index in (json['bag'] as List)) Tetromino.values[index as int],
      ]);
    _queue
      ..clear()
      ..addAll([
        for (final index in (json['queue'] as List))
          Tetromino.values[index as int],
      ]);
    _scriptedIndex = json['scriptedIndex'] as int? ?? _scriptedPieces.length;

    final activeJson = json['active'] as Map?;
    active = activeJson == null
        ? null
        : ActivePiece(
            type: Tetromino.values[activeJson['type'] as int],
            rotation: activeJson['rotation'] as int,
            x: activeJson['x'] as int,
            y: activeJson['y'] as int,
          );
    holdPiece = _tetrominoFromIndex(json['holdPiece'] as int? ?? -1);
    canHold = json['canHold'] as bool? ?? true;
    gameOver = json['gameOver'] as bool? ?? false;
    paused = json['paused'] as bool? ?? false;
    score = json['score'] as int? ?? 0;
    level = json['level'] as int? ?? 1;
    lines = json['lines'] as int? ?? 0;
    lockCount = json['lockCount'] as int? ?? 0;
    combo = json['combo'] as int? ?? -1;
    backToBack = json['backToBack'] as bool? ?? false;
    _fallAccumulator = Duration(
      microseconds: json['fallAccumulatorUs'] as int? ?? 0,
    );
    _lockElapsed = Duration(microseconds: json['lockElapsedUs'] as int? ?? 0);
    _lockResetCount = json['lockResetCount'] as int? ?? 0;
    _lastActionWasRotation = json['lastActionWasRotation'] as bool? ?? false;
    // Saves from before these fields existed default conservatively: the
    // current row counts as the lowest already reached.
    _lowestReachedY = json['lowestReachedY'] as int? ?? active?.y ?? 0;
    _lastRotationKickIndex = json['lastRotationKickIndex'] as int? ?? 0;
    _softDropping = false;
    _pendingGarbage
      ..clear()
      ..addAll([
        for (final lines in (json['pendingGarbage'] as List? ?? const []))
          lines as int,
      ]);
    _events.clear();
    lastClear = LineClearResult.none;
    lastLineClearSnapshot = null;
  }

  static Tetromino? _tetrominoFromIndex(int index) {
    if (index < 0 || index >= Tetromino.values.length) {
      return null;
    }
    return Tetromino.values[index];
  }

  void tick(Duration elapsed) {
    if (gameOver || paused || active == null) {
      return;
    }

    _fallAccumulator += elapsed;
    final interval = _fallInterval;
    while (_fallAccumulator >= interval) {
      if (_tryMove(0, 1, resetLock: false)) {
        _fallAccumulator -= interval;
        if (_softDropping) {
          score += 1;
        }
      } else {
        _fallAccumulator = Duration.zero;
        break;
      }
    }

    final piece = active;
    if (piece == null) {
      return;
    }

    // The lock timer only accrues while grounded; going airborne (up-kick,
    // sliding off a ledge) pauses it. It resets when the piece falls to a new
    // lowest row or a move/rotation spends one of the 15 lock resets.
    if (_isGrounded(piece)) {
      _lockElapsed += elapsed;
      if (_lockElapsed >= lockDelay) {
        _lockActive();
      }
    }
  }

  bool moveLeft() => _tryMove(-1, 0);

  bool moveRight() => _tryMove(1, 0);

  bool softDropStep() {
    final moved = _tryMove(0, 1, resetLock: false);
    if (moved) {
      score += 1;
    }
    return moved;
  }

  int hardDrop() {
    final piece = active;
    final ghost = ghostPiece;
    if (piece == null || ghost == null || gameOver || paused) {
      return 0;
    }

    final distance = ghost.y - piece.y;
    if (distance > 0) {
      // The drop, not the rotation, is now the piece's last action, so the
      // lock below must not count as a T-spin.
      _lastActionWasRotation = false;
    }
    active = ghost;
    score += distance * 2;
    _lockActive();
    return distance;
  }

  bool rotateClockwise() => _rotate(1);

  bool rotateCounterClockwise() => _rotate(-1);

  bool hold() {
    final piece = active;
    if (piece == null || !canHold || gameOver || paused) {
      return false;
    }

    final previousHold = holdPiece;
    holdPiece = piece.type;
    canHold = false;
    _fallAccumulator = Duration.zero;
    _lockElapsed = Duration.zero;
    _lockResetCount = 0;
    _lastActionWasRotation = false;

    if (previousHold == null) {
      _spawnNext();
    } else {
      _spawnPiece(previousHold);
    }
    return true;
  }

  void togglePause() {
    if (!gameOver) {
      paused = !paused;
    }
  }

  bool _tryMove(int dx, int dy, {bool resetLock = true}) {
    final piece = active;
    if (piece == null || gameOver || paused) {
      return false;
    }

    final moved = piece.copyWith(x: piece.x + dx, y: piece.y + dy);
    if (!_canPlace(moved)) {
      return false;
    }

    final wasGrounded = _isGrounded(piece);
    active = moved;
    _lastActionWasRotation = false;
    if (dy > 0) {
      _refillLockResetsIfNewLowest(moved);
    } else if (resetLock) {
      _spendLockReset(wasGrounded: wasGrounded);
    }
    return true;
  }

  bool _rotate(int direction) {
    final piece = active;
    if (piece == null || gameOver || paused) {
      return false;
    }

    final from = normalizeRotation(piece.rotation);
    final to = normalizeRotation(from + direction);
    final kicks = _wallKicks(piece.type, from, to);
    for (var kickIndex = 0; kickIndex < kicks.length; kickIndex += 1) {
      final kick = kicks[kickIndex];
      final rotated = piece.copyWith(
        rotation: to,
        x: piece.x + kick.x,
        y: piece.y + kick.y,
      );
      if (_canPlace(rotated)) {
        final wasGrounded = _isGrounded(piece);
        active = rotated;
        _lastActionWasRotation = true;
        _lastRotationKickIndex = kickIndex;
        if (rotated.y > _lowestReachedY) {
          // A downward kick advances the low-water mark without refilling the
          // reset budget: only genuine falls refill it.
          _lowestReachedY = rotated.y;
        }
        _spendLockReset(wasGrounded: wasGrounded);
        return true;
      }
    }
    return false;
  }

  /// Refills the move-reset budget when the piece falls below every row it
  /// has occupied before; falling back onto already-visited rows (after an
  /// upward kick) keeps the spent budget, so lock delay cannot be stalled
  /// forever.
  void _refillLockResetsIfNewLowest(ActivePiece moved) {
    if (moved.y > _lowestReachedY) {
      _lowestReachedY = moved.y;
      _lockElapsed = Duration.zero;
      _lockResetCount = 0;
    }
  }

  /// Spends one of the 15 lock-delay resets for a move or rotation performed
  /// in the lock phase (grounded before or after the action). Once the budget
  /// is exhausted the timer keeps running and the piece locks when it expires.
  void _spendLockReset({required bool wasGrounded}) {
    final piece = active;
    if (piece == null || (!wasGrounded && !_isGrounded(piece))) {
      return;
    }
    if (_lockResetCount < moveResetLimit) {
      _lockElapsed = Duration.zero;
      _lockResetCount += 1;
    }
  }

  bool _canPlace(ActivePiece piece) {
    for (final cell in piece.cells) {
      if (cell.x < 0 || cell.x >= width) {
        return false;
      }
      if (cell.y < 0 || cell.y >= totalRows) {
        return false;
      }
      if (_board[cell.y][cell.x] != null) {
        return false;
      }
    }
    return true;
  }

  bool _isGrounded(ActivePiece piece) {
    return !_canPlace(piece.copyWith(y: piece.y + 1));
  }

  void _lockActive() {
    final piece = active;
    if (piece == null) {
      return;
    }

    final cells = piece.cells.toList(growable: false);
    final locksCompletelyAboveVisible = cells.every(
      (cell) => cell.y < bufferRows,
    );
    final tSpinKind = _detectTSpin(piece);

    for (final cell in cells) {
      if (cell.y < 0 || cell.y >= totalRows) {
        gameOver = true;
        active = null;
        _emit(const ToppedOutEvent());
        return;
      }
      _board[cell.y][cell.x] = cell.type;
    }
    lockCount += 1;

    final filledRows = _filledRows();
    lastLineClearSnapshot = filledRows.isEmpty
        ? null
        : LineClearAnimationSnapshot(
            board: BoardSnapshot._(_board),
            rows: filledRows,
          );
    final cleared = _clearLines();
    final perfectClear = cleared > 0 && _isBoardEmpty;
    _applyScoring(
      cleared,
      tSpin: tSpinKind != _TSpinKind.none,
      tSpinMini: tSpinKind == _TSpinKind.mini,
      perfectClear: perfectClear,
    );

    if (cleared > 0) {
      final attack = attackForClear(lastClear, combo);
      final remaining = _cancelPendingGarbage(attack);
      _emit(
        LinesClearedEvent(
          clear: lastClear,
          attackSent: remaining,
          garbageCancelled: attack - remaining,
        ),
      );
    } else {
      _emit(const PieceLockedEvent());
    }

    if (locksCompletelyAboveVisible) {
      gameOver = true;
      active = null;
      _emit(const ToppedOutEvent());
      return;
    }

    if (cleared == 0 && _pendingGarbage.isNotEmpty) {
      final applied = _applyPendingGarbageRows();
      if (applied > 0) {
        _emit(GarbageAppliedEvent(lines: applied));
      }
      if (gameOver) {
        active = null;
        _emit(const ToppedOutEvent());
        return;
      }
    }

    canHold = true;
    _fallAccumulator = Duration.zero;
    _lockElapsed = Duration.zero;
    _lockResetCount = 0;
    _lastActionWasRotation = false;
    _spawnNext();
  }

  /// Consumes pending garbage chunks against an outgoing [attack]; returns
  /// the attack lines left over to send to the opponent.
  int _cancelPendingGarbage(int attack) {
    var remaining = attack;
    while (remaining > 0 && _pendingGarbage.isNotEmpty) {
      if (_pendingGarbage.first <= remaining) {
        remaining -= _pendingGarbage.removeAt(0);
      } else {
        _pendingGarbage.first -= remaining;
        remaining = 0;
      }
    }
    return remaining;
  }

  /// Inserts pending garbage rows at the bottom of the board (shifting the
  /// stack up), at most [maxGarbagePerLock] lines per lock; the remainder
  /// stays queued. Each chunk gets a single hole column. Sets [gameOver] when
  /// the displaced stack would be pushed out of the top of the matrix.
  int _applyPendingGarbageRows() {
    var applied = 0;
    while (_pendingGarbage.isNotEmpty && applied < maxGarbagePerLock) {
      final chunk = min(_pendingGarbage.first, maxGarbagePerLock - applied);
      if (chunk <= 0) {
        break;
      }
      if (_pendingGarbage.first <= chunk) {
        _pendingGarbage.removeAt(0);
      } else {
        _pendingGarbage.first -= chunk;
      }

      final hole = _garbageRandom.nextInt(width);
      for (var i = 0; i < chunk; i += 1) {
        if (_board.first.any((cell) => cell != null)) {
          gameOver = true;
          return applied;
        }
        _board.removeAt(0);
        _board.add(
          List<Tetromino?>.generate(
            width,
            (x) => x == hole ? null : Tetromino.garbage,
          ),
        );
        applied += 1;
      }
    }
    return applied;
  }

  int _clearLines() {
    var cleared = 0;
    var y = totalRows - 1;
    while (y >= 0) {
      if (_board[y].every((cell) => cell != null)) {
        _board.removeAt(y);
        _board.insert(0, List<Tetromino?>.filled(width, null));
        cleared += 1;
      } else {
        y -= 1;
      }
    }
    return cleared;
  }

  List<int> _filledRows() {
    final rows = <int>[];
    for (var y = 0; y < totalRows; y += 1) {
      if (_board[y].every((cell) => cell != null)) {
        rows.add(y);
      }
    }
    return rows;
  }

  void _applyScoring(
    int lineCount, {
    required bool tSpin,
    required bool tSpinMini,
    required bool perfectClear,
  }) {
    final scoringLevel = level;
    final wasBackToBack = backToBack;
    final difficult = lineCount == 4 || (tSpin && lineCount > 0);
    var points = _baseLineClearPoints(
      lineCount,
      tSpin: tSpin,
      tSpinMini: tSpinMini,
    );

    if (difficult && wasBackToBack) {
      points = (points * 3 / 2).round();
    }

    if (lineCount > 0) {
      combo += 1;
      if (combo > 0) {
        points += 50 * combo;
      }
    } else {
      combo = -1;
    }

    if (perfectClear) {
      points += _perfectClearPoints(lineCount, backToBackTetris: wasBackToBack);
    }

    score += points * scoringLevel;
    lines += lineCount;
    level = 1 + lines ~/ 10;

    if (lineCount > 0) {
      backToBack = difficult || (backToBack && !difficult);
      if (!difficult) {
        backToBack = false;
      }
    }

    lastClear = LineClearResult(
      lines: lineCount,
      tSpin: tSpin,
      tSpinMini: tSpinMini,
      perfectClear: perfectClear,
      backToBack: difficult && wasBackToBack,
      points: points * scoringLevel,
    );
  }

  int _baseLineClearPoints(
    int lineCount, {
    required bool tSpin,
    required bool tSpinMini,
  }) {
    if (tSpinMini) {
      return switch (lineCount) { 0 => 100, 1 => 200, 2 => 400, _ => 0 };
    }

    if (tSpin) {
      return switch (lineCount) {
        0 => 400,
        1 => 800,
        2 => 1200,
        3 => 1600,
        _ => 0,
      };
    }

    return switch (lineCount) {
      1 => 100,
      2 => 300,
      3 => 500,
      4 => 800,
      _ => 0,
    };
  }

  int _perfectClearPoints(int lineCount, {required bool backToBackTetris}) {
    if (lineCount == 4 && backToBackTetris) {
      return 3200;
    }
    return switch (lineCount) {
      1 => 800,
      2 => 1200,
      3 => 1800,
      4 => 2000,
      _ => 0,
    };
  }

  /// Guideline 3-corner T-spin detection with mini classification: a T whose
  /// last action was a rotation and that has at least three of the four
  /// diagonal corners around its center occupied is a T-spin. It is a mini
  /// when only one of the two corners on the pointing side (next to the nub)
  /// is occupied, unless the rotation used the fifth SRS kick test.
  _TSpinKind _detectTSpin(ActivePiece piece) {
    if (piece.type != Tetromino.t || !_lastActionWasRotation) {
      return _TSpinKind.none;
    }

    final centerX = piece.x + 1;
    final centerY = piece.y + 1;
    // Corner offsets on the side the nub points toward (front) and the flat
    // side (back), per rotation state: 0 points up, R right, 2 down, L left.
    final front = switch (normalizeRotation(piece.rotation)) {
      0 => const [GridPoint(-1, -1), GridPoint(1, -1)],
      1 => const [GridPoint(1, -1), GridPoint(1, 1)],
      2 => const [GridPoint(-1, 1), GridPoint(1, 1)],
      _ => const [GridPoint(-1, -1), GridPoint(-1, 1)],
    };
    final back = switch (normalizeRotation(piece.rotation)) {
      0 => const [GridPoint(-1, 1), GridPoint(1, 1)],
      1 => const [GridPoint(-1, -1), GridPoint(-1, 1)],
      2 => const [GridPoint(-1, -1), GridPoint(1, -1)],
      _ => const [GridPoint(1, -1), GridPoint(1, 1)],
    };

    int occupied(List<GridPoint> offsets) => offsets
        .where(
          (offset) => _isOccupiedForTSpin(
            GridPoint(centerX + offset.x, centerY + offset.y),
          ),
        )
        .length;

    final frontOccupied = occupied(front);
    final backOccupied = occupied(back);
    if (frontOccupied + backOccupied < 3) {
      return _TSpinKind.none;
    }
    if (frontOccupied == 2 ||
        _lastRotationKickIndex == _tSpinUpgradeKickIndex) {
      return _TSpinKind.full;
    }
    return _TSpinKind.mini;
  }

  bool _isOccupiedForTSpin(GridPoint point) {
    if (point.x < 0 || point.x >= width || point.y >= totalRows) {
      return true;
    }
    if (point.y < 0) {
      return false;
    }
    return _board[point.y][point.x] != null;
  }

  bool get _isBoardEmpty {
    return _board.every((row) => row.every((cell) => cell == null));
  }

  void _spawnNext() {
    _spawnPiece(_drawNext());
  }

  void _spawnPiece(Tetromino type) {
    var piece = ActivePiece(
      type: type,
      rotation: 0,
      x: _spawnX(type),
      y: _spawnY(type),
    );

    if (!_canPlace(piece)) {
      gameOver = true;
      active = null;
      _emit(const ToppedOutEvent());
      return;
    }

    // Guideline: pieces move down one row immediately after appearing.
    final dropped = piece.copyWith(y: piece.y + 1);
    if (_canPlace(dropped)) {
      piece = dropped;
    }
    active = piece;
    _lowestReachedY = piece.y;
  }

  int _spawnX(Tetromino type) {
    return switch (type) {
      Tetromino.i || Tetromino.o => 3,
      _ => 3,
    };
  }

  int _spawnY(Tetromino type) {
    return switch (type) {
      Tetromino.i => bufferRows - 2,
      _ => bufferRows - 2,
    };
  }

  Tetromino _drawNext() {
    _ensureQueue();
    final type = _queue.removeAt(0);
    _ensureQueue();
    return type;
  }

  void _ensureQueue() {
    while (_queue.length < previewCount + 1) {
      if (_scriptedIndex < _scriptedPieces.length) {
        _queue.add(_scriptedPieces[_scriptedIndex]);
        _scriptedIndex += 1;
        continue;
      }

      if (_bag.isEmpty) {
        _bag.addAll(Tetromino.playablePieces);
        _bag.shuffle(_random);
      }
      _queue.add(_bag.removeLast());
    }
  }

  List<GridPoint> _wallKicks(Tetromino type, int from, int to) {
    if (type == Tetromino.o) {
      return _noKick;
    }

    final key = from * 4 + to;
    if (type == Tetromino.i) {
      return switch (key) {
        1 => _i0R,
        4 => _iR0,
        6 => _iR2,
        9 => _i2R,
        11 => _i2L,
        14 => _iL2,
        12 => _iL0,
        3 => _i0L,
        _ => _noKick,
      };
    }

    return switch (key) {
      1 => _jlstz0R,
      4 => _jlstzR0,
      6 => _jlstzR2,
      9 => _jlstz2R,
      11 => _jlstz2L,
      14 => _jlstzL2,
      12 => _jlstzL0,
      3 => _jlstz0L,
      _ => _noKick,
    };
  }
}

const _noKick = <GridPoint>[GridPoint(0, 0)];

const _jlstz0R = <GridPoint>[
  GridPoint(0, 0),
  GridPoint(-1, 0),
  GridPoint(-1, -1),
  GridPoint(0, 2),
  GridPoint(-1, 2),
];
const _jlstzR0 = <GridPoint>[
  GridPoint(0, 0),
  GridPoint(1, 0),
  GridPoint(1, 1),
  GridPoint(0, -2),
  GridPoint(1, -2),
];
const _jlstzR2 = _jlstzR0;
const _jlstz2R = _jlstz0R;
const _jlstz2L = <GridPoint>[
  GridPoint(0, 0),
  GridPoint(1, 0),
  GridPoint(1, -1),
  GridPoint(0, 2),
  GridPoint(1, 2),
];
const _jlstzL2 = <GridPoint>[
  GridPoint(0, 0),
  GridPoint(-1, 0),
  GridPoint(-1, 1),
  GridPoint(0, -2),
  GridPoint(-1, -2),
];
const _jlstzL0 = _jlstzL2;
const _jlstz0L = _jlstz2L;

const _i0R = <GridPoint>[
  GridPoint(0, 0),
  GridPoint(-2, 0),
  GridPoint(1, 0),
  GridPoint(-2, 1),
  GridPoint(1, -2),
];
const _iR0 = <GridPoint>[
  GridPoint(0, 0),
  GridPoint(2, 0),
  GridPoint(-1, 0),
  GridPoint(2, -1),
  GridPoint(-1, 2),
];
const _iR2 = <GridPoint>[
  GridPoint(0, 0),
  GridPoint(-1, 0),
  GridPoint(2, 0),
  GridPoint(-1, -2),
  GridPoint(2, 1),
];
const _i2R = <GridPoint>[
  GridPoint(0, 0),
  GridPoint(1, 0),
  GridPoint(-2, 0),
  GridPoint(1, 2),
  GridPoint(-2, -1),
];
const _i2L = _iR0;
const _iL2 = _i0R;
const _iL0 = _i2R;
const _i0L = _iR2;

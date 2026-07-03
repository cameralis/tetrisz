import 'dart:math';

import 'tetromino.dart';

final class LineClearResult {
  const LineClearResult({
    required this.lines,
    required this.tSpin,
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
  final bool perfectClear;
  final bool backToBack;
  final int points;
}

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
  static const _saveVersion = 1;

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
  final List<Tetromino> _scriptedPieces;
  late List<List<Tetromino?>> _board;
  final List<Tetromino> _bag = [];
  final List<Tetromino> _queue = [];

  int _scriptedIndex = 0;
  Duration _fallAccumulator = Duration.zero;
  Duration _lockElapsed = Duration.zero;
  int _lockResetCount = 0;
  bool _lastActionWasRotation = false;

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

  List<Tetromino> get nextQueue {
    return List.unmodifiable(_queue.take(previewCount));
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
    final gravity = gravityInterval;
    while (_fallAccumulator >= gravity) {
      if (_tryMove(0, 1, resetLock: false)) {
        _fallAccumulator -= gravity;
        _lockElapsed = Duration.zero;
        _lockResetCount = 0;
      } else {
        _fallAccumulator = Duration.zero;
        break;
      }
    }

    final piece = active;
    if (piece == null) {
      return;
    }

    if (_isGrounded(piece)) {
      _lockElapsed += elapsed;
      if (_lockElapsed >= lockDelay) {
        _lockActive();
      }
    } else {
      _lockElapsed = Duration.zero;
    }
  }

  bool moveLeft() => _tryMove(-1, 0);

  bool moveRight() => _tryMove(1, 0);

  bool softDropStep() {
    final moved = _tryMove(0, 1, resetLock: false);
    if (moved) {
      score += 1;
      _lockElapsed = Duration.zero;
      _lockResetCount = 0;
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

    active = moved;
    _lastActionWasRotation = false;
    if (dy > 0) {
      _lockElapsed = Duration.zero;
      _lockResetCount = 0;
    } else if (resetLock) {
      _resetLockDelayIfGrounded();
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
    for (final kick in _wallKicks(piece.type, from, to)) {
      final rotated = piece.copyWith(
        rotation: to,
        x: piece.x + kick.x,
        y: piece.y + kick.y,
      );
      if (_canPlace(rotated)) {
        active = rotated;
        _lastActionWasRotation = true;
        _resetLockDelayIfGrounded();
        return true;
      }
    }
    return false;
  }

  void _resetLockDelayIfGrounded() {
    final piece = active;
    if (piece == null || !_isGrounded(piece)) {
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
    final tSpin = _detectTSpin(piece);

    for (final cell in cells) {
      if (cell.y < 0 || cell.y >= totalRows) {
        gameOver = true;
        active = null;
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
    _applyScoring(cleared, tSpin: tSpin, perfectClear: perfectClear);

    if (locksCompletelyAboveVisible) {
      gameOver = true;
      active = null;
      return;
    }

    canHold = true;
    _fallAccumulator = Duration.zero;
    _lockElapsed = Duration.zero;
    _lockResetCount = 0;
    _lastActionWasRotation = false;
    _spawnNext();
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
    required bool perfectClear,
  }) {
    final scoringLevel = level;
    final wasBackToBack = backToBack;
    final difficult = lineCount == 4 || (tSpin && lineCount > 0);
    var points = _baseLineClearPoints(lineCount, tSpin: tSpin);

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
      perfectClear: perfectClear,
      backToBack: difficult && wasBackToBack,
      points: points * scoringLevel,
    );
  }

  int _baseLineClearPoints(int lineCount, {required bool tSpin}) {
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

  bool _detectTSpin(ActivePiece piece) {
    if (piece.type != Tetromino.t || !_lastActionWasRotation) {
      return false;
    }

    final centerX = piece.x + 1;
    final centerY = piece.y + 1;
    final corners = <GridPoint>[
      GridPoint(centerX - 1, centerY - 1),
      GridPoint(centerX + 1, centerY - 1),
      GridPoint(centerX - 1, centerY + 1),
      GridPoint(centerX + 1, centerY + 1),
    ];

    return corners.where((corner) => _isOccupiedForTSpin(corner)).length >= 3;
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
    final piece = ActivePiece(
      type: type,
      rotation: 0,
      x: _spawnX(type),
      y: _spawnY(type),
    );

    active = piece;
    if (!_canPlace(piece)) {
      gameOver = true;
      active = null;
    }
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
        _bag.addAll(Tetromino.values);
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

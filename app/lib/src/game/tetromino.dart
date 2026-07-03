enum Tetromino {
  i,
  j,
  l,
  o,
  s,
  z,
  t,
  // Locked garbage cells only; never spawns as an active piece. Keep last so
  // index-based save files stay valid.
  garbage;

  /// The seven pieces the 7-bag draws from; excludes [garbage].
  static const List<Tetromino> playablePieces = [i, j, l, o, s, z, t];

  String get label => switch (this) {
    Tetromino.i => 'I',
    Tetromino.j => 'J',
    Tetromino.l => 'L',
    Tetromino.o => 'O',
    Tetromino.s => 'S',
    Tetromino.z => 'Z',
    Tetromino.t => 'T',
    Tetromino.garbage => 'X',
  };
}

final class GridPoint {
  const GridPoint(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) {
    return other is GridPoint && other.x == x && other.y == y;
  }

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'GridPoint($x, $y)';
}

final class MinoCell {
  const MinoCell({required this.x, required this.y, required this.type});

  final int x;
  final int y;
  final Tetromino type;
}

final class ActivePiece {
  const ActivePiece({
    required this.type,
    required this.rotation,
    required this.x,
    required this.y,
  });

  final Tetromino type;
  final int rotation;
  final int x;
  final int y;

  ActivePiece copyWith({Tetromino? type, int? rotation, int? x, int? y}) {
    return ActivePiece(
      type: type ?? this.type,
      rotation: rotation ?? this.rotation,
      x: x ?? this.x,
      y: y ?? this.y,
    );
  }

  Iterable<MinoCell> get cells sync* {
    for (final point in tetrominoCells(type, rotation)) {
      yield MinoCell(x: x + point.x, y: y + point.y, type: type);
    }
  }
}

int normalizeRotation(int rotation) =>
    rotation % 4 < 0 ? rotation % 4 + 4 : rotation % 4;

List<GridPoint> tetrominoCells(Tetromino type, int rotation) {
  final state = normalizeRotation(rotation);
  return switch (type) {
    Tetromino.i => _iCells[state],
    Tetromino.j => _jCells[state],
    Tetromino.l => _lCells[state],
    Tetromino.o => _oCells[state],
    Tetromino.s => _sCells[state],
    Tetromino.z => _zCells[state],
    Tetromino.t => _tCells[state],
    Tetromino.garbage => const [],
  };
}

const _iCells = <List<GridPoint>>[
  [GridPoint(0, 1), GridPoint(1, 1), GridPoint(2, 1), GridPoint(3, 1)],
  [GridPoint(2, 0), GridPoint(2, 1), GridPoint(2, 2), GridPoint(2, 3)],
  [GridPoint(0, 2), GridPoint(1, 2), GridPoint(2, 2), GridPoint(3, 2)],
  [GridPoint(1, 0), GridPoint(1, 1), GridPoint(1, 2), GridPoint(1, 3)],
];

const _jCells = <List<GridPoint>>[
  [GridPoint(0, 0), GridPoint(0, 1), GridPoint(1, 1), GridPoint(2, 1)],
  [GridPoint(1, 0), GridPoint(2, 0), GridPoint(1, 1), GridPoint(1, 2)],
  [GridPoint(0, 1), GridPoint(1, 1), GridPoint(2, 1), GridPoint(2, 2)],
  [GridPoint(1, 0), GridPoint(1, 1), GridPoint(0, 2), GridPoint(1, 2)],
];

const _lCells = <List<GridPoint>>[
  [GridPoint(2, 0), GridPoint(0, 1), GridPoint(1, 1), GridPoint(2, 1)],
  [GridPoint(1, 0), GridPoint(1, 1), GridPoint(1, 2), GridPoint(2, 2)],
  [GridPoint(0, 1), GridPoint(1, 1), GridPoint(2, 1), GridPoint(0, 2)],
  [GridPoint(0, 0), GridPoint(1, 0), GridPoint(1, 1), GridPoint(1, 2)],
];

const _oCells = <List<GridPoint>>[
  [GridPoint(1, 0), GridPoint(2, 0), GridPoint(1, 1), GridPoint(2, 1)],
  [GridPoint(1, 0), GridPoint(2, 0), GridPoint(1, 1), GridPoint(2, 1)],
  [GridPoint(1, 0), GridPoint(2, 0), GridPoint(1, 1), GridPoint(2, 1)],
  [GridPoint(1, 0), GridPoint(2, 0), GridPoint(1, 1), GridPoint(2, 1)],
];

const _sCells = <List<GridPoint>>[
  [GridPoint(1, 0), GridPoint(2, 0), GridPoint(0, 1), GridPoint(1, 1)],
  [GridPoint(1, 0), GridPoint(1, 1), GridPoint(2, 1), GridPoint(2, 2)],
  [GridPoint(1, 1), GridPoint(2, 1), GridPoint(0, 2), GridPoint(1, 2)],
  [GridPoint(0, 0), GridPoint(0, 1), GridPoint(1, 1), GridPoint(1, 2)],
];

const _zCells = <List<GridPoint>>[
  [GridPoint(0, 0), GridPoint(1, 0), GridPoint(1, 1), GridPoint(2, 1)],
  [GridPoint(2, 0), GridPoint(1, 1), GridPoint(2, 1), GridPoint(1, 2)],
  [GridPoint(0, 1), GridPoint(1, 1), GridPoint(1, 2), GridPoint(2, 2)],
  [GridPoint(1, 0), GridPoint(0, 1), GridPoint(1, 1), GridPoint(0, 2)],
];

const _tCells = <List<GridPoint>>[
  [GridPoint(1, 0), GridPoint(0, 1), GridPoint(1, 1), GridPoint(2, 1)],
  [GridPoint(1, 0), GridPoint(1, 1), GridPoint(2, 1), GridPoint(1, 2)],
  [GridPoint(0, 1), GridPoint(1, 1), GridPoint(2, 1), GridPoint(1, 2)],
  [GridPoint(1, 0), GridPoint(0, 1), GridPoint(1, 1), GridPoint(1, 2)],
];

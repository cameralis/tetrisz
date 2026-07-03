import '../game/tetris_game.dart';
import '../game/tetromino.dart';

/// Wire protocol version for game messages.
const int gameProtocolVersion = 1;

/// WebSocket close codes the backend uses to reject a join.
const int closeRoomNotFound = 4404;
const int closeRoomFull = 4409;

// ---------------------------------------------------------------------------
// Server envelope: messages on the room WebSocket.
// ---------------------------------------------------------------------------

sealed class ServerEnvelope {
  const ServerEnvelope();

  /// Decodes a server envelope; returns null for unknown or malformed input.
  static ServerEnvelope? decode(Object? json) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    switch (json['t']) {
      case 'joined':
        final role = json['role'];
        if (role is! String) {
          return null;
        }
        return JoinedEnvelope(
          role: role,
          rejoin: json['rejoin'] as bool? ?? false,
        );
      case 'peer_joined':
        return const PeerJoinedEnvelope();
      case 'peer_rejoined':
        return const PeerRejoinedEnvelope();
      case 'peer_left':
        return const PeerLeftEnvelope();
      case 'start':
        final seed = json['seed'];
        final matchId = json['matchId'];
        if (seed is! int || matchId is! int) {
          return null;
        }
        return StartEnvelope(seed: seed, matchId: matchId);
      case 'rematch_requested':
        return const RematchRequestedEnvelope();
      case 'signal':
        return SignalEnvelope(data: json['d']);
      case 'relay':
        return RelayEnvelope(data: json['d']);
      case 'pong':
        return const PongEnvelope();
      default:
        return null;
    }
  }
}

final class JoinedEnvelope extends ServerEnvelope {
  const JoinedEnvelope({required this.role, required this.rejoin});

  final String role;
  final bool rejoin;

  bool get isHost => role == 'host';
}

final class PeerJoinedEnvelope extends ServerEnvelope {
  const PeerJoinedEnvelope();
}

final class PeerRejoinedEnvelope extends ServerEnvelope {
  const PeerRejoinedEnvelope();
}

final class PeerLeftEnvelope extends ServerEnvelope {
  const PeerLeftEnvelope();
}

final class StartEnvelope extends ServerEnvelope {
  const StartEnvelope({required this.seed, required this.matchId});

  final int seed;
  final int matchId;
}

final class RematchRequestedEnvelope extends ServerEnvelope {
  const RematchRequestedEnvelope();
}

final class SignalEnvelope extends ServerEnvelope {
  const SignalEnvelope({required this.data});

  final Object? data;
}

final class RelayEnvelope extends ServerEnvelope {
  const RelayEnvelope({required this.data});

  final Object? data;
}

final class PongEnvelope extends ServerEnvelope {
  const PongEnvelope();
}

// ---------------------------------------------------------------------------
// Game messages: travel over the WebRTC data channel or inside `relay.d`.
// ---------------------------------------------------------------------------

sealed class GameMessage {
  const GameMessage();

  Map<String, dynamic> encode();

  /// Decodes a game message; returns null for unknown/incompatible input.
  static GameMessage? decode(Object? json) {
    if (json is! Map<String, dynamic> ||
        json['v'] != gameProtocolVersion ||
        json['k'] is! String) {
      return null;
    }
    switch (json['k']) {
      case 'attack':
        final seq = json['seq'];
        final lines = json['lines'];
        if (seq is! int || lines is! int) {
          return null;
        }
        return AttackMsg(seq: seq, lines: lines);
      case 'state':
        final seq = json['seq'];
        final cells = json['cells'];
        if (seq is! int || cells is! String) {
          return null;
        }
        return BoardStateMsg(
          seq: seq,
          cells: cells,
          active: ActivePieceWire.decode(json['active']),
          pendingGarbage: json['pending'] as int? ?? 0,
          score: json['score'] as int? ?? 0,
          lines: json['lines'] as int? ?? 0,
        );
      case 'over':
        final seq = json['seq'];
        if (seq is! int) {
          return null;
        }
        return GameOverMsg(seq: seq);
      case 'ping':
        final ts = json['ts'];
        if (ts is! int) {
          return null;
        }
        return P2pPingMsg(timestampMs: ts);
      case 'pong':
        final ts = json['ts'];
        if (ts is! int) {
          return null;
        }
        return P2pPongMsg(timestampMs: ts);
      default:
        return null;
    }
  }
}

/// Garbage attack. [seq] is monotonic per sender so receivers can dedup when
/// the same attack arrives over both transports.
final class AttackMsg extends GameMessage {
  const AttackMsg({required this.seq, required this.lines});

  final int seq;
  final int lines;

  @override
  Map<String, dynamic> encode() => {
    'v': gameProtocolVersion,
    'k': 'attack',
    'seq': seq,
    'lines': lines,
  };
}

/// Throttled mirror of the sender's board for display on the opponent's
/// screen. Stale snapshots (lower [seq]) are dropped by the receiver.
final class BoardStateMsg extends GameMessage {
  const BoardStateMsg({
    required this.seq,
    required this.cells,
    required this.active,
    required this.pendingGarbage,
    required this.score,
    required this.lines,
  });

  final int seq;

  /// Visible board as a 200-char string (20 rows x 10 columns, top-down,
  /// row-major): '.' for empty, otherwise the [Tetromino] index digit.
  final String cells;
  final ActivePieceWire? active;
  final int pendingGarbage;
  final int score;
  final int lines;

  @override
  Map<String, dynamic> encode() => {
    'v': gameProtocolVersion,
    'k': 'state',
    'seq': seq,
    'cells': cells,
    'active': active?.encode(),
    'pending': pendingGarbage,
    'score': score,
    'lines': lines,
  };
}

final class GameOverMsg extends GameMessage {
  const GameOverMsg({required this.seq});

  final int seq;

  @override
  Map<String, dynamic> encode() => {
    'v': gameProtocolVersion,
    'k': 'over',
    'seq': seq,
  };
}

final class P2pPingMsg extends GameMessage {
  const P2pPingMsg({required this.timestampMs});

  final int timestampMs;

  @override
  Map<String, dynamic> encode() => {
    'v': gameProtocolVersion,
    'k': 'ping',
    'ts': timestampMs,
  };
}

final class P2pPongMsg extends GameMessage {
  const P2pPongMsg({required this.timestampMs});

  final int timestampMs;

  @override
  Map<String, dynamic> encode() => {
    'v': gameProtocolVersion,
    'k': 'pong',
    'ts': timestampMs,
  };
}

/// Active piece on the wire. Coordinates use full-matrix rows (0 is the top
/// hidden buffer row), matching [ActivePiece].
final class ActivePieceWire {
  const ActivePieceWire({
    required this.type,
    required this.rotation,
    required this.x,
    required this.y,
  });

  final Tetromino type;
  final int rotation;
  final int x;
  final int y;

  static ActivePieceWire? decode(Object? json) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    final type = json['t'];
    final rotation = json['r'];
    final x = json['x'];
    final y = json['y'];
    if (type is! int ||
        rotation is! int ||
        x is! int ||
        y is! int ||
        type < 0 ||
        type >= Tetromino.values.length) {
      return null;
    }
    return ActivePieceWire(
      type: Tetromino.values[type],
      rotation: rotation,
      x: x,
      y: y,
    );
  }

  Map<String, dynamic> encode() => {
    't': type.index,
    'r': rotation,
    'x': x,
    'y': y,
  };

  ActivePiece toActivePiece() =>
      ActivePiece(type: type, rotation: rotation, x: x, y: y);
}

/// Encodes the visible portion of [game]'s board for [BoardStateMsg.cells].
String encodeVisibleBoard(TetrisGame game) {
  final buffer = StringBuffer();
  for (var y = 0; y < TetrisGame.visibleRows; y += 1) {
    for (var x = 0; x < TetrisGame.width; x += 1) {
      final cell = game.visibleCellAt(x, y);
      buffer.write(cell == null ? '.' : cell.index.toString());
    }
  }
  return buffer.toString();
}

/// Decoded opponent board state, kept cheap to query from a painter.
final class OpponentSnapshot {
  OpponentSnapshot({
    required this.cells,
    required this.active,
    required this.pendingGarbage,
    required this.score,
    required this.lines,
  });

  static OpponentSnapshot? fromMessage(BoardStateMsg message) {
    if (message.cells.length != TetrisGame.visibleRows * TetrisGame.width) {
      return null;
    }
    return OpponentSnapshot(
      cells: message.cells,
      active: message.active,
      pendingGarbage: message.pendingGarbage,
      score: message.score,
      lines: message.lines,
    );
  }

  final String cells;
  final ActivePieceWire? active;
  final int pendingGarbage;
  final int score;
  final int lines;

  /// Cell at visible coordinates, or null when empty.
  Tetromino? visibleCellAt(int x, int visibleY) {
    if (x < 0 ||
        x >= TetrisGame.width ||
        visibleY < 0 ||
        visibleY >= TetrisGame.visibleRows) {
      return null;
    }
    final char = cells.codeUnitAt(visibleY * TetrisGame.width + x);
    if (char == 0x2e /* '.' */) {
      return null;
    }
    final index = char - 0x30;
    if (index < 0 || index >= Tetromino.values.length) {
      return null;
    }
    return Tetromino.values[index];
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tetris/src/game/tetris_game.dart';
import 'package:tetris/src/game/tetromino.dart';
import 'package:tetris/src/net/match_transport.dart';
import 'package:tetris/src/net/protocol.dart';
import 'package:tetris/src/net/room_client.dart';
import 'package:tetris/src/net/versus_session.dart';

class FakeTransport implements MatchTransport {
  FakeTransport(this.kind);

  @override
  final TransportKind kind;

  bool open = true;
  final sent = <GameMessage>[];
  final incoming = StreamController<GameMessage>.broadcast();

  @override
  bool get isOpen => open;

  @override
  Stream<GameMessage> get messages => incoming.stream;

  @override
  void send(GameMessage message) => sent.add(message);

  @override
  Future<void> close() => incoming.close();
}

class FakeRoom implements RoomChannel {
  final envelopeController = StreamController<ServerEnvelope>.broadcast();
  final stateNotifier = ValueNotifier(RoomConnectionState.connected);
  final rttNotifier = ValueNotifier<Duration?>(null);
  final relaysSent = <Map<String, dynamic>>[];
  final signalsSent = <Object?>[];
  int rematchRequests = 0;

  @override
  String get code => 'TESTY';

  @override
  Stream<ServerEnvelope> get envelopes => envelopeController.stream;

  @override
  ValueListenable<RoomConnectionState> get state => stateNotifier;

  @override
  ValueListenable<Duration?> get rtt => rttNotifier;

  @override
  void sendSignal(Object? data) => signalsSent.add(data);

  @override
  void sendRelay(Map<String, dynamic> data) => relaysSent.add(data);

  @override
  void requestRematch() => rematchRequests += 1;

  @override
  Future<void> close() async {
    await envelopeController.close();
  }
}

Future<void> pump([int times = 3]) async {
  for (var i = 0; i < times; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

VersusSession makeSession(
  FakeRoom room,
  FailoverTransport transport, {
  List<Tetromino> scriptedPieces = const [],
  Duration grace = const Duration(seconds: 10),
}) {
  return VersusSession(
    room: room,
    start: const StartEnvelope(seed: 1234, matchId: 1),
    isHost: true,
    transport: transport,
    gameFactory: (seed) => scriptedPieces.isEmpty
        ? TetrisGame(seed: seed)
        : TetrisGame(seed: seed, scriptedPieces: scriptedPieces),
    countdownDuration: const Duration(milliseconds: 1),
    disconnectGrace: grace,
  );
}

void main() {
  group('protocol', () {
    test('game messages round-trip through encode/decode', () {
      const attack = AttackMsg(seq: 7, lines: 4);
      final decodedAttack = GameMessage.decode(attack.encode()) as AttackMsg;
      expect(decodedAttack.seq, 7);
      expect(decodedAttack.lines, 4);

      const state = BoardStateMsg(
        seq: 3,
        cells: '....',
        active: ActivePieceWire(type: Tetromino.t, rotation: 1, x: 4, y: 19),
        pendingGarbage: 2,
        score: 1200,
        lines: 9,
      );
      final decodedState = GameMessage.decode(state.encode()) as BoardStateMsg;
      expect(decodedState.seq, 3);
      expect(decodedState.active?.type, Tetromino.t);
      expect(decodedState.active?.y, 19);
      expect(decodedState.pendingGarbage, 2);

      const over = GameOverMsg(seq: 9);
      expect((GameMessage.decode(over.encode()) as GameOverMsg).seq, 9);

      expect(GameMessage.decode({'v': 99, 'k': 'attack'}), isNull);
      expect(GameMessage.decode({'v': 1, 'k': 'unknown'}), isNull);
    });

    test('board encoding mirrors garbage and empty cells', () {
      final game = TetrisGame(seed: 1, scriptedPieces: [Tetromino.o]);
      game.setVisibleCell(0, TetrisGame.visibleRows - 1, Tetromino.garbage);
      game.setVisibleCell(9, 0, Tetromino.t);

      final cells = encodeVisibleBoard(game);
      expect(cells, hasLength(TetrisGame.visibleRows * TetrisGame.width));

      final snapshot = OpponentSnapshot.fromMessage(
        BoardStateMsg(
          seq: 1,
          cells: cells,
          active: null,
          pendingGarbage: 0,
          score: 0,
          lines: 0,
        ),
      );
      expect(snapshot, isNotNull);
      expect(
        snapshot!.visibleCellAt(0, TetrisGame.visibleRows - 1),
        Tetromino.garbage,
      );
      expect(snapshot.visibleCellAt(9, 0), Tetromino.t);
      expect(snapshot.visibleCellAt(5, 5), isNull);
    });

    test('server envelopes decode', () {
      expect(
        ServerEnvelope.decode({'t': 'joined', 'role': 'host', 'rejoin': false}),
        isA<JoinedEnvelope>().having((e) => e.isHost, 'isHost', isTrue),
      );
      expect(
        ServerEnvelope.decode({'t': 'start', 'seed': 5, 'matchId': 2}),
        isA<StartEnvelope>().having((e) => e.seed, 'seed', 5),
      );
      expect(ServerEnvelope.decode({'t': 'nonsense'}), isNull);
      expect(ServerEnvelope.decode('not a map'), isNull);
    });
  });

  group('FailoverTransport', () {
    test('dedups attacks arriving on both transports', () async {
      final relay = FakeTransport(TransportKind.relay);
      final p2p = FakeTransport(TransportKind.p2p);
      final failover = FailoverTransport(relay: relay)..attachP2p(p2p);

      final received = <GameMessage>[];
      failover.messages.listen(received.add);

      relay.incoming.add(const AttackMsg(seq: 1, lines: 2));
      p2p.incoming.add(const AttackMsg(seq: 1, lines: 2));
      p2p.incoming.add(const AttackMsg(seq: 2, lines: 1));
      await pump();

      expect(received.whereType<AttackMsg>().map((m) => m.seq), [1, 2]);
    });

    test('drops stale board states', () async {
      final relay = FakeTransport(TransportKind.relay);
      final failover = FailoverTransport(relay: relay);

      final received = <GameMessage>[];
      failover.messages.listen(received.add);

      BoardStateMsg state(int seq) => BoardStateMsg(
        seq: seq,
        cells: '',
        active: null,
        pendingGarbage: 0,
        score: 0,
        lines: 0,
      );
      relay.incoming.add(state(5));
      relay.incoming.add(state(3));
      relay.incoming.add(state(6));
      await pump();

      expect(received.whereType<BoardStateMsg>().map((m) => m.seq), [5, 6]);
    });

    test('sends critical messages on every open transport, state on active',
        () async {
      final relay = FakeTransport(TransportKind.relay);
      final p2p = FakeTransport(TransportKind.p2p);
      final failover = FailoverTransport(relay: relay)..attachP2p(p2p);
      failover.promoteToP2p();
      expect(failover.active.value, TransportKind.p2p);

      failover.send(const AttackMsg(seq: 1, lines: 4));
      expect(relay.sent.whereType<AttackMsg>(), hasLength(1));
      expect(p2p.sent.whereType<AttackMsg>(), hasLength(1));

      const state = BoardStateMsg(
        seq: 1,
        cells: '',
        active: null,
        pendingGarbage: 0,
        score: 0,
        lines: 0,
      );
      failover.send(state);
      expect(relay.sent.whereType<BoardStateMsg>(), isEmpty);
      expect(p2p.sent.whereType<BoardStateMsg>(), hasLength(1));

      // P2P dies: demote, state flows over relay again.
      p2p.open = false;
      failover.demoteToRelay();
      failover.send(state);
      expect(relay.sent.whereType<BoardStateMsg>(), hasLength(1));
    });

    test('cannot promote while the p2p pipe is closed', () {
      final relay = FakeTransport(TransportKind.relay);
      final p2p = FakeTransport(TransportKind.p2p)..open = false;
      final failover = FailoverTransport(relay: relay)..attachP2p(p2p);

      failover.promoteToP2p();
      expect(failover.active.value, TransportKind.relay);
    });
  });

  group('VersusSession', () {
    test('counts down then plays, and a Tetris sends an attack', () async {
      final room = FakeRoom();
      final relay = FakeTransport(TransportKind.relay);
      final failover = FailoverTransport(relay: relay);
      final session = makeSession(
        room,
        failover,
        scriptedPieces: [Tetromino.i, Tetromino.o, Tetromino.o],
      );

      expect(session.phase.value, VersusPhase.countdown);
      expect(session.game.paused, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.phase.value, VersusPhase.playing);
      expect(session.game.paused, isFalse);

      final game = session.game;
      for (var i = 0; i < 4; i += 1) {
        final y = TetrisGame.visibleRows - 1 - i;
        for (var x = 1; x < TetrisGame.width; x += 1) {
          game.setVisibleCell(x, y, Tetromino.z);
        }
      }
      // Stray block prevents an accidental perfect clear.
      game.setVisibleCell(5, TetrisGame.visibleRows - 5, Tetromino.z);

      game.rotateClockwise();
      while (game.moveLeft()) {}
      game.hardDrop();
      session.onLocalTick();

      final attacks = relay.sent.whereType<AttackMsg>().toList();
      expect(attacks, hasLength(1));
      expect(attacks.single.lines, 4);
      expect(attacks.single.seq, 1);

      await session.dispose();
    });

    test('applies incoming attacks and wins on opponent game over', () async {
      final room = FakeRoom();
      final relay = FakeTransport(TransportKind.relay);
      final failover = FailoverTransport(relay: relay);
      final session = makeSession(room, failover);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      relay.incoming.add(const AttackMsg(seq: 1, lines: 3));
      await pump();
      expect(session.game.pendingGarbageLines, 3);

      relay.incoming.add(const GameOverMsg(seq: 2));
      await pump();
      expect(session.phase.value, VersusPhase.won);
      expect(session.game.paused, isTrue);

      await session.dispose();
    });

    test('local top-out sends game over and loses', () async {
      final room = FakeRoom();
      final relay = FakeTransport(TransportKind.relay);
      final failover = FailoverTransport(relay: relay);
      final session = makeSession(room, failover);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final game = session.game;
      // Block the spawn area high in the buffer to force a top-out.
      for (var y = 0; y < TetrisGame.totalRows - 2; y += 1) {
        for (var x = 0; x < TetrisGame.width; x += 1) {
          if (x != 0) {
            game.setCell(x, y, Tetromino.z);
          }
        }
      }
      game.hardDrop();
      session.onLocalTick();

      expect(session.phase.value, VersusPhase.lost);
      expect(relay.sent.whereType<GameOverMsg>(), hasLength(1));
      // The final board state was flushed before the game-over message.
      expect(relay.sent.whereType<BoardStateMsg>(), isNotEmpty);

      await session.dispose();
    });

    test('opponent disconnect past grace ends the match', () async {
      final room = FakeRoom();
      final relay = FakeTransport(TransportKind.relay);
      final failover = FailoverTransport(relay: relay);
      final session = makeSession(
        room,
        failover,
        grace: const Duration(milliseconds: 30),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      room.envelopeController.add(const PeerLeftEnvelope());
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(session.phase.value, VersusPhase.opponentLeft);

      await session.dispose();
    });

    test('a rejoin within grace keeps the match alive', () async {
      final room = FakeRoom();
      final relay = FakeTransport(TransportKind.relay);
      final failover = FailoverTransport(relay: relay);
      final session = makeSession(
        room,
        failover,
        grace: const Duration(milliseconds: 50),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      room.envelopeController.add(const PeerLeftEnvelope());
      await pump();
      room.envelopeController.add(const PeerRejoinedEnvelope());
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(session.phase.value, VersusPhase.playing);

      await session.dispose();
    });

    test('rematch start swaps in a fresh seeded game', () async {
      final room = FakeRoom();
      final relay = FakeTransport(TransportKind.relay);
      final failover = FailoverTransport(relay: relay);
      final session = makeSession(room, failover);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      relay.incoming.add(const GameOverMsg(seq: 1));
      await pump();
      expect(session.phase.value, VersusPhase.won);

      session.requestRematch();
      expect(room.rematchRequests, 1);
      expect(session.localWantsRematch.value, isTrue);

      room.envelopeController.add(const RematchRequestedEnvelope());
      await pump();
      expect(session.opponentWantsRematch.value, isTrue);

      final firstGame = session.game;
      room.envelopeController.add(const StartEnvelope(seed: 777, matchId: 2));
      await pump();

      expect(session.matchId, 2);
      expect(session.seed, 777);
      expect(session.game, isNot(same(firstGame)));
      expect(session.phase.value, VersusPhase.countdown);
      expect(session.localWantsRematch.value, isFalse);
      expect(session.opponentWantsRematch.value, isFalse);

      // Attack seq restarts and the dedup table was reset: the same seq 1
      // attack applies again in the new match.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      relay.incoming.add(const AttackMsg(seq: 1, lines: 2));
      await pump();
      expect(session.game.pendingGarbageLines, 2);

      await session.dispose();
    });
  });
}

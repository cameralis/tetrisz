// Live end-to-end test against a locally running backend.
//
// Start the backend first, then run:
//
//   cd backend && pnpm dev
//   cd app && fvm flutter test test_live \
//       --dart-define=TETRIS_BACKEND_URL=http://localhost:8787
//
// Excluded from the default `flutter test` run by living outside test/.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tetris/src/game/tetris_game.dart';
import 'package:tetris/src/game/tetromino.dart';
import 'package:tetris/src/net/protocol.dart';
import 'package:tetris/src/net/room_client.dart';
import 'package:tetris/src/net/versus_session.dart';

Future<T> awaitValue<T>(
  T? Function() probe, {
  Duration timeout = const Duration(seconds: 10),
  String? label,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = probe();
    if (value != null) {
      return value;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw TimeoutException('timed out waiting for ${label ?? T.toString()}');
}

Future<StartEnvelope> awaitStart(RoomClient client, {int? afterMatchId}) {
  final completer = Completer<StartEnvelope>();
  late final StreamSubscription<ServerEnvelope> sub;
  sub = client.envelopes.listen((envelope) {
    if (envelope is StartEnvelope &&
        (afterMatchId == null || envelope.matchId > afterMatchId) &&
        !completer.isCompleted) {
      completer.complete(envelope);
      sub.cancel();
    }
  });
  return completer.future.timeout(const Duration(seconds: 10));
}

VersusSession makeSession(RoomClient client, StartEnvelope start,
    {required bool isHost, List<Tetromino> pieces = const []}) {
  return VersusSession(
    room: client,
    start: start,
    isHost: isHost,
    countdownDuration: const Duration(milliseconds: 100),
    gameFactory: (seed) => pieces.isEmpty
        ? TetrisGame(seed: seed)
        : TetrisGame(seed: seed, scriptedPieces: pieces),
  );
}

void main() {
  test('two clients play a full match over the live relay', () async {
    // --- Room pairing: create, join, shared seed. -------------------------
    final host = await RoomClient.create();
    expect(host.code, matches(RegExp(r'^[A-Z2-9]{5}$')));

    final hostStartFuture = awaitStart(host);
    final hostSeesReady = host.envelopes
        .firstWhere((envelope) => envelope is PeerReadyEnvelope)
        .timeout(const Duration(seconds: 10));
    final guest = RoomClient.join(host.code);
    final guestStartFuture = awaitStart(guest);

    // v2 ready-up gate: the match must not start until both send ready.
    var startedEarly = false;
    unawaited(hostStartFuture.then((_) => startedEarly = true));
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(
      startedEarly,
      isFalse,
      reason: 'match must not start before both players ready up',
    );

    guest.sendReady();
    await hostSeesReady;
    host.sendReady();

    final hostStart = await hostStartFuture;
    final guestStart = await guestStartFuture;
    expect(hostStart.seed, guestStart.seed);
    expect(hostStart.matchId, 1);

    // --- Sessions run their local games from the shared seed. ------------
    final hostSession = makeSession(
      host,
      hostStart,
      isHost: true,
      pieces: [Tetromino.i, Tetromino.o, Tetromino.o],
    );
    final guestSession = makeSession(guest, guestStart, isHost: false);

    // Both games deal identical bags once scripted pieces run out; here we
    // simply confirm both reach the playing phase.
    await awaitValue(
      () => hostSession.phase.value == VersusPhase.playing &&
              guestSession.phase.value == VersusPhase.playing
          ? true
          : null,
      label: 'both sessions playing',
    );

    // --- Host scores a Tetris; garbage arrives at the guest. -------------
    final hostGame = hostSession.game;
    for (var i = 0; i < 4; i += 1) {
      final y = TetrisGame.visibleRows - 1 - i;
      for (var x = 1; x < TetrisGame.width; x += 1) {
        hostGame.setVisibleCell(x, y, Tetromino.z);
      }
    }
    hostGame.setVisibleCell(5, TetrisGame.visibleRows - 5, Tetromino.z);
    hostGame.rotateClockwise();
    while (hostGame.moveLeft()) {}
    hostGame.hardDrop();
    hostSession.onLocalTick();

    await awaitValue(
      () => guestSession.game.pendingGarbageLines == 4 ? true : null,
      label: 'guest pending garbage',
    );

    // The guest also received the host's board mirror eventually.
    hostSession.onLocalTick();
    await awaitValue(
      () => guestSession.opponent.value,
      label: 'guest sees host board snapshot',
    );

    // --- Guest tops out; host wins. ---------------------------------------
    final guestGame = guestSession.game;
    for (var y = 0; y < TetrisGame.totalRows - 2; y += 1) {
      for (var x = 1; x < TetrisGame.width; x += 1) {
        guestGame.setCell(x, y, Tetromino.z);
      }
    }
    guestGame.hardDrop();
    guestSession.onLocalTick();

    expect(guestSession.phase.value, VersusPhase.lost);
    await awaitValue(
      () => hostSession.phase.value == VersusPhase.won ? true : null,
      label: 'host wins',
    );

    // --- Rematch: both request, fresh identical seed. ---------------------
    final hostRestart = awaitStart(host, afterMatchId: 1);
    final guestRestart = awaitStart(guest, afterMatchId: 1);
    hostSession.requestRematch();
    await awaitValue(
      () => guestSession.opponentWantsRematch.value ? true : null,
      label: 'guest sees rematch request',
    );
    guestSession.requestRematch();

    final hostSecond = await hostRestart;
    final guestSecond = await guestRestart;
    expect(hostSecond.matchId, 2);
    expect(hostSecond.seed, guestSecond.seed);

    await awaitValue(
      () => hostSession.matchId == 2 && guestSession.matchId == 2 ? true : null,
      label: 'both sessions on match 2',
    );
    expect(hostSession.game.gameOver, isFalse);
    expect(guestSession.game.gameOver, isFalse);

    await hostSession.dispose();
    await guestSession.dispose();
  });

  test('joining a nonexistent room reports room-not-found', () async {
    final client = RoomClient.join('ZZZZZ');
    await awaitValue(
      () => client.state.value == RoomConnectionState.failed ? true : null,
      label: 'failed connection state',
    );
    expect(client.failureReason.value, contains('not found'));
    await client.close();
  });
}

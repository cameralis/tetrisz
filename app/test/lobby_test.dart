import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetris/src/net/protocol.dart';
import 'package:tetris/src/net/room_client.dart';
import 'package:tetris/src/ui/lobby_page.dart';
import 'package:tetris/src/ui/tetris_app.dart';

class FakeRoom implements RoomChannel {
  final envelopeController = StreamController<ServerEnvelope>.broadcast();
  final stateNotifier = ValueNotifier(RoomConnectionState.connected);
  final rttNotifier = ValueNotifier<Duration?>(null);
  final failureNotifier = ValueNotifier<String?>(null);
  int readiesSent = 0;

  @override
  String get code => 'TESTY';

  @override
  Stream<ServerEnvelope> get envelopes => envelopeController.stream;

  @override
  ValueListenable<RoomConnectionState> get state => stateNotifier;

  @override
  ValueListenable<Duration?> get rtt => rttNotifier;

  @override
  ValueListenable<String?> get failureReason => failureNotifier;

  @override
  void sendSignal(Object? data) {}

  @override
  void sendRelay(Map<String, dynamic> data) {}

  @override
  void sendReady() => readiesSent += 1;

  @override
  void requestRematch() {}

  @override
  Future<void> close() async {
    if (!envelopeController.isClosed) {
      await envelopeController.close();
    }
  }
}

Widget _lobby(FakeRoom room) {
  return MaterialApp(
    home: LobbyPage(
      enableAudio: false,
      soundEffects: const NoopTetrisSoundEffects(),
      enableP2p: false,
      createRoom: () async => room,
      joinRoom: (_) => room,
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('host readies up after opponent joins, start hands off', (
    tester,
  ) async {
    final room = FakeRoom();
    await tester.pumpWidget(_lobby(room));

    await tester.tap(find.byKey(const ValueKey('lobby-create')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('TESTY'), findsOneWidget);
    expect(find.text('Waiting for your opponent…'), findsOneWidget);
    expect(find.byKey(const ValueKey('lobby-ready')), findsNothing);

    room.envelopeController.add(
      const JoinedEnvelope(role: 'host', rejoin: false),
    );
    room.envelopeController.add(const PeerJoinedEnvelope());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byKey(const ValueKey('lobby-ready')), findsOneWidget);
    expect(find.text('Ready up'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lobby-ready')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(room.readiesSent, 1);
    expect(find.text('Waiting for opponent…'), findsOneWidget);
    expect(find.text('YOU · READY'), findsOneWidget);

    room.envelopeController.add(const PeerReadyEnvelope());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('OPPONENT · READY'), findsOneWidget);

    room.envelopeController.add(const StartEnvelope(seed: 7, matchId: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(TetrisGamePage), findsOneWidget);

    // Tear the game page down cleanly (disposes the versus session).
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('guest joining sees existing peer and their ready state', (
    tester,
  ) async {
    final room = FakeRoom();
    await tester.pumpWidget(_lobby(room));

    await tester.enterText(
      find.byKey(const ValueKey('lobby-code-field')),
      'TESTY',
    );
    await tester.tap(find.byKey(const ValueKey('lobby-join')));
    await tester.pump();

    room.envelopeController.add(
      const JoinedEnvelope(
        role: 'guest',
        rejoin: false,
        peerPresent: true,
        peerReady: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byKey(const ValueKey('lobby-ready')), findsOneWidget);
    expect(find.text('OPPONENT · READY'), findsOneWidget);
    expect(room.readiesSent, 0);
  });

  testWidgets('peer leaving during ready phase falls back to waiting', (
    tester,
  ) async {
    final room = FakeRoom();
    await tester.pumpWidget(_lobby(room));

    await tester.tap(find.byKey(const ValueKey('lobby-create')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    room.envelopeController.add(
      const JoinedEnvelope(role: 'host', rejoin: false),
    );
    room.envelopeController.add(const PeerJoinedEnvelope());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('lobby-ready')), findsOneWidget);

    room.envelopeController.add(const PeerLeftEnvelope());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byKey(const ValueKey('lobby-ready')), findsNothing);
    expect(find.text('Waiting for your opponent…'), findsOneWidget);
  });
}

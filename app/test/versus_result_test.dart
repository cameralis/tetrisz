import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetris/src/net/protocol.dart';
import 'package:tetris/src/net/room_client.dart';
import 'package:tetris/src/net/versus_session.dart';
import 'package:tetris/src/ui/tetris_app.dart';
import 'package:tetris/src/ui/ui_sounds.dart';

final class RecordingUiSounds implements UiSounds {
  final List<UiSfx> played = [];

  @override
  void play(UiSfx sfx) => played.add(sfx);

  @override
  void dispose() {}
}

class FakeRoom implements RoomChannel {
  final envelopeController = StreamController<ServerEnvelope>.broadcast();
  final stateNotifier = ValueNotifier(RoomConnectionState.connected);
  final rttNotifier = ValueNotifier<Duration?>(null);
  final failureNotifier = ValueNotifier<String?>(null);
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
  ValueListenable<String?> get failureReason => failureNotifier;

  @override
  void sendSignal(Object? data) {}

  @override
  void sendRelay(Map<String, dynamic> data) {}

  @override
  void sendReady() {}

  @override
  void requestRematch() => rematchRequests += 1;

  @override
  Future<void> close() async {
    if (!envelopeController.isClosed) {
      await envelopeController.close();
    }
  }
}

Future<VersusSession> _pumpFinishedMatch(
  WidgetTester tester,
  FakeRoom room,
  VersusPhase result,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final session = VersusSession(
    room: room,
    start: const StartEnvelope(seed: 11, matchId: 1),
    isHost: true,
    countdownDuration: const Duration(milliseconds: 1),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: TetrisGamePage(
        enableAudio: false,
        soundEffects: const NoopTetrisSoundEffects(),
        versusSession: session,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  session.phase.value = result;
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return session;
}

Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  late RecordingUiSounds sounds;

  setUp(() {
    sounds = RecordingUiSounds();
    UiFeedback.install(sounds);
    UiFeedback.sfxVolume = 1.0;
  });

  tearDown(() {
    UiFeedback.install(const NoopUiSounds());
  });

  testWidgets('wide layout shows the side sheet clear of the board', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final room = FakeRoom();
    await _pumpFinishedMatch(tester, room, VersusPhase.won);

    expect(find.byKey(const ValueKey('versus-result-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('versus-result-overlay')), findsNothing);
    expect(find.text('YOU WIN'), findsOneWidget);
    expect(sounds.played, contains(UiSfx.win));

    final sheetLeft = tester
        .getTopLeft(find.byKey(const ValueKey('versus-result-sheet')))
        .dx;
    final boardRight = tester
        .getBottomRight(find.byKey(const ValueKey('tetris-board')))
        .dx;
    expect(
      sheetLeft,
      greaterThanOrEqualTo(boardRight),
      reason: 'the result sheet must not cover the player board',
    );

    await _teardown(tester);
  });

  testWidgets('landscape-compact still gets the side sheet', (tester) async {
    tester.view.physicalSize = const Size(840, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final room = FakeRoom();
    await _pumpFinishedMatch(tester, room, VersusPhase.lost);

    expect(find.byKey(const ValueKey('versus-result-sheet')), findsOneWidget);
    expect(find.text('YOU LOSE'), findsOneWidget);
    expect(sounds.played, contains(UiSfx.lose));

    final sheetLeft = tester
        .getTopLeft(find.byKey(const ValueKey('versus-result-sheet')))
        .dx;
    final boardRight = tester
        .getBottomRight(find.byKey(const ValueKey('tetris-board')))
        .dx;
    expect(sheetLeft, greaterThanOrEqualTo(boardRight));

    await _teardown(tester);
  });

  testWidgets('narrow portrait falls back to the centered overlay', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final room = FakeRoom();
    await _pumpFinishedMatch(tester, room, VersusPhase.lost);

    expect(find.byKey(const ValueKey('versus-result-overlay')), findsOneWidget);
    expect(find.byKey(const ValueKey('versus-result-sheet')), findsNothing);
    expect(find.text('YOU LOSE'), findsOneWidget);

    await _teardown(tester);
  });

  testWidgets('rematch button requests a rematch over the room', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final room = FakeRoom();
    await _pumpFinishedMatch(tester, room, VersusPhase.won);

    await tester.tap(find.text('Rematch'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(room.rematchRequests, 1);
    expect(find.text('Waiting for opponent…'), findsOneWidget);

    await _teardown(tester);
  });

  testWidgets('opponent-left variant hides rematch', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final room = FakeRoom();
    await _pumpFinishedMatch(tester, room, VersusPhase.opponentLeft);

    expect(find.text('OPPONENT LEFT'), findsOneWidget);
    expect(find.text('Rematch'), findsNothing);
    expect(find.text('Leave match'), findsOneWidget);

    await _teardown(tester);
  });
}

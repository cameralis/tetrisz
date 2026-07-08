import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetris/src/net/protocol.dart';
import 'package:tetris/src/net/room_client.dart';
import 'package:tetris/src/net/versus_session.dart';
import 'package:tetris/src/ui/tetris_app.dart';
import 'package:tetris/src/ui/toasts.dart';
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

  @override
  String get code => 'TESTY';

  @override
  Stream<ServerEnvelope> get envelopes => envelopeController.stream;

  @override
  ValueListenable<RoomConnectionState> get state => stateNotifier;

  @override
  ValueListenable<Duration?> get rtt => rttNotifier;

  @override
  void sendSignal(Object? data) {}

  @override
  void sendRelay(Map<String, dynamic> data) {}

  @override
  void requestRematch() {}

  @override
  Future<void> close() async {
    if (!envelopeController.isClosed) {
      await envelopeController.close();
    }
  }
}

Widget _bareHost() {
  return const MediaQuery(
    data: MediaQueryData(),
    child: TetrisToastHost(child: SizedBox.expand()),
  );
}

/// Enter (340ms) + hold (2600ms) + exit (200ms) with margin.
Future<void> _pumpThroughLifetime(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 2600));
  await tester.pump(const Duration(milliseconds: 400));
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

  group('TetrisToastHost', () {
    testWidgets('slams in, plays the toast sound, and auto-dismisses', (
      tester,
    ) async {
      await tester.pumpWidget(_bareHost());

      TetrisToastHost.show('Opponent joined the room');
      await tester.pump();
      expect(find.text('Opponent joined the room'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 400));
      expect(sounds.played, contains(UiSfx.toast));

      await tester.pump(const Duration(milliseconds: 2600));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Opponent joined the room'), findsNothing);
    });

    testWidgets('stacks multiple toasts', (tester) async {
      await tester.pumpWidget(_bareHost());

      TetrisToastHost.show('first');
      TetrisToastHost.show('second');
      await tester.pump();

      expect(find.text('first'), findsOneWidget);
      expect(find.text('second'), findsOneWidget);
      await _pumpThroughLifetime(tester);
      expect(find.text('first'), findsNothing);
      expect(find.text('second'), findsNothing);
    });

    testWidgets('tap dismisses early', (tester) async {
      await tester.pumpWidget(_bareHost());

      TetrisToastHost.show('tap me');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('tap me'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('tap me'), findsNothing);
    });

    testWidgets('show without a mounted host is a safe no-op', (tester) async {
      expect(() => TetrisToastHost.show('nobody home'), returnsNormally);
    });
  });

  group('versus room event toasts', () {
    testWidgets('peer leave and rejoin toast during a match', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final room = FakeRoom();
      final session = VersusSession(
        room: room,
        start: const StartEnvelope(seed: 42, matchId: 1),
        isHost: true,
        countdownDuration: const Duration(milliseconds: 1),
      );

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              TetrisToastHost(child: child ?? const SizedBox.shrink()),
          home: TetrisGamePage(
            enableAudio: false,
            soundEffects: const NoopTetrisSoundEffects(),
            versusSession: session,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      room.envelopeController.add(const PeerLeftEnvelope());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.textContaining('Opponent disconnected'),
        findsOneWidget,
      );

      room.envelopeController.add(const PeerRejoinedEnvelope());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Opponent reconnected'), findsOneWidget);

      // Let both toasts expire before tearing the page down.
      await _pumpThroughLifetime(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}

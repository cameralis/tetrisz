import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetris/src/auth/auth_service.dart';
import 'package:tetris/src/net/protocol.dart';
import 'package:tetris/src/net/rankings_client.dart';
import 'package:tetris/src/net/room_client.dart';
import 'package:tetris/src/net/versus_session.dart';
import 'package:tetris/src/ui/leaderboard_page.dart';
import 'package:tetris/src/ui/tetris_app.dart';

class FakeRoom implements RoomChannel {
  final envelopeController = StreamController<ServerEnvelope>.broadcast();
  final stateNotifier = ValueNotifier(RoomConnectionState.connected);
  final rttNotifier = ValueNotifier<Duration?>(null);
  final failureNotifier = ValueNotifier<String?>(null);

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
  void requestRematch() {}

  @override
  Future<void> close() async {
    if (!envelopeController.isClosed) {
      await envelopeController.close();
    }
  }
}

class FakeRankingsApi implements RankingsApi {
  final reports = <({String roomCode, int matchId, bool won})>[];
  ReportOutcome next = const ReportOutcome(
    status: ReportStatus.rated,
    ratingDelta: 16,
    newRating: 1216,
  );
  RankingsSnapshot snapshot = const RankingsSnapshot(entries: []);

  @override
  Future<ReportOutcome> reportResult({
    required String roomCode,
    required int matchId,
    required bool won,
  }) async {
    reports.add((roomCode: roomCode, matchId: matchId, won: won));
    return next;
  }

  @override
  Future<RankingsSnapshot> fetchRankings() async => snapshot;
}

Future<VersusSession> _pumpVersus(
  WidgetTester tester,
  FakeRoom room,
  FakeRankingsApi api,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final session = VersusSession(
    room: room,
    start: const StartEnvelope(seed: 5, matchId: 1),
    isHost: true,
    countdownDuration: const Duration(milliseconds: 1),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: TetrisGamePage(
        enableAudio: false,
        soundEffects: const NoopTetrisSoundEffects(),
        versusSession: session,
        rankingsApi: api,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  return session;
}

void main() {
  tearDown(() {
    Auth.install(UnconfiguredAuthService());
  });

  testWidgets('a signed-in win reports the rated result and shows the delta', (
    tester,
  ) async {
    final auth = FakeAuthService();
    await auth.signInWithApple();
    Auth.install(auth);

    final room = FakeRoom();
    final api = FakeRankingsApi();
    final session = await _pumpVersus(tester, room, api);

    session.phase.value = VersusPhase.won;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(api.reports, hasLength(1));
    expect(api.reports.single.roomCode, 'TESTY');
    expect(api.reports.single.matchId, 1);
    expect(api.reports.single.won, isTrue);
    expect(session.ratingDelta.value, 16);
    expect(find.text('RATING +16'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a loss reports won=false and shows a negative delta', (
    tester,
  ) async {
    final auth = FakeAuthService();
    await auth.signInWithApple();
    Auth.install(auth);

    final room = FakeRoom();
    final api = FakeRankingsApi()
      ..next = const ReportOutcome(
        status: ReportStatus.rated,
        ratingDelta: -16,
        newRating: 1184,
      );
    final session = await _pumpVersus(tester, room, api);

    session.phase.value = VersusPhase.lost;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(api.reports.single.won, isFalse);
    expect(find.text('RATING −16'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('signed-out matches stay unrated', (tester) async {
    final room = FakeRoom();
    final api = FakeRankingsApi();
    final session = await _pumpVersus(tester, room, api);

    session.phase.value = VersusPhase.won;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(api.reports, isEmpty);
    expect(find.text('RATING +16'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('rankings board renders entries and your rank', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final api = FakeRankingsApi()
      ..snapshot = const RankingsSnapshot(
        entries: [
          RankingEntry(
            rank: 1,
            displayName: 'ALPHA',
            rating: 1300,
            ratedGames: 9,
          ),
          RankingEntry(
            rank: 2,
            displayName: 'BRAVO',
            rating: 1216,
            ratedGames: 4,
          ),
        ],
        yourRank: 2,
        yourRating: 1216,
      );
    await tester.pumpWidget(
      MaterialApp(home: LeaderboardPage(rankingsApi: api)),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byKey(const ValueKey('board-versus')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('ALPHA'), findsOneWidget);
    expect(find.text('1300'), findsOneWidget);
    expect(find.text('#2 · 1216'), findsOneWidget);
  });
}

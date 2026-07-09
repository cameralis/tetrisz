import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tetris/src/net/protocol.dart';
import 'package:tetris/src/net/rankings_client.dart';
import 'package:tetris/src/net/room_client.dart';
import 'package:tetris/src/net/versus_session.dart';
import 'package:tetris/src/ui/leaderboard_page.dart';
import 'package:tetris/src/ui/tetris_app.dart';

/// Live drive of the ELO surfaces: the real (empty until sign-in exists)
/// versus ranking board against production, then the designed board and the
/// rated-result delta on the win sheet using the same fakes the tests use.
const _markerDir = String.fromEnvironment('E2E_MARKER_DIR');

Future<void> _stage(WidgetTester tester, String name) async {
  if (_markerDir.isNotEmpty) {
    File('$_markerDir/$name')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('');
  }
  await tester.pump(const Duration(milliseconds: 1400));
}

class _FakeRoom implements RoomChannel {
  final envelopeController = StreamController<ServerEnvelope>.broadcast();
  final stateNotifier = ValueNotifier(RoomConnectionState.connected);
  final rttNotifier = ValueNotifier<Duration?>(null);
  final failureNotifier = ValueNotifier<String?>(null);

  @override
  String get code => 'DEMOZ';

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

class _FakeRankingsApi implements RankingsApi {
  @override
  Future<ReportOutcome> reportResult({
    required String roomCode,
    required int matchId,
    required bool won,
  }) async {
    return const ReportOutcome(
      status: ReportStatus.rated,
      ratingDelta: 16,
      newRating: 1216,
    );
  }

  @override
  Future<RankingsSnapshot> fetchRankings() async {
    return const RankingsSnapshot(
      entries: [
        RankingEntry(rank: 1, displayName: 'HEAVY', rating: 1381, ratedGames: 24),
        RankingEntry(rank: 2, displayName: 'SZABI', rating: 1216, ratedGames: 4),
        RankingEntry(rank: 3, displayName: 'GHOST', rating: 1184, ratedGames: 4),
        RankingEntry(rank: 4, displayName: 'BLOCKED', rating: 1112, ratedGames: 12),
      ],
      yourRank: 2,
      yourRating: 1216,
    );
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('rankings board and rated delta', (tester) async {
    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pump(const Duration(milliseconds: 1100));

    // Real production board: empty until accounts go live.
    await tester.tap(find.byKey(const ValueKey('home-leaderboard')));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byKey(const ValueKey('board-versus')));
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.textContaining('No rated matches'), findsOneWidget);
    await _stage(tester, 'rank1_prod_empty');

    // Designed board with data, via the test fakes.
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => LeaderboardPage(rankingsApi: _FakeRankingsApi()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('board-versus')).last);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('HEAVY'), findsOneWidget);
    await _stage(tester, 'rank2_board');

    // Rated delta on the win sheet.
    final room = _FakeRoom();
    final session = VersusSession(
      room: room,
      start: const StartEnvelope(seed: 3, matchId: 1),
      isHost: true,
      countdownDuration: const Duration(milliseconds: 1),
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => TetrisGamePage(
          enableAudio: false,
          soundEffects: const NoopTetrisSoundEffects(),
          versusSession: session,
          rankingsApi: _FakeRankingsApi(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    session
      ..wins.value = 1
      ..ratingDelta.value = 16
      ..phase.value = VersusPhase.won;
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('RATING +16'), findsOneWidget);
    await _stage(tester, 'rank3_delta');
    await _stage(tester, 'rank4_done');
  });
}

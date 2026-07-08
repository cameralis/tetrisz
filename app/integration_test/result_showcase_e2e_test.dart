import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tetris/src/game/tetris_game.dart';
import 'package:tetris/src/game/tetromino.dart';
import 'package:tetris/src/net/protocol.dart';
import 'package:tetris/src/net/room_client.dart';
import 'package:tetris/src/net/versus_session.dart';
import 'package:tetris/src/ui/tetris_app.dart';

/// Live drive of the end-of-match experience against a real backend: a
/// headless guest joins, both ready up, the guest tops out, and the host's
/// WIN sheet slides in beside the board (wide layout) with the rematch flow.
const _markerDir = String.fromEnvironment('E2E_MARKER_DIR');

Future<void> _stage(WidgetTester tester, String name) async {
  if (_markerDir.isNotEmpty) {
    File('$_markerDir/$name')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('');
  }
  await tester.pump(const Duration(milliseconds: 1400));
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
  String? label,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('timed out waiting for ${label ?? 'condition'}');
    }
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('win sheet beside the board after a live match', (tester) async {
    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(find.byKey(const ValueKey('home-versus')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('lobby-create')));
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('lobby-room-code')).evaluate().isNotEmpty,
      label: 'room code',
    );
    final code = tester
        .widget<SelectableText>(find.byKey(const ValueKey('lobby-room-code')))
        .data!;

    final guest = RoomClient.join(code);
    VersusSession? guestSession;
    Timer? guestTicker;
    unawaited(
      guest.envelopes.firstWhere((e) => e is StartEnvelope).then((envelope) {
        guestSession = VersusSession(
          room: guest,
          start: envelope as StartEnvelope,
          isHost: false,
        );
        guestTicker = Timer.periodic(
          const Duration(milliseconds: 150),
          (_) => guestSession?.onLocalTick(),
        );
      }),
    );

    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('lobby-ready')).evaluate().isNotEmpty,
      label: 'ready button',
    );
    await tester.tap(find.byKey(const ValueKey('lobby-ready')));
    guest.sendReady();

    await _pumpUntil(
      tester,
      () => find.text('HOLD').evaluate().isNotEmpty,
      label: 'match HUD',
    );
    // Let the countdown play out and the match begin.
    await _pumpUntil(
      tester,
      () => guestSession?.phase.value == VersusPhase.playing,
      label: 'guest playing',
    );
    await tester.pump(const Duration(milliseconds: 800));

    // The guest tops out; the visible host wins.
    final guestGame = guestSession!.game;
    for (var y = 0; y < TetrisGame.totalRows - 2; y += 1) {
      for (var x = 1; x < TetrisGame.width; x += 1) {
        guestGame.setCell(x, y, Tetromino.z);
      }
    }
    guestGame.hardDrop();
    guestSession!.onLocalTick();

    await _pumpUntil(
      tester,
      () => find.text('YOU WIN').evaluate().isNotEmpty,
      label: 'win title',
    );
    expect(
      find.byKey(const ValueKey('versus-result-sheet')),
      findsOneWidget,
      reason: 'wide layout must use the side sheet',
    );
    // Board is fully visible beside the sheet.
    final sheetLeft = tester
        .getTopLeft(find.byKey(const ValueKey('versus-result-sheet')))
        .dx;
    final boardRight = tester
        .getBottomRight(find.byKey(const ValueKey('tetris-board')))
        .dx;
    expect(sheetLeft, greaterThanOrEqualTo(boardRight));
    await _stage(tester, 'result1_win_sheet');
    await tester.pump(const Duration(milliseconds: 1200));

    // Rematch: host clicks, guest agrees over the wire, next match counts in.
    await tester.tap(find.text('Rematch'));
    await tester.pump(const Duration(milliseconds: 400));
    await _stage(tester, 'result2_waiting_rematch');
    guestSession!.requestRematch();
    await _pumpUntil(
      tester,
      () => find.text('YOU WIN').evaluate().isEmpty,
      label: 'second match countdown',
    );
    await _stage(tester, 'result3_rematch_countdown');

    guestTicker?.cancel();
    await guestSession?.dispose();
    await _stage(tester, 'result4_done');
  });
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tetris/src/net/protocol.dart';
import 'package:tetris/src/net/room_client.dart';
import 'package:tetris/src/net/versus_session.dart';
import 'package:tetris/src/ui/tetris_app.dart';

/// Live drive of the ready-up flow against a real backend: the visible app
/// hosts a room; a headless guest client in this same process joins, the
/// host readies via the real button, the guest readies over the wire, and
/// the match starts with the countdown.
///
/// Run with a reachable backend, e.g.:
///   --dart-define=TETRIS_BACKEND_URL=http://localhost:8787
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

  testWidgets('ready-up flow against the live backend', (tester) async {
    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(find.byKey(const ValueKey('home-versus')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('lobby-create')));

    // Wait for the real backend to allocate a room code.
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('lobby-room-code')).evaluate().isNotEmpty,
      label: 'room code',
    );
    final code = tester
        .widget<SelectableText>(find.byKey(const ValueKey('lobby-room-code')))
        .data!;
    expect(code, matches(RegExp(r'^[A-Z2-9]{5}$')));
    await _stage(tester, 'lobby1_waiting');

    // Headless guest joins over the wire.
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
        // Keep the guest session draining/mirroring so the host sees a live
        // opponent board.
        guestTicker = Timer.periodic(
          const Duration(milliseconds: 150),
          (_) => guestSession?.onLocalTick(),
        );
      }),
    );

    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('lobby-ready')).evaluate().isNotEmpty,
      label: 'ready button after guest join',
    );
    await _stage(tester, 'lobby2_opponent_joined');

    await tester.tap(find.byKey(const ValueKey('lobby-ready')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Waiting for opponent…'), findsOneWidget);
    await _stage(tester, 'lobby3_host_ready');

    guest.sendReady();
    await _pumpUntil(
      tester,
      () => find.byType(TetrisGamePage).evaluate().isNotEmpty,
      label: 'match start',
    );
    await tester.pump(const Duration(milliseconds: 700));
    await _stage(tester, 'lobby4_countdown');

    await _pumpUntil(
      tester,
      () => find.text('HOLD').evaluate().isNotEmpty,
      label: 'match HUD',
    );
    await tester.pump(const Duration(milliseconds: 2600));
    await _stage(tester, 'lobby5_match_running');

    guestTicker?.cancel();
    await guestSession?.dispose();
    await _stage(tester, 'lobby6_done');
  });
}

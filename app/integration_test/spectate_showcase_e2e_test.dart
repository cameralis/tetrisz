import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tetris/src/auth/auth_service.dart';
import 'package:tetris/src/game/tetris_game.dart';
import 'package:tetris/src/net/friends_client.dart';
import 'package:tetris/src/net/presence_client.dart';
import 'package:tetris/src/net/protocol.dart';
import 'package:tetris/src/ui/spectate_page.dart';
import 'package:tetris/src/ui/tetris_app.dart';

/// Live drive of spectation: a headless seeded TetrisGame plays in-process
/// (as the friend's device would) and its real frames stream into the
/// SpectatePage, ending with the stream-ended state.
const _markerDir = String.fromEnvironment('E2E_MARKER_DIR');

Future<void> _stage(WidgetTester tester, String name) async {
  if (_markerDir.isNotEmpty) {
    File('$_markerDir/$name')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('');
  }
  await tester.pump(const Duration(milliseconds: 1400));
}

class _FakePresenceChannel implements PresenceChannel {
  final controller = StreamController<PresenceEvent>.broadcast();

  @override
  Stream<PresenceEvent> get events => controller.stream;

  @override
  void setStatus(FriendPresence status) {}

  @override
  void sendInvite(String toUid) {}

  @override
  void respondInvite({
    required String toUid,
    required bool accept,
    String? roomCode,
  }) {}

  @override
  void watch(String uid) {}

  @override
  void unwatch() {}

  @override
  void publishSpectate(Map<String, dynamic> frame) {}

  @override
  Future<void> close() async {}
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('spectating a friend playing solo, live', (tester) async {
    final auth = FakeAuthService(uid: 'me');
    await auth.signInWithApple();
    final channel = _FakePresenceChannel();
    final hub = PresenceHub(auth: auth, channelFactory: (_) => channel);
    PresenceHub.install(hub);

    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pump(const Duration(milliseconds: 900));

    // The friend's device: a real seeded engine playing headlessly.
    final friendGame = TetrisGame(seed: 99);
    var seq = 0;
    var drops = 0;
    Map<String, dynamic> frameOf(TetrisGame game) {
      final active = game.active;
      seq += 1;
      return BoardStateMsg(
        seq: seq,
        cells: encodeVisibleBoard(game),
        active: active == null
            ? null
            : ActivePieceWire(
                type: active.type,
                rotation: active.rotation,
                x: active.x,
                y: active.y,
              ),
        pendingGarbage: 0,
        score: game.score,
        lines: game.lines,
      ).encode()
        ..['level'] = game.level;
    }

    final playTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (friendGame.gameOver) {
        return;
      }
      // Wander and drop so the board visibly grows.
      if (drops.isEven) {
        friendGame.moveLeft();
      } else {
        friendGame.moveRight();
        friendGame.rotateClockwise();
      }
      friendGame.hardDrop();
      drops += 1;
      channel.controller.add(
        SpectateFrame(fromUid: 'u-star', data: frameOf(friendGame)),
      );
    });

    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => SpectatePage(
          friend: const Friend(
            uid: 'u-star',
            displayName: 'STAR',
            friendCode: 'SSSSSS',
            rating: 1381,
          ),
          hub: hub,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await _stage(tester, 'spec1_waiting_or_first_frames');

    // Let a dozen pieces land on the watched board.
    await tester.pump(const Duration(seconds: 4));
    expect(find.textContaining('SCORE'), findsOneWidget);
    await _stage(tester, 'spec2_live_board');

    playTimer.cancel();
    channel.controller.add(const SpectateEnded(fromUid: 'u-star'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('spectate-ended')), findsOneWidget);
    await _stage(tester, 'spec3_stream_ended');
    await _stage(tester, 'spec4_done');
  });
}

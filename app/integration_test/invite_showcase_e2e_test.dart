import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tetris/src/auth/auth_service.dart';
import 'package:tetris/src/net/friends_client.dart';
import 'package:tetris/src/net/presence_client.dart';
import 'package:tetris/src/net/profile_client.dart';
import 'package:tetris/src/net/room_client.dart';
import 'package:tetris/src/ui/friends_page.dart';
import 'package:tetris/src/ui/tetris_app.dart';

/// Live drive of the friend-invite journey. The presence layer itself is the
/// test fake (real presence needs the Firebase sign-in from #10), but
/// everything from the accept onward is real: a production room is created,
/// a headless friend joins it over the wire, and the ready-up flow runs.
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

class _FakePresenceChannel implements PresenceChannel {
  final controller = StreamController<PresenceEvent>.broadcast();
  final responses = <({String toUid, bool accept, String? roomCode})>[];

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
  }) {
    responses.add((toUid: toUid, accept: accept, roomCode: roomCode));
  }

  @override
  void watch(String uid) {}

  @override
  void unwatch() {}

  @override
  void publishSpectate(Map<String, dynamic> frame) {}

  @override
  Future<void> close() async {}
}

class _FakeProfileApi implements ProfileApi {
  @override
  Future<PlayerProfile> fetch() async => const PlayerProfile(
    uid: 'me',
    displayName: 'SZABI',
    friendCode: 'AAAAAA',
    rating: 1216,
    ratedGames: 4,
  );

  @override
  Future<PlayerProfile> updateName(String name) => fetch();
}

class _FakeFriendsApi implements FriendsApi {
  @override
  Future<List<Friend>> list() async => const [
    Friend(
      uid: 'u-heavy',
      displayName: 'HEAVY',
      friendCode: 'HHHHHH',
      rating: 1381,
    ),
  ];

  @override
  Future<Friend> add(String friendCode) async =>
      (await list()).first;

  @override
  Future<void> remove(String uid) async {}
}

class _FakePresenceQuery implements PresenceQueryApi {
  @override
  Future<Map<String, FriendPresence>> query(List<String> uids) async => {
    'u-heavy': FriendPresence.online,
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('friend invite: online friend, challenge dialog, real room', (
    tester,
  ) async {
    final auth = FakeAuthService(uid: 'me');
    await auth.signInWithApple();
    final channel = _FakePresenceChannel();
    final hub = PresenceHub(auth: auth, channelFactory: (_) => channel);
    PresenceHub.install(hub);

    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pump(const Duration(milliseconds: 1100));

    // Friends page with a live online friend and its 1v1 button.
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => FriendsPage(
          auth: auth,
          friendsApi: _FakeFriendsApi(),
          profileApi: _FakeProfileApi(),
          presenceQuery: _FakePresenceQuery(),
          presenceHub: hub,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Online'), findsOneWidget);
    await _stage(tester, 'invite1_online_friend');

    await tester.tap(find.byKey(const ValueKey('friend-invite-u-heavy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await _stage(tester, 'invite2_sent_toast');
    await tester.pump(const Duration(milliseconds: 2600));

    // Incoming challenge (as the other side would see it).
    channel.controller.add(const InviteReceived(fromUid: 'u-heavy'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('1v1 challenge!'), findsOneWidget);
    await _stage(tester, 'invite3_challenge_dialog');

    // Accept: creates a REAL production room and waits in it.
    await tester.tap(find.byKey(const ValueKey('invite-accept')));
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('lobby-room-code')).evaluate().isNotEmpty,
      label: 'lobby with real room',
    );
    final code = tester
        .widget<SelectableText>(find.byKey(const ValueKey('lobby-room-code')))
        .data!;
    expect(channel.responses.single.roomCode, code);
    await _stage(tester, 'invite4_room_created');

    // The inviter's client joins the same room over the wire; ready-up runs.
    final friend = RoomClient.join(code);
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('lobby-ready')).evaluate().isNotEmpty,
      label: 'ready phase',
    );
    await _stage(tester, 'invite5_ready_phase');
    await friend.close();
    await tester.pump(const Duration(milliseconds: 600));
    await _stage(tester, 'invite6_done');
  });
}

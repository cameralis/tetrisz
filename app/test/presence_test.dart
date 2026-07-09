import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetris/src/auth/auth_service.dart';
import 'package:tetris/src/net/friends_client.dart';
import 'package:tetris/src/net/presence_client.dart';
import 'package:tetris/src/net/profile_client.dart';
import 'package:tetris/src/net/protocol.dart';
import 'package:tetris/src/net/room_client.dart';
import 'package:tetris/src/ui/friends_page.dart';
import 'package:tetris/src/ui/lobby_page.dart';
import 'package:tetris/src/ui/tetris_app.dart';

class FakePresenceChannel implements PresenceChannel {
  final controller = StreamController<PresenceEvent>.broadcast();
  final statuses = <FriendPresence>[];
  final invitesSent = <String>[];
  final responses = <({String toUid, bool accept, String? roomCode})>[];

  @override
  Stream<PresenceEvent> get events => controller.stream;

  @override
  void setStatus(FriendPresence status) => statuses.add(status);

  @override
  void sendInvite(String toUid) => invitesSent.add(toUid);

  @override
  void respondInvite({
    required String toUid,
    required bool accept,
    String? roomCode,
  }) {
    responses.add((toUid: toUid, accept: accept, roomCode: roomCode));
  }

  @override
  Future<void> close() async {
    if (!controller.isClosed) {
      await controller.close();
    }
  }
}

class FakeRoom implements RoomChannel {
  final envelopeController = StreamController<ServerEnvelope>.broadcast();
  final stateNotifier = ValueNotifier(RoomConnectionState.connected);
  final rttNotifier = ValueNotifier<Duration?>(null);
  final failureNotifier = ValueNotifier<String?>(null);
  int readiesSent = 0;

  @override
  String get code => 'INVIT';

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

class FakeProfileApi implements ProfileApi {
  @override
  Future<PlayerProfile> fetch() async => const PlayerProfile(
    uid: 'me',
    displayName: 'ME',
    friendCode: 'AAAAAA',
    rating: 1200,
    ratedGames: 0,
  );

  @override
  Future<PlayerProfile> updateName(String name) => fetch();
}

class FakeFriendsApi implements FriendsApi {
  final friends = <Friend>[
    const Friend(
      uid: 'u-pal',
      displayName: 'PAL',
      friendCode: 'PPPPPP',
      rating: 1250,
    ),
  ];

  @override
  Future<List<Friend>> list() async => List.of(friends);

  @override
  Future<Friend> add(String friendCode) async => friends.first;

  @override
  Future<void> remove(String uid) async {}
}

class FakePresenceQuery implements PresenceQueryApi {
  Map<String, FriendPresence> statuses = {};

  @override
  Future<Map<String, FriendPresence>> query(List<String> uids) async =>
      statuses;
}

PresenceHub _hubWith(FakeAuthService auth, FakePresenceChannel channel) {
  return PresenceHub(auth: auth, channelFactory: (_) => channel);
}

void main() {
  tearDown(() {
    PresenceHub.instance = null;
    Auth.install(UnconfiguredAuthService());
  });

  test('hub connects on sign-in, disconnects on sign-out', () async {
    final auth = FakeAuthService();
    final channel = FakePresenceChannel();
    final hub = _hubWith(auth, channel);

    expect(hub.connectedForSignedInUser, isFalse);
    await auth.signInWithApple();
    expect(hub.connectedForSignedInUser, isTrue);
    expect(channel.statuses, isNotEmpty);

    await auth.signOut();
    expect(hub.connectedForSignedInUser, isFalse);
  });

  testWidgets('online friends show status and an invite button that sends', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final auth = FakeAuthService();
    await auth.signInWithApple();
    final channel = FakePresenceChannel();
    final hub = _hubWith(auth, channel);
    final query = FakePresenceQuery()
      ..statuses = {'u-pal': FriendPresence.online};

    await tester.pumpWidget(
      MaterialApp(
        home: FriendsPage(
          auth: auth,
          friendsApi: FakeFriendsApi(),
          profileApi: FakeProfileApi(),
          presenceQuery: query,
          presenceHub: hub,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Online'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('friend-invite-u-pal')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(channel.invitesSent, ['u-pal']);

    // Drain the pending presence poll timer before teardown.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('incoming invite prompts and accept creates + joins a room', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final auth = FakeAuthService();
    await auth.signInWithApple();
    final channel = FakePresenceChannel();
    PresenceHub.install(_hubWith(auth, channel));
    final room = FakeRoom();

    await tester.pumpWidget(
      TetrisApp(
        enableAudio: false,
        gamepad: null,
        createInviteRoom: () async => room,
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    channel.controller.add(const InviteReceived(fromUid: 'u-challenger'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('1v1 challenge!'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('invite-accept')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(channel.responses, hasLength(1));
    expect(channel.responses.single.accept, isTrue);
    expect(channel.responses.single.roomCode, 'INVIT');
    // Landed in the lobby, waiting in the created room.
    expect(find.byType(LobbyPage), findsOneWidget);
    expect(find.text('INVIT'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('declining an invite responds without navigating', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final auth = FakeAuthService();
    await auth.signInWithApple();
    final channel = FakePresenceChannel();
    PresenceHub.install(_hubWith(auth, channel));

    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pump(const Duration(milliseconds: 400));

    channel.controller.add(const InviteReceived(fromUid: 'u-challenger'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('invite-decline')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(channel.responses.single.accept, isFalse);
    expect(find.byType(LobbyPage), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('the accepted event joins the inviter into the room', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final auth = FakeAuthService();
    await auth.signInWithApple();
    final channel = FakePresenceChannel();
    PresenceHub.install(_hubWith(auth, channel));

    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pump(const Duration(milliseconds: 400));

    channel.controller.add(
      const InviteAccepted(fromUid: 'u-pal', roomCode: 'JOINR'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // Navigated into the lobby joining that code (the fake join is not
    // wired here, so the page sits in its waiting stage for JOINR).
    expect(find.byType(LobbyPage), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

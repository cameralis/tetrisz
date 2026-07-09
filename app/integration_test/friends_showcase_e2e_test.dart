import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tetris/src/auth/auth_service.dart';
import 'package:tetris/src/net/friends_client.dart';
import 'package:tetris/src/net/profile_client.dart';
import 'package:tetris/src/ui/friends_page.dart';
import 'package:tetris/src/ui/tetris_app.dart';

/// Live drive of the Friends screen: the real signed-out gate, then the
/// signed-in flow (own code, add by code, list, remove) on the fakes the
/// tests use.
const _markerDir = String.fromEnvironment('E2E_MARKER_DIR');

Future<void> _stage(WidgetTester tester, String name) async {
  if (_markerDir.isNotEmpty) {
    File('$_markerDir/$name')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('');
  }
  await tester.pump(const Duration(milliseconds: 1400));
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
  final friends = <Friend>[
    const Friend(
      uid: 'u-heavy',
      displayName: 'HEAVY',
      friendCode: 'HHHHHH',
      rating: 1381,
    ),
  ];

  @override
  Future<List<Friend>> list() async => List.of(friends);

  @override
  Future<Friend> add(String friendCode) async {
    final friend = Friend(
      uid: 'u-$friendCode',
      displayName: 'GHOST',
      friendCode: friendCode,
      rating: 1184,
    );
    friends.add(friend);
    return friend;
  }

  @override
  Future<void> remove(String uid) async {
    friends.removeWhere((friend) => friend.uid == uid);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('friends: signed-out gate and full signed-in flow', (
    tester,
  ) async {
    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pump(const Duration(milliseconds: 1100));

    // Real state: signed out gates to the account screen.
    await tester.tap(find.byKey(const ValueKey('home-friends')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('friends-goto-account')), findsOneWidget);
    await _stage(tester, 'friends1_signed_out');

    // Signed-in flow with the test fakes.
    final auth = FakeAuthService(uid: 'me');
    await auth.signInWithApple();
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => FriendsPage(
          auth: auth,
          friendsApi: _FakeFriendsApi(),
          profileApi: _FakeProfileApi(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('HEAVY'), findsOneWidget);
    await _stage(tester, 'friends2_list');

    await tester.enterText(
      find.byKey(const ValueKey('friends-code-field')),
      'GGGGGG',
    );
    await tester.tap(find.byKey(const ValueKey('friends-add')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('GHOST'), findsOneWidget);
    await _stage(tester, 'friends3_added');
    await tester.pump(const Duration(milliseconds: 2600));

    await tester.tap(find.byKey(const ValueKey('friend-remove-u-GGGGGG')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('GHOST'), findsNothing);
    await _stage(tester, 'friends4_removed');
    await tester.pump(const Duration(milliseconds: 2600));
    await _stage(tester, 'friends5_done');
  });
}

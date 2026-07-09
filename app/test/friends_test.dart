import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tetris/src/auth/auth_service.dart';
import 'package:tetris/src/net/friends_client.dart';
import 'package:tetris/src/net/profile_client.dart';
import 'package:tetris/src/ui/friends_page.dart';
import 'package:tetris/src/ui/toasts.dart';

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
  final friends = <Friend>[];
  Object? addError;
  final added = <String>[];
  final removed = <String>[];

  @override
  Future<List<Friend>> list() async => List.of(friends);

  @override
  Future<Friend> add(String friendCode) async {
    if (addError != null) {
      throw addError!;
    }
    added.add(friendCode);
    final friend = Friend(
      uid: 'u-$friendCode',
      displayName: 'BUDDY',
      friendCode: friendCode,
      rating: 1216,
    );
    friends.add(friend);
    return friend;
  }

  @override
  Future<void> remove(String uid) async {
    removed.add(uid);
    friends.removeWhere((friend) => friend.uid == uid);
  }
}

Widget _host(AuthService auth, FakeFriendsApi friends) {
  return MaterialApp(
    builder: (context, child) =>
        TetrisToastHost(child: child ?? const SizedBox.shrink()),
    home: FriendsPage(
      auth: auth,
      friendsApi: friends,
      profileApi: FakeProfileApi(),
    ),
  );
}

Future<void> _drainToasts(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('signed-out state routes to the account page', (tester) async {
    await tester.pumpWidget(_host(UnconfiguredAuthService(), FakeFriendsApi()));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('friends-goto-account')), findsOneWidget);
  });

  testWidgets('adding a friend by code updates the list', (tester) async {
    final auth = FakeAuthService();
    await auth.signInWithApple();
    final api = FakeFriendsApi();
    await tester.pumpWidget(_host(auth, api));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('AAAAAA'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('friends-code-field')),
      'BBBBBB',
    );
    await tester.tap(find.byKey(const ValueKey('friends-add')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(api.added, ['BBBBBB']);
    expect(find.text('BUDDY'), findsOneWidget);
    expect(find.textContaining('now friends'), findsOneWidget);
    await _drainToasts(tester);
  });

  testWidgets('add errors surface as toasts', (tester) async {
    final auth = FakeAuthService();
    await auth.signInWithApple();
    final api = FakeFriendsApi()
      ..addError = FriendsException('No player has that friend code.');
    await tester.pumpWidget(_host(auth, api));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(
      find.byKey(const ValueKey('friends-code-field')),
      'CCCCCC',
    );
    await tester.tap(find.byKey(const ValueKey('friends-add')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('No player has that friend code.'), findsOneWidget);
    await _drainToasts(tester);
  });

  testWidgets('removing a friend calls the backend and empties the list', (
    tester,
  ) async {
    final auth = FakeAuthService();
    await auth.signInWithApple();
    final api = FakeFriendsApi()
      ..friends.add(
        const Friend(
          uid: 'u-x',
          displayName: 'EX',
          friendCode: 'XXXXXX',
          rating: 1100,
        ),
      );
    await tester.pumpWidget(_host(auth, api));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('EX'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('friend-remove-u-x')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(api.removed, ['u-x']);
    expect(find.text('EX'), findsNothing);
    expect(find.textContaining('No friends yet'), findsOneWidget);
    await _drainToasts(tester);
  });
}

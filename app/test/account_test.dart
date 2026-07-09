import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tetris/src/auth/auth_service.dart';
import 'package:tetris/src/net/profile_client.dart';
import 'package:tetris/src/ui/account_page.dart';
import 'package:tetris/src/ui/toasts.dart';

class FakeProfileApi implements ProfileApi {
  FakeProfileApi();

  String displayName = '';
  int fetches = 0;
  int updates = 0;

  PlayerProfile get _profile => PlayerProfile(
    uid: 'fake-user',
    displayName: displayName,
    friendCode: 'KDX7Q2',
    rating: 1200,
    ratedGames: 0,
  );

  @override
  Future<PlayerProfile> fetch() async {
    fetches += 1;
    return _profile;
  }

  @override
  Future<PlayerProfile> updateName(String name) async {
    updates += 1;
    displayName = name;
    return _profile;
  }
}

Widget _host(AuthService auth, ProfileApi api) {
  return MaterialApp(
    builder: (context, child) =>
        TetrisToastHost(child: child ?? const SizedBox.shrink()),
    home: AccountPage(auth: auth, profileApi: api),
  );
}

void main() {
  testWidgets('sign in reveals the profile with friend code and rating', (
    tester,
  ) async {
    final auth = FakeAuthService();
    final api = FakeProfileApi();
    await tester.pumpWidget(_host(auth, api));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(const ValueKey('account-signin-apple')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('account-signin-apple')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('KDX7Q2'), findsOneWidget);
    expect(find.byKey(const ValueKey('account-rating')), findsOneWidget);
    expect(find.text('1200'), findsOneWidget);
    expect(api.fetches, 1);
  });

  testWidgets('saving the display name calls the backend', (tester) async {
    final auth = FakeAuthService();
    final api = FakeProfileApi();
    await auth.signInWithApple();
    await tester.pumpWidget(_host(auth, api));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(
      find.byKey(const ValueKey('account-name')),
      'SZABI',
    );
    await tester.tap(find.byKey(const ValueKey('account-save-name')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(api.updates, 1);
    expect(api.displayName, 'SZABI');
    expect(find.text('Display name saved'), findsOneWidget);
    // Let the toast expire.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('sign out returns to the signed-out state', (tester) async {
    final auth = FakeAuthService();
    final api = FakeProfileApi();
    await auth.signInWithApple();
    await tester.pumpWidget(_host(auth, api));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byKey(const ValueKey('account-signout')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const ValueKey('account-signin-apple')), findsOneWidget);
  });

  testWidgets('unconfigured build explains itself instead of signing in', (
    tester,
  ) async {
    final auth = UnconfiguredAuthService();
    final api = FakeProfileApi();
    await tester.pumpWidget(_host(auth, api));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.textContaining('no Firebase project'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('account-signin-apple')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.textContaining('not configured in this build'),
      findsOneWidget,
    );
    expect(auth.account.value, isNull);
    // Let the toast expire.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 400));
  });
}

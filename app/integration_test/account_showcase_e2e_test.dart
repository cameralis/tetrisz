import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tetris/src/auth/auth_service.dart';
import 'package:tetris/src/net/profile_client.dart';
import 'package:tetris/src/ui/account_page.dart';
import 'package:tetris/src/ui/tetris_app.dart';

/// Live drive of the Account screen: the real unconfigured build state
/// (sign-in disabled with an explanation), then the signed-in profile UI
/// exercised with the fake auth/profile backends.
const _markerDir = String.fromEnvironment('E2E_MARKER_DIR');

Future<void> _stage(WidgetTester tester, String name) async {
  if (_markerDir.isNotEmpty) {
    File('$_markerDir/$name')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('');
  }
  await tester.pump(const Duration(milliseconds: 1400));
}

class _ShowcaseProfileApi implements ProfileApi {
  String displayName = 'SZABI';

  PlayerProfile get _profile => PlayerProfile(
    uid: 'showcase',
    displayName: displayName,
    friendCode: 'KDX7Q2',
    rating: 1200,
    ratedGames: 0,
  );

  @override
  Future<PlayerProfile> fetch() async => _profile;

  @override
  Future<PlayerProfile> updateName(String name) async {
    displayName = name;
    return _profile;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('account screen: unconfigured state and signed-in profile', (
    tester,
  ) async {
    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pump(const Duration(milliseconds: 1100));

    // Real state of this build: accounts unconfigured.
    await tester.tap(find.byKey(const ValueKey('home-account')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('no Firebase project'), findsOneWidget);
    await _stage(tester, 'account1_signed_out');

    await tester.tap(find.byKey(const ValueKey('account-signin-apple')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.textContaining('not configured in this build'),
      findsOneWidget,
    );
    await _stage(tester, 'account2_unconfigured_toast');
    await tester.pump(const Duration(milliseconds: 2800));

    // Signed-in UI, driven by the fake backends the tests use.
    final auth = FakeAuthService(uid: 'showcase');
    await auth.signInWithApple();
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => AccountPage(auth: auth, profileApi: _ShowcaseProfileApi()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('KDX7Q2'), findsOneWidget);
    await _stage(tester, 'account3_profile');

    await tester.enterText(
      find.byKey(const ValueKey('account-name')),
      'SZABI_PRO',
    );
    await tester.tap(find.byKey(const ValueKey('account-save-name')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Display name saved'), findsOneWidget);
    await _stage(tester, 'account4_name_saved');
    await tester.pump(const Duration(milliseconds: 2800));
    await _stage(tester, 'account5_done');
  });
}

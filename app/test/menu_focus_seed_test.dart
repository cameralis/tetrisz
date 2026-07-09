import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamepads/gamepads.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetris/src/auth/auth_service.dart';
import 'package:tetris/src/input/gamepad_service.dart';
import 'package:tetris/src/net/friends_client.dart';
import 'package:tetris/src/ui/account_page.dart';
import 'package:tetris/src/ui/controls_page.dart';
import 'package:tetris/src/ui/diagnostics_page.dart';
import 'package:tetris/src/ui/friends_page.dart';
import 'package:tetris/src/ui/leaderboard_page.dart';
import 'package:tetris/src/ui/spectate_page.dart';

/// Every menu page must seed controller focus on entry: without an
/// `autofocus` control the first d-pad press only lands focus somewhere and
/// nothing on screen highlights, which reads as "controller doesn't work
/// here".
///
/// True when the primary focus sits inside the widget carrying [key].
bool _focusWithin(Key key) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) {
    return false;
  }
  if (context.widget.key == key) {
    return true;
  }
  var found = false;
  context.visitAncestorElements((element) {
    if (element.widget.key == key) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

Future<void> _pumpPage(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(MaterialApp(home: page));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('account page (signed out) seeds focus on Apple sign-in', (
    tester,
  ) async {
    await _pumpPage(tester, AccountPage(auth: FakeAuthService()));
    expect(_focusWithin(const ValueKey('account-signin-apple')), isTrue);
  });

  testWidgets('friends page (signed out) seeds focus on Go to Account', (
    tester,
  ) async {
    await _pumpPage(tester, FriendsPage(auth: FakeAuthService()));
    expect(_focusWithin(const ValueKey('friends-goto-account')), isTrue);
  });

  testWidgets('leaderboard page seeds focus on the solo tab', (tester) async {
    await _pumpPage(tester, const LeaderboardPage());
    expect(_focusWithin(const ValueKey('board-solo')), isTrue);
  });

  testWidgets('diagnostics page seeds focus on the controls tile', (
    tester,
  ) async {
    await _pumpPage(tester, const DiagnosticsPage());
    expect(_focusWithin(const ValueKey('open-controls')), isTrue);
  });

  testWidgets('controls page seeds focus on the first action tile', (
    tester,
  ) async {
    // Without a gamepad service the action tiles are inert (capture
    // disabled), so the seed only applies when one is present — as in
    // production, where main() always installs the platform service.
    final gamepad = GamepadService(
      events: const Stream<NormalizedGamepadEvent>.empty(),
      list: () async => const [],
    );
    await _pumpPage(tester, ControlsPage(gamepad: gamepad));
    expect(_focusWithin(const ValueKey('gamepad-action-moveLeft')), isTrue);
  });

  testWidgets('spectate page seeds focus on its back button', (tester) async {
    await _pumpPage(
      tester,
      const SpectatePage(
        friend: Friend(
          uid: 'u1',
          displayName: 'Friend',
          friendCode: 'ABC123',
          rating: 1000,
        ),
      ),
    );
    expect(_focusWithin(const ValueKey('spectate-back')), isTrue);
  });
}

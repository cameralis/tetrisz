import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamepads/gamepads.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetris/src/game/tetris_game.dart';
import 'package:tetris/src/game/tetromino.dart';
import 'package:tetris/src/input/gamepad_service.dart';
import 'package:tetris/src/ui/controls_page.dart';
import 'package:tetris/src/ui/tetris_app.dart';

const _phoneViewport = Size(390, 844);

class _FakeGamepad {
  _FakeGamepad()
    : _source = StreamController<NormalizedGamepadEvent>.broadcast() {
    service = GamepadService(
      events: _source.stream,
      list: () async => const [],
    );
  }

  final StreamController<NormalizedGamepadEvent> _source;
  late final GamepadService service;

  void setButton(GamepadButton button, bool down, {String pad = 'pad-1'}) {
    _source.add(
      NormalizedGamepadEvent(
        gamepadId: pad,
        timestamp: 0,
        value: down ? 1 : 0,
        button: button,
        rawEvent: GamepadEvent(
          gamepadId: pad,
          timestamp: 0,
          type: KeyType.button,
          key: 'test',
          value: down ? 1 : 0,
        ),
      ),
    );
  }
}

void _usePhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = _phoneViewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Presses and releases a button, pumping so both edges are delivered.
Future<void> _press(
  WidgetTester tester,
  _FakeGamepad gamepad,
  GamepadButton button,
) async {
  gamepad.setButton(button, true);
  await tester.pump();
  gamepad.setButton(button, false);
  await tester.pump();
}

Future<TetrisGame> _pumpGame(WidgetTester tester, _FakeGamepad gamepad) async {
  final game = TetrisGame(scriptedPieces: List.filled(64, Tetromino.t));
  await tester.pumpWidget(
    TetrisApp(enableAudio: false, game: game, gamepad: gamepad.service),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  return game;
}

void main() {
  testWidgets('controller starts a game from the home menu with South', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final gamepad = _FakeGamepad();
    await tester.pumpWidget(
      TetrisApp(enableAudio: false, gamepad: gamepad.service),
    );
    await tester.pump();

    // Play is autofocused; a single South press activates it.
    await _press(tester, gamepad, GamepadButton.a);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const ValueKey('tetris-board')), findsOneWidget);
  });

  testWidgets('controller cannot pop the game page with East mid-round', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final gamepad = _FakeGamepad();
    await _pumpGame(tester, gamepad);

    await _press(tester, gamepad, GamepadButton.b);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('tetris-board')), findsOneWidget);
  });

  testWidgets('focus navigation stays off while the board is live', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final gamepad = _FakeGamepad();
    final game = await _pumpGame(tester, gamepad);

    expect(gamepad.service.uiNavigationBlocked, isTrue);

    // D-pad moves the piece, not focus: no button may take primary focus.
    final spawnX = game.active!.x;
    await _press(tester, gamepad, GamepadButton.dpadLeft);
    expect(game.active!.x, spawnX - 1);
    final focused = FocusManager.instance.primaryFocus;
    expect(focused is FocusScopeNode || focused == null, isTrue);
  });

  testWidgets('pause overlay is controller-driven: resume via South', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final gamepad = _FakeGamepad();
    final game = await _pumpGame(tester, gamepad);

    await _press(tester, gamepad, GamepadButton.start);
    expect(game.paused, isTrue);
    expect(gamepad.service.uiNavigationBlocked, isFalse);

    // The Resume button autofocuses when the overlay appears; South both
    // reaches the inert gameplay handler (board is paused) and activates it.
    await _press(tester, gamepad, GamepadButton.a);
    await tester.pump(const Duration(milliseconds: 100));

    expect(game.paused, isFalse);
    expect(gamepad.service.uiNavigationBlocked, isTrue);
  });

  testWidgets('d-pad adjusts a focused volume slider without moving focus', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final gamepad = _FakeGamepad();
    final game = await _pumpGame(tester, gamepad);

    await _press(tester, gamepad, GamepadButton.start);
    expect(game.paused, isTrue);

    // Walk focus upward from the autofocused Resume button until the music
    // slider has it; the exact hop count is a traversal-policy detail.
    bool musicSliderFocused() {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) {
        return false;
      }
      final slider = context.widget is Slider
          ? context.widget as Slider
          : context.findAncestorWidgetOfExactType<Slider>();
      return slider?.key == const ValueKey('music-volume-slider');
    }

    for (var i = 0; i < 6 && !musicSliderFocused(); i += 1) {
      await _press(tester, gamepad, GamepadButton.dpadUp);
    }
    expect(musicSliderFocused(), isTrue);

    final musicSlider = find.byKey(const ValueKey('music-volume-slider'));
    final before = tester.widget<Slider>(musicSlider).value;
    await _press(tester, gamepad, GamepadButton.dpadRight);
    final after = tester.widget<Slider>(musicSlider).value;
    expect(after, moreOrLessEquals(before + 0.05));

    await _press(tester, gamepad, GamepadButton.dpadLeft);
    expect(
      tester.widget<Slider>(musicSlider).value,
      moreOrLessEquals(before),
    );
  });

  testWidgets('game over overlay restarts via the autofocused Restart', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final gamepad = _FakeGamepad();
    final game = await _pumpGame(tester, gamepad);

    // Stack T pieces without moving until the round tops out.
    for (var i = 0; i < 20 && !game.gameOver; i += 1) {
      await _press(tester, gamepad, GamepadButton.dpadUp);
    }
    expect(game.gameOver, isTrue);
    await tester.pump(const Duration(milliseconds: 100));
    expect(gamepad.service.uiNavigationBlocked, isFalse);

    await _press(tester, gamepad, GamepadButton.a);
    await tester.pump(const Duration(milliseconds: 100));

    expect(game.gameOver, isFalse);
    expect(game.lockCount, 0);
  });

  testWidgets('binding capture claims the pad so navigation stays quiet', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final gamepad = _FakeGamepad();
    await tester.pumpWidget(
      MaterialApp(home: ControlsPage(gamepad: gamepad.service)),
    );
    await tester.pump();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('gamepad-action-hold')),
      200,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('gamepad-action-hold')),
    );
    await tester.pumpAndSettle();

    expect(gamepad.service.uiNavigationBlocked, isFalse);
    await tester.tap(find.byKey(const ValueKey('gamepad-action-hold')));
    await tester.pumpAndSettle();
    expect(gamepad.service.uiNavigationBlocked, isTrue);

    gamepad.setButton(GamepadButton.leftTrigger, true);
    await tester.pumpAndSettle();
    expect(find.text('Bind Hold'), findsNothing);
    expect(gamepad.service.uiNavigationBlocked, isFalse);
  });

  testWidgets('East pops a pushed menu page back to home', (tester) async {
    _usePhoneViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final gamepad = _FakeGamepad();
    await tester.pumpWidget(
      TetrisApp(enableAudio: false, gamepad: gamepad.service),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('home-leaderboard')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-play')), findsNothing);

    await _press(tester, gamepad, GamepadButton.b);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-play')), findsOneWidget);
  });
}

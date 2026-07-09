import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamepads/gamepads.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetris/src/game/tetris_game.dart';
import 'package:tetris/src/game/tetromino.dart';
import 'package:tetris/src/input/control_bindings.dart';
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

  void setAxis(GamepadAxis axis, double value, {String pad = 'pad-1'}) {
    _source.add(
      NormalizedGamepadEvent(
        gamepadId: pad,
        timestamp: 0,
        value: value,
        axis: axis,
        rawEvent: GamepadEvent(
          gamepadId: pad,
          timestamp: 0,
          type: KeyType.analog,
          key: 'test',
          value: value,
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

/// Pumps straight onto the game page with an injected deterministic game and
/// fake gamepad, waiting out the async preference load.
Future<TetrisGame> _pumpGame(WidgetTester tester, _FakeGamepad gamepad) async {
  final game = TetrisGame(scriptedPieces: List.filled(64, Tetromino.t));
  await tester.pumpWidget(
    TetrisApp(enableAudio: false, game: game, gamepad: gamepad.service),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  return game;
}

/// Delivers pending gamepad stream events to the page without advancing the
/// game clock.
Future<void> _deliver(WidgetTester tester) => tester.pump();

void main() {
  testWidgets('guideline gamepad defaults drive the board', (tester) async {
    _usePhoneViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final gamepad = _FakeGamepad();
    final game = await _pumpGame(tester, gamepad);

    final spawnX = game.active!.x;
    gamepad.setButton(GamepadButton.dpadLeft, true);
    await _deliver(tester);
    gamepad.setButton(GamepadButton.dpadLeft, false);
    await _deliver(tester);
    expect(game.active!.x, spawnX - 1);

    gamepad.setButton(GamepadButton.dpadRight, true);
    await _deliver(tester);
    gamepad.setButton(GamepadButton.dpadRight, false);
    await _deliver(tester);
    expect(game.active!.x, spawnX);

    // B/Circle rotates clockwise, A/Cross counterclockwise.
    gamepad.setButton(GamepadButton.b, true);
    await _deliver(tester);
    expect(game.active!.rotation, 1);
    gamepad.setButton(GamepadButton.b, false);
    gamepad.setButton(GamepadButton.a, true);
    await _deliver(tester);
    expect(game.active!.rotation, 0);
    gamepad.setButton(GamepadButton.a, false);
    await _deliver(tester);

    // Bumpers hold.
    gamepad.setButton(GamepadButton.leftBumper, true);
    await _deliver(tester);
    expect(game.holdPiece, Tetromino.t);
    gamepad.setButton(GamepadButton.leftBumper, false);
    await _deliver(tester);

    // D-pad up hard drops and locks.
    final locksBefore = game.lockCount;
    gamepad.setButton(GamepadButton.dpadUp, true);
    await _deliver(tester);
    expect(game.lockCount, locksBefore + 1);
    gamepad.setButton(GamepadButton.dpadUp, false);
    await _deliver(tester);

    // Menu/Options pauses and resumes.
    gamepad.setButton(GamepadButton.start, true);
    await _deliver(tester);
    expect(game.paused, isTrue);
    gamepad.setButton(GamepadButton.start, false);
    gamepad.setButton(GamepadButton.start, true);
    await _deliver(tester);
    expect(game.paused, isFalse);
    gamepad.setButton(GamepadButton.start, false);
    await _deliver(tester);
  });

  testWidgets('left stick moves and soft drops via the engine', (tester) async {
    _usePhoneViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final gamepad = _FakeGamepad();
    final game = await _pumpGame(tester, gamepad);

    final spawnX = game.active!.x;
    gamepad.setAxis(GamepadAxis.leftStickX, -1);
    await _deliver(tester);
    expect(game.active!.x, spawnX - 1);
    gamepad.setAxis(GamepadAxis.leftStickX, 0);
    await _deliver(tester);

    // Stick down (-1) engages the engine's sustained soft drop.
    gamepad.setAxis(GamepadAxis.leftStickY, -1);
    await _deliver(tester);
    expect(game.softDropping, isTrue);
    gamepad.setAxis(GamepadAxis.leftStickY, 0);
    await _deliver(tester);
    expect(game.softDropping, isFalse);
  });

  testWidgets('held direction auto-repeats after the DAS delay', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final gamepad = _FakeGamepad();
    final game = await _pumpGame(tester, gamepad);

    gamepad.setButton(GamepadButton.dpadRight, true);
    await _deliver(tester);
    final afterPress = game.active!.x;

    // Four 50 ms frames: 167 ms DAS delay elapses inside the fourth, which
    // then also covers one 33 ms repeat interval.
    for (var i = 0; i < 4; i += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(game.active!.x, afterPress + 2);

    gamepad.setButton(GamepadButton.dpadRight, false);
    await _deliver(tester);
    final afterRelease = game.active!.x;
    await tester.pump(const Duration(milliseconds: 200));
    expect(game.active!.x, afterRelease);
  });

  testWidgets('custom gamepad bindings from preferences apply', (tester) async {
    _usePhoneViewport(tester);
    SharedPreferences.setMockInitialValues({
      tetrisGamepadBindingsPreferenceKey: '{"buttonSouth":"hardDrop"}',
    });
    final gamepad = _FakeGamepad();
    final game = await _pumpGame(tester, gamepad);

    // D-pad up is unbound in the custom map.
    gamepad.setButton(GamepadButton.dpadUp, true);
    await _deliver(tester);
    expect(game.lockCount, 0);
    gamepad.setButton(GamepadButton.dpadUp, false);
    await _deliver(tester);

    gamepad.setButton(GamepadButton.a, true);
    await _deliver(tester);
    expect(game.lockCount, 1);
    gamepad.setButton(GamepadButton.a, false);
    await _deliver(tester);
  });

  testWidgets('rebound touch gestures apply', (tester) async {
    _usePhoneViewport(tester);
    SharedPreferences.setMockInitialValues({
      tetrisTouchBindingsPreferenceKey:
          '{"tapRight":"hold","tapLeft":"moveLeft"}',
    });
    final gamepad = _FakeGamepad();
    final game = await _pumpGame(tester, gamepad);

    final board = find.byKey(const ValueKey('tetris-board'));
    final center = tester.getCenter(board);

    final spawnX = game.active!.x;
    await tester.tapAt(center + const Offset(-80, 0));
    await tester.pump();
    expect(game.active!.x, spawnX - 1);
    expect(game.holdPiece, isNull);

    await tester.tapAt(center + const Offset(80, 0));
    await tester.pump();
    expect(game.holdPiece, Tetromino.t);
  });

  testWidgets('controls page captures a new binding from the gamepad', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final gamepad = _FakeGamepad();
    await tester.pumpWidget(
      MaterialApp(home: ControlsPage(gamepad: gamepad.service)),
    );
    await tester.pump();

    // scrollUntilVisible stops once the tile is built, which can still be in
    // the off-screen cache area; ensureVisible actually brings it on screen.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('gamepad-action-hold')),
      200,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('gamepad-action-hold')),
    );
    await tester.pumpAndSettle();
    // Hold starts on the bumpers per the guideline defaults.
    expect(
      find.byKey(const ValueKey('binding-hold-leftBumper')),
      findsOneWidget,
    );

    // Tap the tile's title: the binding chips in the subtitle are themselves
    // pressable now (press removes the binding), so the tile's center is no
    // longer a safe tap target.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('gamepad-action-hold')),
        matching: find.text('Hold'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Bind Hold'), findsOneWidget);

    gamepad.setButton(GamepadButton.leftTrigger, true);
    await tester.pumpAndSettle();
    expect(find.text('Bind Hold'), findsNothing);
    expect(
      find.byKey(const ValueKey('binding-hold-leftTrigger')),
      findsOneWidget,
    );

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(tetrisGamepadBindingsPreferenceKey),
      contains('"leftTrigger":"hold"'),
    );
  });

  testWidgets('controls page rebinds a touch gesture', (tester) async {
    _usePhoneViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final gamepad = _FakeGamepad();
    await tester.pumpWidget(
      MaterialApp(home: ControlsPage(gamepad: gamepad.service)),
    );
    await tester.pump();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('touch-gesture-swipeUp')),
      200,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('touch-gesture-swipeUp')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('touch-gesture-swipeUp')));
    await tester.pumpAndSettle();
    // The dropdown menu draws over the page; its item is the last match.
    await tester.tap(find.text('Rotate Right').last);
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(tetrisTouchBindingsPreferenceKey),
      contains('"swipeUp":"rotateClockwise"'),
    );
  });
}

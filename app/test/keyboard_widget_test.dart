import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetris/src/game/tetris_game.dart';
import 'package:tetris/src/game/tetromino.dart';
import 'package:tetris/src/input/control_bindings.dart';
import 'package:tetris/src/ui/controls_page.dart';
import 'package:tetris/src/ui/tetris_app.dart';

const _desktopViewport = Size(1280, 800);

/// Keyboard support is gated to [isDesktopPlatform], but the test binding
/// reports Android by default. Force a desktop platform for the body and
/// clear it before the body returns — the framework verifies foundation debug
/// vars are unset at the end of the test, ahead of any `tearDown`.
Future<void> _onDesktop(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void _useDesktopViewport(WidgetTester tester) {
  tester.view.physicalSize = _desktopViewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Pumps straight onto the game page with an injected deterministic game,
/// waiting out the async preference load.
Future<TetrisGame> _pumpGame(WidgetTester tester) async {
  final game = TetrisGame(scriptedPieces: List.filled(64, Tetromino.t));
  await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  return game;
}

Future<void> _tap(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.pump();
}

void main() {
  testWidgets('standard keyboard defaults drive the board', (tester) async {
    await _onDesktop(() async {
      _useDesktopViewport(tester);
      SharedPreferences.setMockInitialValues({});
      final game = await _pumpGame(tester);

      final spawnX = game.active!.x;
      await _tap(tester, LogicalKeyboardKey.arrowLeft);
      expect(game.active!.x, spawnX - 1);
      await _tap(tester, LogicalKeyboardKey.arrowRight);
      expect(game.active!.x, spawnX);

      // Up rotates clockwise, Z rotates counterclockwise.
      await _tap(tester, LogicalKeyboardKey.arrowUp);
      expect(game.active!.rotation, 1);
      await _tap(tester, LogicalKeyboardKey.keyZ);
      expect(game.active!.rotation, 0);

      // C holds.
      await _tap(tester, LogicalKeyboardKey.keyC);
      expect(game.holdPiece, Tetromino.t);

      // Space hard drops and locks.
      final locksBefore = game.lockCount;
      await _tap(tester, LogicalKeyboardKey.space);
      expect(game.lockCount, locksBefore + 1);

      // Esc pauses and resumes.
      await _tap(tester, LogicalKeyboardKey.escape);
      expect(game.paused, isTrue);
      await _tap(tester, LogicalKeyboardKey.escape);
      expect(game.paused, isFalse);
    });
  });

  testWidgets('holding Down engages the engine soft drop', (tester) async {
    await _onDesktop(() async {
      _useDesktopViewport(tester);
      SharedPreferences.setMockInitialValues({});
      final game = await _pumpGame(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(game.softDropping, isTrue);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(game.softDropping, isFalse);
    });
  });

  testWidgets('a held direction auto-repeats after the DAS delay', (
    tester,
  ) async {
    await _onDesktop(() async {
      _useDesktopViewport(tester);
      SharedPreferences.setMockInitialValues({});
      final game = await _pumpGame(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      final afterPress = game.active!.x;

      // Four 50 ms frames: the 167 ms DAS delay elapses inside the fourth,
      // which then also covers one 33 ms repeat interval.
      for (var i = 0; i < 4; i += 1) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(game.active!.x, afterPress + 2);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      final afterRelease = game.active!.x;
      await tester.pump(const Duration(milliseconds: 200));
      expect(game.active!.x, afterRelease);
    });
  });

  testWidgets('custom keyboard bindings from preferences apply', (
    tester,
  ) async {
    await _onDesktop(() async {
      _useDesktopViewport(tester);
      SharedPreferences.setMockInitialValues({
        tetrisKeyboardBindingsPreferenceKey:
            '{"${LogicalKeyboardKey.keyW.keyId}":"hardDrop"}',
      });
      final game = await _pumpGame(tester);

      // Up is unbound in the custom map, so it no longer rotates.
      await _tap(tester, LogicalKeyboardKey.arrowUp);
      expect(game.active!.rotation, 0);

      // W now hard drops and locks.
      final locksBefore = game.lockCount;
      await _tap(tester, LogicalKeyboardKey.keyW);
      expect(game.lockCount, locksBefore + 1);
    });
  });

  testWidgets('controls page captures a new keyboard binding', (tester) async {
    await _onDesktop(() async {
      _useDesktopViewport(tester);
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const MaterialApp(home: ControlsPage()));
      await tester.pump();

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('keyboard-action-hardDrop')),
        200,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('keyboard-action-hardDrop')),
      );
      await tester.pumpAndSettle();
      // Space hard drops per the standard defaults.
      expect(
        find.byKey(
          ValueKey('key-binding-hardDrop-${LogicalKeyboardKey.space.keyId}'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('keyboard-action-hardDrop')));
      await tester.pumpAndSettle();
      expect(find.text('Bind Hard Drop'), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.pumpAndSettle();
      expect(find.text('Bind Hard Drop'), findsNothing);
      expect(
        find.byKey(
          ValueKey('key-binding-hardDrop-${LogicalKeyboardKey.keyW.keyId}'),
        ),
        findsOneWidget,
      );

      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString(tetrisKeyboardBindingsPreferenceKey),
        contains('"${LogicalKeyboardKey.keyW.keyId}":"hardDrop"'),
      );
    });
  });

  testWidgets('Esc cancels the capture dialog without binding', (tester) async {
    await _onDesktop(() async {
      _useDesktopViewport(tester);
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const MaterialApp(home: ControlsPage()));
      await tester.pump();

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('keyboard-action-hold')),
        200,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('keyboard-action-hold')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('keyboard-action-hold')));
      await tester.pumpAndSettle();
      expect(find.text('Bind Hold'), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Bind Hold'), findsNothing);

      // Hold keeps its defaults; Esc did not become a Hold binding.
      expect(
        find.byKey(
          ValueKey('key-binding-hold-${LogicalKeyboardKey.keyC.keyId}'),
        ),
        findsOneWidget,
      );
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString(tetrisKeyboardBindingsPreferenceKey),
        isNull,
      );
    });
  });
}

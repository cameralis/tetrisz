import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetris/src/game/tetris_game.dart';
import 'package:tetris/src/game/tetromino.dart';
import 'package:tetris/src/ui/tetris_app.dart';

const _phoneViewport = Size(390, 844);
const _staleFrameGap = Duration(seconds: 20);
const _partialSnapDrag = Offset(24, 0);
const _committingSnapDrag = Offset(34, 0);
const _partialDiagonalDownDrag = Offset(24, 96);
const _committingDiagonalDownDrag = Offset(34, 96);
const _committingDiagonalUpDrag = Offset(34, -96);
const _snapCommitDuration = Duration(milliseconds: 64);
const _snapPreviewFraction = 0.25;
const _snapCommitFraction = 0.7;
const _snapBlockedFraction = 0.22;
const _largeWallDrag = Offset(240, 0);

void _usePhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = _phoneViewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

int _visibleLockedCellCount(TetrisGame game) {
  var count = 0;
  for (var y = 0; y < TetrisGame.visibleRows; y += 1) {
    for (var x = 0; x < TetrisGame.width; x += 1) {
      if (game.visibleCellAt(x, y) != null) {
        count += 1;
      }
    }
  }
  return count;
}

double _boardActiveHorizontalOffset(WidgetTester tester) {
  final boardPaints = tester.widgetList<CustomPaint>(
    find.descendant(
      of: find.byKey(const ValueKey('tetris-board')),
      matching: find.byType(CustomPaint),
    ),
  );
  final boardPaint = boardPaints.singleWhere(
    (paint) => paint.painter.runtimeType.toString() == '_BoardPainter',
  );
  return (boardPaint.painter as dynamic).activeHorizontalOffset as double;
}

double _previewOffsetForDrag(double dragX, double cellWidth) {
  return ((dragX / (cellWidth * _snapCommitFraction)) * _snapPreviewFraction)
      .clamp(-_snapPreviewFraction, _snapPreviewFraction)
      .toDouble();
}

Future<void> _flushPreferenceTasks(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(Duration.zero);
  });
  await tester.pump();
}

void _expectFreshZeroGame(TetrisGame game) {
  expect(game.score, 0);
  expect(game.lines, 0);
  expect(game.level, 1);
  expect(game.gameOver, isFalse);
  expect(game.paused, isFalse);
  expect(_visibleLockedCellCount(game), 0);
  expect(game.activeCells, isNotEmpty);
  expect(
    game.activeCells.where((cell) => cell.y >= TetrisGame.bufferRows),
    isEmpty,
  );
}

TetrisGame _visiblePieceGame(Tetromino type) {
  final game = TetrisGame(scriptedPieces: [type, Tetromino.o, Tetromino.i]);
  for (var i = 0; i < 4; i += 1) {
    game.softDropStep();
  }
  return game;
}

void _fillVisibleRowExcept(
  TetrisGame game,
  int visibleY,
  Set<int> openColumns,
) {
  for (var x = 0; x < TetrisGame.width; x += 1) {
    if (!openColumns.contains(x)) {
      game.setVisibleCell(x, visibleY, Tetromino.z);
    }
  }
}

final class _RecordingSoundEffects implements TetrisSoundEffects {
  final played = <({TetrisSfx sfx, double volume})>[];
  var disposed = false;

  List<TetrisSfx> get playedSfx => played.map((event) => event.sfx).toList();

  @override
  void play(TetrisSfx sfx, {double volume = 1.0}) {
    played.add((sfx: sfx, volume: volume));
  }

  @override
  void dispose() {
    disposed = true;
  }
}

final class _RecordingMusicPlayer implements TetrisMusicPlayer {
  final playedAssets = <String>[];
  final volumes = <double>[];
  final _completeController = StreamController<void>.broadcast();
  var pauseCount = 0;
  var resumeCount = 0;
  var stopCount = 0;
  var disposed = false;

  @override
  Stream<void> get onTrackComplete => _completeController.stream;

  void completeTrack() {
    _completeController.add(null);
  }

  @override
  Future<void> playAsset(String assetPath) async {
    playedAssets.add(assetPath);
  }

  @override
  Future<void> resume() async {
    resumeCount += 1;
  }

  @override
  Future<void> pause() async {
    pauseCount += 1;
  }

  @override
  Future<void> stop() async {
    stopCount += 1;
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _completeController.close();
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('all sound effect assets are loadable', (tester) async {
    expect(AssetTetrisSoundEffects().assetPrefix, isEmpty);
    for (final sfx in TetrisSfx.values) {
      expect(File(sfx.assetPath).existsSync(), isTrue, reason: sfx.assetPath);
      final bytes = await rootBundle.load(sfx.assetPath);
      expect(bytes.lengthInBytes, greaterThan(0), reason: sfx.assetPath);
    }
  });

  testWidgets('all music playlist assets are loadable', (tester) async {
    for (final assetPath in tetrisMusicPlaylist) {
      final bytes = await rootBundle.load(assetPath);
      expect(bytes.lengthInBytes, greaterThan(0), reason: assetPath);
    }
  });

  testWidgets('renders the playable Tetris surface', (tester) async {
    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pump();

    expect(find.text('TETRIS'), findsOneWidget);
    expect(find.text('HOLD'), findsOneWidget);
    expect(find.text('NEXT'), findsOneWidget);
    expect(find.text('SCORE'), findsWidgets);
    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.byTooltip('Restart'), findsOneWidget);
  });

  testWidgets('renders without overflow on a phone viewport', (tester) async {
    _usePhoneViewport(tester);

    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    final topBar = find.byKey(const ValueKey('compact-top-bar'));
    final boardRect = tester.getRect(board);
    final topBarRect = tester.getRect(topBar);
    final pauseRect = tester.getRect(find.byTooltip('Pause'));

    expect(find.text('HOLD'), findsOneWidget);
    expect(find.text('NEXT'), findsOneWidget);
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.byTooltip('Mute'), findsNothing);
    expect(find.byTooltip('Rotate clockwise'), findsNothing);
    expect(find.byTooltip('Rotate counter-clockwise'), findsNothing);
    expect(find.byTooltip('Hard drop'), findsNothing);
    expect(find.byTooltip('Hold'), findsNothing);
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(boardRect.left, 0);
    expect(boardRect.right, 390);
    expect(boardRect.top, greaterThanOrEqualTo(0));
    expect(boardRect.bottom, lessThanOrEqualTo(844));
    expect(topBarRect.bottom, lessThanOrEqualTo(boardRect.top));
    expect(pauseRect.bottom, lessThanOrEqualTo(boardRect.top));

    await tester.drag(board, const Offset(0, -160));
    await tester.pump();

    expect(tester.getRect(board), boardRect);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new game starts from zero without locked board cells', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    final game = TetrisGame(
      scriptedPieces: const [Tetromino.z, Tetromino.l, Tetromino.o],
    );

    await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
    await tester.pump();

    _expectFreshZeroGame(game);

    await tester.pump(_staleFrameGap);

    _expectFreshZeroGame(game);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/new_game_start_zero.png'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('restart does not apply accumulated ticker time', (tester) async {
    _usePhoneViewport(tester);

    final game = TetrisGame(
      scriptedPieces: const [Tetromino.z, Tetromino.l, Tetromino.o],
    );

    await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
    await tester.pump();

    game.hardDrop();
    await tester.pump();

    expect(_visibleLockedCellCount(game), greaterThan(0));

    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    await tester.tap(find.byTooltip('Restart'));
    await tester.pump(_staleFrameGap);

    _expectFreshZeroGame(game);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plays movement and rotation sound effects', (tester) async {
    _usePhoneViewport(tester);
    final game = _visiblePieceGame(Tetromino.t);
    final soundEffects = _RecordingSoundEffects();

    await tester.pumpWidget(
      TetrisApp(enableAudio: false, game: game, soundEffects: soundEffects),
    );
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    final gesture = await tester.startGesture(tester.getCenter(board));
    await gesture.moveBy(_committingSnapDrag);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    await tester.tapAt(tester.getCenter(board) + const Offset(60, 0));
    await tester.pump();
    await tester.tapAt(tester.getCenter(board) - const Offset(60, 0));
    await tester.pump();

    expect(soundEffects.playedSfx, contains(TetrisSfx.slide));
    expect(soundEffects.playedSfx, contains(TetrisSfx.rotate));
    expect(soundEffects.playedSfx, contains(TetrisSfx.counterRotate));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pause menu controls default and changed sound volumes', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    final game = _visiblePieceGame(Tetromino.t);
    final soundEffects = _RecordingSoundEffects();

    await tester.pumpWidget(
      TetrisApp(enableAudio: false, game: game, soundEffects: soundEffects),
    );
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    final gesture = await tester.startGesture(tester.getCenter(board));
    await gesture.moveBy(_committingSnapDrag);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final defaultSlide = soundEffects.played.lastWhere(
      (event) => event.sfx == TetrisSfx.slide,
    );
    expect(defaultSlide.volume, 2.0);

    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();

    final musicSliderFinder = find.byKey(const ValueKey('music-volume-slider'));
    final sfxSliderFinder = find.byKey(const ValueKey('sfx-volume-slider'));
    expect(musicSliderFinder, findsOneWidget);
    expect(sfxSliderFinder, findsOneWidget);
    expect(find.byTooltip('Mute'), findsNothing);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/pause_menu_volume_settings.png'),
    );

    final musicSlider = tester.widget<Slider>(musicSliderFinder);
    expect(musicSlider.value, 0.3);
    expect(musicSlider.max, 1);
    musicSlider.onChanged!(0.2);
    await tester.pump();
    expect(tester.widget<Slider>(musicSliderFinder).value, 0.2);

    final sfxSlider = tester.widget<Slider>(sfxSliderFinder);
    expect(sfxSlider.value, 2.0);
    expect(sfxSlider.max, 2.0);
    sfxSlider.onChanged!(1.25);
    await tester.pump();
    expect(tester.widget<Slider>(sfxSliderFinder).value, 1.25);

    await tester.tap(find.byTooltip('Resume').last);
    await tester.pump();

    await tester.tapAt(tester.getCenter(board) + const Offset(60, 0));
    await tester.pump();

    final changedRotate = soundEffects.played.lastWhere(
      (event) => event.sfx == TetrisSfx.rotate,
    );
    expect(changedRotate.volume, 1.25);
    expect(tester.takeException(), isNull);
  });

  testWidgets('persists changed pause menu volumes across app restart', (
    tester,
  ) async {
    _usePhoneViewport(tester);

    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await _flushPreferenceTasks(tester);

    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();

    final musicSliderFinder = find.byKey(const ValueKey('music-volume-slider'));
    final sfxSliderFinder = find.byKey(const ValueKey('sfx-volume-slider'));
    tester.widget<Slider>(musicSliderFinder).onChanged!(0.2);
    tester.widget<Slider>(sfxSliderFinder).onChanged!(1.25);
    await _flushPreferenceTasks(tester);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await _flushPreferenceTasks(tester);

    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();

    expect(tester.widget<Slider>(musicSliderFinder).value, 0.2);
    expect(tester.widget<Slider>(sfxSliderFinder).value, 1.25);
    expect(tester.takeException(), isNull);
  });

  testWidgets('music playlist advances in order and wraps to the first track', (
    tester,
  ) async {
    final musicPlayer = _RecordingMusicPlayer();
    addTearDown(musicPlayer.dispose);

    await tester.pumpWidget(
      TetrisApp(enableAudio: true, musicPlayer: musicPlayer),
    );
    await _flushPreferenceTasks(tester);

    expect(musicPlayer.playedAssets, [tetrisMusicPlaylist[0]]);

    musicPlayer.completeTrack();
    await _flushPreferenceTasks(tester);
    expect(musicPlayer.playedAssets, [
      tetrisMusicPlaylist[0],
      tetrisMusicPlaylist[1],
    ]);

    musicPlayer.completeTrack();
    await _flushPreferenceTasks(tester);
    expect(musicPlayer.playedAssets, [
      tetrisMusicPlaylist[0],
      tetrisMusicPlaylist[1],
      tetrisMusicPlaylist[2],
    ]);

    musicPlayer.completeTrack();
    await _flushPreferenceTasks(tester);
    expect(musicPlayer.playedAssets, [
      tetrisMusicPlaylist[0],
      tetrisMusicPlaylist[1],
      tetrisMusicPlaylist[2],
      tetrisMusicPlaylist[0],
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('restart starts the music playlist from the first track', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    final musicPlayer = _RecordingMusicPlayer();
    addTearDown(musicPlayer.dispose);

    await tester.pumpWidget(
      TetrisApp(enableAudio: true, musicPlayer: musicPlayer),
    );
    await _flushPreferenceTasks(tester);

    musicPlayer.completeTrack();
    await _flushPreferenceTasks(tester);
    expect(musicPlayer.playedAssets.last, tetrisMusicPlaylist[1]);

    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    await tester.tap(find.byTooltip('Restart'));
    await _flushPreferenceTasks(tester);

    expect(musicPlayer.stopCount, 1);
    expect(musicPlayer.playedAssets.last, tetrisMusicPlaylist[0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plays soft drop sound while long pressing', (tester) async {
    _usePhoneViewport(tester);
    final game = _visiblePieceGame(Tetromino.t);
    final soundEffects = _RecordingSoundEffects();

    await tester.pumpWidget(
      TetrisApp(enableAudio: false, game: game, soundEffects: soundEffects),
    );
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    final gesture = await tester.startGesture(tester.getCenter(board));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pump();

    expect(soundEffects.playedSfx, contains(TetrisSfx.softDrop));
    expect(tester.takeException(), isNull);
  });

  testWidgets('plays hard drop and line clear sounds', (tester) async {
    _usePhoneViewport(tester);
    final game = TetrisGame(scriptedPieces: [Tetromino.i, Tetromino.o]);
    final bottom = TetrisGame.visibleRows - 1;
    _fillVisibleRowExcept(game, bottom, {3, 4, 5, 6});
    final soundEffects = _RecordingSoundEffects();

    await tester.pumpWidget(
      TetrisApp(enableAudio: false, game: game, soundEffects: soundEffects),
    );
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    await tester.drag(board, const Offset(0, 96));
    await tester.pump();

    expect(
      soundEffects.playedSfx,
      containsAll([TetrisSfx.hardDrop, TetrisSfx.clear]),
    );
    expect(soundEffects.playedSfx, isNot(contains(TetrisSfx.hardLock)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('plays tetris and level up sounds', (tester) async {
    _usePhoneViewport(tester);
    final game = TetrisGame(scriptedPieces: [Tetromino.i, Tetromino.o]);
    game.lines = 9;
    game.active = game.active!.copyWith(rotation: 1);
    for (
      var row = TetrisGame.visibleRows - 4;
      row < TetrisGame.visibleRows;
      row += 1
    ) {
      _fillVisibleRowExcept(game, row, {5});
    }
    final soundEffects = _RecordingSoundEffects();

    await tester.pumpWidget(
      TetrisApp(enableAudio: false, game: game, soundEffects: soundEffects),
    );
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    await tester.drag(board, const Offset(0, 96));
    await tester.pump();

    expect(
      soundEffects.playedSfx,
      containsAll([TetrisSfx.hardDrop, TetrisSfx.tetris, TetrisSfx.levelUp]),
    );
    expect(soundEffects.playedSfx, isNot(contains(TetrisSfx.clear)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('plays hard lock sound when lock delay expires', (tester) async {
    _usePhoneViewport(tester);
    final game = TetrisGame(scriptedPieces: [Tetromino.o, Tetromino.i]);
    while (game.softDropStep()) {}
    final soundEffects = _RecordingSoundEffects();

    await tester.pumpWidget(
      TetrisApp(enableAudio: false, game: game, soundEffects: soundEffects),
    );
    await tester.pump();

    await tester.pump(TetrisGame.lockDelay ~/ 2);
    await tester.pump(TetrisGame.lockDelay ~/ 2);

    expect(soundEffects.playedSfx, contains(TetrisSfx.hardLock));
    expect(soundEffects.playedSfx, isNot(contains(TetrisSfx.hardDrop)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal drag previews block snap without moving column', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    final game = _visiblePieceGame(Tetromino.t);
    final startX = game.active!.x;

    await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    final gesture = await tester.startGesture(tester.getCenter(board));
    await gesture.moveBy(_partialSnapDrag);
    await tester.pump();

    final cellWidth = _phoneViewport.width / TetrisGame.width;
    expect(game.active!.x, startX);
    expect(
      _boardActiveHorizontalOffset(tester),
      closeTo(_previewOffsetForDrag(_partialSnapDrag.dx, cellWidth), 0.01),
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/block_snap_partial_drag.png'),
    );

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));

    expect(game.active!.x, startX);
    expect(_boardActiveHorizontalOffset(tester), 0);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/block_snap_after_release.png'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal drag snaps to the next column after enough pull', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    final game = _visiblePieceGame(Tetromino.t);
    final startX = game.active!.x;

    await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    final gesture = await tester.startGesture(tester.getCenter(board));
    await gesture.moveBy(_committingSnapDrag);
    await tester.pump();

    final cellWidth = _phoneViewport.width / TetrisGame.width;
    final residualOffset = _previewOffsetForDrag(
      _committingSnapDrag.dx - cellWidth * _snapCommitFraction,
      cellWidth,
    );

    expect(game.active!.x, startX + 1);
    expect(
      _boardActiveHorizontalOffset(tester),
      closeTo(residualOffset + _snapPreviewFraction - 1, 0.01),
    );

    await tester.pump(const Duration(milliseconds: 16));

    final midAnimationOffset = _boardActiveHorizontalOffset(tester);
    expect(midAnimationOffset, greaterThan(_snapPreviewFraction - 1));
    expect(midAnimationOffset, lessThan(residualOffset));

    await tester.pump(_snapCommitDuration);

    expect(_boardActiveHorizontalOffset(tester), closeTo(residualOffset, 0.01));

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));

    expect(game.active!.x, startX + 1);
    expect(_boardActiveHorizontalOffset(tester), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal snap animation tracks drag without restarting', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    final game = _visiblePieceGame(Tetromino.t);

    await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    final gesture = await tester.startGesture(tester.getCenter(board));
    await gesture.moveBy(_committingSnapDrag);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(_boardActiveHorizontalOffset(tester), lessThan(0));

    final cellWidth = _phoneViewport.width / TetrisGame.width;
    final targetOffset = _previewOffsetForDrag(
      _committingSnapDrag.dx + 2 - cellWidth * _snapCommitFraction,
      cellWidth,
    );

    await gesture.moveBy(const Offset(2, 0));
    await tester.pump();

    expect(_boardActiveHorizontalOffset(tester), lessThan(targetOffset));

    await tester.pump(_snapCommitDuration);

    expect(_boardActiveHorizontalOffset(tester), closeTo(targetOffset, 0.01));

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));

    expect(_boardActiveHorizontalOffset(tester), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'horizontal drag can snap across multiple columns before release',
    (tester) async {
      _usePhoneViewport(tester);
      final game = _visiblePieceGame(Tetromino.t);
      final startX = game.active!.x;

      await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
      await tester.pump();

      final board = find.byKey(const ValueKey('tetris-board'));
      final gesture = await tester.startGesture(tester.getCenter(board));
      await gesture.moveBy(_committingSnapDrag);
      await tester.pump();
      await gesture.moveBy(_committingSnapDrag);
      await tester.pump();

      expect(game.active!.x, startX + 2);
      expect(_boardActiveHorizontalOffset(tester), lessThan(0));

      await tester.pump(_snapCommitDuration);

      expect(_boardActiveHorizontalOffset(tester), greaterThan(0));

      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));

      expect(game.active!.x, startX + 2);
      expect(_boardActiveHorizontalOffset(tester), 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('horizontal drag resists blocked wall snaps', (tester) async {
    _usePhoneViewport(tester);
    final game = _visiblePieceGame(Tetromino.t);
    while (game.moveLeft()) {}
    final wallX = game.active!.x;

    await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    final gesture = await tester.startGesture(tester.getCenter(board));
    await gesture.moveBy(-_committingSnapDrag);
    await tester.pump();

    expect(game.active!.x, wallX);
    expect(
      _boardActiveHorizontalOffset(tester),
      closeTo(-_snapBlockedFraction, 0.01),
    );

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));

    expect(game.active!.x, wallX);
    expect(_boardActiveHorizontalOffset(tester), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'horizontal drag responds immediately after reversing at a wall',
    (tester) async {
      _usePhoneViewport(tester);
      final game = _visiblePieceGame(Tetromino.t);
      while (game.moveRight()) {}
      final wallX = game.active!.x;

      await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
      await tester.pump();

      final board = find.byKey(const ValueKey('tetris-board'));
      final gesture = await tester.startGesture(tester.getCenter(board));
      await gesture.moveBy(_largeWallDrag);
      await tester.pump();

      expect(game.active!.x, wallX);
      expect(
        _boardActiveHorizontalOffset(tester),
        closeTo(_snapBlockedFraction, 0.01),
      );

      await gesture.moveBy(-_committingSnapDrag);
      await tester.pump();

      expect(game.active!.x, lessThan(wallX));
      expect(
        _boardActiveHorizontalOffset(tester),
        closeTo(1 - _snapPreviewFraction, 0.1),
      );

      await tester.pump(_snapCommitDuration);

      expect(_boardActiveHorizontalOffset(tester), lessThanOrEqualTo(0));

      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));

      expect(_boardActiveHorizontalOffset(tester), 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('large horizontal drag commits without visual backlog', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    final game = _visiblePieceGame(Tetromino.t);
    final startX = game.active!.x;

    await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    final gesture = await tester.startGesture(tester.getCenter(board));
    await gesture.moveBy(const Offset(180, 0));
    await tester.pump();

    expect(game.active!.x, greaterThan(startX + 1));
    expect(_boardActiveHorizontalOffset(tester), greaterThan(-0.8));
    expect(_boardActiveHorizontalOffset(tester), lessThan(0.3));

    await tester.pump(_snapCommitDuration);

    expect(_boardActiveHorizontalOffset(tester).abs(), lessThanOrEqualTo(0.25));

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));

    expect(game.active!.x, greaterThan(startX + 1));
    expect(_boardActiveHorizontalOffset(tester), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'large horizontal drag plays one slide sound for the move event',
    (tester) async {
      _usePhoneViewport(tester);
      final game = _visiblePieceGame(Tetromino.t);
      final soundEffects = _RecordingSoundEffects();

      await tester.pumpWidget(
        TetrisApp(enableAudio: false, game: game, soundEffects: soundEffects),
      );
      await tester.pump();

      final board = find.byKey(const ValueKey('tetris-board'));
      final gesture = await tester.startGesture(tester.getCenter(board));
      await gesture.moveBy(const Offset(180, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      final slideCount = soundEffects.playedSfx
          .where((sfx) => sfx == TetrisSfx.slide)
          .length;
      expect(game.active!.x, greaterThan(4));
      expect(slideCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('horizontal drag lock prevents hard drop after dragging down', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    final game = _visiblePieceGame(Tetromino.t);
    final startX = game.active!.x;

    await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    final gesture = await tester.startGesture(tester.getCenter(board));
    await gesture.moveBy(_committingSnapDrag);
    await tester.pump();
    await gesture.moveBy(const Offset(0, 96));
    await tester.pump();

    expect(game.active!.x, startX + 1);
    expect(_visibleLockedCellCount(game), 0);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));

    expect(game.active, isNotNull);
    expect(game.active!.x, startX + 1);
    expect(_visibleLockedCellCount(game), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal drag lock prevents hold after dragging up', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    final game = _visiblePieceGame(Tetromino.t);
    final startX = game.active!.x;
    final activeType = game.active!.type;

    await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    final gesture = await tester.startGesture(tester.getCenter(board));
    await gesture.moveBy(_committingSnapDrag);
    await tester.pump();
    await gesture.moveBy(const Offset(0, -96));
    await tester.pump();

    expect(game.active!.x, startX + 1);
    expect(game.holdPiece, isNull);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));

    expect(game.holdPiece, isNull);
    expect(game.active!.type, activeType);
    expect(game.active!.x, startX + 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal intent prevents hard drop before column snap', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    final game = _visiblePieceGame(Tetromino.t);
    final startX = game.active!.x;

    await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    final gesture = await tester.startGesture(tester.getCenter(board));
    await gesture.moveBy(_partialSnapDrag);
    await tester.pump();

    expect(game.active!.x, startX);
    expect(_boardActiveHorizontalOffset(tester), greaterThan(0));

    await gesture.moveBy(const Offset(0, 96));
    await tester.pump();

    expect(_visibleLockedCellCount(game), 0);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));

    expect(game.active, isNotNull);
    expect(game.active!.x, startX);
    expect(_visibleLockedCellCount(game), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal intent prevents hold before column snap', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    final game = _visiblePieceGame(Tetromino.t);
    final startX = game.active!.x;
    final activeType = game.active!.type;

    await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    final gesture = await tester.startGesture(tester.getCenter(board));
    await gesture.moveBy(_partialSnapDrag);
    await tester.pump();

    expect(game.active!.x, startX);
    expect(_boardActiveHorizontalOffset(tester), greaterThan(0));

    await gesture.moveBy(const Offset(0, -96));
    await tester.pump();

    expect(game.holdPiece, isNull);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));

    expect(game.holdPiece, isNull);
    expect(game.active!.type, activeType);
    expect(game.active!.x, startX);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'partial diagonal down drag locks horizontal before column snap',
    (tester) async {
      _usePhoneViewport(tester);
      final game = _visiblePieceGame(Tetromino.t);
      final startX = game.active!.x;

      await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
      await tester.pump();

      final board = find.byKey(const ValueKey('tetris-board'));
      final gesture = await tester.startGesture(tester.getCenter(board));
      await gesture.moveBy(_partialDiagonalDownDrag);
      await tester.pump();

      expect(game.active!.x, startX);
      expect(_visibleLockedCellCount(game), 0);
      expect(_boardActiveHorizontalOffset(tester), greaterThan(0));

      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));

      expect(game.active, isNotNull);
      expect(game.active!.x, startX);
      expect(_visibleLockedCellCount(game), 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('diagonal down drag locks horizontal during the same move', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    final game = _visiblePieceGame(Tetromino.t);
    final startX = game.active!.x;

    await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    final gesture = await tester.startGesture(tester.getCenter(board));
    await gesture.moveBy(_committingDiagonalDownDrag);
    await tester.pump();

    expect(game.active!.x, startX + 1);
    expect(_visibleLockedCellCount(game), 0);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));

    expect(game.active, isNotNull);
    expect(game.active!.x, startX + 1);
    expect(_visibleLockedCellCount(game), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('diagonal up drag locks horizontal during the same move', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    final game = _visiblePieceGame(Tetromino.t);
    final startX = game.active!.x;
    final activeType = game.active!.type;

    await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    final gesture = await tester.startGesture(tester.getCenter(board));
    await gesture.moveBy(_committingDiagonalUpDrag);
    await tester.pump();

    expect(game.active!.x, startX + 1);
    expect(game.holdPiece, isNull);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));

    expect(game.holdPiece, isNull);
    expect(game.active!.type, activeType);
    expect(game.active!.x, startX + 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'vertical swipe still hard drops while horizontal snap is active',
    (tester) async {
      _usePhoneViewport(tester);
      final game = _visiblePieceGame(Tetromino.t);

      await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
      await tester.pump();

      final board = find.byKey(const ValueKey('tetris-board'));
      await tester.drag(board, const Offset(0, 96));
      await tester.pump();

      expect(_visibleLockedCellCount(game), greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('vertical swipe with small horizontal drift still hard drops', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    final game = _visiblePieceGame(Tetromino.t);

    await tester.pumpWidget(TetrisApp(enableAudio: false, game: game));
    await tester.pump();

    final board = find.byKey(const ValueKey('tetris-board'));
    final gesture = await tester.startGesture(tester.getCenter(board));
    await gesture.moveBy(const Offset(10, 96));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(_visibleLockedCellCount(game), greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../game/tetris_game.dart';
import '../game/tetromino.dart';

const _boardBack = Color(0xFF07080A);
const _background = _boardBack;
const _panel = Color(0xFF1B1D22);
const _text = Color(0xFFF3F6FA);
const _mutedText = Color(0xFFA5ADBA);
const _gridLine = Color(0x12FFFFFF);
const _bufferSliverRows = 0.25;
const _compactTopBarHeight = 54.0;
const _maxTickDelta = Duration(milliseconds: 250);
const _snapBackDuration = Duration(milliseconds: 120);
const _snapCommitDuration = Duration(milliseconds: 64);
const _lineClearAnimationDuration = Duration(milliseconds: 520);
const _lineClearDropDelay = Duration(milliseconds: 24);
const _boardImpactDuration = Duration(milliseconds: 1200);
const _boardImpactDownCells = 0.36;
const _boardSideImpactCells = 0.18;
const _lineClearSnapShaderAsset = 'shaders/line_clear_snap.glsl';
const _lineClearSnapTextureCellSize = 32.0;
const _lineClearSnapParticleLifetime = 0.72;
const _lineClearSnapFadeDuration = 0.42;
const _lineClearSnapParticleSpeed = 0.26;
const _lineClearSnapParticlesInRow = TetrisGame.width * 5;
const _lineClearSnapParticlesInColumn = TetrisGame.visibleRows * 5;
const _lineClearSnapWarmUpSize = Size(320, 640);
const _horizontalIntentFraction = 0.35;
const _minHorizontalIntentDistance = 20.0;
const _snapPreviewFraction = 0.25;
const _snapCommitFraction = 0.7;
const _snapBlockedFraction = 0.22;
const _defaultMusicVolume = 0.3;
const _defaultSfxVolume = 2.0;
const _maxSfxVolume = 2.0;
const _musicVolumePreferenceKey = 'tetris.musicVolume';
const _sfxVolumePreferenceKey = 'tetris.sfxVolume';
const _boardAspectRatio =
    TetrisGame.width / (TetrisGame.visibleRows + _bufferSliverRows);

@visibleForTesting
const tetrisMusicPlaylist = <String>[
  'assets/audio/korobeiniki.m4a',
  'assets/audio/music2.m4a',
  'assets/audio/music3.m4a',
];

enum TetrisSfx {
  slide('sfx/slide.mp3'),
  rotate('sfx/rotate.mp3'),
  counterRotate('sfx/counter_rotate.mp3'),
  softDrop('sfx/soft_drop.mp3'),
  hardDrop('sfx/hard_drop.mp3'),
  hardLock('sfx/hard_lock.mp3'),
  clear('sfx/clear.mp3'),
  tetris('sfx/tetris.mp3'),
  levelUp('sfx/level_up.mp3');

  const TetrisSfx(this.assetPath);

  final String assetPath;
}

enum TetrisHaptic { move, softDrop, rotate, hardDrop }

abstract interface class TetrisMusicPlayer {
  Stream<void> get onTrackComplete;

  Future<void> playAsset(String assetPath);

  Future<void> resume();

  Future<void> pause();

  Future<void> stop();

  Future<void> setVolume(double volume);

  Future<void> dispose();
}

final class AssetTetrisMusicPlayer implements TetrisMusicPlayer {
  AssetTetrisMusicPlayer({AudioPlayer? player})
    : _player = player ?? AudioPlayer() {
    _player.audioCache = AudioCache(prefix: '');
  }

  final AudioPlayer _player;

  @override
  Stream<void> get onTrackComplete => _player.onPlayerComplete;

  @override
  Future<void> playAsset(String assetPath) async {
    await _player.setReleaseMode(ReleaseMode.stop);
    await _player.play(AssetSource(assetPath));
  }

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> dispose() => _player.dispose();
}

abstract interface class TetrisSoundEffects {
  void play(TetrisSfx sfx, {double volume = 1.0});

  void dispose();
}

final class NoopTetrisSoundEffects implements TetrisSoundEffects {
  const NoopTetrisSoundEffects();

  @override
  void play(TetrisSfx sfx, {double volume = 1.0}) {}

  @override
  void dispose() {}
}

final class AssetTetrisSoundEffects implements TetrisSoundEffects {
  AssetTetrisSoundEffects({AudioCache? audioCache})
    : _audioCache = audioCache ?? AudioCache(prefix: '');

  final AudioCache _audioCache;
  final Map<TetrisSfx, Future<AudioPool>> _pools = {};

  @visibleForTesting
  String get assetPrefix => _audioCache.prefix;

  @override
  void play(TetrisSfx sfx, {double volume = 1.0}) {
    unawaited(_play(sfx, volume));
  }

  Future<void> _play(TetrisSfx sfx, double volume) async {
    final playbackVolume = (volume.clamp(0.0, _maxSfxVolume) / _maxSfxVolume)
        .toDouble();
    if (playbackVolume <= 0) {
      return;
    }

    try {
      final pool = await _poolFor(sfx);
      await pool.start(volume: playbackVolume);
    } catch (_) {}
  }

  Future<AudioPool> _poolFor(TetrisSfx sfx) {
    return _pools.putIfAbsent(
      sfx,
      () => AudioPool.createFromAsset(
        path: sfx.assetPath,
        audioCache: _audioCache,
        maxPlayers: 4,
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_dispose());
  }

  Future<void> _dispose() async {
    try {
      final pools = await Future.wait(_pools.values);
      await Future.wait(pools.map((pool) => pool.dispose()));
    } catch (_) {}
  }
}

abstract interface class TetrisHaptics {
  void play(TetrisHaptic haptic);
}

final class PlatformTetrisHaptics implements TetrisHaptics {
  const PlatformTetrisHaptics();

  @override
  void play(TetrisHaptic haptic) {
    unawaited(switch (haptic) {
      TetrisHaptic.move ||
      TetrisHaptic.softDrop => HapticFeedback.selectionClick(),
      TetrisHaptic.rotate => HapticFeedback.mediumImpact(),
      TetrisHaptic.hardDrop => HapticFeedback.heavyImpact(),
    });
  }
}

final class _SoundSnapshot {
  const _SoundSnapshot({
    required this.lockCount,
    required this.lines,
    required this.level,
  });

  factory _SoundSnapshot.fromGame(TetrisGame game) {
    return _SoundSnapshot(
      lockCount: game.lockCount,
      lines: game.lines,
      level: game.level,
    );
  }

  final int lockCount;
  final int lines;
  final int level;
}

class TetrisApp extends StatelessWidget {
  const TetrisApp({
    super.key,
    this.enableAudio = true,
    this.game,
    this.musicPlayer,
    this.soundEffects,
    this.haptics,
  });

  final bool enableAudio;
  final TetrisGame? game;
  final TetrisMusicPlayer? musicPlayer;
  final TetrisSoundEffects? soundEffects;
  final TetrisHaptics? haptics;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tetris',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF44D7FF),
          brightness: Brightness.dark,
        ),
        textTheme: ThemeData.dark().textTheme.apply(
          bodyColor: _text,
          displayColor: _text,
        ),
      ),
      home: TetrisGamePage(
        enableAudio: enableAudio,
        game: game,
        musicPlayer: musicPlayer,
        soundEffects: soundEffects,
        haptics: haptics,
      ),
    );
  }
}

class TetrisGamePage extends StatefulWidget {
  const TetrisGamePage({
    super.key,
    this.enableAudio = true,
    this.game,
    this.musicPlayer,
    this.soundEffects,
    this.haptics,
  });

  final bool enableAudio;
  final TetrisGame? game;
  final TetrisMusicPlayer? musicPlayer;
  final TetrisSoundEffects? soundEffects;
  final TetrisHaptics? haptics;

  @override
  State<TetrisGamePage> createState() => _TetrisGamePageState();
}

class _TetrisGamePageState extends State<TetrisGamePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final TetrisGame _game;
  late final Ticker _ticker;
  late final AnimationController _snapBackController;
  late final AnimationController _lineClearController;
  late final AnimationController _boardImpactController;
  late final TetrisSoundEffects _soundEffects;
  late final TetrisHaptics _haptics;
  late final bool _disposeSoundEffects;
  late final bool _disposeMusicPlayer;
  Future<void>? _volumePreferencesFuture;
  TetrisMusicPlayer? _musicPlayer;
  StreamSubscription<void>? _musicCompleteSubscription;
  Timer? _softDropTimer;

  Duration _lastFrameElapsed = Duration.zero;
  int? _dragPointer;
  double _dragX = 0;
  double _dragY = 0;
  double _snapDragX = 0;
  double _snapPreviewOffsetCells = 0;
  double _snapPulseOffsetCells = 0;
  double _snapVisualOffsetCells = 0;
  Offset _boardImpactOffsetCells = Offset.zero;
  Animation<double> _snapBackAnimation = const AlwaysStoppedAnimation(0);
  Animation<Offset> _boardImpactAnimation = const AlwaysStoppedAnimation(
    Offset.zero,
  );
  bool _horizontalDragLocked = false;
  bool _lineClearAnimating = false;
  bool _musicStarted = false;
  bool _volumePreferencesLoaded = false;
  int _musicTrackIndex = 0;
  int _dragWallImpactMask = 0;
  int _lineClearAnimationSerial = 0;
  double _musicVolume = _defaultMusicVolume;
  double _sfxVolume = _defaultSfxVolume;
  LineClearAnimationSnapshot? _lineClearSnapshot;
  ui.FragmentShader? _lineClearSnapShader;
  ui.Image? _lineClearSnapImage;
  bool _lineClearSnapWarmUpComplete = false;

  bool get _boardAcceptsInput =>
      !_game.paused && !_game.gameOver && !_lineClearAnimating;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _game = widget.game ?? TetrisGame();
    _volumePreferencesFuture = _loadVolumePreferences();
    final soundEffects = widget.soundEffects;
    if (soundEffects != null) {
      _soundEffects = soundEffects;
      _disposeSoundEffects = false;
    } else if (widget.enableAudio) {
      _soundEffects = AssetTetrisSoundEffects();
      _disposeSoundEffects = true;
    } else {
      _soundEffects = const NoopTetrisSoundEffects();
      _disposeSoundEffects = false;
    }
    _haptics = widget.haptics ?? const PlatformTetrisHaptics();
    _ticker = createTicker(_onFrame)..start();
    _snapBackController =
        AnimationController(vsync: this, duration: _snapBackDuration)
          ..addListener(() {
            if (mounted) {
              setState(() {
                _snapPulseOffsetCells = _snapBackAnimation.value;
                _updateSnapVisualOffset();
              });
            }
          });
    _lineClearController =
        AnimationController(vsync: this, duration: _lineClearAnimationDuration)
          ..addListener(() {
            if (mounted && _lineClearAnimating) {
              setState(() {});
            }
          });
    _boardImpactController =
        AnimationController(vsync: this, duration: _boardImpactDuration)
          ..addListener(() {
            if (mounted) {
              setState(() {
                _boardImpactOffsetCells = _boardImpactAnimation.value;
              });
            }
          });
    if (widget.enableAudio) {
      _musicPlayer = widget.musicPlayer ?? AssetTetrisMusicPlayer();
      _disposeMusicPlayer = widget.musicPlayer == null;
      _musicCompleteSubscription = _musicPlayer!.onTrackComplete.listen((_) {
        if (mounted && !_game.paused && !_game.gameOver) {
          unawaited(_playNextMusicTrack());
        }
      });
      unawaited(_playMusicAfterVolumePreferencesLoad());
    } else {
      _disposeMusicPlayer = false;
    }
    unawaited(_loadLineClearSnapProgram());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _softDropTimer?.cancel();
    _lineClearSnapImage?.dispose();
    _snapBackController.dispose();
    _lineClearController.dispose();
    _boardImpactController.dispose();
    _ticker.dispose();
    unawaited(_musicCompleteSubscription?.cancel() ?? Future.value());
    if (_disposeSoundEffects) {
      _soundEffects.dispose();
    }
    if (_disposeMusicPlayer) {
      unawaited(_musicPlayer?.dispose() ?? Future.value());
    }
    super.dispose();
  }

  Future<void> _loadLineClearSnapProgram() async {
    try {
      final program = await ui.FragmentProgram.fromAsset(
        _lineClearSnapShaderAsset,
      );
      final shader = program.fragmentShader();
      if (!mounted) {
        return;
      }
      setState(() {
        _lineClearSnapShader = shader;
      });
      await _warmUpLineClearSnapShader(shader);
      if (!mounted) {
        return;
      }
      setState(() {
        _lineClearSnapWarmUpComplete = true;
      });
    } catch (_) {
      // Tests and unsupported renderers can run without the shader; the board
      // still holds the pre-clear snapshot until the animation completes.
    }
  }

  Future<void> _warmUpLineClearSnapShader(ui.FragmentShader shader) async {
    await SchedulerBinding.instance.endOfFrame;
    if (!mounted) {
      return;
    }

    final image = await _renderLineClearSnapWarmUpImage();
    try {
      await _renderLineClearSnapShaderFrame(
        shader: shader,
        image: image,
        size: _lineClearSnapWarmUpSize,
        progress: 0.18,
      );
      await _renderLineClearSnapShaderFrame(
        shader: shader,
        image: image,
        size: _lineClearSnapWarmUpSize,
        progress: 0.72,
      );
    } finally {
      image.dispose();
    }
  }

  Future<ui.Image> _renderLineClearSnapWarmUpImage() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & _lineClearSnapWarmUpSize);
    const cellSize = _lineClearSnapTextureCellSize;
    final bottom = TetrisGame.visibleRows - 1;
    for (var x = 0; x < TetrisGame.width; x += 1) {
      _drawMino(
        canvas,
        Offset.zero,
        cellSize,
        x,
        bottom,
        Tetromino.values[x % Tetromino.values.length],
      );
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(
      _lineClearSnapWarmUpSize.width.ceil(),
      _lineClearSnapWarmUpSize.height.ceil(),
    );
    picture.dispose();
    return image;
  }

  Future<void> _renderLineClearSnapShaderFrame({
    required ui.FragmentShader shader,
    required ui.Image image,
    required Size size,
    required double progress,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & size);
    _configureLineClearSnapShader(
      shader: shader,
      progress: progress,
      image: image,
      size: size,
    );
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    final picture = recorder.endRecording();
    final rendered = await picture.toImage(
      size.width.ceil(),
      size.height.ceil(),
    );
    rendered.dispose();
    picture.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_musicVolume > 0 && !_game.paused && !_game.gameOver) {
        unawaited(_playMusic());
      }
    } else {
      unawaited(_musicPlayer?.pause() ?? Future.value());
    }
  }

  void _onFrame(Duration elapsed) {
    final delta = elapsed - _lastFrameElapsed;
    _lastFrameElapsed = elapsed;
    if (delta <= Duration.zero ||
        delta > _maxTickDelta ||
        _game.paused ||
        _game.gameOver ||
        _lineClearAnimating) {
      return;
    }

    final before = _SoundSnapshot.fromGame(_game);
    _game.tick(delta);
    final lineClearSnapshot = _lineClearSnapshotAfter(before);
    _playPostActionSfx(before);
    if (mounted) {
      if (lineClearSnapshot != null) {
        _startLineClearAnimation(lineClearSnapshot);
      } else {
        setState(() {});
      }
    }
  }

  Future<void> _loadVolumePreferences() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final musicVolume = preferences.getDouble(_musicVolumePreferenceKey);
      final sfxVolume = preferences.getDouble(_sfxVolumePreferenceKey);
      if (!mounted) {
        return;
      }

      setState(() {
        if (musicVolume != null) {
          _musicVolume = musicVolume.clamp(0.0, 1.0).toDouble();
        }
        if (sfxVolume != null) {
          _sfxVolume = sfxVolume.clamp(0.0, _maxSfxVolume).toDouble();
        }
        _volumePreferencesLoaded = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _volumePreferencesLoaded = true;
        });
      }
    }
  }

  Future<void> _playMusicAfterVolumePreferencesLoad() async {
    final loading = _volumePreferencesFuture;
    if (!_volumePreferencesLoaded && loading != null) {
      await loading;
    }
    if (mounted) {
      await _playMusic();
    }
  }

  Future<void> _playMusic() async {
    final loading = _volumePreferencesFuture;
    if (!_volumePreferencesLoaded && loading != null) {
      await loading;
      if (!mounted) {
        return;
      }
    }

    if (!widget.enableAudio || _musicVolume <= 0) {
      return;
    }

    final player = _musicPlayer;
    if (player == null) {
      return;
    }

    try {
      await player.setVolume(_musicVolume);
      if (_musicStarted) {
        await player.resume();
      } else {
        await player.playAsset(tetrisMusicPlaylist[_musicTrackIndex]);
        _musicStarted = true;
      }
    } catch (_) {
      // Web and mobile platforms can block audio until a user gesture.
    }
  }

  Future<void> _playNextMusicTrack() async {
    _musicTrackIndex = (_musicTrackIndex + 1) % tetrisMusicPlaylist.length;
    _musicStarted = false;
    await _playMusic();
  }

  Future<void> _restartMusicPlaylist() async {
    _musicTrackIndex = 0;
    _musicStarted = false;
    try {
      await _musicPlayer?.stop();
    } catch (_) {}
    await _playMusic();
  }

  void _runAction(VoidCallback action) {
    if (!_boardAcceptsInput) {
      return;
    }
    unawaited(_playMusic());
    setState(action);
  }

  T _runGameAction<T>(
    T Function() action, {
    TetrisSfx? successSfx,
    TetrisHaptic? successHaptic,
    bool Function(T result, _SoundSnapshot before)? didSucceed,
    bool suppressLockSfx = false,
  }) {
    unawaited(_playMusic());
    final before = _SoundSnapshot.fromGame(_game);
    late final T result;
    setState(() {
      result = action();
    });

    final lineClearSnapshot = _lineClearSnapshotAfter(before);
    final succeeded = didSucceed?.call(result, before) ?? true;
    if (succeeded && successSfx != null) {
      _playSfx(successSfx);
    }
    if (succeeded && successHaptic != null) {
      _playHaptic(successHaptic);
    }
    _playPostActionSfx(before, suppressLockSfx: suppressLockSfx);
    if (lineClearSnapshot != null) {
      _startLineClearAnimation(lineClearSnapshot);
    }
    return result;
  }

  LineClearAnimationSnapshot? _lineClearSnapshotAfter(_SoundSnapshot before) {
    if (_game.lines <= before.lines) {
      return null;
    }
    return _game.lastLineClearSnapshot;
  }

  void _startLineClearAnimation(LineClearAnimationSnapshot snapshot) {
    _lineClearController.stop();
    final serial = _lineClearAnimationSerial + 1;
    _lineClearAnimationSerial = serial;
    _setLineClearSnapImage(null);
    setState(() {
      _lineClearSnapshot = snapshot;
      _lineClearAnimating = true;
    });
    unawaited(_prepareLineClearSnapImage(snapshot, serial));
    unawaited(_runLineClearAnimation(serial));
  }

  Future<void> _prepareLineClearSnapImage(
    LineClearAnimationSnapshot snapshot,
    int serial,
  ) async {
    final image = await _renderLineClearSnapImage(snapshot);
    if (!mounted || serial != _lineClearAnimationSerial) {
      image.dispose();
      return;
    }

    setState(() {
      _setLineClearSnapImage(image);
    });
  }

  Future<ui.Image> _renderLineClearSnapImage(
    LineClearAnimationSnapshot snapshot,
  ) async {
    final width = (TetrisGame.width * _lineClearSnapTextureCellSize).ceil();
    final height = (TetrisGame.visibleRows * _lineClearSnapTextureCellSize)
        .ceil();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );

    for (final row in snapshot.rows) {
      final visibleY = row - TetrisGame.bufferRows;
      if (visibleY < 0 || visibleY >= TetrisGame.visibleRows) {
        continue;
      }
      for (var x = 0; x < TetrisGame.width; x += 1) {
        final type = snapshot.board.visibleCellAt(x, visibleY);
        if (type != null) {
          _drawMino(
            canvas,
            Offset.zero,
            _lineClearSnapTextureCellSize,
            x,
            visibleY,
            type,
          );
        }
      }
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    return image;
  }

  void _setLineClearSnapImage(ui.Image? image) {
    final previous = _lineClearSnapImage;
    _lineClearSnapImage = image;
    previous?.dispose();
  }

  Future<void> _runLineClearAnimation(int serial) async {
    try {
      await _lineClearController.forward(from: 0).orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted || serial != _lineClearAnimationSerial) {
      return;
    }

    setState(() {
      _lineClearController.value = 1;
    });
    await Future<void>.delayed(_lineClearDropDelay);
    if (!mounted || serial != _lineClearAnimationSerial) {
      return;
    }

    setState(() {
      _lineClearSnapshot = null;
      _lineClearAnimating = false;
      _setLineClearSnapImage(null);
    });
  }

  void _playPostActionSfx(
    _SoundSnapshot before, {
    bool suppressLockSfx = false,
  }) {
    final locked = _game.lockCount > before.lockCount;
    if (locked && !suppressLockSfx) {
      _playSfx(TetrisSfx.hardLock);
    }

    if (_game.lines > before.lines) {
      _playSfx(_game.lastClear.lines == 4 ? TetrisSfx.tetris : TetrisSfx.clear);
    }

    if (_game.level > before.level) {
      _playSfx(TetrisSfx.levelUp);
    }
  }

  void _playSfx(TetrisSfx sfx) {
    if (_sfxVolume <= 0) {
      return;
    }
    _soundEffects.play(sfx, volume: _sfxVolume);
  }

  void _playHaptic(TetrisHaptic haptic) {
    _haptics.play(haptic);
  }

  void _restart() {
    _lineClearController.stop();
    _boardImpactController.stop();
    _lineClearAnimationSerial += 1;
    _setLineClearSnapImage(null);
    setState(() {
      _lineClearAnimating = false;
      _lineClearSnapshot = null;
      _dragWallImpactMask = 0;
      _boardImpactOffsetCells = Offset.zero;
      _game.restart();
    });
    unawaited(_restartMusicPlaylist());
  }

  void _togglePause() {
    setState(_game.togglePause);
    if (_game.paused) {
      unawaited(_musicPlayer?.pause() ?? Future.value());
    } else {
      unawaited(_playMusic());
    }
  }

  void _setMusicVolume(double volume) {
    final nextVolume = volume.clamp(0.0, 1.0).toDouble();
    setState(() {
      _musicVolume = nextVolume;
    });
    unawaited(_saveVolumePreference(_musicVolumePreferenceKey, nextVolume));
    unawaited(_applyMusicVolume());
  }

  Future<void> _applyMusicVolume() async {
    final player = _musicPlayer;
    if (!widget.enableAudio || player == null) {
      return;
    }

    try {
      await player.setVolume(_musicVolume);
      if (_musicVolume <= 0) {
        await player.pause();
      } else if (!_game.paused && !_game.gameOver) {
        await _playMusic();
      }
    } catch (_) {}
  }

  void _setSfxVolume(double volume) {
    final nextVolume = volume.clamp(0.0, _maxSfxVolume).toDouble();
    setState(() {
      _sfxVolume = nextVolume;
    });
    unawaited(_saveVolumePreference(_sfxVolumePreferenceKey, nextVolume));
  }

  Future<void> _saveVolumePreference(String key, double volume) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setDouble(key, volume);
    } catch (_) {}
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!_boardAcceptsInput) {
      return;
    }
    _dragPointer = event.pointer;
    _snapBackController.stop();
    _dragX = 0;
    _dragY = 0;
    _snapDragX = 0;
    _snapPreviewOffsetCells = 0;
    _snapPulseOffsetCells = 0;
    _snapVisualOffsetCells = 0;
    _dragWallImpactMask = 0;
    _horizontalDragLocked = false;
    unawaited(_playMusic());
  }

  void _startSoftDrop() {
    _softDropTimer?.cancel();
    _softDropStep();
    _softDropTimer = Timer.periodic(const Duration(milliseconds: 45), (_) {
      if (!mounted) {
        return;
      }
      _softDropStep();
    });
  }

  void _stopSoftDrop() {
    _softDropTimer?.cancel();
    _softDropTimer = null;
  }

  void _softDropStep() {
    if (!_boardAcceptsInput) {
      return;
    }
    _runGameAction<bool>(
      _game.softDropStep,
      successSfx: TetrisSfx.softDrop,
      successHaptic: TetrisHaptic.softDrop,
      didSucceed: (moved, _) => moved,
    );
  }

  void _hardDrop() {
    if (!_boardAcceptsInput) {
      return;
    }
    final impactOffset = _hardDropImpactOffset();
    final lockCount = _game.lockCount;
    _stopSoftDrop();
    _snapBackController.stop();
    _resetSnapOffsets();
    _commitHardDrop();
    if (_game.lockCount > lockCount) {
      _startBoardImpact(impactOffset);
    }
  }

  void _commitHardDrop() {
    _runGameAction<int>(
      _game.hardDrop,
      successSfx: TetrisSfx.hardDrop,
      successHaptic: TetrisHaptic.hardDrop,
      didSucceed: (_, before) => _game.lockCount > before.lockCount,
      suppressLockSfx: true,
    );
  }

  Offset _hardDropImpactOffset() {
    return const Offset(0, _boardImpactDownCells);
  }

  void _startBoardImpact(Offset impactOffset) {
    _boardImpactController.stop();
    _boardImpactAnimation =
        TweenSequence<Offset>([
          TweenSequenceItem(
            tween: Tween<Offset>(
              begin: impactOffset,
              end: impactOffset * -0.1,
            ).chain(CurveTween(curve: Curves.easeOutCubic)),
            weight: 44,
          ),
          TweenSequenceItem(
            tween: Tween<Offset>(
              begin: impactOffset * -0.1,
              end: impactOffset * 0.04,
            ).chain(CurveTween(curve: Curves.easeInOutCubic)),
            weight: 24,
          ),
          TweenSequenceItem(
            tween: Tween<Offset>(
              begin: impactOffset * 0.04,
              end: Offset.zero,
            ).chain(CurveTween(curve: Curves.easeOutCubic)),
            weight: 32,
          ),
        ]).animate(
          CurvedAnimation(parent: _boardImpactController, curve: Curves.linear),
        );
    setState(() {
      _boardImpactOffsetCells = impactOffset;
    });
    _boardImpactController.forward(from: 0);
  }

  void _rotateClockwise() {
    if (!_boardAcceptsInput) {
      return;
    }
    _runGameAction<bool>(
      _game.rotateClockwise,
      successSfx: TetrisSfx.rotate,
      successHaptic: TetrisHaptic.rotate,
      didSucceed: (rotated, _) => rotated,
    );
  }

  void _rotateCounterClockwise() {
    if (!_boardAcceptsInput) {
      return;
    }
    _runGameAction<bool>(
      _game.rotateCounterClockwise,
      successSfx: TetrisSfx.counterRotate,
      successHaptic: TetrisHaptic.rotate,
      didSucceed: (rotated, _) => rotated,
    );
  }

  void _handlePointerMove(PointerMoveEvent event, double cellSize) {
    if (_dragPointer != event.pointer) {
      return;
    }

    _dragX += event.delta.dx;
    _dragY += event.delta.dy;
    _snapDragX += event.delta.dx;

    final snapDistance = cellSize * _snapCommitFraction;
    if (snapDistance <= 0) {
      return;
    }

    final horizontalIntentDistance = math.min(
      snapDistance,
      math.max(
        _minHorizontalIntentDistance,
        cellSize * _horizontalIntentFraction,
      ),
    );
    if (!_horizontalDragLocked && _dragX.abs() >= horizontalIntentDistance) {
      _lockHorizontalDrag();
    }

    if (!_horizontalDragLocked && _dragX.abs() < _dragY.abs()) {
      return;
    }

    var committedColumns = 0;
    var pulseDirection = 0;
    var wallImpactDirection = 0;
    setState(() {
      while (_snapDragX.abs() >= snapDistance) {
        final direction = _snapDragX.sign.toInt();
        if (!_canMoveHorizontally(direction)) {
          break;
        }
        _moveHorizontally(direction);
        _snapDragX -= snapDistance * direction;
        committedColumns += direction;
        pulseDirection = direction;
      }

      final direction = _snapDragX.sign.toInt();
      final blocked = direction != 0 && !_canMoveHorizontally(direction);
      if (blocked) {
        _snapPreviewOffsetCells = _snapBlockedFraction * direction;
        _snapDragX = 0;
        if (_canTriggerWallImpact(direction) &&
            !_hasTriggeredWallImpact(direction)) {
          wallImpactDirection = direction;
          _rememberWallImpact(direction);
        }
      } else {
        _snapPreviewOffsetCells = _snapPreviewOffsetForDrag(
          _snapDragX,
          snapDistance,
        );
      }

      if (committedColumns != 0) {
        _snapPulseOffsetCells = (pulseDirection * (_snapPreviewFraction - 1))
            .toDouble();
      }
      _updateSnapVisualOffset();
    });

    if (committedColumns != 0) {
      _playSfx(TetrisSfx.slide);
      _playHaptic(TetrisHaptic.move);
      _animateSnapPulseToZero(_snapCommitDuration);
    }
    if (wallImpactDirection != 0) {
      _startBoardImpact(Offset(wallImpactDirection * _boardSideImpactCells, 0));
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_dragPointer != event.pointer) {
      return;
    }
    _finishDrag();
    _dragPointer = null;
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_dragPointer != event.pointer) {
      return;
    }
    _animateSnapBack();
    _dragX = 0;
    _dragY = 0;
    _snapDragX = 0;
    _dragWallImpactMask = 0;
    _horizontalDragLocked = false;
    _dragPointer = null;
  }

  void _finishDrag() {
    const verticalThreshold = 48.0;
    if (!_horizontalDragLocked &&
        _dragY.abs() >= verticalThreshold &&
        _dragY.abs() > _dragX.abs()) {
      _snapBackController.stop();
      _resetSnapOffsets();
      if (_dragY < 0) {
        _runAction(_game.hold);
      } else {
        _hardDrop();
      }
    } else {
      _animateSnapBack();
    }
    _dragX = 0;
    _dragY = 0;
    _snapDragX = 0;
    _dragWallImpactMask = 0;
    _horizontalDragLocked = false;
  }

  void _moveHorizontally(int direction) {
    if (direction < 0) {
      _game.moveLeft();
    } else {
      _game.moveRight();
    }
  }

  void _lockHorizontalDrag() {
    _horizontalDragLocked = true;
    _stopSoftDrop();
  }

  bool _canMoveHorizontally(int direction) {
    if (direction == 0 ||
        _game.active == null ||
        _game.gameOver ||
        _game.paused) {
      return false;
    }

    for (final cell in _game.activeCells) {
      final targetX = cell.x + direction;
      if (targetX < 0 || targetX >= TetrisGame.width) {
        return false;
      }
      if (_game.cellAt(targetX, cell.y) != null) {
        return false;
      }
    }
    return true;
  }

  bool _canTriggerWallImpact(int direction) {
    if (direction == 0 || _game.hardDropDistance <= 0) {
      return false;
    }

    for (final cell in _game.activeCells) {
      final targetX = cell.x + direction;
      if (targetX < 0 || targetX >= TetrisGame.width) {
        return true;
      }
    }
    return false;
  }

  bool _hasTriggeredWallImpact(int direction) {
    return (_dragWallImpactMask & _wallImpactBit(direction)) != 0;
  }

  void _rememberWallImpact(int direction) {
    _dragWallImpactMask |= _wallImpactBit(direction);
  }

  int _wallImpactBit(int direction) {
    return direction < 0 ? 1 : 2;
  }

  void _animateSnapBack() {
    _snapBackController.stop();
    if (_snapVisualOffsetCells.abs() < 0.001) {
      _resetSnapOffsets();
      return;
    }

    _snapPulseOffsetCells = _snapVisualOffsetCells;
    _snapPreviewOffsetCells = 0;
    _animateSnapPulseToZero(_snapBackDuration);
  }

  void _animateSnapPulseToZero(Duration duration) {
    _snapBackController.stop();
    if (_snapPulseOffsetCells.abs() < 0.001) {
      _snapPulseOffsetCells = 0;
      _updateSnapVisualOffset();
      return;
    }

    _snapBackController.duration = duration;
    _snapBackAnimation = Tween<double>(begin: _snapPulseOffsetCells, end: 0)
        .animate(
          CurvedAnimation(
            parent: _snapBackController,
            curve: Curves.easeOutCubic,
          ),
        );
    _snapBackController.forward(from: 0);
  }

  void _updateSnapVisualOffset() {
    _snapVisualOffsetCells = _snapPreviewOffsetCells + _snapPulseOffsetCells;
  }

  void _resetSnapOffsets() {
    _snapPreviewOffsetCells = 0;
    _snapPulseOffsetCells = 0;
    _snapVisualOffsetCells = 0;
  }

  double _snapPreviewOffsetForDrag(double dragX, double snapDistance) {
    if (snapDistance <= 0) {
      return 0;
    }

    return ((dragX / snapDistance) * _snapPreviewFraction)
        .clamp(-_snapPreviewFraction, _snapPreviewFraction)
        .toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 760;

            if (compact) {
              return _buildCompactLayout(constraints);
            }

            return _buildWideLayout(constraints);
          },
        ),
      ),
    );
  }

  Widget _buildWideLayout(BoxConstraints constraints) {
    final boardHeight = math.min(constraints.maxHeight, 760.0);
    final boardWidth = math.min(
      constraints.maxWidth,
      boardHeight * _boardAspectRatio,
    );
    final resolvedBoardHeight = boardWidth / _boardAspectRatio;
    final cellSize = _cellSizeFor(boardWidth, resolvedBoardHeight);

    return SizedBox.expand(
      child: _buildGestureSurface(
        cellSize: cellSize,
        child: Center(
          child: _buildBoardCanvas(boardWidth, resolvedBoardHeight),
        ),
      ),
    );
  }

  Widget _buildCompactLayout(BoxConstraints constraints) {
    final availableBoardHeight = math.max(
      0.0,
      constraints.maxHeight - _compactTopBarHeight,
    );
    final boardWidth = math.min(
      constraints.maxWidth,
      availableBoardHeight * _boardAspectRatio,
    );
    final boardHeight = boardWidth / _boardAspectRatio;

    return SizedBox.expand(
      child: Column(
        children: [
          SizedBox(
            key: const ValueKey('compact-top-bar'),
            height: _compactTopBarHeight,
            child: _CompactTopBar(
              holdPiece: _game.holdPiece,
              nextPiece: _game.nextQueue.first,
              score: _game.score,
              level: _game.level,
              lines: _game.lines,
              paused: _game.paused,
              onPause: _togglePause,
            ),
          ),
          Expanded(child: Center(child: _buildBoard(boardWidth, boardHeight))),
        ],
      ),
    );
  }

  Widget _buildBoard(double width, double height) {
    return _buildGestureSurface(
      cellSize: _cellSizeFor(width, height),
      child: _buildBoardCanvas(width, height),
    );
  }

  double _cellSizeFor(double width, double height) {
    return math.min(
      width / TetrisGame.width,
      height / (TetrisGame.visibleRows + _bufferSliverRows),
    );
  }

  Widget _buildGestureSurface({
    required double cellSize,
    required Widget child,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _handlePointerDown,
          onPointerMove: (event) => _handlePointerMove(event, cellSize),
          onPointerUp: _handlePointerUp,
          onPointerCancel: _handlePointerCancel,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) {
              if (!_boardAcceptsInput) {
                return;
              }
              if (details.localPosition.dx > constraints.maxWidth / 2) {
                _rotateClockwise();
              } else {
                _rotateCounterClockwise();
              }
            },
            onLongPressStart: (_) {
              if (_boardAcceptsInput && !_horizontalDragLocked) {
                _startSoftDrop();
              }
            },
            onLongPressEnd: (_) => _stopSoftDrop(),
            child: child,
          ),
        );
      },
    );
  }

  Widget _buildBoardCanvas(double width, double height) {
    return SizedBox(
      key: const ValueKey('tetris-board'),
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: CustomPaint(
              painter: _BoardPainter(
                game: _game,
                activeHorizontalOffset: _snapVisualOffsetCells,
                boardImpactOffset: _boardImpactOffsetCells,
                lineClearSnapshot: _lineClearSnapshot,
                lineClearProgress: _lineClearController.value,
                lineClearSnapShader: _lineClearSnapWarmUpComplete
                    ? _lineClearSnapShader
                    : null,
                lineClearSnapImage: _lineClearSnapImage,
              ),
              size: Size.infinite,
            ),
          ),
          if (_game.gameOver || _game.paused)
            _GameOverlay(
              gameOver: _game.gameOver,
              score: _game.score,
              musicVolume: _musicVolume,
              sfxVolume: _sfxVolume,
              onMusicVolumeChanged: _setMusicVolume,
              onSfxVolumeChanged: _setSfxVolume,
              onRestart: _restart,
              onResume: _togglePause,
            ),
        ],
      ),
    );
  }
}

class _CompactTopBar extends StatelessWidget {
  const _CompactTopBar({
    required this.holdPiece,
    required this.nextPiece,
    required this.score,
    required this.level,
    required this.lines,
    required this.paused,
    required this.onPause,
  });

  final Tetromino? holdPiece;
  final Tetromino nextPiece;
  final int score;
  final int level;
  final int lines;
  final bool paused;
  final VoidCallback onPause;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: _panel),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Row(
          children: [
            _TopPieceSlot(title: 'HOLD', piece: holdPiece),
            const SizedBox(width: 8),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _CompactMetric(label: 'SCORE', value: score),
                  ),
                  Expanded(
                    child: _CompactMetric(label: 'LEVEL', value: level),
                  ),
                  Expanded(
                    child: _CompactMetric(label: 'LINES', value: lines),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _TopPieceSlot(title: 'NEXT', piece: nextPiece),
            const SizedBox(width: 8),
            _TopControls(paused: paused, framed: false, onPause: onPause),
          ],
        ),
      ),
    );
  }
}

class _TopPieceSlot extends StatelessWidget {
  const _TopPieceSlot({required this.title, required this.piece});

  final String title;
  final Tetromino? piece;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 42,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              title,
              maxLines: 1,
              style: const TextStyle(
                color: _mutedText,
                fontSize: 9,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 2),
          SizedBox.square(
            dimension: 28,
            child: piece == null
                ? const Center(
                    child: Text('-', style: TextStyle(color: _mutedText)),
                  )
                : CustomPaint(painter: _PiecePreviewPainter(piece!)),
          ),
        ],
      ),
    );
  }
}

class _CompactMetric extends StatelessWidget {
  const _CompactMetric({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            maxLines: 1,
            style: const TextStyle(
              color: _mutedText,
              fontSize: 9,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        Text(
          value.toString(),
          maxLines: 1,
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w900,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _TopControls extends StatelessWidget {
  const _TopControls({
    required this.paused,
    required this.onPause,
    this.framed = true,
  });

  final bool paused;
  final VoidCallback onPause;
  final bool framed;

  @override
  Widget build(BuildContext context) {
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ControlButton(
          tooltip: paused ? 'Resume' : 'Pause',
          icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          size: framed ? 44 : 42,
          onPressed: onPause,
        ),
      ],
    );

    if (!framed) {
      return controls;
    }

    return _Panel(child: controls);
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.size = 44,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: size,
        child: IconButton.filledTonal(
          visualDensity: VisualDensity.compact,
          icon: Icon(icon),
          onPressed: onPressed,
        ),
      ),
    );
  }
}

class _GameOverlay extends StatelessWidget {
  const _GameOverlay({
    required this.gameOver,
    required this.score,
    required this.musicVolume,
    required this.sfxVolume,
    required this.onMusicVolumeChanged,
    required this.onSfxVolumeChanged,
    required this.onRestart,
    required this.onResume,
  });

  final bool gameOver;
  final int score;
  final double musicVolume;
  final double sfxVolume;
  final ValueChanged<double> onMusicVolumeChanged;
  final ValueChanged<double> onSfxVolumeChanged;
  final VoidCallback onRestart;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.62)),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 30,
                offset: Offset(0, 16),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  gameOver ? 'GAME OVER' : 'PAUSED',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                _Metric(label: 'SCORE', value: score.toString()),
                if (!gameOver) ...[
                  const SizedBox(height: 14),
                  SizedBox(
                    width: 250,
                    child: _VolumeControls(
                      musicVolume: musicVolume,
                      sfxVolume: sfxVolume,
                      onMusicVolumeChanged: onMusicVolumeChanged,
                      onSfxVolumeChanged: onSfxVolumeChanged,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!gameOver) ...[
                      _ControlButton(
                        tooltip: 'Resume',
                        icon: Icons.play_arrow_rounded,
                        onPressed: onResume,
                      ),
                      const SizedBox(width: 8),
                    ],
                    _ControlButton(
                      tooltip: 'Restart',
                      icon: Icons.restart_alt_rounded,
                      onPressed: onRestart,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VolumeControls extends StatelessWidget {
  const _VolumeControls({
    required this.musicVolume,
    required this.sfxVolume,
    required this.onMusicVolumeChanged,
    required this.onSfxVolumeChanged,
  });

  final double musicVolume;
  final double sfxVolume;
  final ValueChanged<double> onMusicVolumeChanged;
  final ValueChanged<double> onSfxVolumeChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _VolumeSlider(
          key: const ValueKey('music-volume-row'),
          label: 'MUSIC',
          icon: Icons.music_note_rounded,
          value: musicVolume,
          max: 1,
          sliderKey: const ValueKey('music-volume-slider'),
          onChanged: onMusicVolumeChanged,
        ),
        const SizedBox(height: 10),
        _VolumeSlider(
          key: const ValueKey('sfx-volume-row'),
          label: 'SFX',
          icon: Icons.graphic_eq_rounded,
          value: sfxVolume,
          max: _maxSfxVolume,
          sliderKey: const ValueKey('sfx-volume-slider'),
          onChanged: onSfxVolumeChanged,
        ),
      ],
    );
  }
}

class _VolumeSlider extends StatelessWidget {
  const _VolumeSlider({
    super.key,
    required this.label,
    required this.icon,
    required this.value,
    required this.max,
    required this.sliderKey,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final double value;
  final double max;
  final Key sliderKey;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final percent = (value * 100).round();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: _mutedText),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: _mutedText,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Text(
              '$percent%',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            key: sliderKey,
            value: value,
            min: 0,
            max: max,
            divisions: (max * 20).round(),
            semanticFormatterCallback: (sliderValue) =>
                '${(sliderValue * 100).round()}%',
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Padding(padding: const EdgeInsets.all(12), child: child),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            maxLines: 1,
            softWrap: false,
            style: const TextStyle(
              color: _mutedText,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 3),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _BoardPainter extends CustomPainter {
  const _BoardPainter({
    required this.game,
    required this.activeHorizontalOffset,
    required this.boardImpactOffset,
    required this.lineClearSnapshot,
    required this.lineClearProgress,
    required this.lineClearSnapShader,
    required this.lineClearSnapImage,
  });

  final TetrisGame game;
  final double activeHorizontalOffset;
  final Offset boardImpactOffset;
  final LineClearAnimationSnapshot? lineClearSnapshot;
  final double lineClearProgress;
  final ui.FragmentShader? lineClearSnapShader;
  final ui.Image? lineClearSnapImage;

  @override
  void paint(Canvas canvas, Size size) {
    final cellSize = math.min(
      size.width / TetrisGame.width,
      size.height / (TetrisGame.visibleRows + _bufferSliverRows),
    );
    final boardWidth = cellSize * TetrisGame.width;
    final boardHeight = cellSize * (TetrisGame.visibleRows + _bufferSliverRows);
    final origin = Offset(
      (size.width - boardWidth) / 2,
      (size.height - boardHeight) / 2,
    );
    final visibleOrigin = origin + Offset(0, cellSize * _bufferSliverRows);
    final boardRect = origin & Size(boardWidth, boardHeight);
    final radius = Radius.circular(cellSize * 0.16);
    final impactOffset = Offset(
      boardImpactOffset.dx * cellSize,
      boardImpactOffset.dy * cellSize,
    );

    canvas.save();
    canvas.translate(impactOffset.dx, impactOffset.dy);
    canvas.drawRRect(
      RRect.fromRectAndRadius(boardRect, const Radius.circular(8)),
      Paint()..color = _boardBack,
    );

    final gridPaint = Paint()..color = _gridLine;
    _drawBufferSliver(canvas, origin, visibleOrigin, cellSize, gridPaint);

    for (var y = 0; y < TetrisGame.visibleRows; y += 1) {
      for (var x = 0; x < TetrisGame.width; x += 1) {
        final rect = _cellRect(visibleOrigin, cellSize, x, y).deflate(1);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), gridPaint);
      }
    }

    for (var y = 0; y < TetrisGame.visibleRows; y += 1) {
      for (var x = 0; x < TetrisGame.width; x += 1) {
        final type = _visibleCellAt(x, y);
        if (type != null && !_isLineClearCell(y)) {
          _drawMino(canvas, visibleOrigin, cellSize, x, y, type);
        }
      }
    }
    _drawLineClearSnapEffect(canvas, visibleOrigin, cellSize);

    if (lineClearSnapshot == null) {
      for (final cell in game.ghostCells) {
        final y = cell.y - TetrisGame.bufferRows;
        if (y >= 0 && y < TetrisGame.visibleRows) {
          _drawGhost(
            canvas,
            visibleOrigin,
            cellSize,
            cell.x + activeHorizontalOffset,
            y,
            cell.type,
          );
        }
      }
    }

    if (lineClearSnapshot == null) {
      for (final cell in game.activeCells) {
        final y = cell.y - TetrisGame.bufferRows;
        if (y >= 0 && y < TetrisGame.visibleRows) {
          _drawMino(
            canvas,
            visibleOrigin,
            cellSize,
            cell.x + activeHorizontalOffset,
            y,
            cell.type,
          );
        }
      }
    }
    canvas.restore();
  }

  void _drawBufferSliver(
    Canvas canvas,
    Offset origin,
    Offset visibleOrigin,
    double cellSize,
    Paint gridPaint,
  ) {
    final clip = Rect.fromLTWH(
      origin.dx,
      origin.dy,
      cellSize * TetrisGame.width,
      cellSize * _bufferSliverRows,
    );
    final hiddenOrigin = Offset(origin.dx, visibleOrigin.dy - cellSize);
    final radius = Radius.circular(cellSize * 0.16);

    canvas.save();
    canvas.clipRect(clip);
    for (var x = 0; x < TetrisGame.width; x += 1) {
      final rect = _cellRect(hiddenOrigin, cellSize, x, 0).deflate(1);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), gridPaint);
      final type = _cellAt(x, TetrisGame.bufferRows - 1);
      if (type != null) {
        _drawMino(canvas, hiddenOrigin, cellSize, x, 0, type);
      }
    }

    void drawSliverCell(MinoCell cell, void Function() draw) {
      if (cell.y == TetrisGame.bufferRows - 1) {
        draw();
      }
    }

    if (lineClearSnapshot == null) {
      for (final cell in game.ghostCells) {
        drawSliverCell(
          cell,
          () => _drawGhost(
            canvas,
            hiddenOrigin,
            cellSize,
            cell.x + activeHorizontalOffset,
            0,
            cell.type,
          ),
        );
      }
      for (final cell in game.activeCells) {
        drawSliverCell(
          cell,
          () => _drawMino(
            canvas,
            hiddenOrigin,
            cellSize,
            cell.x + activeHorizontalOffset,
            0,
            cell.type,
          ),
        );
      }
    }
    canvas.restore();
  }

  Tetromino? _cellAt(int x, int y) {
    final snapshot = lineClearSnapshot;
    if (snapshot != null) {
      return snapshot.board.cellAt(x, y);
    }
    return game.cellAt(x, y);
  }

  Tetromino? _visibleCellAt(int x, int y) {
    final snapshot = lineClearSnapshot;
    if (snapshot != null) {
      return snapshot.board.visibleCellAt(x, y);
    }
    return game.visibleCellAt(x, y);
  }

  bool _isLineClearCell(int visibleY) {
    final snapshot = lineClearSnapshot;
    return snapshot != null && snapshot.containsVisibleRow(visibleY);
  }

  void _drawLineClearSnapEffect(
    Canvas canvas,
    Offset visibleOrigin,
    double cellSize,
  ) {
    final snapshot = lineClearSnapshot;
    if (snapshot == null) {
      return;
    }

    final shaderImage = lineClearSnapImage;
    final shader = lineClearSnapShader;
    if (shaderImage == null || shader == null) {
      for (final row in snapshot.rows) {
        final visibleY = row - TetrisGame.bufferRows;
        if (visibleY < 0 || visibleY >= TetrisGame.visibleRows) {
          continue;
        }
        for (var x = 0; x < TetrisGame.width; x += 1) {
          final type = snapshot.board.visibleCellAt(x, visibleY);
          if (type != null) {
            _drawMino(canvas, visibleOrigin, cellSize, x, visibleY, type);
          }
        }
      }
      return;
    }

    final visibleSize = Size(
      cellSize * TetrisGame.width,
      cellSize * TetrisGame.visibleRows,
    );
    _configureLineClearSnapShader(
      shader: shader,
      progress: lineClearProgress,
      image: shaderImage,
      size: visibleSize,
    );
    canvas.save();
    canvas.translate(visibleOrigin.dx, visibleOrigin.dy);
    canvas.drawRect(Offset.zero & visibleSize, Paint()..shader = shader);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BoardPainter oldDelegate) => true;
}

void _configureLineClearSnapShader({
  required ui.FragmentShader shader,
  required double progress,
  required ui.Image image,
  required Size size,
}) {
  shader.setFloat(0, progress.clamp(0.0, 1.0).toDouble());
  shader.setFloat(1, _lineClearSnapParticleLifetime);
  shader.setFloat(2, _lineClearSnapFadeDuration);
  shader.setFloat(3, _lineClearSnapParticlesInRow.toDouble());
  shader.setFloat(4, _lineClearSnapParticlesInColumn.toDouble());
  shader.setFloat(5, _lineClearSnapParticleSpeed);
  shader.setFloat(6, size.width);
  shader.setFloat(7, size.height);
  shader.setImageSampler(0, image);
}

class _PiecePreviewPainter extends CustomPainter {
  const _PiecePreviewPainter(this.type);

  final Tetromino type;

  @override
  void paint(Canvas canvas, Size size) {
    final points = tetrominoCells(type, 0);
    final minX = points.map((point) => point.x).reduce(math.min);
    final maxX = points.map((point) => point.x).reduce(math.max);
    final minY = points.map((point) => point.y).reduce(math.min);
    final maxY = points.map((point) => point.y).reduce(math.max);
    final pieceWidth = maxX - minX + 1;
    final pieceHeight = maxY - minY + 1;
    final cellSize = math.min(
      size.width / (pieceWidth + 0.5),
      size.height / (pieceHeight + 0.5),
    );
    final origin = Offset(
      (size.width - pieceWidth * cellSize) / 2 - minX * cellSize,
      (size.height - pieceHeight * cellSize) / 2 - minY * cellSize,
    );

    for (final point in points) {
      _drawMino(canvas, origin, cellSize, point.x, point.y, type);
    }
  }

  @override
  bool shouldRepaint(covariant _PiecePreviewPainter oldDelegate) {
    return oldDelegate.type != type;
  }
}

Rect _cellRect(Offset origin, double cellSize, num x, num y) {
  return Rect.fromLTWH(
    origin.dx + x.toDouble() * cellSize,
    origin.dy + y.toDouble() * cellSize,
    cellSize,
    cellSize,
  );
}

void _drawMino(
  Canvas canvas,
  Offset origin,
  double cellSize,
  num x,
  num y,
  Tetromino type,
) {
  final rect = _cellRect(origin, cellSize, x, y).deflate(cellSize * 0.06);
  final radius = Radius.circular(cellSize * 0.14);
  final color = _colorFor(type);
  canvas.drawRRect(
    RRect.fromRectAndRadius(rect, radius),
    Paint()..color = color,
  );
  final highlight = Rect.fromLTWH(
    rect.left + cellSize * 0.08,
    rect.top + cellSize * 0.08,
    rect.width - cellSize * 0.16,
    math.max(1, rect.height * 0.18),
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(highlight, Radius.circular(cellSize * 0.08)),
    Paint()..color = Colors.white.withValues(alpha: 0.22),
  );
}

void _drawGhost(
  Canvas canvas,
  Offset origin,
  double cellSize,
  num x,
  num y,
  Tetromino type,
) {
  final rect = _cellRect(origin, cellSize, x, y).deflate(cellSize * 0.1);
  final rrect = RRect.fromRectAndRadius(rect, Radius.circular(cellSize * 0.13));
  final outlineColor = tetrisGhostHdrOutlineColorFor(type);
  canvas.drawRRect(
    rrect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(5.0, cellSize * 0.26)
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, cellSize * 0.16)
      ..color = outlineColor.withValues(alpha: 0.26),
  );
  canvas.drawRRect(
    rrect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(3.2, cellSize * 0.18)
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, cellSize * 0.075)
      ..color = outlineColor.withValues(alpha: 0.42),
  );
  canvas.drawRRect(
    rrect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2.2, cellSize * 0.13)
      ..strokeJoin = StrokeJoin.round
      ..color = outlineColor.withValues(alpha: 0.3),
  );
  canvas.drawRRect(
    rrect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.6, cellSize * 0.085)
      ..strokeJoin = StrokeJoin.round
      ..color = outlineColor,
  );
  canvas.drawRRect(
    rrect.deflate(math.max(0.5, cellSize * 0.04)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.7, cellSize * 0.028)
      ..strokeJoin = StrokeJoin.round
      ..color = outlineColor.withValues(alpha: 0.58),
  );
}

@visibleForTesting
ui.Color tetrisGhostHdrOutlineColorFor(Tetromino type) {
  return switch (type) {
    Tetromino.i => const ui.Color.from(
      alpha: 1,
      red: 0,
      green: 1.05,
      blue: 4.35,
      colorSpace: ui.ColorSpace.extendedSRGB,
    ),
    Tetromino.j => const ui.Color.from(
      alpha: 1,
      red: 0.05,
      green: 0.18,
      blue: 4.6,
      colorSpace: ui.ColorSpace.extendedSRGB,
    ),
    Tetromino.l => const ui.Color.from(
      alpha: 1,
      red: 4.5,
      green: 0.68,
      blue: 0,
      colorSpace: ui.ColorSpace.extendedSRGB,
    ),
    Tetromino.o => const ui.Color.from(
      alpha: 1,
      red: 4.15,
      green: 2.35,
      blue: 0,
      colorSpace: ui.ColorSpace.extendedSRGB,
    ),
    Tetromino.s => const ui.Color.from(
      alpha: 1,
      red: 0,
      green: 4.25,
      blue: 0.08,
      colorSpace: ui.ColorSpace.extendedSRGB,
    ),
    Tetromino.z => const ui.Color.from(
      alpha: 1,
      red: 4.55,
      green: 0.02,
      blue: 0.12,
      colorSpace: ui.ColorSpace.extendedSRGB,
    ),
    Tetromino.t => const ui.Color.from(
      alpha: 1,
      red: 2.9,
      green: 0,
      blue: 4.35,
      colorSpace: ui.ColorSpace.extendedSRGB,
    ),
  };
}

Color _colorFor(Tetromino type) {
  return switch (type) {
    Tetromino.i => const Color(0xFF43D9FF),
    Tetromino.j => const Color(0xFF3568FF),
    Tetromino.l => const Color(0xFFFF9E2C),
    Tetromino.o => const Color(0xFFFFE156),
    Tetromino.s => const Color(0xFF58D957),
    Tetromino.z => const Color(0xFFFF4D5E),
    Tetromino.t => const Color(0xFFD85BFF),
  };
}

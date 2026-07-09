import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../game/tetris_game.dart';
import '../game/tetromino.dart';
import '../input/control_bindings.dart';
import '../input/das_repeater.dart';
import '../input/gamepad_service.dart';
import '../input/gamepad_ui_navigator.dart';
import '../auth/auth_service.dart';
import '../net/leaderboard_client.dart';
import '../net/presence_client.dart';
import '../net/protocol.dart';
import '../net/rankings_client.dart';
import '../net/room_client.dart';
import '../net/versus_session.dart';
import 'lobby_page.dart';
import '../platform_support.dart';
import 'board_painting.dart';
import 'components.dart';
import 'home_page.dart';
import 'leaderboard_page.dart';
import 'theme.dart';
import 'toasts.dart';
import 'ui_sounds.dart';
import 'versus_widgets.dart';

const _boardBack = TetrisColors.background;
const _background = _boardBack;
const _panel = TetrisColors.panel;
const _text = TetrisColors.text;
const _mutedText = TetrisColors.mutedText;
const _gridLine = TetrisColors.gridLine;
const _bufferSliverRows = 0.25;
const _compactTopBarHeight = 54.0;
const _maxTickDelta = Duration(milliseconds: 250);
const _snapBackDuration = Duration(milliseconds: 120);
const _snapCommitDuration = Duration(milliseconds: 64);
const _lineClearAnimationDuration = Duration(milliseconds: 520);
const _lineClearDropDelay = Duration(milliseconds: 24);
const _boardImpactDuration = Duration(milliseconds: 1200);
const _boardImpactMinCells = 0.2;
const _boardImpactPerDropCell = 0.03;
const _boardImpactMaxCells = 0.75;
const _dustLifetime = Duration(milliseconds: 480);
const _dustGravityCellsPerSecSq = 18.0;
const _maxDustBursts = 6;
const _boardSideImpactCells = 0.18;
const _lineClearSnapShaderAsset = 'shaders/line_clear_snap.glsl';
const _lineClearSnapTextureCellSize = 32.0;
const _lineClearSnapParticleLifetime = 0.72;
const _lineClearSnapFadeDuration = 0.42;
const _lineClearSnapParticleSpeed = 0.26;
const _lineClearSnapParticlesInRow = TetrisGame.width * 5;
const _lineClearSnapParticlesInColumn = TetrisGame.visibleRows * 5;
const _lineClearSnapWarmUpSize = Size(320, 640);
@visibleForTesting
const tetrisLineClearSnapParticleHdrBoost = 4.25;
@visibleForTesting
const tetrisLineClearSnapParticleGlowBoost = 0.55;
const _horizontalIntentFraction = 0.35;
const _minHorizontalIntentDistance = 20.0;
const _minGestureCellSize = 36.0;
const _wideSidePanelWidth = 148.0;
const _wideSidePanelGap = 16.0;
const _snapPreviewFraction = 0.25;
const _snapCommitFraction = 0.7;
const _snapBlockedFraction = 0.22;
const _defaultMusicVolume = 0.3;
const _defaultSfxVolume = 2.0;
const _maxSfxVolume = 2.0;
const _musicVolumePreferenceKey = 'tetris.musicVolume';
const _sfxVolumePreferenceKey = tetrisSfxVolumePreferenceKey;
@visibleForTesting
const tetrisHighScorePreferenceKey = 'tetris.highScore';
@visibleForTesting
const tetrisSavedGamePreferenceKey = 'tetris.savedGame';
// Bumped when scoring rules change enough that old high scores are not
// comparable (era 2: guideline T-spin mini values + hard-drop no longer
// preserving T-spin detection). High scores from older eras are discarded.
@visibleForTesting
const tetrisScoringEraPreferenceKey = 'tetris.scoringEra';
@visibleForTesting
const tetrisCurrentScoringEra = 2;
const _movementSfxStartGap = Duration(milliseconds: 55);
const _rotationSfxStartGap = Duration(milliseconds: 35);
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

  /// Whether a track is actively playing right now. Callers use this to skip
  /// redundant resume/volume calls on the per-input music keepalive path.
  bool get isPlaying;

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
    // Nobody consumes onPositionChanged, and audioplayers' frame-based
    // position updater stacks an extra per-frame getCurrentPosition poll on
    // EVERY resume() without cancelling the previous one — with resume fired
    // per input, a long round accumulates thousands of per-frame platform
    // calls and the game grinds to 20-30fps.
    _player.positionUpdater = null;
  }

  final AudioPlayer _player;

  @override
  Stream<void> get onTrackComplete => _player.onPlayerComplete;

  @override
  bool get isPlaying => _player.state == PlayerState.playing;

  @override
  Future<void> playAsset(String assetPath) async {
    await _player.setReleaseMode(ReleaseMode.stop);
    await _player.play(AssetSource(assetPath));
  }

  @override
  Future<void> resume() async {
    if (isPlaying) {
      // Resuming a playing player is a no-op semantically, but audioplayers
      // restarts its position updater on every call; don't feed it.
      return;
    }
    await _player.resume();
  }

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
    : _audioCache = audioCache ?? AudioCache(prefix: '') {
    _warmUpPlayers();
  }

  /// Fixed number of platform players per effect; the N+1th overlapping copy
  /// restarts the oldest player instead of allocating a new one. audioplayers
  /// never removes released players from its native registry (only dispose()
  /// does), so allocating per overlap — like AudioPool.start does — leaks a
  /// native player + event channel on every overflow and the whole session
  /// slows down as they accumulate.
  static const _playersPerEffect = 4;

  final AudioCache _audioCache;
  final Map<TetrisSfx, Future<List<AudioPlayer>>> _players = {};
  final Map<TetrisSfx, int> _nextPlayerIndex = {};
  final Stopwatch _clock = Stopwatch()..start();
  final Map<TetrisSfx, int> _lastStartMilliseconds = {};
  final Set<TetrisSfx> _startsInProgress = {};

  @visibleForTesting
  String get assetPrefix => _audioCache.prefix;

  @override
  void play(TetrisSfx sfx, {double volume = 1.0}) {
    final playbackVolume = (volume.clamp(0.0, _maxSfxVolume) / _maxSfxVolume)
        .toDouble();
    if (playbackVolume <= 0) {
      return;
    }

    if (_startsInProgress.contains(sfx)) {
      return;
    }

    final now = _clock.elapsedMilliseconds;
    final lastStart = _lastStartMilliseconds[sfx];
    final minimumGap = _minimumStartGapFor(sfx).inMilliseconds;
    if (lastStart != null && now - lastStart < minimumGap) {
      return;
    }

    _lastStartMilliseconds[sfx] = now;
    _startsInProgress.add(sfx);
    unawaited(_play(sfx, playbackVolume));
  }

  Future<void> _play(TetrisSfx sfx, double playbackVolume) async {
    try {
      final players = await _playersFor(sfx);
      final index = _nextPlayerIndex[sfx] ?? 0;
      _nextPlayerIndex[sfx] = (index + 1) % players.length;
      final player = players[index];
      // Rewinds the player if its previous copy of the sound is still going;
      // with four newer layers on top the cut tail is inaudible.
      await player.stop();
      await player.setVolume(playbackVolume);
      await player.resume();
    } catch (_) {
    } finally {
      _startsInProgress.remove(sfx);
    }
  }

  Duration _minimumStartGapFor(TetrisSfx sfx) {
    return switch (sfx) {
      TetrisSfx.slide || TetrisSfx.softDrop => _movementSfxStartGap,
      TetrisSfx.rotate || TetrisSfx.counterRotate => _rotationSfxStartGap,
      TetrisSfx.hardDrop ||
      TetrisSfx.hardLock ||
      TetrisSfx.clear ||
      TetrisSfx.tetris ||
      TetrisSfx.levelUp => Duration.zero,
    };
  }

  Future<List<AudioPlayer>> _playersFor(TetrisSfx sfx) {
    return _players.putIfAbsent(sfx, () async {
      final players = <AudioPlayer>[];
      try {
        for (var i = 0; i < _playersPerEffect; i += 1) {
          final player = AudioPlayer()..audioCache = _audioCache;
          // Position streams are unused; the default frame-based updater
          // would poll getCurrentPosition every frame while a sound plays.
          player.positionUpdater = null;
          players.add(player);
          await player.setReleaseMode(ReleaseMode.stop);
          await player.setSource(AssetSource(sfx.assetPath));
        }
        return players;
      } catch (_) {
        for (final player in players) {
          unawaited(player.dispose());
        }
        rethrow;
      }
    });
  }

  void _warmUpPlayers() {
    for (final sfx in TetrisSfx.values) {
      unawaited(_playersFor(sfx).then<void>((_) {}, onError: (_, _) {}));
    }
  }

  @override
  void dispose() {
    unawaited(_dispose());
  }

  Future<void> _dispose() async {
    for (final playersFuture in _players.values) {
      try {
        final players = await playersFuture;
        await Future.wait(players.map((player) => player.dispose()));
      } catch (_) {}
    }
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

class TetrisApp extends StatefulWidget {
  const TetrisApp({
    super.key,
    this.enableAudio = true,
    this.game,
    this.musicPlayer,
    this.soundEffects,
    this.haptics,
    this.gamepad,
    this.createInviteRoom,
  });

  final bool enableAudio;
  final TetrisGame? game;
  final TetrisMusicPlayer? musicPlayer;
  final TetrisSoundEffects? soundEffects;
  final TetrisHaptics? haptics;

  /// Gamepad input source; `null` disables controller support (widget tests
  /// must not touch the platform event channel).
  final GamepadService? gamepad;

  /// Test seam for the room created when accepting a friend invite.
  final Future<RoomChannel> Function()? createInviteRoom;

  @override
  State<TetrisApp> createState() => _TetrisAppState();
}

class _TetrisAppState extends State<TetrisApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<PresenceEvent>? _presenceSubscription;
  bool _inviteDialogOpen = false;

  @override
  void initState() {
    super.initState();
    _presenceSubscription = PresenceHub.instance?.events.listen(
      _onPresenceEvent,
    );
  }

  @override
  void dispose() {
    unawaited(_presenceSubscription?.cancel() ?? Future.value());
    super.dispose();
  }

  void _onPresenceEvent(PresenceEvent event) {
    final hub = PresenceHub.instance;
    if (hub == null) {
      return;
    }
    switch (event) {
      case InviteReceived(:final fromUid):
        // Mid-match players are busy; decline without interrupting.
        if (hub.status == FriendPresence.versus || _inviteDialogOpen) {
          hub.respondInvite(toUid: fromUid, accept: false);
          return;
        }
        unawaited(_promptInvite(fromUid));
      case InviteAccepted(:final roomCode):
        TetrisToastHost.show(
          'Challenge accepted — joining the room!',
          icon: Icons.sports_esports_rounded,
          accent: TetrisColors.ok,
        );
        _navigatorKey.currentState?.push(
          MaterialPageRoute<void>(
            builder: (_) => LobbyPage(
              enableAudio: widget.enableAudio,
              musicPlayer: widget.musicPlayer,
              soundEffects: widget.soundEffects,
              haptics: widget.haptics,
              gamepad: widget.gamepad,
              initialJoinCode: roomCode,
            ),
          ),
        );
      case InviteDeclined():
        TetrisToastHost.show(
          'Your challenge was declined.',
          icon: Icons.person_off_rounded,
        );
      case InviteFailed():
        TetrisToastHost.show(
          'That friend is not online right now.',
          icon: Icons.info_outline_rounded,
        );
      default:
        // Spectate traffic is handled by the pages that own it.
        break;
    }
  }

  Future<void> _promptInvite(String fromUid) async {
    final hub = PresenceHub.instance;
    final navigatorContext = _navigatorKey.currentContext;
    if (hub == null || navigatorContext == null) {
      return;
    }
    _inviteDialogOpen = true;
    UiFeedback.play(UiSfx.toast);
    Timer? expiry;
    final accepted = await showDialog<bool>(
      context: navigatorContext,
      barrierDismissible: false,
      builder: (dialogContext) {
        expiry = Timer(const Duration(seconds: 30), () {
          if (Navigator.of(dialogContext).canPop()) {
            Navigator.of(dialogContext).pop(false);
          }
        });
        return AlertDialog(
          backgroundColor: TetrisColors.panel,
          title: const Text(
            '1v1 challenge!',
            style: TextStyle(color: TetrisColors.text, fontSize: 17),
          ),
          content: const Text(
            'A friend is challenging you to a versus match.',
            style: TextStyle(color: TetrisColors.mutedText, fontSize: 13),
          ),
          actions: [
            TetrisButton(
              key: const ValueKey('invite-decline'),
              variant: TetrisButtonVariant.ghost,
              compact: true,
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Decline'),
            ),
            TetrisButton(
              key: const ValueKey('invite-accept'),
              variant: TetrisButtonVariant.primary,
              compact: true,
              autofocus: true,
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Accept'),
            ),
          ],
        );
      },
    );
    expiry?.cancel();
    _inviteDialogOpen = false;
    if (accepted != true) {
      hub.respondInvite(toUid: fromUid, accept: false);
      return;
    }
    try {
      final room = await (widget.createInviteRoom?.call() ??
          RoomClient.create());
      hub.respondInvite(toUid: fromUid, accept: true, roomCode: room.code);
      _navigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => LobbyPage(
            enableAudio: widget.enableAudio,
            musicPlayer: widget.musicPlayer,
            soundEffects: widget.soundEffects,
            haptics: widget.haptics,
            gamepad: widget.gamepad,
            initialClient: room,
          ),
        ),
      );
    } catch (error) {
      hub.respondInvite(toUid: fromUid, accept: false);
      TetrisToastHost.show(
        'Could not open a room: $error',
        icon: Icons.error_outline_rounded,
        accent: TetrisColors.danger,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tetris',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      // Above the Navigator so every route, dialog and overlay is
      // controller-navigable (d-pad moves focus, South activates, East pops)
      // and toasts land on top of everything.
      builder: (context, child) => GamepadUiNavigator(
        gamepad: widget.gamepad,
        navigatorKey: _navigatorKey,
        child: TetrisToastHost(child: child ?? const SizedBox.shrink()),
      ),
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
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: TetrisPageTransitionsBuilder(),
            TargetPlatform.iOS: TetrisPageTransitionsBuilder(),
            TargetPlatform.macOS: TetrisPageTransitionsBuilder(),
            TargetPlatform.linux: TetrisPageTransitionsBuilder(),
            TargetPlatform.windows: TetrisPageTransitionsBuilder(),
          },
        ),
      ),
      // Tests inject a game and land straight on the board; production boots
      // to the home menu.
      home: widget.game != null
          ? TetrisGamePage(
              enableAudio: widget.enableAudio,
              game: widget.game,
              musicPlayer: widget.musicPlayer,
              soundEffects: widget.soundEffects,
              haptics: widget.haptics,
              gamepad: widget.gamepad,
            )
          : HomePage(
              enableAudio: widget.enableAudio,
              musicPlayer: widget.musicPlayer,
              soundEffects: widget.soundEffects,
              haptics: widget.haptics,
              gamepad: widget.gamepad,
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
    this.gamepad,
    this.versusSession,
    this.rankingsApi,
  });

  final bool enableAudio;
  final TetrisGame? game;
  final TetrisMusicPlayer? musicPlayer;
  final TetrisSoundEffects? soundEffects;
  final TetrisHaptics? haptics;

  /// Gamepad input source; `null` disables controller support.
  final GamepadService? gamepad;

  /// When set, this page runs a 1v1 match: the session owns the seeded game,
  /// persistence and pause are disabled, and versus overlays render on top of
  /// the board.
  final VersusSession? versusSession;

  /// Rated-result reporting; defaults to the real backend client. Tests
  /// inject a fake.
  final RankingsApi? rankingsApi;

  @override
  State<TetrisGamePage> createState() => _TetrisGamePageState();
}

class _TetrisGamePageState extends State<TetrisGamePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // Not `final`: a versus rematch swaps in a fresh seeded game.
  late TetrisGame _game;
  late final Ticker _ticker;
  late final AnimationController _snapBackController;
  late final AnimationController _lineClearController;
  late final AnimationController _boardImpactController;
  late final TetrisSoundEffects _soundEffects;
  late final TetrisHaptics _haptics;
  late final bool _disposeSoundEffects;
  late final bool _disposeMusicPlayer;
  Future<void>? _preferencesFuture;
  TetrisMusicPlayer? _musicPlayer;
  StreamSubscription<void>? _musicCompleteSubscription;
  StreamSubscription<GamepadControlEvent>? _gamepadSubscription;
  StreamSubscription<ServerEnvelope>? _versusEnvelopeSubscription;
  GamepadBindings _gamepadBindings = GamepadBindings.guideline();
  TouchBindings _touchBindings = TouchBindings.defaults();
  KeyboardBindings _keyboardBindings = KeyboardBindings.standard();
  // Non-null only on desktop; owns the game page's keyboard focus so physical
  // keys reach gameplay while menus keep their own focus traversal.
  FocusNode? _keyboardFocusNode;
  final DasRepeater _dasRepeater = DasRepeater();

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
  int _highScore = 0;
  bool _highScoreDirty = false;
  double _musicVolume = _defaultMusicVolume;
  double _sfxVolume = _defaultSfxVolume;
  LineClearAnimationSnapshot? _lineClearSnapshot;
  ui.FragmentShader? _lineClearSnapShader;
  ui.Image? _lineClearSnapImage;
  bool _lineClearSnapWarmUpComplete = false;
  bool _leaderboardSubmitted = false;
  bool _gamepadClaimedForPlay = false;
  bool _countdownGoTail = false;
  VersusPhase? _lastVersusPhase;
  Timer? _countdownTailTimer;
  final List<_DustBurst> _dustBursts = [];
  final math.Random _dustRandom = math.Random();
  Timer? _spectateTimer;
  int _spectateSeq = 0;

  bool get _boardAcceptsInput =>
      !_game.paused && !_game.gameOver && !_lineClearAnimating;

  /// While the board is live the controller belongs to gameplay; once a
  /// menu-like surface is up (pause / game over overlay, versus result) the
  /// claim is released so the global [GamepadUiNavigator] can drive it.
  /// Called from build so every state transition re-evaluates it.
  void _syncGamepadUiNavigationClaim() {
    final gamepad = widget.gamepad;
    if (gamepad == null) {
      return;
    }
    final session = widget.versusSession;
    final menuSurfaceShown = session == null
        ? _game.paused || _game.gameOver
        : switch (session.phase.value) {
            VersusPhase.won ||
            VersusPhase.lost ||
            VersusPhase.opponentLeft => true,
            _ => false,
          };
    final claim = !menuSurfaceShown;
    if (claim == _gamepadClaimedForPlay) {
      return;
    }
    _gamepadClaimedForPlay = claim;
    if (claim) {
      gamepad.blockUiNavigation();
    } else {
      gamepad.unblockUiNavigation();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _game = widget.game ?? widget.versusSession?.game ?? TetrisGame();
    // Friends see whether we're in a solo round or a match.
    PresenceHub.instance?.setStatus(
      widget.versusSession == null
          ? FriendPresence.solo
          : FriendPresence.versus,
    );
    // Solo play streams to spectating friends — but only while someone is
    // actually watching, so idle rounds cost nothing.
    if (widget.versusSession == null) {
      PresenceHub.instance?.watcherCount.addListener(_syncSpectatePublishing);
      _syncSpectatePublishing();
    }
    final session = widget.versusSession;
    if (session != null) {
      _lastVersusPhase = session.phase.value;
      session.gameNotifier.addListener(_onVersusGameSwapped);
      session.phase.addListener(_onVersusStateChanged);
      session.opponent.addListener(_onVersusStateChanged);
      _versusEnvelopeSubscription = session.room.envelopes.listen(
        _onVersusEnvelope,
      );
    }
    _preferencesFuture = _loadPreferences();
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
    _gamepadSubscription = widget.gamepad?.controlEvents.listen(
      _onGamepadControl,
    );
    if (isDesktopPlatform) {
      _keyboardFocusNode = FocusNode(debugLabel: 'tetris-gameplay-keyboard');
    }
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
    _flushHighScore();
    if (_gamepadClaimedForPlay) {
      _gamepadClaimedForPlay = false;
      widget.gamepad?.unblockUiNavigation();
    }
    WidgetsBinding.instance.removeObserver(this);
    final session = widget.versusSession;
    if (session != null) {
      session.gameNotifier.removeListener(_onVersusGameSwapped);
      session.phase.removeListener(_onVersusStateChanged);
      session.opponent.removeListener(_onVersusStateChanged);
      unawaited(_versusEnvelopeSubscription?.cancel() ?? Future.value());
      unawaited(session.dispose());
    }
    _countdownTailTimer?.cancel();
    _spectateTimer?.cancel();
    PresenceHub.instance?.watcherCount.removeListener(
      _syncSpectatePublishing,
    );
    PresenceHub.instance?.setStatus(FriendPresence.online);
    _lineClearSnapImage?.dispose();
    _snapBackController.dispose();
    _lineClearController.dispose();
    _boardImpactController.dispose();
    _ticker.dispose();
    _keyboardFocusNode?.dispose();
    unawaited(_gamepadSubscription?.cancel() ?? Future.value());
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
        Tetromino.playablePieces[x % Tetromino.playablePieces.length],
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
      return;
    }

    if (widget.versusSession != null) {
      // A versus board must not pause (the opponent keeps playing) and never
      // persists. The room socket reconnects on resume; staying away past
      // the grace period forfeits the match on the opponent's side.
      unawaited(_musicPlayer?.pause() ?? Future.value());
      return;
    }

    // Leaving the foreground: freeze the round so nothing falls while the
    // player is away and persist a resumable snapshot to disk.
    _autoPauseForBackground();
    _flushHighScore();
    unawaited(_persistGameState());
    unawaited(_musicPlayer?.pause() ?? Future.value());
  }

  void _autoPauseForBackground() {
    if (_game.gameOver || _game.paused) {
      return;
    }
    _game.setSoftDropping(false);
    if (mounted) {
      setState(() {
        _game.paused = true;
      });
    } else {
      _game.paused = true;
    }
  }

  void _onVersusGameSwapped() {
    final session = widget.versusSession;
    if (session == null || !mounted) {
      return;
    }
    setState(() {
      _game = session.game;
      _lineClearAnimating = false;
      _lineClearSnapshot = null;
      _boardImpactOffsetCells = Offset.zero;
    });
  }

  void _onVersusStateChanged() {
    if (!mounted) {
      return;
    }
    final phase = widget.versusSession?.phase.value;
    if (_lastVersusPhase == VersusPhase.countdown &&
        phase == VersusPhase.playing) {
      _countdownGoTail = true;
      _countdownTailTimer?.cancel();
      _countdownTailTimer = Timer(CountdownOverlay.goTail, () {
        if (mounted) {
          setState(() => _countdownGoTail = false);
        }
      });
    }
    if (_lastVersusPhase != phase &&
        (phase == VersusPhase.won || phase == VersusPhase.lost)) {
      unawaited(_reportRatedResult(phase == VersusPhase.won));
    }
    _lastVersusPhase = phase;
    setState(() {});
  }

  void _syncSpectatePublishing() {
    final hub = PresenceHub.instance;
    final shouldPublish =
        hub != null && hub.watcherCount.value > 0 && mounted;
    if (shouldPublish && _spectateTimer == null) {
      _spectateTimer = Timer.periodic(
        const Duration(milliseconds: 150),
        (_) => _publishSpectateFrame(),
      );
      _publishSpectateFrame();
    } else if (!shouldPublish) {
      _spectateTimer?.cancel();
      _spectateTimer = null;
    }
  }

  void _publishSpectateFrame() {
    final hub = PresenceHub.instance;
    if (hub == null) {
      return;
    }
    final active = _game.active;
    _spectateSeq += 1;
    final frame = BoardStateMsg(
      seq: _spectateSeq,
      cells: encodeVisibleBoard(_game),
      active: active == null
          ? null
          : ActivePieceWire(
              type: active.type,
              rotation: active.rotation,
              x: active.x,
              y: active.y,
            ),
      pendingGarbage: 0,
      score: _game.score,
      lines: _game.lines,
    ).encode();
    // Level rides along for the spectator HUD; decoders ignore extras.
    frame['level'] = _game.level;
    hub.publishSpectate(frame);
  }

  /// Honest-client rated reporting: both players report their own outcome;
  /// the backend rates the match once the reports pair up. Signed-out play
  /// stays unrated. The first reporter polls once more to pick up the delta.
  Future<void> _reportRatedResult(bool won) async {
    final session = widget.versusSession;
    if (session == null || Auth.instance.account.value == null) {
      return;
    }
    final api = widget.rankingsApi ?? HttpRankingsApi(auth: Auth.instance);
    final matchId = session.matchId;
    try {
      for (var attempt = 0; attempt < 3; attempt += 1) {
        final outcome = await api.reportResult(
          roomCode: session.room.code,
          matchId: matchId,
          won: won,
        );
        if (outcome.status == ReportStatus.rated) {
          if (mounted && session.matchId == matchId) {
            session.ratingDelta.value = outcome.ratingDelta;
          }
          return;
        }
        if (outcome.status == ReportStatus.discarded) {
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!mounted || session.matchId != matchId) {
          return;
        }
      }
    } catch (_) {
      // Rated results are best-effort; the match outcome itself already
      // rendered.
    }
  }

  /// Room lifecycle toasts during a match; the session itself handles the
  /// grace timer and phase changes.
  void _onVersusEnvelope(ServerEnvelope envelope) {
    switch (envelope) {
      case PeerLeftEnvelope():
        TetrisToastHost.show(
          'Opponent disconnected — waiting for them to return',
          icon: Icons.link_off_rounded,
          accent: TetrisColors.danger,
        );
      case PeerRejoinedEnvelope():
        TetrisToastHost.show(
          'Opponent reconnected',
          icon: Icons.link_rounded,
          accent: TetrisColors.ok,
        );
      default:
        break;
    }
  }

  void _onFrame(Duration elapsed) {
    final delta = elapsed - _lastFrameElapsed;
    _lastFrameElapsed = elapsed;
    // Versus event drain runs every frame, even while the board is paused or
    // animating, so attacks and game-over reach the opponent immediately.
    widget.versusSession?.onLocalTick();
    if (_dustBursts.isNotEmpty) {
      final now = DateTime.now();
      _dustBursts.removeWhere(
        (burst) => now.difference(burst.spawnedAt) > _dustLifetime,
      );
    }
    _maybeSubmitLeaderboardScore();
    if (_game.gameOver) {
      _flushHighScore();
    }
    if (delta <= Duration.zero ||
        delta > _maxTickDelta ||
        _game.paused ||
        _game.gameOver ||
        _lineClearAnimating) {
      return;
    }

    // Held gamepad directions auto-repeat here; skipping the poll while the
    // board is blocked (above) freezes the DAS charge instead of flushing a
    // burst of queued shifts on resume.
    final dasShifts = _dasRepeater.poll(delta);
    for (var i = 0; i < dasShifts; i += 1) {
      _moveOnceWithFeedback(_dasRepeater.activeDirection);
    }

    final before = _SoundSnapshot.fromGame(_game);
    final beforeY = _game.active?.y;
    _game.tick(delta);
    _recordHighScoreIfNeeded();
    if (_game.softDropping &&
        _game.lockCount == before.lockCount &&
        beforeY != null &&
        (_game.active?.y ?? beforeY) > beforeY) {
      // Engine-driven soft drop rows; the sfx layer rate-limits repeats.
      _playSfx(TetrisSfx.softDrop);
    }
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

  Future<void> _loadPreferences() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      // One-time migration: high scores earned under pre-rebalance scoring
      // (inflated T-spin values) are not comparable, so drop them.
      final scoringEra = preferences.getInt(tetrisScoringEraPreferenceKey) ?? 1;
      if (scoringEra < tetrisCurrentScoringEra) {
        await preferences.remove(tetrisHighScorePreferenceKey);
        await preferences.setInt(
          tetrisScoringEraPreferenceKey,
          tetrisCurrentScoringEra,
        );
      }
      final musicVolume = preferences.getDouble(_musicVolumePreferenceKey);
      final sfxVolume = preferences.getDouble(_sfxVolumePreferenceKey);
      final highScore = preferences.getInt(tetrisHighScorePreferenceKey);
      final savedGame = preferences.getString(tetrisSavedGamePreferenceKey);
      final gamepadBindings = GamepadBindings.decode(
        preferences.getString(tetrisGamepadBindingsPreferenceKey),
      );
      final touchBindings = TouchBindings.decode(
        preferences.getString(tetrisTouchBindingsPreferenceKey),
      );
      final keyboardBindings = KeyboardBindings.decode(
        preferences.getString(tetrisKeyboardBindingsPreferenceKey),
      );
      if (!mounted) {
        return;
      }

      setState(() {
        _gamepadBindings = gamepadBindings;
        _touchBindings = touchBindings;
        _keyboardBindings = keyboardBindings;
        if (musicVolume != null) {
          _musicVolume = musicVolume.clamp(0.0, 1.0).toDouble();
        }
        if (sfxVolume != null) {
          _sfxVolume = sfxVolume.clamp(0.0, _maxSfxVolume).toDouble();
          UiFeedback.setFromStoredSfxVolume(_sfxVolume);
        }
        // Only adopt a disk snapshot when the host did not inject a specific
        // game (production always uses the internal game; tests can override)
        // and this is not a versus match, whose game is seeded by the server.
        if (savedGame != null &&
            widget.game == null &&
            widget.versusSession == null) {
          _restoreSavedGame(savedGame);
        }
        _highScore = math.max(highScore ?? 0, _game.score);
        _volumePreferencesLoaded = true;
      });
      _recordHighScoreIfNeeded();
    } catch (_) {
      if (mounted) {
        setState(() {
          _highScore = math.max(_highScore, _game.score);
          _volumePreferencesLoaded = true;
        });
        _recordHighScoreIfNeeded();
      }
    }
  }

  Future<void> _playMusicAfterVolumePreferencesLoad() async {
    final loading = _preferencesFuture;
    if (!_volumePreferencesLoaded && loading != null) {
      await loading;
    }
    // A restored game boots paused; hold the music until the player resumes.
    if (mounted && !_game.paused && !_game.gameOver) {
      await _playMusic();
    }
  }

  Future<void> _playMusic() async {
    final loading = _preferencesFuture;
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

    // This runs on every input as an autoplay-unblock keepalive; while the
    // track is audibly playing there is nothing to do, and each redundant
    // setVolume/resume is a platform-channel call on the main thread.
    if (_musicStarted && player.isPlaying) {
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
    _recordHighScoreIfNeeded();

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
    // Crunch: the board jolts harder the more rows went down; a Tetris also
    // kicks sideways.
    final cleared = snapshot.rows.length;
    _startBoardImpact(
      Offset(cleared >= 4 ? 0.1 : 0.0, 0.1 + 0.09 * cleared),
    );
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
    _flushHighScore();
    _lineClearController.stop();
    _boardImpactController.stop();
    _lineClearAnimationSerial += 1;
    _setLineClearSnapImage(null);
    setState(() {
      _lineClearAnimating = false;
      _lineClearSnapshot = null;
      _dragWallImpactMask = 0;
      _boardImpactOffsetCells = Offset.zero;
      _leaderboardSubmitted = false;
      _game.restart();
    });
    // The game-over overlay held keyboard focus for its buttons; a fresh round
    // hands it back to the board.
    _ensureKeyboardFocus();
    unawaited(_clearSavedGame());
    unawaited(_restartMusicPlaylist());
  }

  void _togglePause() {
    if (widget.versusSession != null) {
      return; // No pausing in versus: the opponent keeps playing.
    }
    setState(_game.togglePause);
    if (_game.paused) {
      _flushHighScore();
      unawaited(_musicPlayer?.pause() ?? Future.value());
    } else {
      // Resuming dismisses the pause overlay, which held keyboard focus for
      // its buttons; hand it back to the board.
      _ensureKeyboardFocus();
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
    // Menu sounds follow the same slider.
    UiFeedback.setFromStoredSfxVolume(nextVolume);
    unawaited(_saveVolumePreference(_sfxVolumePreferenceKey, nextVolume));
  }

  Future<void> _saveVolumePreference(String key, double volume) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setDouble(key, volume);
    } catch (_) {}
  }

  /// Fire-and-forget submission of a finished single-player round to the
  /// global leaderboard, once per round and only when a display name is set.
  void _maybeSubmitLeaderboardScore() {
    if (widget.versusSession != null ||
        !_game.gameOver ||
        _leaderboardSubmitted ||
        _game.score <= 0) {
      return;
    }
    _leaderboardSubmitted = true;
    final score = _game.score;
    final lines = _game.lines;
    final level = _game.level;
    unawaited(() async {
      try {
        final preferences = await SharedPreferences.getInstance();
        final name =
            preferences.getString(tetrisPlayerNamePreferenceKey)?.trim() ?? '';
        if (name.isEmpty) {
          return;
        }
        final client = LeaderboardClient();
        try {
          await client.submit(
            name: name,
            score: score,
            lines: lines,
            level: level,
          );
        } finally {
          client.close();
        }
      } catch (_) {
        // Leaderboard submission is best-effort; the game result stands.
      }
    }());
  }

  void _recordHighScoreIfNeeded() {
    if (widget.versusSession != null) {
      return; // Garbage-fed versus scores do not compete with solo runs.
    }
    if (_game.score <= _highScore) {
      return;
    }

    // Only the in-memory value tracks every point; the preference write is
    // deferred to round boundaries. Persisting here would issue a platform
    // channel write per scoring event (soft drops alone score at ~20Hz).
    _highScore = _game.score;
    _highScoreDirty = true;
  }

  void _flushHighScore() {
    if (!_highScoreDirty) {
      return;
    }
    _highScoreDirty = false;
    unawaited(_saveHighScorePreference(_highScore));
  }

  Future<void> _saveHighScorePreference(int highScore) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(tetrisHighScorePreferenceKey, highScore);
    } catch (_) {}
  }

  void _restoreSavedGame(String encoded) {
    try {
      final json = jsonDecode(encoded) as Map<String, dynamic>;
      _game.restore(json);
      if (_game.gameOver) {
        // A finished round is not worth resuming; start fresh instead.
        _game.restart();
        unawaited(_clearSavedGame());
        return;
      }
      // Resume on the player's terms: surface the pause overlay so the round
      // only continues once they tap resume.
      _game.paused = true;
    } catch (_) {
      // Corrupt or incompatible snapshot: discard it and keep the fresh game.
      _game.restart();
      unawaited(_clearSavedGame());
    }
  }

  Future<void> _persistGameState() async {
    if (widget.versusSession != null) {
      // Versus matches are never resumable; persisting one would also
      // clobber the single-player save.
      return;
    }
    try {
      final preferences = await SharedPreferences.getInstance();
      if (_game.gameOver) {
        await preferences.remove(tetrisSavedGamePreferenceKey);
        return;
      }
      await preferences.setString(
        tetrisSavedGamePreferenceKey,
        jsonEncode(_game.toJson()),
      );
    } catch (_) {}
  }

  Future<void> _clearSavedGame() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(tetrisSavedGamePreferenceKey);
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
    if (!_boardAcceptsInput) {
      return;
    }
    // One immediate step for responsiveness; from here the engine falls at
    // the guideline soft drop speed (20x gravity) until the press ends.
    _softDropStep();
    _game.setSoftDropping(true);
  }

  void _stopSoftDrop() {
    _game.setSoftDropping(false);
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
    final dust = _buildHardDropDust();
    final lockCount = _game.lockCount;
    _stopSoftDrop();
    _snapBackController.stop();
    _resetSnapOffsets();
    _commitHardDrop();
    if (_game.lockCount > lockCount) {
      _startBoardImpact(impactOffset);
      if (dust != null) {
        _dustBursts.add(dust);
        if (_dustBursts.length > _maxDustBursts) {
          _dustBursts.removeAt(0);
        }
      }
    }
  }

  /// Dust kicked up where the piece lands, computed pre-drop from the ghost
  /// position; more distance kicks harder.
  _DustBurst? _buildHardDropDust() {
    final piece = _game.active;
    final distance = _game.hardDropDistance;
    if (piece == null || distance < 1) {
      return null;
    }
    final bottomByColumn = <int, int>{};
    for (final cell in piece.cells) {
      final landedY = cell.y + distance;
      final existing = bottomByColumn[cell.x];
      if (existing == null || landedY > existing) {
        bottomByColumn[cell.x] = landedY;
      }
    }
    final intensity = (0.5 + distance * 0.05).clamp(0.5, 1.4);
    final particles = <_DustParticle>[];
    for (final entry in bottomByColumn.entries) {
      final visibleY = entry.value - TetrisGame.bufferRows;
      if (visibleY < 0 || visibleY >= TetrisGame.visibleRows) {
        continue;
      }
      for (var i = 0; i < 3; i += 1) {
        particles.add(
          _DustParticle(
            cellX: entry.key + _dustRandom.nextDouble(),
            cellY: visibleY + 1.0,
            vx: (_dustRandom.nextDouble() - 0.5) * 6 * intensity,
            vy: -(1.5 + _dustRandom.nextDouble() * 3.5) * intensity,
            radius: 0.06 + _dustRandom.nextDouble() * 0.07,
            tint: colorForTetromino(piece.type),
          ),
        );
      }
    }
    return _DustBurst(spawnedAt: DateTime.now(), particles: particles);
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
    // Heavier the further the piece fell.
    final depth = (_boardImpactMinCells +
            _game.hardDropDistance * _boardImpactPerDropCell)
        .clamp(_boardImpactMinCells, _boardImpactMaxCells);
    return Offset(0, depth);
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

  void _moveOnceWithFeedback(int direction) {
    if (direction == 0 || !_boardAcceptsInput) {
      return;
    }
    _runGameAction<bool>(
      () => direction < 0 ? _game.moveLeft() : _game.moveRight(),
      successSfx: TetrisSfx.slide,
      successHaptic: TetrisHaptic.move,
      didSucceed: (moved, _) => moved,
    );
  }

  void _onGamepadControl(GamepadControlEvent event) {
    final action = _gamepadBindings.actionFor(event.control);
    if (action == null) {
      return;
    }
    if (event.pressed) {
      _onActionPressed(action);
    } else {
      _onActionReleased(action);
    }
  }

  /// Desktop keyboard control, sharing the gamepad path: [_onActionPressed]
  /// drives DAS and sustained soft drop identically. Installed only while the
  /// [Focus] wrapper exists, i.e. on desktop.
  ///
  /// Pause/restart stays live over the pause and game-over overlays so Esc
  /// resumes; every other action fires only while the board accepts input.
  /// Any unbound key — and every gameplay key while a menu surface is up —
  /// bubbles on untouched, so Flutter's built-in arrow/enter focus traversal
  /// keeps navigating menus.
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final action = _keyboardBindings.actionFor(event.logicalKey);
    if (action == null) {
      return KeyEventResult.ignored;
    }
    if (action != GameAction.pause && !_boardAcceptsInput) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      _onActionPressed(action);
    } else if (event is KeyUpEvent) {
      _onActionReleased(action);
    }
    // KeyRepeatEvents are swallowed: DAS and the engine's sustained soft drop
    // own auto-repeat, and consuming them keeps OS key-repeat from leaking to
    // the menu shortcuts.
    return KeyEventResult.handled;
  }

  /// Returns keyboard focus to the board after a menu surface (which grabbed
  /// focus for its buttons) closes, so gameplay keys resume reaching the game.
  void _ensureKeyboardFocus() {
    final node = _keyboardFocusNode;
    if (node != null && !node.hasFocus) {
      node.requestFocus();
    }
  }

  void _onActionPressed(GameAction action) {
    switch (action) {
      case GameAction.moveLeft:
        _dasRepeater.press(-1);
        _moveOnceWithFeedback(-1);
      case GameAction.moveRight:
        _dasRepeater.press(1);
        _moveOnceWithFeedback(1);
      case GameAction.softDrop:
        _startSoftDrop();
      case GameAction.hardDrop:
        _hardDrop();
      case GameAction.rotateClockwise:
        _rotateClockwise();
      case GameAction.rotateCounterClockwise:
        _rotateCounterClockwise();
      case GameAction.hold:
        _runAction(_game.hold);
      case GameAction.pause:
        if (_game.gameOver && widget.versusSession == null) {
          _restart();
        } else {
          _togglePause();
        }
    }
  }

  void _onActionReleased(GameAction action) {
    switch (action) {
      case GameAction.moveLeft:
        _dasRepeater.release(-1);
      case GameAction.moveRight:
        _dasRepeater.release(1);
      case GameAction.softDrop:
        _stopSoftDrop();
      case GameAction.hardDrop:
      case GameAction.rotateClockwise:
      case GameAction.rotateCounterClockwise:
      case GameAction.hold:
      case GameAction.pause:
        break;
    }
  }

  /// Runs a momentary (tap/swipe) touch action. Sustained soft drop is only
  /// meaningful for held inputs, so here it performs a single step.
  void _performTouchAction(GameAction? action) {
    switch (action) {
      case null:
        break;
      case GameAction.moveLeft:
        _moveOnceWithFeedback(-1);
      case GameAction.moveRight:
        _moveOnceWithFeedback(1);
      case GameAction.softDrop:
        _softDropStep();
      case GameAction.hardDrop:
        _hardDrop();
      case GameAction.rotateClockwise:
        _rotateClockwise();
      case GameAction.rotateCounterClockwise:
        _rotateCounterClockwise();
      case GameAction.hold:
        _runAction(_game.hold);
      case GameAction.pause:
        _togglePause();
    }
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
      final gesture = _dragY < 0
          ? TouchGesture.swipeUp
          : TouchGesture.swipeDown;
      _performTouchAction(_touchBindings.actionFor(gesture));
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
    _syncGamepadUiNavigationClaim();
    // Block the iOS edge-swipe / Android back gesture: an accidental pop
    // mid-round would silently abandon the game (and forfeit a versus
    // match). Leaving is always an explicit button: the pause/game-over
    // menu in solo, the result overlay in versus.
    Widget page = PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact =
                  constraints.maxWidth < 760 || constraints.maxHeight < 500;

              final layout = compact
                  ? _buildCompactLayout(constraints)
                  : _buildWideLayout(constraints);
              return _wrapWithVersusResult(layout, constraints);
            },
          ),
        ),
      ),
    );
    final keyboardFocusNode = _keyboardFocusNode;
    if (keyboardFocusNode != null) {
      // Wraps the whole page (desktop only). `skipTraversal` keeps this node
      // out of the menu overlays' arrow/Tab navigation while still letting it
      // hold focus for gameplay; overlay buttons are descendants, so their
      // key events bubble through here and gameplay keys still land while the
      // board is live.
      page = Focus(
        focusNode: keyboardFocusNode,
        autofocus: true,
        skipTraversal: true,
        onKeyEvent: _handleKeyEvent,
        child: page,
      );
    }
    return page;
  }

  /// Persists the round (solo only; no-op for finished games) and returns to
  /// the home menu. Bypasses [PopScope] deliberately: this is the one
  /// sanctioned exit.
  void _exitToMenu() {
    _flushHighScore();
    unawaited(_persistGameState());
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  Widget _buildWideLayout(BoxConstraints constraints) {
    const sideColumnWidth = _wideSidePanelWidth + _wideSidePanelGap;
    final boardHeight = math.min(constraints.maxHeight, 760.0);
    final maxBoardWidth = math.max(
      0.0,
      constraints.maxWidth - 2 * sideColumnWidth,
    );
    final boardWidth = math.min(maxBoardWidth, boardHeight * _boardAspectRatio);
    final resolvedBoardHeight = boardWidth / _boardAspectRatio;
    final cellSize = _cellSizeFor(boardWidth, resolvedBoardHeight);
    final gestureCellSize = _gestureCellSizeFor(cellSize);

    // The side panels live outside the gesture surface so button taps can
    // never double as piece drags; the board area between them keeps the
    // whole-surface gesture behavior of the compact layout.
    return SizedBox.expand(
      child: Row(
        children: [
          SizedBox(
            key: const ValueKey('wide-left-panel'),
            width: sideColumnWidth,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(left: _wideSidePanelGap),
                child: SizedBox(
                  width: _wideSidePanelWidth,
                  height: resolvedBoardHeight,
                  child: _WideLeftColumn(
                    holdPiece: _game.holdPiece,
                    score: _game.score,
                    level: _game.level,
                    lines: _game.lines,
                    paused: _game.paused,
                    showPause: widget.versusSession == null,
                    pauseFocusable: !_game.paused && !_game.gameOver,
                    onPause: _togglePause,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: _buildGestureSurface(
              cellSize: gestureCellSize,
              child: Center(
                child: _buildBoardCanvas(boardWidth, resolvedBoardHeight),
              ),
            ),
          ),
          SizedBox(
            key: const ValueKey('wide-right-panel'),
            width: sideColumnWidth,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(right: _wideSidePanelGap),
                child: SizedBox(
                  width: _wideSidePanelWidth,
                  height: resolvedBoardHeight,
                  child: _WideNextColumn(pieces: _game.nextQueue),
                ),
              ),
            ),
          ),
        ],
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
    final cellSize = _cellSizeFor(boardWidth, boardHeight);
    final gestureCellSize = _gestureCellSizeFor(cellSize);

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
              showPause: widget.versusSession == null,
              pauseFocusable: !_game.paused && !_game.gameOver,
            ),
          ),
          Expanded(
            child: _buildGestureSurface(
              cellSize: gestureCellSize,
              child: Center(child: _buildBoardCanvas(boardWidth, boardHeight)),
            ),
          ),
        ],
      ),
    );
  }

  double _cellSizeFor(double width, double height) {
    return math.min(
      width / TetrisGame.width,
      height / (TetrisGame.visibleRows + _bufferSliverRows),
    );
  }

  double _gestureCellSizeFor(double boardCellSize) {
    return math.max(boardCellSize, _minGestureCellSize);
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
              final gesture =
                  details.localPosition.dx > constraints.maxWidth / 2
                  ? TouchGesture.tapRight
                  : TouchGesture.tapLeft;
              _performTouchAction(_touchBindings.actionFor(gesture));
            },
            onLongPressStart: (_) {
              if (!_boardAcceptsInput || _horizontalDragLocked) {
                return;
              }
              final action = _touchBindings.actionFor(TouchGesture.longPress);
              if (action == GameAction.softDrop) {
                // The one sustained touch action: drop for as long as the
                // press is held.
                _startSoftDrop();
              } else {
                _performTouchAction(action);
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
    final session = widget.versusSession;
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
                dustBursts: _dustBursts,
              ),
              size: Size.infinite,
            ),
          ),
          if (session != null) ..._buildVersusLayer(session, width),
          if (session == null && (_game.gameOver || _game.paused))
            _GameOverlay(
              gameOver: _game.gameOver,
              score: _game.score,
              highScore: _highScore,
              musicVolume: _musicVolume,
              sfxVolume: _sfxVolume,
              onMusicVolumeChanged: _setMusicVolume,
              onSfxVolumeChanged: _setSfxVolume,
              onRestart: _restart,
              onResume: _togglePause,
              onMenu: _exitToMenu,
            ),
        ],
      ),
    );
  }

  List<Widget> _buildVersusLayer(VersusSession session, double boardWidth) {
    return [
      Positioned(
        left: 2,
        top: 0,
        bottom: 0,
        child: GarbageMeter(pendingLines: _game.pendingGarbageLines),
      ),
      Positioned(
        right: 6,
        top: 6,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SessionScoreChip(session: session),
            const SizedBox(width: 6),
            TransportChip(session: session),
          ],
        ),
      ),
      Positioned(
        right: 6,
        top: 38,
        width: boardWidth * 0.30,
        child: Opacity(
          opacity: 0.7,
          child: OpponentBoardView(session: session),
        ),
      ),
      // Kept mounted briefly into `playing` so the GO burst can finish; the
      // overlay ignores pointers so it never eats the first inputs.
      if (session.phase.value == VersusPhase.countdown || _countdownGoTail)
        CountdownOverlay(
          key: ValueKey('countdown-${session.matchId}'),
          duration: session.countdownDuration,
        ),
    ];
  }

  bool get _versusFinished => switch (widget.versusSession?.phase.value) {
    VersusPhase.won || VersusPhase.lost || VersusPhase.opponentLeft => true,
    _ => false,
  };

  /// Places the end-of-match UI: a right-edge sheet when there is enough
  /// horizontal room beside the board (desktop, phone landscape) so the final
  /// board stays fully visible, or a centered overlay on narrow portrait.
  Widget _wrapWithVersusResult(Widget layout, BoxConstraints constraints) {
    final session = widget.versusSession;
    if (session == null || !_versusFinished) {
      return layout;
    }
    final compact =
        constraints.maxWidth < 760 || constraints.maxHeight < 500;
    final boardWidth = compact
        ? math.min(
            constraints.maxWidth,
            math.max(0.0, constraints.maxHeight - _compactTopBarHeight) *
                _boardAspectRatio,
          )
        : math.min(
            math.max(
              0.0,
              constraints.maxWidth -
                  2 * (_wideSidePanelWidth + _wideSidePanelGap),
            ),
            math.min(constraints.maxHeight, 760.0) * _boardAspectRatio,
          );
    final sideSpace = (constraints.maxWidth - boardWidth) / 2;
    final sheetWidth = math.min(300.0, sideSpace - 12);
    if (sheetWidth >= 220) {
      return Stack(
        children: [
          layout,
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: sheetWidth,
            child: VersusResultSheet(
              key: const ValueKey('versus-result-sheet'),
              session: session,
              onLeave: _exitToMenu,
            ),
          ),
        ],
      );
    }
    return Stack(
      children: [
        layout,
        Positioned.fill(
          child: VersusResultOverlay(
            key: const ValueKey('versus-result-overlay'),
            session: session,
            onLeave: _exitToMenu,
          ),
        ),
      ],
    );
  }
}

class _WideLeftColumn extends StatelessWidget {
  const _WideLeftColumn({
    required this.holdPiece,
    required this.score,
    required this.level,
    required this.lines,
    required this.paused,
    required this.showPause,
    required this.onPause,
    this.pauseFocusable = true,
  });

  final Tetromino? holdPiece;
  final int score;
  final int level;
  final int lines;
  final bool paused;
  final bool showPause;
  final VoidCallback onPause;
  final bool pauseFocusable;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Panel(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _PanelLabel('HOLD'),
              const SizedBox(height: 10),
              Center(
                child: SizedBox.square(
                  dimension: 64,
                  child: holdPiece == null
                      ? const Center(
                          child: Text('-', style: TextStyle(color: _mutedText)),
                        )
                      : CustomPaint(painter: _PiecePreviewPainter(holdPiece!)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _Panel(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Metric(label: 'SCORE', value: score.toString()),
              const SizedBox(height: 12),
              _Metric(label: 'LEVEL', value: level.toString()),
              const SizedBox(height: 12),
              _Metric(label: 'LINES', value: lines.toString()),
            ],
          ),
        ),
        const Spacer(),
        if (showPause)
          Align(
            alignment: Alignment.centerLeft,
            child: _TopControls(
              paused: paused,
              onPause: onPause,
              focusable: pauseFocusable,
            ),
          ),
      ],
    );
  }
}

class _WideNextColumn extends StatelessWidget {
  const _WideNextColumn({required this.pieces});

  final List<Tetromino> pieces;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Panel(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _PanelLabel('NEXT'),
              for (final (index, piece) in pieces.indexed) ...[
                SizedBox(height: index == 0 ? 10 : 16),
                Center(
                  child: SizedBox(
                    width: index == 0 ? 56 : 44,
                    height: index == 0 ? 42 : 32,
                    child: CustomPaint(painter: _PiecePreviewPainter(piece)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _PanelLabel extends StatelessWidget {
  const _PanelLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: _mutedText,
        fontSize: 11,
        fontWeight: FontWeight.w800,
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
    this.showPause = true,
    this.pauseFocusable = true,
  });

  final Tetromino? holdPiece;
  final Tetromino nextPiece;
  final int score;
  final int level;
  final int lines;
  final bool paused;
  final VoidCallback onPause;
  final bool showPause;
  final bool pauseFocusable;

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
            if (showPause) ...[
              const SizedBox(width: 8),
              _TopControls(
                paused: paused,
                framed: false,
                onPause: onPause,
                focusable: pauseFocusable,
              ),
            ],
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
    this.focusable = true,
  });

  final bool paused;
  final VoidCallback onPause;
  final bool framed;

  /// False while a menu overlay covers the HUD, so controller focus
  /// traversal cannot land on the hidden pause button behind it.
  final bool focusable;

  @override
  Widget build(BuildContext context) {
    final controls = ExcludeFocus(
      excluding: !focusable,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ControlButton(
            tooltip: paused ? 'Resume' : 'Pause',
            icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            size: framed ? 44 : 42,
            onPressed: onPause,
          ),
        ],
      ),
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
    this.autofocus = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final double size;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TetrisIconButton(
      icon: icon,
      tooltip: tooltip,
      autofocus: autofocus,
      size: size,
      onPressed: onPressed,
    );
  }
}

class _GameOverlay extends StatelessWidget {
  const _GameOverlay({
    required this.gameOver,
    required this.score,
    required this.highScore,
    required this.musicVolume,
    required this.sfxVolume,
    required this.onMusicVolumeChanged,
    required this.onSfxVolumeChanged,
    required this.onRestart,
    required this.onResume,
    required this.onMenu,
  });

  final bool gameOver;
  final int score;
  final int highScore;
  final double musicVolume;
  final double sfxVolume;
  final ValueChanged<double> onMusicVolumeChanged;
  final ValueChanged<double> onSfxVolumeChanged;
  final VoidCallback onRestart;
  final VoidCallback onResume;
  final VoidCallback onMenu;

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
                SizedBox(
                  width: 250,
                  child: Row(
                    children: [
                      Expanded(
                        child: _Metric(label: 'SCORE', value: score.toString()),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: _Metric(
                          label: 'HIGH SCORE',
                          value: highScore.toString(),
                        ),
                      ),
                    ],
                  ),
                ),
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
                        // Pre-focused so a controller can confirm instantly.
                        autofocus: true,
                        onPressed: onResume,
                      ),
                      const SizedBox(width: 8),
                    ],
                    _ControlButton(
                      tooltip: 'Restart',
                      icon: Icons.restart_alt_rounded,
                      autofocus: gameOver,
                      onPressed: onRestart,
                    ),
                    const SizedBox(width: 8),
                    _ControlButton(
                      tooltip: 'Menu',
                      icon: Icons.home_rounded,
                      onPressed: onMenu,
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
          // The gamepad UI navigator dispatches DirectionalFocusIntents at
          // the focused widget; a focused slider consumes left/right as a
          // one-division adjustment and forwards up/down to normal focus
          // traversal (Actions resolution stops at the first matching type,
          // so this action must handle every direction itself).
          child: Actions(
            actions: <Type, Action<Intent>>{
              DirectionalFocusIntent: _SliderGamepadAdjustAction(
                value: value,
                max: max,
                onChanged: onChanged,
              ),
            },
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
        ),
      ],
    );
  }
}

class _SliderGamepadAdjustAction extends Action<DirectionalFocusIntent> {
  _SliderGamepadAdjustAction({
    required this.value,
    required this.max,
    required this.onChanged,
  });

  final double value;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  void invoke(DirectionalFocusIntent intent) {
    switch (intent.direction) {
      case TraversalDirection.left || TraversalDirection.right:
        // One slider division per press, matching the arrow-key step.
        final step = max / (max * 20).round();
        final delta = intent.direction == TraversalDirection.right
            ? step
            : -step;
        onChanged((value + delta).clamp(0.0, max).toDouble());
      case TraversalDirection.up || TraversalDirection.down:
        FocusManager.instance.primaryFocus?.focusInDirection(intent.direction);
    }
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

/// One puff of landing dust; positions are derived from age so no per-frame
/// mutation is needed.
class _DustParticle {
  const _DustParticle({
    required this.cellX,
    required this.cellY,
    required this.vx,
    required this.vy,
    required this.radius,
    required this.tint,
  });

  final double cellX;
  final double cellY;

  /// Velocities in cells/second; radius in cells.
  final double vx;
  final double vy;
  final double radius;
  final Color tint;
}

class _DustBurst {
  _DustBurst({required this.spawnedAt, required this.particles});

  final DateTime spawnedAt;
  final List<_DustParticle> particles;
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
    this.dustBursts = const [],
  });

  final TetrisGame game;
  final double activeHorizontalOffset;
  final Offset boardImpactOffset;
  final LineClearAnimationSnapshot? lineClearSnapshot;
  final double lineClearProgress;
  final ui.FragmentShader? lineClearSnapShader;
  final ui.Image? lineClearSnapImage;
  final List<_DustBurst> dustBursts;

  void _drawDust(Canvas canvas, Offset visibleOrigin, double cellSize) {
    if (dustBursts.isEmpty) {
      return;
    }
    final now = DateTime.now();
    final lifetimeSeconds = _dustLifetime.inMilliseconds / 1000.0;
    final paint = Paint();
    for (final burst in dustBursts) {
      final t =
          (now.difference(burst.spawnedAt).inMicroseconds /
                  _dustLifetime.inMicroseconds)
              .clamp(0.0, 1.0);
      if (t >= 1) {
        continue;
      }
      final seconds = t * lifetimeSeconds;
      final fade = (1 - t) * (1 - t);
      for (final particle in burst.particles) {
        final x = particle.cellX + particle.vx * seconds;
        final y = particle.cellY +
            particle.vy * seconds +
            0.5 * _dustGravityCellsPerSecSq * seconds * seconds;
        paint.color = Color.lerp(particle.tint, const Color(0xFFEDEFF2), 0.55)!
            .withValues(alpha: 0.55 * fade);
        canvas.drawCircle(
          visibleOrigin + Offset(x * cellSize, y * cellSize),
          particle.radius * cellSize * (1 - 0.35 * t),
          paint,
        );
      }
    }
  }

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
      final ghostCells = <MinoCell>[];
      for (final cell in game.ghostCells) {
        final y = cell.y - TetrisGame.bufferRows;
        if (y >= 0 && y < TetrisGame.visibleRows) {
          ghostCells.add(MinoCell(x: cell.x, y: y, type: cell.type));
        }
      }
      _drawGhostPiece(
        canvas,
        visibleOrigin,
        cellSize,
        ghostCells,
        activeHorizontalOffset,
      );
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
    _drawDust(canvas, visibleOrigin, cellSize);
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
      final ghostCells = <MinoCell>[];
      for (final cell in game.ghostCells) {
        if (cell.y == TetrisGame.bufferRows - 1) {
          ghostCells.add(MinoCell(x: cell.x, y: 0, type: cell.type));
        }
      }
      _drawGhostPiece(
        canvas,
        hiddenOrigin,
        cellSize,
        ghostCells,
        activeHorizontalOffset,
      );
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
  shader.setFloat(6, tetrisLineClearSnapParticleHdrBoost);
  shader.setFloat(7, tetrisLineClearSnapParticleGlowBoost);
  shader.setFloat(8, size.width);
  shader.setFloat(9, size.height);
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

Rect _cellRect(Offset origin, double cellSize, num x, num y) =>
    cellRect(origin, cellSize, x, y);

void _drawMino(
  Canvas canvas,
  Offset origin,
  double cellSize,
  num x,
  num y,
  Tetromino type,
) => drawMino(canvas, origin, cellSize, x, y, type);

void _drawGhostPiece(
  Canvas canvas,
  Offset origin,
  double cellSize,
  List<MinoCell> cells,
  double horizontalOffset,
) {
  if (cells.isEmpty) {
    return;
  }

  for (final cell in cells) {
    _drawGhost(
      canvas,
      origin,
      cellSize,
      cell.x + horizontalOffset,
      cell.y,
      cell.type,
    );
  }
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
      ..strokeWidth = math.max(4.8, cellSize * 0.13)
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, cellSize * 0.32)
      ..color = outlineColor.withValues(alpha: 0.065),
  );
  canvas.drawRRect(
    rrect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(3.4, cellSize * 0.08)
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, cellSize * 0.18)
      ..color = outlineColor.withValues(alpha: 0.12),
  );
  canvas.drawRRect(
    rrect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2.2, cellSize * 0.052)
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, cellSize * 0.045)
      ..color = outlineColor.withValues(alpha: 0.28),
  );
  canvas.drawRRect(
    rrect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.8, cellSize * 0.04)
      ..strokeJoin = StrokeJoin.round
      ..color = outlineColor.withValues(alpha: 0.92),
  );
}

@visibleForTesting
ui.Color tetrisGhostHdrOutlineColorFor(Tetromino type) {
  return switch (type) {
    Tetromino.i => const ui.Color.from(
      alpha: 1,
      red: 0.28,
      green: 1.85,
      blue: 3.85,
      colorSpace: ui.ColorSpace.extendedSRGB,
    ),
    Tetromino.j => const ui.Color.from(
      alpha: 1,
      red: 0.32,
      green: 0.82,
      blue: 3.75,
      colorSpace: ui.ColorSpace.extendedSRGB,
    ),
    Tetromino.l => const ui.Color.from(
      alpha: 1,
      red: 3.65,
      green: 1.28,
      blue: 0.28,
      colorSpace: ui.ColorSpace.extendedSRGB,
    ),
    Tetromino.o => const ui.Color.from(
      alpha: 1,
      red: 3.2,
      green: 2.35,
      blue: 0.32,
      colorSpace: ui.ColorSpace.extendedSRGB,
    ),
    Tetromino.s => const ui.Color.from(
      alpha: 1,
      red: 0.68,
      green: 3.35,
      blue: 0.86,
      colorSpace: ui.ColorSpace.extendedSRGB,
    ),
    Tetromino.z => const ui.Color.from(
      alpha: 1,
      red: 3.45,
      green: 0.52,
      blue: 0.64,
      colorSpace: ui.ColorSpace.extendedSRGB,
    ),
    Tetromino.t => const ui.Color.from(
      alpha: 1,
      red: 2.75,
      green: 0.55,
      blue: 3.55,
      colorSpace: ui.ColorSpace.extendedSRGB,
    ),
    // Garbage never becomes an active piece, so it never gets a ghost; a
    // neutral gray keeps the switch exhaustive.
    Tetromino.garbage => const ui.Color.from(
      alpha: 1,
      red: 0.9,
      green: 0.95,
      blue: 1.05,
      colorSpace: ui.ColorSpace.extendedSRGB,
    ),
  };
}

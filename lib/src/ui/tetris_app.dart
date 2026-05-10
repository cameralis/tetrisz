import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../game/tetris_game.dart';
import '../game/tetromino.dart';

const _background = Color(0xFF101114);
const _panel = Color(0xFF1B1D22);
const _text = Color(0xFFF3F6FA);
const _mutedText = Color(0xFFA5ADBA);
const _gridLine = Color(0x12FFFFFF);
const _boardBack = Color(0xFF07080A);
const _bufferSliverRows = 0.25;
const _compactTopBarHeight = 54.0;
const _maxTickDelta = Duration(milliseconds: 250);
const _snapBackDuration = Duration(milliseconds: 120);
const _snapCommitDuration = Duration(milliseconds: 140);
const _horizontalIntentFraction = 0.35;
const _minHorizontalIntentDistance = 20.0;
const _snapPreviewFraction = 0.25;
const _snapCommitFraction = 0.7;
const _snapBlockedFraction = 0.22;
const _boardAspectRatio =
    TetrisGame.width / (TetrisGame.visibleRows + _bufferSliverRows);

class TetrisApp extends StatelessWidget {
  const TetrisApp({super.key, this.enableAudio = true, this.game});

  final bool enableAudio;
  final TetrisGame? game;

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
      home: TetrisGamePage(enableAudio: enableAudio, game: game),
    );
  }
}

class TetrisGamePage extends StatefulWidget {
  const TetrisGamePage({super.key, this.enableAudio = true, this.game});

  final bool enableAudio;
  final TetrisGame? game;

  @override
  State<TetrisGamePage> createState() => _TetrisGamePageState();
}

class _TetrisGamePageState extends State<TetrisGamePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final TetrisGame _game;
  late final Ticker _ticker;
  late final AnimationController _snapBackController;
  AudioPlayer? _musicPlayer;
  Timer? _softDropTimer;

  Duration _lastFrameElapsed = Duration.zero;
  int? _dragPointer;
  double _dragX = 0;
  double _dragY = 0;
  double _snapDragX = 0;
  double _snapVisualOffsetCells = 0;
  Animation<double> _snapBackAnimation = const AlwaysStoppedAnimation(0);
  bool _horizontalDragLocked = false;
  bool _snapCommitAnimating = false;
  bool _musicEnabled = true;
  bool _musicStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _game = widget.game ?? TetrisGame();
    _ticker = createTicker(_onFrame)..start();
    _snapBackController =
        AnimationController(vsync: this, duration: _snapBackDuration)
          ..addListener(() {
            if (mounted) {
              setState(() {
                _snapVisualOffsetCells = _snapBackAnimation.value;
              });
            }
          });
    if (widget.enableAudio) {
      _musicPlayer = AudioPlayer();
      unawaited(_playMusic());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _softDropTimer?.cancel();
    _snapBackController.dispose();
    _ticker.dispose();
    unawaited(_musicPlayer?.dispose() ?? Future.value());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_musicEnabled && !_game.paused && !_game.gameOver) {
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
        _game.gameOver) {
      return;
    }

    _game.tick(delta);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _playMusic() async {
    if (!widget.enableAudio || !_musicEnabled) {
      return;
    }

    final player = _musicPlayer;
    if (player == null) {
      return;
    }

    try {
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setVolume(0.42);
      if (_musicStarted) {
        await player.resume();
      } else {
        await player.play(AssetSource('audio/korobeiniki.m4a'));
        _musicStarted = true;
      }
    } catch (_) {
      // Web and mobile platforms can block audio until a user gesture.
    }
  }

  void _runAction(VoidCallback action) {
    unawaited(_playMusic());
    setState(action);
  }

  void _restart() {
    _runAction(() {
      _game.restart();
    });
  }

  void _togglePause() {
    setState(_game.togglePause);
    if (_game.paused) {
      unawaited(_musicPlayer?.pause() ?? Future.value());
    } else {
      unawaited(_playMusic());
    }
  }

  void _toggleMusic() {
    setState(() {
      _musicEnabled = !_musicEnabled;
    });
    if (_musicEnabled) {
      unawaited(_playMusic());
    } else {
      unawaited(_musicPlayer?.pause() ?? Future.value());
    }
  }

  void _startSoftDrop() {
    _softDropTimer?.cancel();
    _runAction(_game.softDropStep);
    _softDropTimer = Timer.periodic(const Duration(milliseconds: 45), (_) {
      if (!mounted) {
        return;
      }
      _runAction(_game.softDropStep);
    });
  }

  void _stopSoftDrop() {
    _softDropTimer?.cancel();
    _softDropTimer = null;
  }

  void _handlePointerDown(PointerDownEvent event) {
    _dragPointer = event.pointer;
    _snapBackController.stop();
    _dragX = 0;
    _dragY = 0;
    _snapDragX = 0;
    _horizontalDragLocked = false;
    _snapCommitAnimating = false;
    unawaited(_playMusic());
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

    final commitAnimating =
        _snapCommitAnimating && _snapBackController.isAnimating;
    var committedColumns = 0;
    var targetOffset = _snapVisualOffsetCells;
    final continuityOffset = _snapVisualOffsetCells;
    if (!commitAnimating) {
      _snapBackController.stop();
    }
    setState(() {
      while (_snapDragX.abs() >= snapDistance) {
        final direction = _snapDragX.sign.toInt();
        if (!_canMoveHorizontally(direction)) {
          break;
        }
        _moveHorizontally(direction);
        _snapDragX -= snapDistance * direction;
        committedColumns += direction;
      }

      final direction = _snapDragX.sign.toInt();
      final blocked = direction != 0 && !_canMoveHorizontally(direction);
      if (blocked) {
        targetOffset = _snapBlockedFraction * direction;
        _snapDragX = 0;
      } else {
        targetOffset = _snapPreviewOffsetForDrag(_snapDragX, snapDistance);
      }

      if (committedColumns == 0) {
        if (!commitAnimating) {
          _snapVisualOffsetCells = targetOffset;
        }
      } else {
        _snapVisualOffsetCells = continuityOffset.abs() < 0.001
            ? (committedColumns.sign * (_snapPreviewFraction - 1)).toDouble()
            : continuityOffset - committedColumns;
      }
    });

    if (committedColumns != 0) {
      _animateSnapVisualOffsetTo(
        targetOffset,
        _snapCommitDuration,
        commit: true,
      );
    } else if (commitAnimating) {
      _animateSnapVisualOffsetTo(
        targetOffset,
        _snapCommitDuration,
        commit: true,
      );
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
    _horizontalDragLocked = false;
    _snapCommitAnimating = false;
    _dragPointer = null;
  }

  void _finishDrag() {
    const verticalThreshold = 48.0;
    if (!_horizontalDragLocked &&
        _dragY.abs() >= verticalThreshold &&
        _dragY.abs() > _dragX.abs()) {
      _snapBackController.stop();
      _snapVisualOffsetCells = 0;
      if (_dragY < 0) {
        _runAction(_game.hold);
      } else {
        _runAction(_game.hardDrop);
      }
    } else {
      _animateSnapBack();
    }
    _dragX = 0;
    _dragY = 0;
    _snapDragX = 0;
    _horizontalDragLocked = false;
    _snapCommitAnimating = false;
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

  void _animateSnapBack() {
    _animateSnapVisualOffsetTo(0, _snapBackDuration);
  }

  void _animateSnapVisualOffsetTo(
    double target,
    Duration duration, {
    bool commit = false,
  }) {
    _snapBackController.stop();
    _snapCommitAnimating = commit;
    if ((_snapVisualOffsetCells - target).abs() < 0.001) {
      _snapVisualOffsetCells = target;
      _snapCommitAnimating = false;
      return;
    }

    _snapBackController.duration = duration;
    _snapBackAnimation =
        Tween<double>(begin: _snapVisualOffsetCells, end: target).animate(
          CurvedAnimation(
            parent: _snapBackController,
            curve: Curves.easeOutCubic,
          ),
        );
    _snapBackController.forward(from: 0);
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

            return Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: _buildWideLayout(constraints),
                ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: _TopControls(
                    paused: _game.paused,
                    musicEnabled: _musicEnabled,
                    onPause: _togglePause,
                    onMusic: _toggleMusic,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildWideLayout(BoxConstraints constraints) {
    final boardHeight = math.min(constraints.maxHeight - 24, 760.0);
    final boardWidth = boardHeight * _boardAspectRatio;

    return Center(
      child: SizedBox(
        height: boardHeight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 172, child: _buildLeftRail()),
            const SizedBox(width: 14),
            _buildBoard(boardWidth, boardHeight),
            const SizedBox(width: 14),
            SizedBox(width: 188, child: _buildRightRail()),
          ],
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
              musicEnabled: _musicEnabled,
              onPause: _togglePause,
              onMusic: _toggleMusic,
            ),
          ),
          Expanded(child: Center(child: _buildBoard(boardWidth, boardHeight))),
        ],
      ),
    );
  }

  Widget _buildLeftRail() {
    return Column(
      children: [
        _TitlePanel(score: _game.score, level: _game.level, lines: _game.lines),
        const SizedBox(height: 12),
        _PiecePanel(title: 'HOLD', piece: _game.holdPiece),
        const SizedBox(height: 12),
        Expanded(
          child: _StatsPanel(
            score: _game.score,
            level: _game.level,
            lines: _game.lines,
            combo: _game.combo,
          ),
        ),
      ],
    );
  }

  Widget _buildRightRail() {
    return Column(
      children: [
        Expanded(child: _NextPanel(queue: _game.nextQueue)),
        const SizedBox(height: 12),
        _ActionPanel(
          onRestart: _restart,
          onRotateLeft: () => _runAction(_game.rotateCounterClockwise),
          onRotateRight: () => _runAction(_game.rotateClockwise),
          onHold: () => _runAction(_game.hold),
          onDrop: () => _runAction(_game.hardDrop),
        ),
      ],
    );
  }

  Widget _buildBoard(double width, double height) {
    final cellSize = math.min(
      width / TetrisGame.width,
      height / (TetrisGame.visibleRows + _bufferSliverRows),
    );

    return SizedBox(
      key: const ValueKey('tetris-board'),
      width: width,
      height: height,
      child: LayoutBuilder(
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
                if (details.localPosition.dx > constraints.maxWidth / 2) {
                  _runAction(_game.rotateClockwise);
                } else {
                  _runAction(_game.rotateCounterClockwise);
                }
              },
              onLongPressStart: (_) {
                if (!_horizontalDragLocked) {
                  _startSoftDrop();
                }
              },
              onLongPressEnd: (_) => _stopSoftDrop(),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RepaintBoundary(
                    child: CustomPaint(
                      painter: _BoardPainter(
                        game: _game,
                        activeHorizontalOffset: _snapVisualOffsetCells,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                  if (_game.gameOver || _game.paused)
                    _GameOverlay(
                      gameOver: _game.gameOver,
                      score: _game.score,
                      onRestart: _restart,
                      onResume: _togglePause,
                    ),
                ],
              ),
            ),
          );
        },
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
    required this.musicEnabled,
    required this.onPause,
    required this.onMusic,
  });

  final Tetromino? holdPiece;
  final Tetromino nextPiece;
  final int score;
  final int level;
  final int lines;
  final bool paused;
  final bool musicEnabled;
  final VoidCallback onPause;
  final VoidCallback onMusic;

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
            _TopControls(
              paused: paused,
              musicEnabled: musicEnabled,
              framed: false,
              onPause: onPause,
              onMusic: onMusic,
            ),
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
    required this.musicEnabled,
    required this.onPause,
    required this.onMusic,
    this.framed = true,
  });

  final bool paused;
  final bool musicEnabled;
  final VoidCallback onPause;
  final VoidCallback onMusic;
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
        const SizedBox(width: 8),
        _ControlButton(
          tooltip: musicEnabled ? 'Mute' : 'Music',
          icon: musicEnabled
              ? Icons.volume_up_rounded
              : Icons.volume_off_rounded,
          size: framed ? 44 : 42,
          onPressed: onMusic,
        ),
      ],
    );

    if (!framed) {
      return controls;
    }

    return _Panel(child: controls);
  }
}

class _TitlePanel extends StatelessWidget {
  const _TitlePanel({
    required this.score,
    required this.level,
    required this.lines,
  });

  final int score;
  final int level;
  final int lines;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'TETRIS',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w900,
              height: 0.9,
            ),
          ),
          const SizedBox(height: 14),
          _Metric(label: 'SCORE', value: score.toString()),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _Metric(label: 'LEVEL', value: level.toString()),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Metric(label: 'LINES', value: lines.toString()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatsPanel extends StatelessWidget {
  const _StatsPanel({
    required this.score,
    required this.level,
    required this.lines,
    required this.combo,
  });

  final int score;
  final int level;
  final int lines;
  final int combo;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Metric(label: 'SCORE', value: score.toString()),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _Metric(label: 'LEVEL', value: level.toString()),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Metric(label: 'LINES', value: lines.toString()),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _Metric(label: 'COMBO', value: math.max(combo, 0).toString()),
        ],
      ),
    );
  }
}

class _PiecePanel extends StatelessWidget {
  const _PiecePanel({required this.title, required this.piece});

  final String title;
  final Tetromino? piece;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelTitle(title),
          const SizedBox(height: 12),
          SizedBox.square(
            dimension: 96,
            child: piece == null
                ? const Center(
                    child: Text(
                      '-',
                      style: TextStyle(fontSize: 26, color: _mutedText),
                    ),
                  )
                : CustomPaint(painter: _PiecePreviewPainter(piece!)),
          ),
        ],
      ),
    );
  }
}

class _NextPanel extends StatelessWidget {
  const _NextPanel({required this.queue});

  final List<Tetromino> queue;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final bounded = constraints.hasBoundedHeight;
          final gaps = math.max(0, queue.length - 1) * 6.0;
          const headerHeight = 30.0;
          final previewHeight = bounded && queue.isNotEmpty
              ? ((constraints.maxHeight - headerHeight - gaps) / queue.length)
                    .clamp(36.0, 54.0)
              : 48.0;

          return Column(
            mainAxisSize: bounded ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _PanelTitle('NEXT'),
              const SizedBox(height: 10),
              for (var index = 0; index < queue.length; index += 1) ...[
                SizedBox(
                  height: previewHeight,
                  child: CustomPaint(
                    painter: _PiecePreviewPainter(queue[index]),
                  ),
                ),
                if (index != queue.length - 1) const SizedBox(height: 6),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ActionPanel extends StatelessWidget {
  const _ActionPanel({
    required this.onRestart,
    required this.onRotateLeft,
    required this.onRotateRight,
    required this.onHold,
    required this.onDrop,
  });

  final VoidCallback onRestart;
  final VoidCallback onRotateLeft;
  final VoidCallback onRotateRight;
  final VoidCallback onHold;
  final VoidCallback onDrop;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          _ControlButton(
            tooltip: 'Rotate counter-clockwise',
            icon: Icons.rotate_left_rounded,
            onPressed: onRotateLeft,
          ),
          _ControlButton(
            tooltip: 'Rotate clockwise',
            icon: Icons.rotate_right_rounded,
            onPressed: onRotateRight,
          ),
          _ControlButton(
            tooltip: 'Hold',
            icon: Icons.swap_vert_rounded,
            onPressed: onHold,
          ),
          _ControlButton(
            tooltip: 'Hard drop',
            icon: Icons.keyboard_double_arrow_down_rounded,
            onPressed: onDrop,
          ),
          _ControlButton(
            tooltip: 'Restart',
            icon: Icons.restart_alt_rounded,
            onPressed: onRestart,
          ),
        ],
      ),
    );
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
    required this.onRestart,
    required this.onResume,
  });

  final bool gameOver;
  final int score;
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

class _PanelTitle extends StatelessWidget {
  const _PanelTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: _mutedText,
        fontSize: 12,
        fontWeight: FontWeight.w800,
      ),
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
  });

  final TetrisGame game;
  final double activeHorizontalOffset;

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
        final type = game.visibleCellAt(x, y);
        if (type != null) {
          _drawMino(canvas, visibleOrigin, cellSize, x, y, type);
        }
      }
    }

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
      final type = game.cellAt(x, TetrisGame.bufferRows - 1);
      if (type != null) {
        _drawMino(canvas, hiddenOrigin, cellSize, x, 0, type);
      }
    }

    void drawSliverCell(MinoCell cell, void Function() draw) {
      if (cell.y == TetrisGame.bufferRows - 1) {
        draw();
      }
    }

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
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BoardPainter oldDelegate) => true;
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

Rect _cellRect(Offset origin, double cellSize, num x, int y) {
  return Rect.fromLTWH(
    origin.dx + x.toDouble() * cellSize,
    origin.dy + y * cellSize,
    cellSize,
    cellSize,
  );
}

void _drawMino(
  Canvas canvas,
  Offset origin,
  double cellSize,
  num x,
  int y,
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
  int y,
  Tetromino type,
) {
  final rect = _cellRect(origin, cellSize, x, y).deflate(cellSize * 0.12);
  canvas.drawRRect(
    RRect.fromRectAndRadius(rect, Radius.circular(cellSize * 0.12)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.4, cellSize * 0.07)
      ..color = _colorFor(type).withValues(alpha: 0.45),
  );
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

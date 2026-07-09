import 'package:flutter/material.dart';

import '../input/gamepad_service.dart';
import 'account_page.dart';
import 'components.dart';
import 'diagnostics_page.dart';
import 'friends_page.dart';
import 'leaderboard_page.dart';
import 'lobby_page.dart';
import 'tetris_app.dart';
import 'theme.dart';

/// How long the ambient falling-blocks background stays in motion after the
/// page builds. Bounded (rather than repeating forever) so widget tests can
/// settle; menus are typically passed through in seconds anyway.
const _backgroundRunTime = Duration(seconds: 45);
const _entranceDuration = Duration(milliseconds: 950);

/// Entry menu: solo play (with the existing resume-from-disk behavior),
/// versus lobby, and diagnostics — over an ambient rain of heavy blocks.
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    this.enableAudio = true,
    this.musicPlayer,
    this.soundEffects,
    this.haptics,
    this.gamepad,
  });

  final bool enableAudio;
  final TetrisMusicPlayer? musicPlayer;
  final TetrisSoundEffects? soundEffects;
  final TetrisHaptics? haptics;
  final GamepadService? gamepad;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: _entranceDuration,
  )..forward();
  late final AnimationController _background = AnimationController(
    vsync: this,
    duration: _backgroundRunTime,
  )..forward();

  @override
  void dispose() {
    _entrance.dispose();
    _background.dispose();
    super.dispose();
  }

  /// Item [index] drops in with a stagger: slight fall + fade.
  Widget _staggered(int index, Widget child) {
    final animation = CurvedAnimation(
      parent: _entrance,
      curve: Interval(
        (0.3 + index * 0.09).clamp(0.0, 0.95),
        (0.62 + index * 0.09).clamp(0.0, 1.0),
        curve: Curves.easeOutCubic,
      ),
    );
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) => Opacity(
        opacity: animation.value,
        child: Transform.translate(
          offset: Offset(0, -22 * (1 - animation.value)),
          child: child,
        ),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: CustomPaint(
              painter: _FallingBlocksPainter(repaint: _background),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: TetrisIconButton(
                  key: const ValueKey('home-account'),
                  icon: Icons.person_rounded,
                  size: 40,
                  tooltip: 'Account',
                  color: TetrisColors.mutedText,
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AccountPage(),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _TitleSlam(entrance: _entrance),
                      const SizedBox(height: 8),
                      _staggered(
                        0,
                        const Text(
                          '1v1 · garbage battle · online',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: TetrisColors.mutedText,
                            fontSize: 12,
                            letterSpacing: 1.1,
                          ),
                        ),
                      ),
                      const SizedBox(height: 38),
                      _staggered(
                        1,
                        TetrisButton(
                          key: const ValueKey('home-play'),
                          // Pre-focused so a controller can start with one
                          // press.
                          autofocus: true,
                          variant: TetrisButtonVariant.primary,
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => TetrisGamePage(
                                enableAudio: widget.enableAudio,
                                musicPlayer: widget.musicPlayer,
                                soundEffects: widget.soundEffects,
                                haptics: widget.haptics,
                                gamepad: widget.gamepad,
                              ),
                            ),
                          ),
                          child: const Text('Play'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _staggered(
                        2,
                        TetrisButton(
                          key: const ValueKey('home-versus'),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => LobbyPage(
                                enableAudio: widget.enableAudio,
                                musicPlayer: widget.musicPlayer,
                                soundEffects: widget.soundEffects,
                                haptics: widget.haptics,
                                gamepad: widget.gamepad,
                              ),
                            ),
                          ),
                          child: const Text('1v1 Versus'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _staggered(
                        3,
                        TetrisButton(
                          key: const ValueKey('home-leaderboard'),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const LeaderboardPage(),
                            ),
                          ),
                          child: const Text('Leaderboard'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _staggered(
                        4,
                        TetrisButton(
                          key: const ValueKey('home-friends'),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const FriendsPage(),
                            ),
                          ),
                          child: const Text('Friends'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _staggered(
                        5,
                        TetrisButton(
                          key: const ValueKey('home-diagnostics'),
                          variant: TetrisButtonVariant.ghost,
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  DiagnosticsPage(gamepad: widget.gamepad),
                            ),
                          ),
                          child: const Text('Settings & Diagnostics'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 'TETRIS' with each letter slamming down like a dropped piece.
class _TitleSlam extends StatelessWidget {
  const _TitleSlam({required this.entrance});

  final AnimationController entrance;

  static const _letters = ['T', 'E', 'T', 'R', 'I', 'S'];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: entrance,
      builder: (context, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final (i, letter) in _letters.indexed)
              Builder(
                builder: (context) {
                  final t = CurvedAnimation(
                    parent: entrance,
                    curve: Interval(
                      i * 0.055,
                      i * 0.055 + 0.3,
                      curve: Curves.easeIn,
                    ),
                  ).value;
                  // Fall in, then a tiny settle bounce right after landing.
                  final settle = CurvedAnimation(
                    parent: entrance,
                    curve: Interval(
                      (i * 0.055 + 0.3).clamp(0.0, 1.0),
                      (i * 0.055 + 0.45).clamp(0.0, 1.0),
                      curve: Curves.easeOutBack,
                    ),
                  ).value;
                  final dy = -72.0 * (1 - t) + 3.0 * (1 - settle);
                  return Transform.translate(
                    offset: Offset(0, dy),
                    child: Opacity(
                      opacity: t.clamp(0.0, 1.0),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          letter,
                          style: TextStyle(
                            color: TetrisColors.text,
                            fontSize: 44,
                            fontWeight: FontWeight.w800,
                            shadows: [
                              Shadow(
                                color: TetrisColors.accent.withValues(
                                  alpha: 0.35 * settle,
                                ),
                                blurRadius: 18,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
  }
}

/// Ambient rain of dim tetrominoes: pieces accelerate down their lane, land
/// on an invisible floor, rest for a beat and fade; lanes loop on their own
/// phase. Driven purely through [repaint] — no widget rebuilds.
class _FallingBlocksPainter extends CustomPainter {
  _FallingBlocksPainter({required Animation<double> repaint})
    : _time = repaint,
      super(repaint: repaint);

  final Animation<double> _time;

  // Cell offsets per shape (I, O, T, L, S).
  static const _shapes = [
    [(0, 0), (1, 0), (2, 0), (3, 0)],
    [(0, 0), (1, 0), (0, 1), (1, 1)],
    [(0, 0), (1, 0), (2, 0), (1, 1)],
    [(0, 0), (0, 1), (1, 1), (2, 1)],
    [(1, 0), (2, 0), (0, 1), (1, 1)],
  ];
  static const _tints = [
    Color(0xFF44D7FF),
    Color(0xFFF7D046),
    Color(0xFFB868F0),
    Color(0xFFF79E45),
    Color(0xFF58D957),
  ];
  static const _pieceCount = 11;

  @override
  void paint(Canvas canvas, Size size) {
    final seconds = _time.value * _backgroundRunTime.inSeconds;
    final cell = size.width / 26;
    final paint = Paint();
    for (var i = 0; i < _pieceCount; i += 1) {
      // Deterministic lane, phase, and cadence per piece index.
      final lane = (i * 7 + 2) % 24;
      final period = 2.6 + (i % 5) * 0.7;
      final phase = (seconds / period + i * 0.37) % 1.0;
      final shape = _shapes[i % _shapes.length];
      final floorY = size.height * (0.72 + ((i * 13) % 7) * 0.04);

      // Accelerating fall for the first 70% of the cycle, then rest + fade.
      final falling = phase < 0.7;
      final fallT = falling ? phase / 0.7 : 1.0;
      const spawnOffset = 4.0;
      final y = -spawnOffset * cell +
          (floorY + spawnOffset * cell) * Curves.easeIn.transform(fallT);
      final restT = falling ? 0.0 : (phase - 0.7) / 0.3;
      final alpha = falling
          ? 0.13
          : 0.13 * (1 - Curves.easeIn.transform(restT));

      paint.color = _tints[i % _tints.length].withValues(alpha: alpha);
      for (final (dx, dy) in shape) {
        final rect = Rect.fromLTWH(
          lane * cell + dx * cell,
          y + dy * cell,
          cell - 2,
          cell - 2,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(cell * 0.18)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FallingBlocksPainter oldDelegate) => false;
}

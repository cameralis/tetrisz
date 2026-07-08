import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../game/tetris_game.dart';
import '../net/match_transport.dart';
import '../net/protocol.dart';
import '../net/versus_session.dart';
import 'board_painting.dart';
import 'components.dart';
import 'theme.dart';
import 'ui_sounds.dart';

const _panelColor = TetrisColors.panel;
const _textColor = TetrisColors.text;
const _mutedTextColor = TetrisColors.mutedText;
const _accentColor = TetrisColors.accent;
const _garbageColor = TetrisColors.danger;

/// Live mirror of the opponent's board, fed by throttled snapshots.
class OpponentBoardView extends StatelessWidget {
  const OpponentBoardView({super.key, required this.session});

  final VersusSession session;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<OpponentSnapshot?>(
      valueListenable: session.opponent,
      builder: (context, snapshot, _) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: _panelColor.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'OPPONENT',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _mutedTextColor,
                          fontSize: 9,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if ((snapshot?.pendingGarbage ?? 0) > 0)
                      Text(
                        '+${snapshot!.pendingGarbage}',
                        style: const TextStyle(
                          color: _garbageColor,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                AspectRatio(
                  aspectRatio: TetrisGame.width / TetrisGame.visibleRows,
                  child: CustomPaint(
                    painter: OpponentBoardPainter(snapshot: snapshot),
                    size: Size.infinite,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${snapshot?.score ?? 0}',
                  style: const TextStyle(
                    color: _textColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

@visibleForTesting
class OpponentBoardPainter extends CustomPainter {
  OpponentBoardPainter({required this.snapshot});

  final OpponentSnapshot? snapshot;

  @override
  void paint(Canvas canvas, Size size) {
    final cellSize = size.width / TetrisGame.width;
    final backdrop = Paint()..color = const Color(0xFF0B0C0F);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4)),
      backdrop,
    );

    final data = snapshot;
    if (data == null) {
      return;
    }

    const origin = Offset.zero;
    for (var y = 0; y < TetrisGame.visibleRows; y += 1) {
      for (var x = 0; x < TetrisGame.width; x += 1) {
        final cell = data.visibleCellAt(x, y);
        if (cell != null) {
          drawMino(canvas, origin, cellSize, x, y, cell);
        }
      }
    }

    final active = data.active;
    if (active != null) {
      final piece = active.toActivePiece();
      for (final cell in piece.cells) {
        final visibleY = cell.y - TetrisGame.bufferRows;
        if (visibleY >= 0 && visibleY < TetrisGame.visibleRows) {
          drawMino(canvas, origin, cellSize, cell.x, visibleY, cell.type);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant OpponentBoardPainter oldDelegate) =>
      oldDelegate.snapshot != snapshot;
}

/// Thin vertical bar showing garbage lines waiting to hit the local board.
class GarbageMeter extends StatelessWidget {
  const GarbageMeter({super.key, required this.pendingLines});

  final int pendingLines;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GarbageMeterPainter(pendingLines: pendingLines),
      size: const Size(6, double.infinity),
    );
  }
}

class _GarbageMeterPainter extends CustomPainter {
  _GarbageMeterPainter({required this.pendingLines});

  final int pendingLines;

  @override
  void paint(Canvas canvas, Size size) {
    if (pendingLines <= 0) {
      return;
    }
    final segmentHeight = size.height / TetrisGame.visibleRows;
    final paint = Paint()..color = _garbageColor;
    final count = pendingLines.clamp(0, TetrisGame.visibleRows);
    for (var i = 0; i < count; i += 1) {
      final top = size.height - (i + 1) * segmentHeight;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, top + 1, size.width, segmentHeight - 2),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GarbageMeterPainter oldDelegate) =>
      oldDelegate.pendingLines != pendingLines;
}

/// "P2P · 23 ms" / "RELAY · 61 ms" indicator.
class TransportChip extends StatelessWidget {
  const TransportChip({super.key, required this.session});

  final VersusSession session;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TransportKind>(
      valueListenable: session.transportLayer.active,
      builder: (context, kind, _) {
        return ValueListenableBuilder<Duration?>(
          valueListenable: session.room.rtt,
          builder: (context, rtt, _) {
            final isP2p = kind == TransportKind.p2p;
            final label = StringBuffer(isP2p ? 'P2P' : 'RELAY');
            if (rtt != null) {
              label.write(' · ${rtt.inMilliseconds} ms');
            }
            return DecoratedBox(
              decoration: BoxDecoration(
                color: _panelColor.withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isP2p ? const Color(0xFF58D957) : _accentColor,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      label.toString(),
                      style: const TextStyle(
                        color: _textColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// "W 2 · L 1" chip: this room's session tally across rematches. Hidden
/// until the first match ends.
class SessionScoreChip extends StatelessWidget {
  const SessionScoreChip({super.key, required this.session});

  final VersusSession session;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([session.wins, session.losses]),
      builder: (context, _) {
        final wins = session.wins.value;
        final losses = session.losses.value;
        if (wins == 0 && losses == 0) {
          return const SizedBox.shrink();
        }
        return DecoratedBox(
          decoration: BoxDecoration(
            color: _panelColor.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'W $wins',
                    style: const TextStyle(color: Color(0xFF58D957)),
                  ),
                  const TextSpan(
                    text: ' · ',
                    style: TextStyle(color: _mutedTextColor),
                  ),
                  TextSpan(
                    text: 'L $losses',
                    style: const TextStyle(color: _garbageColor),
                  ),
                ],
              ),
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 3-2-1-GO shown while [VersusPhase.countdown] is active (plus a short GO
/// tail after play begins — the parent keeps it mounted briefly).
///
/// Each number slams down like a hard-dropped piece: it accelerates in from
/// above, hits with a screen shake, an impact flash and a beat sound, then
/// settles. GO bursts outward with its own payoff sound. The overlay never
/// intercepts input, so the GO tail cannot eat the first moves of the match.
class CountdownOverlay extends StatefulWidget {
  const CountdownOverlay({super.key, required this.duration});

  final Duration duration;

  /// How long the GO burst lingers after [duration]; parents keep the overlay
  /// mounted for this long into the playing phase.
  static const goTail = Duration(milliseconds: 550);

  @override
  State<CountdownOverlay> createState() => _CountdownOverlayState();
}

class _CountdownOverlayState extends State<CountdownOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _count;
  late final AnimationController _go;
  int _beatsPlayed = 0;
  bool _goSoundPlayed = false;

  /// Fraction of each one-second beat spent falling before impact.
  static const _fallFraction = 0.20;

  @override
  void initState() {
    super.initState();
    _count = AnimationController(vsync: this, duration: widget.duration)
      ..addListener(_onTick)
      ..forward();
    _go = AnimationController(vsync: this, duration: CountdownOverlay.goTail)
      ..addListener(() => setState(() {}));
    _count.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        if (!_goSoundPlayed) {
          _goSoundPlayed = true;
          UiFeedback.play(UiSfx.toast);
        }
        _go.forward();
      }
    });
  }

  void _onTick() {
    // One beat sound per number, at the moment of impact.
    final beats = (_count.value * _totalSeconds).floor();
    final beatProgress = _count.value * _totalSeconds - beats;
    if (beats < _totalSeconds &&
        beatProgress >= _fallFraction &&
        _beatsPlayed <= beats) {
      _beatsPlayed = beats + 1;
      UiFeedback.play(UiSfx.confirm);
    }
    setState(() {});
  }

  int get _totalSeconds =>
      (widget.duration.inMilliseconds / 1000).ceil().clamp(1, 10);

  @override
  void dispose() {
    _count.dispose();
    _go.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final counting = !_count.isCompleted;
    final seconds = _totalSeconds;
    // Position within the current one-second beat.
    final raw = (_count.value * seconds).clamp(0.0, seconds.toDouble());
    final beatIndex = counting ? raw.floor().clamp(0, seconds - 1) : seconds;
    final beatT = counting ? raw - beatIndex : 1.0;
    final label = counting ? '${seconds - beatIndex}' : 'GO';

    // Fall: accelerate in from above during the first fifth of the beat.
    final falling = counting && beatT < _fallFraction;
    final fallT = falling ? beatT / _fallFraction : 1.0;
    final fallOffset = falling ? -160.0 * (1 - Curves.easeIn.transform(fallT)) : 0.0;

    // Impact: shake + flash decaying right after the slam.
    final sinceImpact = falling ? 0.0 : (beatT - _fallFraction).clamp(0.0, 1.0);
    final shakeAmp = counting
        ? 9.0 * (1 - Curves.easeOutCubic.transform((sinceImpact * 2.6).clamp(0.0, 1.0)))
        : 0.0;
    final shakePhase = beatT * 55;
    final shake = falling || shakeAmp <= 0.05
        ? Offset.zero
        : Offset(
            math.sin(shakePhase * 1.7) * shakeAmp,
            math.cos(shakePhase * 2.3) * shakeAmp * 0.7,
          );
    final flash = falling
        ? 0.0
        : (1 - Curves.easeOut.transform((sinceImpact * 2.0).clamp(0.0, 1.0)));

    // GO burst: scale out and fade.
    final goT = _go.value;
    final goScale = counting ? 1.0 : 1.0 + Curves.easeOutCubic.transform(goT) * 0.9;
    final opacity = counting
        ? (falling ? Curves.easeIn.transform(fallT) : 1.0)
        : (1 - Curves.easeIn.transform(goT));
    final dim = counting ? 0.55 : 0.55 * (1 - goT);

    return IgnorePointer(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: dim.clamp(0.0, 1.0)),
        child: Center(
          child: Transform.translate(
            offset: shake,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Impact flash ring behind the number.
                if (flash > 0.01)
                  Container(
                    width: 180 + 140 * (1 - flash),
                    height: 180 + 140 * (1 - flash),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          _accentColor.withValues(alpha: 0.28 * flash),
                          _accentColor.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                Transform.translate(
                  offset: Offset(0, fallOffset),
                  child: Transform.scale(
                    scale: goScale,
                    child: Opacity(
                      opacity: opacity.clamp(0.0, 1.0),
                      child: Text(
                        label,
                        style: TextStyle(
                          color: counting ? _textColor : _accentColor,
                          fontSize: 132,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 6,
                          shadows: [
                            Shadow(
                              color: _accentColor.withValues(
                                alpha: counting ? 0.35 * flash + 0.15 : 0.6,
                              ),
                              blurRadius: 32,
                            ),
                            const Shadow(
                              color: Color(0xB0000000),
                              offset: Offset(0, 6),
                              blurRadius: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Animated end-of-match content: WIN slams in with rising celebration minos,
/// LOSE drops in heavy with a shake, OPPONENT LEFT slides in neutral. Shared
/// by the centered compact overlay and the wide-layout side sheet.
class VersusResultPanel extends StatefulWidget {
  const VersusResultPanel({
    super.key,
    required this.session,
    required this.onLeave,
  });

  final VersusSession session;
  final VoidCallback onLeave;

  @override
  State<VersusResultPanel> createState() => _VersusResultPanelState();
}

class _VersusResultPanelState extends State<VersusResultPanel>
    with TickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 750),
  );
  late final AnimationController _celebrate = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  VersusPhase get _phase => widget.session.phase.value;

  @override
  void initState() {
    super.initState();
    _enter.addListener(() => setState(() {}));
    _enter.forward();
    switch (_phase) {
      case VersusPhase.won:
        _celebrate.repeat();
        UiFeedback.play(UiSfx.win);
      case VersusPhase.lost:
        UiFeedback.play(UiSfx.lose);
      default:
        break;
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _celebrate.dispose();
    super.dispose();
  }

  Widget _title() {
    final (label, color) = switch (_phase) {
      VersusPhase.won => ('YOU WIN', _accentColor),
      VersusPhase.opponentLeft => ('OPPONENT LEFT', _accentColor),
      _ => ('YOU LOSE', _garbageColor),
    };
    final t = _enter.value;
    Widget text = Text(
      label,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: color,
        fontSize: 26,
        fontWeight: FontWeight.w800,
        letterSpacing: 2,
        shadows: [Shadow(color: color.withValues(alpha: 0.4 * t), blurRadius: 22)],
      ),
    );

    switch (_phase) {
      case VersusPhase.won:
        // Slam down to size with an overshoot.
        final scale = 1.0 +
            (1 - Curves.easeOutBack.transform(t.clamp(0.0, 1.0))) * 0.9;
        text = Transform.scale(
          scale: scale,
          child: Opacity(opacity: Curves.easeOut.transform(t), child: text),
        );
      case VersusPhase.lost:
        // Heavy fall then a decaying shake, like the countdown slam.
        const fallFraction = 0.3;
        final falling = t < fallFraction;
        final fallT = falling ? t / fallFraction : 1.0;
        final dy = falling ? -56.0 * (1 - Curves.easeIn.transform(fallT)) : 0.0;
        final sinceImpact = falling ? 0.0 : (t - fallFraction) / (1 - fallFraction);
        final amp = 6.0 * (1 - Curves.easeOutCubic.transform(sinceImpact));
        final shake = falling
            ? Offset.zero
            : Offset(math.sin(t * 90) * amp, math.cos(t * 70) * amp * 0.6);
        text = Transform.translate(
          offset: Offset(0, dy) + shake,
          child: Opacity(opacity: Curves.easeIn.transform(fallT), child: text),
        );
      default:
        text = Opacity(opacity: Curves.easeOut.transform(t), child: text);
    }

    if (_phase != VersusPhase.won) {
      return text;
    }
    // Celebration minos rising behind the title.
    return SizedBox(
      height: 78,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _celebrate,
              builder: (context, _) => CustomPaint(
                painter: _CelebrationPainter(progress: _celebrate.value),
              ),
            ),
          ),
          text,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canRematch = _phase != VersusPhase.opponentLeft;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(),
        const SizedBox(height: 6),
        Text(
          'Score ${widget.session.game.score}',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: _mutedTextColor,
            fontSize: 13,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 10),
        AnimatedBuilder(
          animation: Listenable.merge([
            widget.session.wins,
            widget.session.losses,
          ]),
          builder: (context, _) => Text(
            'THIS ROOM · YOU ${widget.session.wins.value} — '
            '${widget.session.losses.value} THEM',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _mutedTextColor,
              fontSize: 11,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (canRematch) ...[
          ValueListenableBuilder<bool>(
            valueListenable: widget.session.localWantsRematch,
            builder: (context, waiting, _) {
              return TetrisButton(
                variant: TetrisButtonVariant.primary,
                // Pre-focused so a controller can confirm instantly.
                autofocus: true,
                onPressed: waiting ? null : widget.session.requestRematch,
                child: Text(waiting ? 'Waiting for opponent…' : 'Rematch'),
              );
            },
          ),
          ValueListenableBuilder<bool>(
            valueListenable: widget.session.opponentWantsRematch,
            builder: (context, wants, _) {
              if (!wants) {
                return const SizedBox(height: 8);
              }
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  'Opponent wants a rematch',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _accentColor, fontSize: 12),
                ),
              );
            },
          ),
        ],
        TetrisButton(
          variant: TetrisButtonVariant.ghost,
          onPressed: widget.onLeave,
          child: const Text('Leave match'),
        ),
      ],
    );
  }
}

/// Small accent minos drifting up behind a WIN title.
class _CelebrationPainter extends CustomPainter {
  _CelebrationPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (var i = 0; i < 9; i += 1) {
      // Deterministic per-index phase and lane.
      final phase = (progress + i * 0.31) % 1.0;
      final x = size.width * ((i * 0.117 + 0.06) % 1.0);
      final y = size.height * (1.15 - 1.4 * phase);
      final wobble = math.sin((phase * 4 + i) * math.pi) * 3;
      final alpha = (math.sin(phase * math.pi)).clamp(0.0, 1.0) * 0.5;
      final side = 5.0 + (i % 3) * 2.5;
      paint.color = (i.isEven ? _accentColor : const Color(0xFF58D957))
          .withValues(alpha: alpha);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x + wobble, y, side, side),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CelebrationPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

/// Centered result treatment for narrow (portrait) layouts: dims the whole
/// play area and floats the panel card over it.
class VersusResultOverlay extends StatelessWidget {
  const VersusResultOverlay({
    super.key,
    required this.session,
    required this.onLeave,
  });

  final VersusSession session;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.72),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _panelColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: VersusResultPanel(session: session, onLeave: onLeave),
            ),
          ),
        ),
      ),
    );
  }
}

/// Side-sheet result treatment for wide/landscape layouts: slides in along
/// the right edge so the final board state stays fully visible.
class VersusResultSheet extends StatelessWidget {
  const VersusResultSheet({
    super.key,
    required this.session,
    required this.onLeave,
  });

  final VersusSession session;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1.0, end: 0.0),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      builder: (context, offset, child) => FractionalTranslation(
        translation: Offset(offset, 0),
        child: child,
      ),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: _panelColor,
          border: Border(
            left: BorderSide(color: TetrisColors.outlineFaint),
          ),
          boxShadow: [
            BoxShadow(
              color: Color(0x88000000),
              blurRadius: 32,
              offset: Offset(-10, 0),
            ),
          ],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Center(
              child: SingleChildScrollView(
                child: VersusResultPanel(session: session, onLeave: onLeave),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

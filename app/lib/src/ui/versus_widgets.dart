import 'package:flutter/material.dart';

import '../game/tetris_game.dart';
import '../net/match_transport.dart';
import '../net/protocol.dart';
import '../net/versus_session.dart';
import 'board_painting.dart';

const _panelColor = Color(0xFF1B1D22);
const _textColor = Color(0xFFF3F6FA);
const _mutedTextColor = Color(0xFFA5ADBA);
const _accentColor = Color(0xFF44D7FF);
const _garbageColor = Color(0xFFFF4D5E);

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
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'OPPONENT',
                      style: TextStyle(
                        color: _mutedTextColor,
                        fontSize: 9,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w600,
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

/// 3-2-1 shown while [VersusPhase.countdown] is active.
class CountdownOverlay extends StatefulWidget {
  const CountdownOverlay({super.key, required this.duration});

  final Duration duration;

  @override
  State<CountdownOverlay> createState() => _CountdownOverlayState();
}

class _CountdownOverlayState extends State<CountdownOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addListener(() => setState(() {}))
      ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.duration * (1 - _controller.value);
    final seconds = (remaining.inMilliseconds / 1000).ceil();
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.55),
      child: Center(
        child: Text(
          seconds > 0 ? '$seconds' : 'GO',
          style: const TextStyle(
            color: _textColor,
            fontSize: 88,
            fontWeight: FontWeight.w800,
            letterSpacing: 4,
          ),
        ),
      ),
    );
  }
}

/// End-of-match overlay: WIN / LOSE / OPPONENT LEFT with rematch controls.
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
    final (title, color) = switch (session.phase.value) {
      VersusPhase.won => ('YOU WIN', _accentColor),
      VersusPhase.opponentLeft => ('OPPONENT LEFT', _accentColor),
      _ => ('YOU LOSE', _garbageColor),
    };
    final canRematch = session.phase.value != VersusPhase.opponentLeft;

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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: color,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Score ${session.game.score}',
                    style: const TextStyle(
                      color: _mutedTextColor,
                      fontSize: 13,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (canRematch) ...[
                    ValueListenableBuilder<bool>(
                      valueListenable: session.localWantsRematch,
                      builder: (context, waiting, _) {
                        return FilledButton(
                          onPressed: waiting ? null : session.requestRematch,
                          child: Text(
                            waiting ? 'Waiting for opponent…' : 'Rematch',
                          ),
                        );
                      },
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: session.opponentWantsRematch,
                      builder: (context, wants, _) {
                        if (!wants) {
                          return const SizedBox(height: 8);
                        }
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 6),
                          child: Text(
                            'Opponent wants a rematch',
                            style: TextStyle(
                              color: _accentColor,
                              fontSize: 12,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                  TextButton(
                    onPressed: onLeave,
                    child: const Text('Leave match'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

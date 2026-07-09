import 'dart:async';

import 'package:flutter/material.dart';

import '../game/tetris_game.dart';
import '../net/friends_client.dart';
import '../net/presence_client.dart';
import '../net/protocol.dart';
import 'components.dart';
import 'theme.dart';
import 'versus_widgets.dart';

/// Read-only live view of a friend's solo round, fed by spectate frames over
/// the presence connection.
class SpectatePage extends StatefulWidget {
  const SpectatePage({super.key, required this.friend, this.hub});

  final Friend friend;

  /// Defaults to the process-wide hub.
  final PresenceHub? hub;

  @override
  State<SpectatePage> createState() => _SpectatePageState();
}

class _SpectatePageState extends State<SpectatePage> {
  PresenceHub? get _hub => widget.hub ?? PresenceHub.instance;
  StreamSubscription<PresenceEvent>? _subscription;
  OpponentSnapshot? _snapshot;
  int _level = 1;
  bool _ended = false;

  @override
  void initState() {
    super.initState();
    final hub = _hub;
    if (hub != null) {
      _subscription = hub.events.listen(_onEvent);
      hub.watch(widget.friend.uid);
    }
  }

  @override
  void dispose() {
    _hub?.unwatch();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _onEvent(PresenceEvent event) {
    if (!mounted) {
      return;
    }
    switch (event) {
      case SpectateFrame(:final fromUid, :final data)
          when fromUid == widget.friend.uid:
        final message = GameMessage.decode(data);
        if (message is BoardStateMsg) {
          final snapshot = OpponentSnapshot.fromMessage(message);
          if (snapshot != null) {
            setState(() {
              _snapshot = snapshot;
              if (data is Map<String, dynamic> && data['level'] is int) {
                _level = data['level'] as int;
              }
            });
          }
        }
      case SpectateEnded(:final fromUid) when fromUid == widget.friend.uid:
        setState(() => _ended = true);
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(
          'Watching ${widget.friend.displayName}',
          style: const TextStyle(color: TetrisColors.text, fontSize: 17),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: _ended
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'STREAM ENDED',
                      key: ValueKey('spectate-ended'),
                      style: TextStyle(
                        color: TetrisColors.mutedText,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${widget.friend.displayName} finished playing.',
                      style: const TextStyle(
                        color: TetrisColors.mutedText,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 18),
                    TetrisButton(
                      compact: true,
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text('Back'),
                    ),
                  ],
                )
              : snapshot == null
              ? const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: TetrisColors.accent),
                    SizedBox(height: 14),
                    Text(
                      'Waiting for the live board…',
                      style: TextStyle(
                        color: TetrisColors.mutedText,
                        fontSize: 13,
                      ),
                    ),
                  ],
                )
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: TetrisColors.danger,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            'LIVE',
                            style: TextStyle(
                              color: TetrisColors.danger,
                              fontSize: 11,
                              letterSpacing: 1.6,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Text(
                            'SCORE ${snapshot.score} · LEVEL $_level · '
                            'LINES ${snapshot.lines}',
                            key: const ValueKey('spectate-hud'),
                            style: const TextStyle(
                              color: TetrisColors.text,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: AspectRatio(
                          aspectRatio:
                              TetrisGame.width / TetrisGame.visibleRows,
                          child: CustomPaint(
                            painter: OpponentBoardPainter(snapshot: snapshot),
                            size: Size.infinite,
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

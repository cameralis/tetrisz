import 'dart:async';

import 'package:flutter/foundation.dart';

import '../game/tetris_game.dart';
import 'match_transport.dart';
import 'protocol.dart';
import 'room_client.dart';

enum VersusPhase {
  /// Both players received the seed; local boards are frozen for the 3-2-1.
  countdown,
  playing,
  won,
  lost,

  /// The opponent disconnected and did not come back within the grace period.
  opponentLeft,
}

/// Orchestrates one 1v1 session: owns the seeded [TetrisGame] per match,
/// turns drained engine events into outgoing messages, applies incoming
/// attacks, and tracks match phase, opponent mirror, and rematch state.
///
/// Built by the lobby once the room delivers `start`; handed to the game page
/// which calls [onLocalTick] every frame after ticking the game.
class VersusSession {
  VersusSession({
    required RoomChannel room,
    required StartEnvelope start,
    required bool isHost,
    FailoverTransport? transport,
    TetrisGame Function(int seed)? gameFactory,
    this.countdownDuration = const Duration(seconds: 3),
    this.disconnectGrace = const Duration(seconds: 10),
  }) : _room = room,
       _isHost = isHost,
       _gameFactory = gameFactory ?? ((seed) => TetrisGame(seed: seed)),
       transportLayer =
           transport ?? FailoverTransport(relay: RelayTransport(room)) {
    _matchId = start.matchId;
    _seed = start.seed;
    gameNotifier = ValueNotifier<TetrisGame>(_newGame(start.seed));
    _envelopeSubscription = _room.envelopes.listen(_onEnvelope);
    _messageSubscription = transportLayer.messages.listen(_onMessage);
    _startCountdown();
  }

  final Duration countdownDuration;
  final Duration disconnectGrace;

  final RoomChannel _room;
  final bool _isHost;
  final TetrisGame Function(int seed) _gameFactory;
  final FailoverTransport transportLayer;

  late final ValueNotifier<TetrisGame> gameNotifier;
  final phase = ValueNotifier<VersusPhase>(VersusPhase.countdown);
  final opponent = ValueNotifier<OpponentSnapshot?>(null);
  final opponentWantsRematch = ValueNotifier<bool>(false);
  final localWantsRematch = ValueNotifier<bool>(false);

  static const _stateSendInterval = Duration(milliseconds: 150);

  StreamSubscription<ServerEnvelope>? _envelopeSubscription;
  StreamSubscription<GameMessage>? _messageSubscription;
  Timer? _countdownTimer;
  Timer? _graceTimer;
  int _matchId = 0;
  int _seed = 0;
  int _attackSeqOut = 0;
  int _stateSeqOut = 0;
  DateTime _lastStateSentAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _sentGameOver = false;
  bool _disposed = false;

  TetrisGame get game => gameNotifier.value;
  RoomChannel get room => _room;
  bool get isHost => _isHost;
  int get matchId => _matchId;
  int get seed => _seed;

  bool get matchLive =>
      phase.value == VersusPhase.countdown || phase.value == VersusPhase.playing;

  /// Called by the game page every frame, after `game.tick(...)` (and after
  /// input-driven locks), regardless of pause state.
  void onLocalTick() {
    if (_disposed) {
      return;
    }
    final events = game.drainEvents();
    for (final event in events) {
      switch (event) {
        case LinesClearedEvent(:final attackSent) when attackSent > 0:
          _attackSeqOut += 1;
          transportLayer.send(AttackMsg(seq: _attackSeqOut, lines: attackSent));
        case ToppedOutEvent():
          _onLocalTopOut();
        default:
          break;
      }
    }

    if (phase.value == VersusPhase.playing &&
        DateTime.now().difference(_lastStateSentAt) >= _stateSendInterval) {
      _sendBoardState();
    }
  }

  void requestRematch() {
    if (_disposed || matchLive) {
      return;
    }
    localWantsRematch.value = true;
    _room.requestRematch();
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _countdownTimer?.cancel();
    _graceTimer?.cancel();
    await _envelopeSubscription?.cancel();
    await _messageSubscription?.cancel();
    await transportLayer.dispose();
    await _room.close();
    phase.dispose();
    opponent.dispose();
    opponentWantsRematch.dispose();
    localWantsRematch.dispose();
    gameNotifier.dispose();
  }

  TetrisGame _newGame(int seed) => _gameFactory(seed)..paused = true;

  void _startCountdown() {
    _countdownTimer?.cancel();
    phase.value = VersusPhase.countdown;
    _countdownTimer = Timer(countdownDuration, () {
      if (_disposed || phase.value != VersusPhase.countdown) {
        return;
      }
      game.paused = false;
      phase.value = VersusPhase.playing;
    });
  }

  void _onEnvelope(ServerEnvelope envelope) {
    switch (envelope) {
      case StartEnvelope() when envelope.matchId != _matchId:
        _beginNewMatch(envelope);
      case PeerLeftEnvelope():
        _startGraceTimer();
      case PeerRejoinedEnvelope():
        _graceTimer?.cancel();
      case RematchRequestedEnvelope():
        opponentWantsRematch.value = true;
      default:
        break;
    }
  }

  void _onMessage(GameMessage message) {
    switch (message) {
      case AttackMsg(:final lines):
        if (matchLive) {
          game.enqueueGarbage(lines);
        }
      case BoardStateMsg():
        final snapshot = OpponentSnapshot.fromMessage(message);
        if (snapshot != null) {
          opponent.value = snapshot;
        }
      case GameOverMsg():
        if (matchLive) {
          _finish(VersusPhase.won);
        }
      default:
        break;
    }
  }

  void _onLocalTopOut() {
    if (_sentGameOver) {
      return;
    }
    _sentGameOver = true;
    _sendBoardState();
    transportLayer.send(GameOverMsg(seq: _attackSeqOut + 1));
    if (matchLive) {
      _finish(VersusPhase.lost);
    }
  }

  void _finish(VersusPhase result) {
    _countdownTimer?.cancel();
    _graceTimer?.cancel();
    game.paused = true;
    phase.value = result;
  }

  void _startGraceTimer() {
    if (!matchLive) {
      return;
    }
    _graceTimer?.cancel();
    _graceTimer = Timer(disconnectGrace, () {
      if (!_disposed && matchLive) {
        _finish(VersusPhase.opponentLeft);
      }
    });
  }

  void _beginNewMatch(StartEnvelope start) {
    _matchId = start.matchId;
    _seed = start.seed;
    _attackSeqOut = 0;
    _stateSeqOut = 0;
    _sentGameOver = false;
    _lastStateSentAt = DateTime.fromMillisecondsSinceEpoch(0);
    transportLayer.resetForNewMatch();
    opponent.value = null;
    opponentWantsRematch.value = false;
    localWantsRematch.value = false;
    gameNotifier.value = _newGame(start.seed);
    _startCountdown();
  }

  void _sendBoardState() {
    _stateSeqOut += 1;
    _lastStateSentAt = DateTime.now();
    final active = game.active;
    transportLayer.send(
      BoardStateMsg(
        seq: _stateSeqOut,
        cells: encodeVisibleBoard(game),
        active: active == null
            ? null
            : ActivePieceWire(
                type: active.type,
                rotation: active.rotation,
                x: active.x,
                y: active.y,
              ),
        pendingGarbage: game.pendingGarbageLines,
        score: game.score,
        lines: game.lines,
      ),
    );
  }
}

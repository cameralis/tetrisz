import 'dart:async';

import 'package:flutter/foundation.dart';

import 'protocol.dart';
import 'room_client.dart';

enum TransportKind { p2p, relay }

/// One pipe capable of carrying [GameMessage]s to the opponent.
abstract interface class MatchTransport {
  TransportKind get kind;
  bool get isOpen;
  Stream<GameMessage> get messages;
  void send(GameMessage message);
  Future<void> close();
}

/// Fallback transport: game messages ride the room WebSocket as opaque
/// `relay` envelopes forwarded verbatim by the Durable Object.
class RelayTransport implements MatchTransport {
  RelayTransport(this._room) {
    _subscription = _room.envelopes.listen((envelope) {
      if (envelope is RelayEnvelope) {
        final message = GameMessage.decode(envelope.data);
        if (message != null) {
          _messages.add(message);
        }
      }
    });
  }

  final RoomChannel _room;
  final _messages = StreamController<GameMessage>.broadcast();
  StreamSubscription<ServerEnvelope>? _subscription;

  @override
  TransportKind get kind => TransportKind.relay;

  @override
  bool get isOpen =>
      _room.state.value == RoomConnectionState.connected ||
      // Reconnecting still accepts sends: RoomClient buffers and flushes.
      _room.state.value == RoomConnectionState.reconnecting;

  @override
  Stream<GameMessage> get messages => _messages.stream;

  @override
  void send(GameMessage message) => _room.sendRelay(message.encode());

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    await _messages.close();
  }
}

/// Composes the always-available relay transport with an optional P2P
/// transport. Starts on relay, promotes to P2P when told the data channel
/// opened, demotes back on failure.
///
/// Sending policy: critical messages ([AttackMsg], [GameOverMsg]) go over
/// every open transport; [BoardStateMsg] only over the active one. Receivers
/// dedup by sequence number, so double delivery and transport switches can
/// neither double-apply nor drop attacks while either pipe lives.
class FailoverTransport {
  FailoverTransport({required MatchTransport relay}) : _relay = relay {
    _subscriptions.add(relay.messages.listen(_onMessage));
  }

  final MatchTransport _relay;
  MatchTransport? _p2p;
  final List<StreamSubscription<GameMessage>> _subscriptions = [];
  final _messages = StreamController<GameMessage>.broadcast();

  final active = ValueNotifier<TransportKind>(TransportKind.relay);

  final Set<int> _seenAttackSeqs = {};
  int _lastStateSeq = -1;
  bool _seenGameOver = false;

  Stream<GameMessage> get messages => _messages.stream;

  MatchTransport? get p2pTransport => _p2p;

  /// Registers the P2P transport once WebRTC setup begins. Promotion still
  /// only happens via [promoteToP2p].
  void attachP2p(MatchTransport p2p) {
    _p2p = p2p;
    _subscriptions.add(p2p.messages.listen(_onMessage));
  }

  void promoteToP2p() {
    if (_p2p?.isOpen ?? false) {
      active.value = TransportKind.p2p;
    }
  }

  void demoteToRelay() {
    active.value = TransportKind.relay;
  }

  /// Clears dedup state between matches (sequence counters restart).
  void resetForNewMatch() {
    _seenAttackSeqs.clear();
    _lastStateSeq = -1;
    _seenGameOver = false;
  }

  void send(GameMessage message) {
    if (message is BoardStateMsg) {
      _activeTransport.send(message);
      return;
    }
    // Critical messages: every open pipe, receiver dedups.
    var sent = false;
    for (final transport in _openTransports) {
      transport.send(message);
      sent = true;
    }
    if (!sent) {
      // Nothing open right now; the relay buffers through reconnects, so
      // prefer it over dropping the message.
      _relay.send(message);
    }
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _relay.close();
    await _p2p?.close();
    await _messages.close();
    active.dispose();
  }

  MatchTransport get _activeTransport {
    final p2p = _p2p;
    if (active.value == TransportKind.p2p && p2p != null && p2p.isOpen) {
      return p2p;
    }
    return _relay;
  }

  Iterable<MatchTransport> get _openTransports sync* {
    if (_relay.isOpen) {
      yield _relay;
    }
    final p2p = _p2p;
    if (p2p != null && p2p.isOpen) {
      yield p2p;
    }
  }

  void _onMessage(GameMessage message) {
    switch (message) {
      case AttackMsg():
        if (!_seenAttackSeqs.add(message.seq)) {
          return;
        }
      case BoardStateMsg():
        if (message.seq <= _lastStateSeq) {
          return;
        }
        _lastStateSeq = message.seq;
      case GameOverMsg():
        if (_seenGameOver) {
          return;
        }
        _seenGameOver = true;
      case P2pPingMsg():
      case P2pPongMsg():
        break;
    }
    _messages.add(message);
  }
}

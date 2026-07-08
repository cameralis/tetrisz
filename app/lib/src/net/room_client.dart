import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'net_config.dart';
import 'protocol.dart';

enum RoomConnectionState { connecting, connected, reconnecting, closed, failed }

/// The slice of [RoomClient] the rest of the net layer depends on, so tests
/// can substitute a fake.
abstract interface class RoomChannel {
  String get code;
  Stream<ServerEnvelope> get envelopes;
  ValueListenable<RoomConnectionState> get state;
  ValueListenable<Duration?> get rtt;

  /// Human-readable reason when the connection permanently failed.
  ValueListenable<String?> get failureReason;
  void sendSignal(Object? data);
  void sendRelay(Map<String, dynamic> data);
  void sendReady();
  void requestRematch();
  Future<void> close();
}

/// WebSocket connection to one room on the backend. Owns reconnection (same
/// code re-lands on the same Durable Object), RTT pings, and buffering of
/// outgoing messages while the socket is down so relayed attacks are not
/// silently dropped across a reconnect.
class RoomClient implements RoomChannel {
  RoomClient._(this.code, WebSocketChannel Function(Uri)? connector)
    : _connector = connector ?? WebSocketChannel.connect;

  /// Creates a new room and connects to it.
  static Future<RoomClient> create({
    http.Client? httpClient,
    WebSocketChannel Function(Uri)? connector,
  }) async {
    final client = httpClient ?? http.Client();
    try {
      final response = await client
          .post(backendHttpUri('/api/rooms'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 201) {
        throw RoomException('Backend refused to create a room '
            '(HTTP ${response.statusCode})');
      }
      final code = (jsonDecode(response.body) as Map)['code'] as String;
      return RoomClient._(code, connector).._connect();
    } finally {
      if (httpClient == null) {
        client.close();
      }
    }
  }

  /// Connects to an existing room by code.
  static RoomClient join(
    String code, {
    WebSocketChannel Function(Uri)? connector,
  }) {
    return RoomClient._(code.toUpperCase(), connector).._connect();
  }

  static const _reconnectDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
  ];
  static const _pingInterval = Duration(seconds: 3);
  static const _maxBufferedMessages = 128;

  @override
  final String code;

  final WebSocketChannel Function(Uri) _connector;
  final _envelopes = StreamController<ServerEnvelope>.broadcast();
  final _state = ValueNotifier<RoomConnectionState>(
    RoomConnectionState.connecting,
  );
  final _rtt = ValueNotifier<Duration?>(null);

  /// Human-readable reason when [state] is [RoomConnectionState.failed].
  @override
  final ValueNotifier<String?> failureReason = ValueNotifier<String?>(null);

  final List<String> _outgoingBuffer = [];
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  DateTime? _pingSentAt;
  int _reconnectAttempt = 0;
  bool _disposed = false;

  @override
  Stream<ServerEnvelope> get envelopes => _envelopes.stream;

  @override
  ValueListenable<RoomConnectionState> get state => _state;

  @override
  ValueListenable<Duration?> get rtt => _rtt;

  @override
  void sendSignal(Object? data) => _send({'t': 'signal', 'd': data});

  @override
  void sendRelay(Map<String, dynamic> data) => _send({'t': 'relay', 'd': data});

  @override
  void sendReady() => _send({'t': 'ready'});

  @override
  void requestRematch() => _send({'t': 'rematch'});

  @override
  Future<void> close() async {
    _disposed = true;
    _teardownChannel();
    _reconnectTimer?.cancel();
    _state.value = RoomConnectionState.closed;
    await _envelopes.close();
  }

  void _connect() {
    if (_disposed) {
      return;
    }
    final channel = _connector(
      backendWsUri(
        '/api/rooms/$code/ws',
      ).replace(queryParameters: {'v': '$roomProtocolVersion'}),
    );
    _channel = channel;
    _subscription = channel.stream.listen(
      _onData,
      onDone: () => _onDone(channel),
      onError: (Object _) => _onDone(channel),
      cancelOnError: true,
    );
  }

  void _onData(dynamic data) {
    if (data is! String) {
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      return;
    }
    final envelope = ServerEnvelope.decode(decoded);
    if (envelope == null) {
      return;
    }

    if (envelope is JoinedEnvelope) {
      _reconnectAttempt = 0;
      _state.value = RoomConnectionState.connected;
      _flushBuffer();
      _startPinging();
    } else if (envelope is PongEnvelope) {
      final sentAt = _pingSentAt;
      if (sentAt != null) {
        _rtt.value = DateTime.now().difference(sentAt);
        _pingSentAt = null;
      }
    }
    _envelopes.add(envelope);
  }

  void _onDone(WebSocketChannel channel) {
    if (_disposed || channel != _channel) {
      return;
    }
    final closeCode = channel.closeCode;
    _teardownChannel();

    if (closeCode == closeRoomNotFound) {
      _fail('Room not found — check the code.');
      return;
    }
    if (closeCode == closeRoomFull) {
      _fail('Room is already full.');
      return;
    }

    if (_reconnectAttempt >= _reconnectDelays.length) {
      _fail('Lost connection to the room.');
      return;
    }
    final delay = _reconnectDelays[_reconnectAttempt];
    _reconnectAttempt += 1;
    _state.value = RoomConnectionState.reconnecting;
    _reconnectTimer = Timer(delay, _connect);
  }

  void _fail(String reason) {
    failureReason.value = reason;
    _state.value = RoomConnectionState.failed;
  }

  void _send(Map<String, dynamic> message) {
    final encoded = jsonEncode(message);
    if (_state.value == RoomConnectionState.connected && _channel != null) {
      _channel!.sink.add(encoded);
      return;
    }
    if (_outgoingBuffer.length < _maxBufferedMessages) {
      _outgoingBuffer.add(encoded);
    }
  }

  void _flushBuffer() {
    final channel = _channel;
    if (channel == null) {
      return;
    }
    for (final message in _outgoingBuffer) {
      channel.sink.add(message);
    }
    _outgoingBuffer.clear();
  }

  void _startPinging() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      if (_state.value != RoomConnectionState.connected ||
          _pingSentAt != null) {
        return;
      }
      _pingSentAt = DateTime.now();
      _channel?.sink.add('{"t":"ping"}');
    });
  }

  void _teardownChannel() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _pingSentAt = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
  }
}

class RoomException implements Exception {
  RoomException(this.message);

  final String message;

  @override
  String toString() => message;
}

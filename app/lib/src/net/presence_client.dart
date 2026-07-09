import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../auth/auth_service.dart';
import 'net_config.dart';

/// Coarse presence a friend can see.
enum FriendPresence { offline, online, solo, versus }

sealed class PresenceEvent {
  const PresenceEvent();
}

final class InviteReceived extends PresenceEvent {
  const InviteReceived({required this.fromUid});

  final String fromUid;
}

final class InviteAccepted extends PresenceEvent {
  const InviteAccepted({required this.fromUid, required this.roomCode});

  final String fromUid;
  final String roomCode;
}

final class InviteDeclined extends PresenceEvent {
  const InviteDeclined({required this.fromUid});

  final String fromUid;
}

final class InviteFailed extends PresenceEvent {
  const InviteFailed({required this.toUid});

  final String toUid;
}

/// Number of friends currently spectating this player changed.
final class WatchedChanged extends PresenceEvent {
  const WatchedChanged({required this.count});

  final int count;
}

/// A board snapshot from the player being spectated.
final class SpectateFrame extends PresenceEvent {
  const SpectateFrame({required this.fromUid, required this.data});

  final String fromUid;
  final Object? data;
}

/// The spectated player's stream ended (disconnect / left solo play).
final class SpectateEnded extends PresenceEvent {
  const SpectateEnded({required this.fromUid});

  final String fromUid;
}

/// Live connection to the presence hub; one per signed-in app instance.
abstract interface class PresenceChannel {
  Stream<PresenceEvent> get events;

  void setStatus(FriendPresence status);

  void sendInvite(String toUid);

  void respondInvite({
    required String toUid,
    required bool accept,
    String? roomCode,
  });

  /// Start/stop spectating a friend's solo play.
  void watch(String uid);

  void unwatch();

  /// Publish one board frame to whoever is spectating this player.
  void publishSpectate(Map<String, dynamic> frame);

  Future<void> close();
}

/// WebSocket implementation against `/api/presence/ws`.
class WsPresenceChannel implements PresenceChannel {
  WsPresenceChannel({
    required this.auth,
    WebSocketChannel Function(Uri)? connector,
  }) : _connector = connector ?? WebSocketChannel.connect {
    unawaited(_connect());
  }

  static const _reconnectDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  final AuthService auth;
  final WebSocketChannel Function(Uri) _connector;
  final _events = StreamController<PresenceEvent>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  FriendPresence _status = FriendPresence.online;
  bool _disposed = false;

  @override
  Stream<PresenceEvent> get events => _events.stream;

  Future<void> _connect() async {
    if (_disposed) {
      return;
    }
    final token = await auth.idToken();
    if (token == null || _disposed) {
      return;
    }
    try {
      final channel = _connector(
        backendWsUri(
          '/api/presence/ws',
        ).replace(queryParameters: {'token': token}),
      );
      _channel = channel;
      _subscription = channel.stream.listen(
        _onData,
        onDone: () => _onDone(channel),
        onError: (Object _) => _onDone(channel),
        cancelOnError: true,
      );
      _reconnectAttempt = 0;
      // Re-assert the current status after any (re)connect.
      setStatus(_status);
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onDone(WebSocketChannel channel) {
    if (_channel != channel) {
      return;
    }
    _channel = null;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) {
      return;
    }
    final delay = _reconnectDelays[
        _reconnectAttempt.clamp(0, _reconnectDelays.length - 1)];
    _reconnectAttempt += 1;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () => unawaited(_connect()));
  }

  void _onData(dynamic data) {
    if (data is! String) {
      return;
    }
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final event = switch (decoded['t']) {
      'invite' when decoded['from'] is String => InviteReceived(
        fromUid: decoded['from'] as String,
      ),
      'invite_accepted'
          when decoded['from'] is String && decoded['roomCode'] is String =>
        InviteAccepted(
          fromUid: decoded['from'] as String,
          roomCode: decoded['roomCode'] as String,
        ),
      'invite_declined' when decoded['from'] is String => InviteDeclined(
        fromUid: decoded['from'] as String,
      ),
      'invite_failed' when decoded['to'] is String => InviteFailed(
        toUid: decoded['to'] as String,
      ),
      'watched' when decoded['count'] is int => WatchedChanged(
        count: decoded['count'] as int,
      ),
      'spec' when decoded['from'] is String => SpectateFrame(
        fromUid: decoded['from'] as String,
        data: decoded['d'],
      ),
      'spec_end' when decoded['from'] is String => SpectateEnded(
        fromUid: decoded['from'] as String,
      ),
      _ => null,
    };
    if (event != null) {
      _events.add(event);
    }
  }

  void _send(Map<String, dynamic> message) {
    try {
      _channel?.sink.add(jsonEncode(message));
    } catch (_) {}
  }

  @override
  void setStatus(FriendPresence status) {
    _status = status;
    if (status != FriendPresence.offline) {
      _send({'t': 'status', 's': status.name});
    }
  }

  @override
  void sendInvite(String toUid) => _send({'t': 'invite', 'to': toUid});

  @override
  void watch(String uid) => _send({'t': 'watch', 'uid': uid});

  @override
  void unwatch() => _send({'t': 'unwatch'});

  @override
  void publishSpectate(Map<String, dynamic> frame) =>
      _send({'t': 'spec_pub', 'd': frame});

  @override
  void respondInvite({
    required String toUid,
    required bool accept,
    String? roomCode,
  }) {
    _send({
      't': 'invite_response',
      'to': toUid,
      'accept': accept,
      'roomCode': ?roomCode,
    });
  }

  @override
  Future<void> close() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();
    await _events.close();
  }
}

/// Friend presence lookup (`POST /api/presence/query`), friends-only
/// server-side.
abstract interface class PresenceQueryApi {
  Future<Map<String, FriendPresence>> query(List<String> uids);
}

class HttpPresenceQueryApi implements PresenceQueryApi {
  HttpPresenceQueryApi({required this.auth, http.Client? client})
    : _client = client ?? http.Client();

  final AuthService auth;
  final http.Client _client;

  @override
  Future<Map<String, FriendPresence>> query(List<String> uids) async {
    final token = await auth.idToken();
    if (token == null || uids.isEmpty) {
      return {};
    }
    final response = await _client
        .post(
          backendHttpUri('/api/presence/query'),
          headers: {'Authorization': 'Bearer $token'},
          body: jsonEncode({'uids': uids}),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      return {};
    }
    final statuses =
        (jsonDecode(response.body) as Map<String, dynamic>)['statuses']
            as Map<String, dynamic>? ??
        {};
    return statuses.map(
      (uid, raw) => MapEntry(
        uid,
        FriendPresence.values.firstWhere(
          (value) => value.name == raw,
          orElse: () => FriendPresence.offline,
        ),
      ),
    );
  }

  void close() => _client.close();
}

/// Auth-driven presence lifecycle + the app-wide event stream. Installed in
/// main(); inert while signed out (and therefore in every current build
/// until Firebase is configured).
class PresenceHub {
  PresenceHub({
    required this.auth,
    PresenceChannel Function(AuthService auth)? channelFactory,
  }) : _channelFactory =
           channelFactory ?? ((auth) => WsPresenceChannel(auth: auth)) {
    auth.account.addListener(_onAccountChanged);
    _onAccountChanged();
  }

  static PresenceHub? instance;

  static void install(PresenceHub hub) {
    instance = hub;
  }

  final AuthService auth;
  final PresenceChannel Function(AuthService auth) _channelFactory;
  final _events = StreamController<PresenceEvent>.broadcast();
  PresenceChannel? _channel;
  StreamSubscription<PresenceEvent>? _subscription;
  FriendPresence _status = FriendPresence.online;

  /// How many friends are spectating this player right now.
  final watcherCount = ValueNotifier<int>(0);

  Stream<PresenceEvent> get events => _events.stream;

  bool get connectedForSignedInUser => _channel != null;

  void _onAccountChanged() {
    final signedIn = auth.account.value != null;
    if (signedIn && _channel == null) {
      final channel = _channelFactory(auth);
      _channel = channel;
      _subscription = channel.events.listen((event) {
        if (event is WatchedChanged) {
          watcherCount.value = event.count;
        }
        _events.add(event);
      });
      channel.setStatus(_status);
    } else if (!signedIn && _channel != null) {
      final channel = _channel;
      _channel = null;
      watcherCount.value = 0;
      unawaited(_subscription?.cancel());
      _subscription = null;
      unawaited(channel?.close());
    }
  }

  /// Gameplay surfaces report what the player is doing.
  void setStatus(FriendPresence status) {
    _status = status;
    _channel?.setStatus(status);
  }

  FriendPresence get status => _status;

  void sendInvite(String toUid) => _channel?.sendInvite(toUid);

  void respondInvite({
    required String toUid,
    required bool accept,
    String? roomCode,
  }) {
    _channel?.respondInvite(toUid: toUid, accept: accept, roomCode: roomCode);
  }

  void watch(String uid) => _channel?.watch(uid);

  void unwatch() => _channel?.unwatch();

  void publishSpectate(Map<String, dynamic> frame) =>
      _channel?.publishSpectate(frame);
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'match_transport.dart';
import 'protocol.dart';
import 'versus_session.dart';

/// Public STUN servers used for srflx candidate discovery. No TURN: when
/// direct P2P fails, the game falls back to the backend relay instead.
const _iceConfiguration = <String, dynamic>{
  'iceServers': [
    {
      'urls': [
        'stun:stun.l.google.com:19302',
        'stun:stun.cloudflare.com:3478',
      ],
    },
  ],
  'sdpSemantics': 'unified-plan',
};

/// Owns one RTCPeerConnection + game data channel. Signaling messages travel
/// through the room WebSocket (forwarded verbatim by the backend).
class RtcSession {
  RtcSession({required this.isHost, required this.sendSignal});

  final bool isHost;
  final void Function(Object? data) sendSignal;

  final channelState = ValueNotifier<RTCDataChannelState?>(null);
  final iceState = ValueNotifier<RTCIceConnectionState?>(null);
  final _messages = StreamController<String>.broadcast();

  RTCPeerConnection? _connection;
  RTCDataChannel? _channel;
  bool _disposed = false;

  Stream<String> get messages => _messages.stream;

  bool get channelOpen =>
      channelState.value == RTCDataChannelState.RTCDataChannelOpen;

  /// Starts negotiation. The host creates the channel and offers; the guest
  /// waits for both to arrive. Any error leaves the match on relay.
  Future<void> start() async {
    try {
      final connection = await createPeerConnection(_iceConfiguration);
      if (_disposed) {
        await connection.dispose();
        return;
      }
      _connection = connection;

      connection.onIceCandidate = (candidate) {
        sendSignal({
          'kind': 'candidate',
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      };
      connection.onIceConnectionState = (state) {
        if (!_disposed) {
          iceState.value = state;
        }
      };
      connection.onDataChannel = _adoptChannel;

      if (isHost) {
        final channel = await connection.createDataChannel(
          'game',
          RTCDataChannelInit()..ordered = true,
        );
        _adoptChannel(channel);
        final offer = await connection.createOffer();
        await connection.setLocalDescription(offer);
        sendSignal({'kind': 'offer', 'sdp': offer.sdp, 'type': offer.type});
      }
    } catch (error) {
      debugPrint('WebRTC unavailable, staying on relay: $error');
    }
  }

  Future<void> handleSignal(Object? data) async {
    final connection = _connection;
    if (connection == null || data is! Map) {
      return;
    }
    try {
      switch (data['kind']) {
        case 'offer':
          await connection.setRemoteDescription(
            RTCSessionDescription(data['sdp'] as String?, data['type'] as String?),
          );
          final answer = await connection.createAnswer();
          await connection.setLocalDescription(answer);
          sendSignal({'kind': 'answer', 'sdp': answer.sdp, 'type': answer.type});
        case 'answer':
          await connection.setRemoteDescription(
            RTCSessionDescription(data['sdp'] as String?, data['type'] as String?),
          );
        case 'candidate':
          await connection.addCandidate(
            RTCIceCandidate(
              data['candidate'] as String?,
              data['sdpMid'] as String?,
              data['sdpMLineIndex'] as int?,
            ),
          );
      }
    } catch (error) {
      debugPrint('WebRTC signal handling failed: $error');
    }
  }

  void sendText(String text) {
    final channel = _channel;
    if (channel != null && channelOpen) {
      channel.send(RTCDataChannelMessage(text));
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _messages.close();
    await _channel?.close();
    await _connection?.close();
    await _connection?.dispose();
    channelState.dispose();
    iceState.dispose();
  }

  void _adoptChannel(RTCDataChannel channel) {
    _channel = channel;
    channel.onDataChannelState = (state) {
      if (!_disposed) {
        channelState.value = state;
      }
    };
    channel.onMessage = (message) {
      if (!_disposed && message.isBinary == false) {
        _messages.add(message.text);
      }
    };
    // Some platforms report an already-open state without a transition event.
    if (channel.state != null && !_disposed) {
      channelState.value = channel.state;
    }
  }
}

/// [MatchTransport] over the WebRTC data channel.
class P2pTransport implements MatchTransport {
  P2pTransport(this._rtc) {
    _subscription = _rtc.messages.listen((text) {
      Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        return;
      }
      final message = GameMessage.decode(decoded);
      if (message != null) {
        _incoming.add(message);
      }
    });
  }

  final RtcSession _rtc;
  final _incoming = StreamController<GameMessage>.broadcast();
  StreamSubscription<String>? _subscription;

  @override
  TransportKind get kind => TransportKind.p2p;

  @override
  bool get isOpen => _rtc.channelOpen;

  @override
  Stream<GameMessage> get messages => _incoming.stream;

  @override
  void send(GameMessage message) => _rtc.sendText(jsonEncode(message.encode()));

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    await _incoming.close();
    await _rtc.dispose();
  }
}

/// Attaches WebRTC to a [VersusSession]: feeds signaling both ways and drives
/// promotion/demotion of the failover transport. Its lifetime is bound to the
/// session's room stream; when the session closes, everything unwinds.
class VersusRtcCoordinator {
  VersusRtcCoordinator(this.session) {
    _rtc = RtcSession(
      isHost: session.isHost,
      sendSignal: session.room.sendSignal,
    );
    session.transportLayer.attachP2p(P2pTransport(_rtc));
    session.room.envelopes.listen((envelope) {
      if (envelope is SignalEnvelope) {
        unawaited(_rtc.handleSignal(envelope.data));
      }
    });
    _rtc.channelState.addListener(_onChannelState);
    _rtc.iceState.addListener(_onIceState);
    unawaited(_rtc.start());
  }

  static const _iceDisconnectDebounce = Duration(seconds: 2);

  final VersusSession session;
  late final RtcSession _rtc;
  Timer? _demoteTimer;

  void _onChannelState() {
    switch (_rtc.channelState.value) {
      case RTCDataChannelState.RTCDataChannelOpen:
        _demoteTimer?.cancel();
        session.transportLayer.promoteToP2p();
      case RTCDataChannelState.RTCDataChannelClosing:
      case RTCDataChannelState.RTCDataChannelClosed:
        session.transportLayer.demoteToRelay();
      default:
        break;
    }
  }

  void _onIceState() {
    switch (_rtc.iceState.value) {
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        _demoteTimer?.cancel();
        session.transportLayer.demoteToRelay();
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        // Transient blips recover; give ICE a moment before demoting.
        _demoteTimer?.cancel();
        _demoteTimer = Timer(_iceDisconnectDebounce, () {
          if (_rtc.iceState.value ==
              RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
            session.transportLayer.demoteToRelay();
          }
        });
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _demoteTimer?.cancel();
        if (_rtc.channelOpen) {
          session.transportLayer.promoteToP2p();
        }
      default:
        break;
    }
  }
}

final class StunProbeResult {
  const StunProbeResult({
    required this.srflxFound,
    required this.candidateTypes,
    this.error,
  });

  /// True when a server-reflexive candidate was gathered: direct P2P across
  /// the internet is likely to work from this network.
  final bool srflxFound;
  final Set<String> candidateTypes;
  final String? error;
}

/// Gathers ICE candidates against public STUN servers to estimate whether
/// direct P2P is available from the current network.
Future<StunProbeResult> probeStun({
  Duration timeout = const Duration(seconds: 5),
}) async {
  RTCPeerConnection? connection;
  final types = <String>{};
  try {
    connection = await createPeerConnection(_iceConfiguration);
    final srflxSeen = Completer<void>();

    connection.onIceCandidate = (candidate) {
      final text = candidate.candidate ?? '';
      final match = RegExp(r'typ (\w+)').firstMatch(text);
      if (match != null) {
        types.add(match.group(1)!);
      }
      if (text.contains('typ srflx') && !srflxSeen.isCompleted) {
        srflxSeen.complete();
      }
    };

    await connection.createDataChannel('probe', RTCDataChannelInit());
    final offer = await connection.createOffer();
    await connection.setLocalDescription(offer);

    await srflxSeen.future.timeout(timeout);
    return StunProbeResult(srflxFound: true, candidateTypes: types);
  } on TimeoutException {
    return StunProbeResult(
      srflxFound: false,
      candidateTypes: types,
      error: 'No server-reflexive candidate within the timeout.',
    );
  } catch (error) {
    return StunProbeResult(
      srflxFound: false,
      candidateTypes: types,
      error: '$error',
    );
  } finally {
    await connection?.close();
    await connection?.dispose();
  }
}

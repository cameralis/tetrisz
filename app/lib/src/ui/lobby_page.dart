import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../input/gamepad_service.dart';
import '../net/protocol.dart';
import '../net/room_client.dart';
import '../net/rtc_session.dart';
import '../net/versus_session.dart';
import 'tetris_app.dart';

const _textColor = Color(0xFFF3F6FA);
const _mutedTextColor = Color(0xFFA5ADBA);
const _accentColor = Color(0xFF44D7FF);
const _errorColor = Color(0xFFFF4D5E);

enum _LobbyStage { idle, connecting, waiting, error }

/// Create-or-join screen. Owns the [RoomClient] until the match starts, then
/// hands it to a [VersusSession] and replaces itself with the game page.
class LobbyPage extends StatefulWidget {
  const LobbyPage({
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
  State<LobbyPage> createState() => _LobbyPageState();
}

class _LobbyPageState extends State<LobbyPage> {
  final _codeController = TextEditingController();
  _LobbyStage _stage = _LobbyStage.idle;
  String? _roomCode;
  String? _error;
  bool _isHost = false;
  bool _handedOff = false;
  RoomClient? _client;
  StreamSubscription<ServerEnvelope>? _subscription;

  @override
  void dispose() {
    _subscription?.cancel();
    if (!_handedOff) {
      unawaited(_client?.close());
    }
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _createRoom() async {
    setState(() {
      _stage = _LobbyStage.connecting;
      _error = null;
    });
    try {
      final client = await RoomClient.create();
      _adoptClient(client);
      setState(() {
        _roomCode = client.code;
        _stage = _LobbyStage.waiting;
      });
    } catch (error) {
      setState(() {
        _stage = _LobbyStage.error;
        _error = 'Could not create a match: $error';
      });
    }
  }

  void _joinRoom() {
    final code = _codeController.text.trim().toUpperCase();
    if (code.length < 4) {
      setState(() {
        _stage = _LobbyStage.error;
        _error = 'Enter the room code your friend shared.';
      });
      return;
    }
    setState(() {
      _stage = _LobbyStage.waiting;
      _roomCode = code;
      _error = null;
    });
    _adoptClient(RoomClient.join(code));
  }

  void _adoptClient(RoomClient client) {
    _client = client;
    client.failureReason.addListener(_onFailure);
    _subscription = client.envelopes.listen(_onEnvelope);
  }

  void _onFailure() {
    final reason = _client?.failureReason.value;
    if (reason != null && mounted && !_handedOff) {
      setState(() {
        _stage = _LobbyStage.error;
        _error = reason;
      });
    }
  }

  void _onEnvelope(ServerEnvelope envelope) {
    final client = _client;
    if (client == null || !mounted) {
      return;
    }
    switch (envelope) {
      case JoinedEnvelope():
        _isHost = envelope.isHost;
      case StartEnvelope():
        if (_handedOff) {
          return;
        }
        _handedOff = true;
        final session = VersusSession(
          room: client,
          start: envelope,
          isHost: _isHost,
        );
        // Kick off WebRTC negotiation; the match starts on relay and
        // promotes to P2P the moment the data channel opens.
        VersusRtcCoordinator(session);
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => TetrisGamePage(
              enableAudio: widget.enableAudio,
              musicPlayer: widget.musicPlayer,
              soundEffects: widget.soundEffects,
              haptics: widget.haptics,
              gamepad: widget.gamepad,
              versusSession: session,
            ),
          ),
        );
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('1v1 Versus', style: TextStyle(color: _textColor)),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: switch (_stage) {
              _LobbyStage.waiting => _buildWaiting(),
              _ => _buildIdle(),
            },
          ),
        ),
      ),
    );
  }

  Widget _buildIdle() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          key: const ValueKey('lobby-create'),
          style: FilledButton.styleFrom(
            backgroundColor: _accentColor,
            foregroundColor: const Color(0xFF07080A),
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          onPressed: _stage == _LobbyStage.connecting ? null : _createRoom,
          child: Text(
            _stage == _LobbyStage.connecting ? 'Creating…' : 'Create match',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 28),
        const Text(
          'OR JOIN A FRIEND',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _mutedTextColor,
            fontSize: 11,
            letterSpacing: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('lobby-code-field'),
          controller: _codeController,
          textCapitalization: TextCapitalization.characters,
          textAlign: TextAlign.center,
          maxLength: 5,
          style: const TextStyle(
            color: _textColor,
            fontSize: 24,
            letterSpacing: 8,
            fontWeight: FontWeight.w700,
          ),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9]')),
          ],
          decoration: InputDecoration(
            counterText: '',
            hintText: 'CODE',
            hintStyle: TextStyle(
              color: _mutedTextColor.withValues(alpha: 0.4),
              letterSpacing: 8,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0x33FFFFFF)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _accentColor),
            ),
          ),
          onSubmitted: (_) => _joinRoom(),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const ValueKey('lobby-join'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _textColor,
            side: const BorderSide(color: Color(0x33FFFFFF)),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          onPressed: _joinRoom,
          child: const Text('Join'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _errorColor, fontSize: 13),
            ),
          ),
      ],
    );
  }

  Widget _buildWaiting() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          'ROOM CODE',
          style: TextStyle(
            color: _mutedTextColor,
            fontSize: 11,
            letterSpacing: 1.4,
          ),
        ),
        const SizedBox(height: 8),
        SelectableText(
          _roomCode ?? '',
          key: const ValueKey('lobby-room-code'),
          style: const TextStyle(
            color: _textColor,
            fontSize: 42,
            letterSpacing: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 24),
        const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            color: _accentColor,
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Waiting for your opponent…',
          style: TextStyle(color: _mutedTextColor, fontSize: 13),
        ),
        const SizedBox(height: 30),
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

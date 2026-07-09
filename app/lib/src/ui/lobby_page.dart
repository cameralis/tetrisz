import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../input/gamepad_service.dart';
import '../net/protocol.dart';
import '../net/room_client.dart';
import '../net/rtc_session.dart';
import '../net/versus_session.dart';
import 'components.dart';
import 'tetris_app.dart';
import 'theme.dart';
import 'toasts.dart';
import 'ui_sounds.dart';

enum _LobbyStage { idle, connecting, waiting, error }

/// Create-or-join screen. Owns the [RoomChannel] until the match starts:
/// once both players are in the room each must ready up; the server then
/// sends `start` and the lobby hands the channel to a [VersusSession] and
/// replaces itself with the game page.
class LobbyPage extends StatefulWidget {
  const LobbyPage({
    super.key,
    this.enableAudio = true,
    this.musicPlayer,
    this.soundEffects,
    this.haptics,
    this.gamepad,
    this.createRoom,
    this.joinRoom,
    this.enableP2p = true,
    this.initialJoinCode,
    this.initialClient,
  });

  final bool enableAudio;
  final TetrisMusicPlayer? musicPlayer;
  final TetrisSoundEffects? soundEffects;
  final TetrisHaptics? haptics;
  final GamepadService? gamepad;

  /// Test seams; production uses [RoomClient.create] / [RoomClient.join].
  final Future<RoomChannel> Function()? createRoom;
  final RoomChannel Function(String code)? joinRoom;

  /// Tests disable this so no WebRTC platform channels are touched.
  final bool enableP2p;

  /// Friend-invite entry points: join this room code immediately on open…
  final String? initialJoinCode;

  /// …or adopt an already-connected room (the invite accepter created it).
  final RoomChannel? initialClient;

  @override
  State<LobbyPage> createState() => _LobbyPageState();
}

class _LobbyPageState extends State<LobbyPage> {
  final _codeController = TextEditingController();
  _LobbyStage _stage = _LobbyStage.idle;
  String? _roomCode;
  String? _error;
  bool _isHost = false;
  bool _peerPresent = false;
  bool _localReady = false;
  bool _opponentReady = false;
  bool _handedOff = false;
  RoomChannel? _client;
  StreamSubscription<ServerEnvelope>? _subscription;

  @override
  void initState() {
    super.initState();
    final initialClient = widget.initialClient;
    final initialJoinCode = widget.initialJoinCode;
    if (initialClient != null) {
      _adoptClient(initialClient);
      _stage = _LobbyStage.waiting;
      _roomCode = initialClient.code;
    } else if (initialJoinCode != null) {
      _stage = _LobbyStage.waiting;
      _roomCode = initialJoinCode.toUpperCase();
      _adoptClient(
        widget.joinRoom?.call(_roomCode!) ?? RoomClient.join(_roomCode!),
      );
    }
  }

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
      final client = await (widget.createRoom?.call() ?? RoomClient.create());
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
    _adoptClient(widget.joinRoom?.call(code) ?? RoomClient.join(code));
  }

  void _sendReady() {
    final client = _client;
    if (client == null || _localReady) {
      return;
    }
    client.sendReady();
    setState(() => _localReady = true);
  }

  void _adoptClient(RoomChannel client) {
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
        setState(() {
          _peerPresent = envelope.peerPresent;
          _opponentReady = envelope.peerReady;
        });
      case PeerJoinedEnvelope():
        setState(() {
          _peerPresent = true;
          _opponentReady = false;
        });
        TetrisToastHost.show(
          'Opponent joined the room',
          icon: Icons.person_add_alt_1_rounded,
          accent: TetrisColors.ok,
        );
      case PeerLeftEnvelope():
        setState(() {
          _peerPresent = false;
          _opponentReady = false;
        });
        TetrisToastHost.show(
          'Opponent left the room',
          icon: Icons.person_off_rounded,
          accent: TetrisColors.danger,
        );
      case PeerReadyEnvelope():
        setState(() => _opponentReady = true);
        UiFeedback.play(UiSfx.confirm);
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
        if (widget.enableP2p) {
          VersusRtcCoordinator(session);
        }
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
        title: const Text(
          '1v1 Versus',
          style: TextStyle(color: TetrisColors.text),
        ),
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
        TetrisButton(
          key: const ValueKey('lobby-create'),
          variant: TetrisButtonVariant.primary,
          autofocus: true,
          onPressed: _stage == _LobbyStage.connecting ? null : _createRoom,
          child: Text(
            _stage == _LobbyStage.connecting ? 'Creating…' : 'Create match',
          ),
        ),
        const SizedBox(height: 28),
        const Center(child: TetrisSectionHeader('OR JOIN A FRIEND')),
        const SizedBox(height: 4),
        TetrisTextField(
          key: const ValueKey('lobby-code-field'),
          controller: _codeController,
          textCapitalization: TextCapitalization.characters,
          textAlign: TextAlign.center,
          maxLength: 5,
          style: const TextStyle(
            color: TetrisColors.text,
            fontSize: 24,
            letterSpacing: 8,
            fontWeight: FontWeight.w700,
          ),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9]')),
          ],
          hint: 'CODE',
          hintStyle: TextStyle(
            color: TetrisColors.mutedText.withValues(alpha: 0.4),
            letterSpacing: 8,
          ),
          onSubmitted: (_) => _joinRoom(),
        ),
        const SizedBox(height: 12),
        TetrisButton(
          key: const ValueKey('lobby-join'),
          onPressed: _joinRoom,
          child: const Text('Join'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: TetrisColors.danger, fontSize: 13),
            ),
          ),
      ],
    );
  }

  Widget _buildWaiting() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: TetrisSectionHeader('ROOM CODE')),
        Center(
          child: SelectableText(
            _roomCode ?? '',
            key: const ValueKey('lobby-room-code'),
            style: const TextStyle(
              color: TetrisColors.text,
              fontSize: 42,
              letterSpacing: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 24),
        if (!_peerPresent) ...[
          const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: TetrisColors.accent,
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Waiting for your opponent…',
            textAlign: TextAlign.center,
            style: TextStyle(color: TetrisColors.mutedText, fontSize: 13),
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: _ReadyChip(
                  key: const ValueKey('lobby-ready-you'),
                  label: 'YOU',
                  ready: _localReady,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ReadyChip(
                  key: const ValueKey('lobby-ready-opponent'),
                  label: 'OPPONENT',
                  ready: _opponentReady,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TetrisButton(
            key: const ValueKey('lobby-ready'),
            variant: TetrisButtonVariant.primary,
            autofocus: true,
            onPressed: _localReady ? null : _sendReady,
            child: Text(
              _localReady ? 'Waiting for opponent…' : 'Ready up',
            ),
          ),
        ],
        const SizedBox(height: 22),
        TetrisButton(
          variant: TetrisButtonVariant.ghost,
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Per-player readiness indicator in the pre-match lobby.
class _ReadyChip extends StatelessWidget {
  const _ReadyChip({super.key, required this.label, required this.ready});

  final String label;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: ready
            ? Color.lerp(TetrisColors.panel, TetrisColors.ok, 0.16)!
            : TetrisColors.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: ready ? TetrisColors.ok : TetrisColors.outlineFaint,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ready ? TetrisColors.ok : TetrisColors.mutedText,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              ready ? '$label · READY' : label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ready ? TetrisColors.text : TetrisColors.mutedText,
                fontSize: 11,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

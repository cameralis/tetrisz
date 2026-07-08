import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../input/gamepad_service.dart';
import '../net/net_config.dart';
import '../net/rtc_session.dart';
import 'components.dart';
import 'controls_page.dart';
import 'theme.dart';

/// Connectivity diagnostics: is the backend reachable, and is direct P2P
/// likely to work from this network? Also shows the live match transport
/// when opened during a game (via the session-aware tile values pushed in).
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key, this.gamepad});

  /// Optional gamepad service, surfaced here for input diagnostics.
  final GamepadService? gamepad;

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

enum _ProbeState { idle, running, ok, failed }

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  _ProbeState _backendState = _ProbeState.idle;
  String _backendDetail = 'Not checked yet';
  _ProbeState _stunState = _ProbeState.idle;
  String _stunDetail = 'Not checked yet';

  @override
  void initState() {
    super.initState();
    unawaited(_probeBackend());
    unawaited(_probeP2p());
  }

  Future<void> _probeP2p() async {
    setState(() {
      _stunState = _ProbeState.running;
      _stunDetail = 'Gathering ICE candidates…';
    });
    final result = await probeStun();
    if (!mounted) {
      return;
    }
    setState(() {
      if (result.srflxFound) {
        _stunState = _ProbeState.ok;
        _stunDetail =
            'P2P likely available · candidates: '
            '${result.candidateTypes.join(', ')}';
      } else {
        _stunState = _ProbeState.failed;
        _stunDetail =
            'Relay-only likely — ${result.error ?? 'no STUN response'}'
            '${result.candidateTypes.isEmpty ? '' : ' · candidates: ${result.candidateTypes.join(', ')}'}';
      }
    });
  }

  Future<void> _probeBackend() async {
    setState(() {
      _backendState = _ProbeState.running;
      _backendDetail = 'Checking…';
    });
    final stopwatch = Stopwatch()..start();
    try {
      final response = await http
          .get(backendHttpUri('/api/health'))
          .timeout(const Duration(seconds: 6));
      stopwatch.stop();
      if (!mounted) {
        return;
      }
      setState(() {
        if (response.statusCode == 200) {
          _backendState = _ProbeState.ok;
          _backendDetail =
              'Reachable · ${stopwatch.elapsedMilliseconds} ms round trip';
        } else {
          _backendState = _ProbeState.failed;
          _backendDetail = 'HTTP ${response.statusCode}';
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _backendState = _ProbeState.failed;
        _backendDetail = 'Unreachable: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text(
          'Settings & Diagnostics',
          style: TextStyle(color: TetrisColors.text, fontSize: 17),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const TetrisSectionHeader('CONTROLS'),
            TetrisListTile(
              key: const ValueKey('open-controls'),
              leading: const Icon(
                Icons.sports_esports,
                color: TetrisColors.accent,
              ),
              title: const Text('Controller & touch bindings'),
              subtitle: const Text(
                'Xbox / PlayStation gamepads and touch gestures',
              ),
              trailing: const Icon(
                Icons.chevron_right,
                color: TetrisColors.mutedText,
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ControlsPage(gamepad: widget.gamepad),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const TetrisSectionHeader('CONNECTIVITY'),
            _DiagnosticTile(
              title: 'Matchmaking backend',
              subtitle: '$backendBaseUrl\n$_backendDetail',
              state: _backendState,
              onRetry: _probeBackend,
            ),
            ..._buildP2pSection(),
            const SizedBox(height: 20),
            const TetrisSectionHeader('ABOUT'),
            const _InfoTile(
              title: 'Transport strategy',
              body:
                  'Matches connect peer-to-peer over WebRTC when the network '
                  'allows it, and automatically fall back to relaying through '
                  'the backend when it does not. The in-game chip shows which '
                  'path is active.',
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildP2pSection() {
    return [
      _DiagnosticTile(
        title: 'Direct P2P availability',
        subtitle: _stunDetail,
        state: _stunState,
        onRetry: _probeP2p,
      ),
    ];
  }
}

class _DiagnosticTile extends StatelessWidget {
  const _DiagnosticTile({
    required this.title,
    required this.subtitle,
    required this.state,
    required this.onRetry,
  });

  final String title;
  final String subtitle;
  final _ProbeState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (state) {
      _ProbeState.ok => (Icons.check_circle, TetrisColors.ok),
      _ProbeState.failed => (Icons.error, TetrisColors.danger),
      _ProbeState.running => (Icons.sync, TetrisColors.accent),
      _ProbeState.idle => (Icons.circle_outlined, TetrisColors.mutedText),
    };
    return TetrisListTile(
      leading: Icon(icon, color: color),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: TetrisIconButton(
        icon: Icons.refresh,
        size: 38,
        color: TetrisColors.mutedText,
        tooltip: 'Re-run check',
        onPressed: state == _ProbeState.running ? null : onRetry,
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return TetrisPanel(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(color: TetrisColors.text, fontSize: 14),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: const TextStyle(
              color: TetrisColors.mutedText,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

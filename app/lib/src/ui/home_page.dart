import 'package:flutter/material.dart';

import '../input/gamepad_service.dart';
import 'components.dart';
import 'diagnostics_page.dart';
import 'leaderboard_page.dart';
import 'lobby_page.dart';
import 'tetris_app.dart';
import 'theme.dart';

/// Entry menu: solo play (with the existing resume-from-disk behavior),
/// versus lobby, and diagnostics.
class HomePage extends StatelessWidget {
  const HomePage({
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
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'TETRIS',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: TetrisColors.text,
                      fontSize: 44,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 10,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '1v1 · garbage battle · online',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: TetrisColors.mutedText,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 40),
                  TetrisButton(
                    key: const ValueKey('home-play'),
                    // Pre-focused so a controller can start with one press.
                    autofocus: true,
                    variant: TetrisButtonVariant.primary,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TetrisGamePage(
                          enableAudio: enableAudio,
                          musicPlayer: musicPlayer,
                          soundEffects: soundEffects,
                          haptics: haptics,
                          gamepad: gamepad,
                        ),
                      ),
                    ),
                    child: const Text('Play'),
                  ),
                  const SizedBox(height: 12),
                  TetrisButton(
                    key: const ValueKey('home-versus'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => LobbyPage(
                          enableAudio: enableAudio,
                          musicPlayer: musicPlayer,
                          soundEffects: soundEffects,
                          haptics: haptics,
                          gamepad: gamepad,
                        ),
                      ),
                    ),
                    child: const Text('1v1 Versus'),
                  ),
                  const SizedBox(height: 12),
                  TetrisButton(
                    key: const ValueKey('home-leaderboard'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const LeaderboardPage(),
                      ),
                    ),
                    child: const Text('Leaderboard'),
                  ),
                  const SizedBox(height: 12),
                  TetrisButton(
                    key: const ValueKey('home-diagnostics'),
                    variant: TetrisButtonVariant.ghost,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => DiagnosticsPage(gamepad: gamepad),
                      ),
                    ),
                    child: const Text('Settings & Diagnostics'),
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

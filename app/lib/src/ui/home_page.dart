import 'package:flutter/material.dart';

import 'diagnostics_page.dart';
import 'leaderboard_page.dart';
import 'lobby_page.dart';
import 'tetris_app.dart';

const _textColor = Color(0xFFF3F6FA);
const _mutedTextColor = Color(0xFFA5ADBA);
const _accentColor = Color(0xFF44D7FF);

/// Entry menu: solo play (with the existing resume-from-disk behavior),
/// versus lobby, and diagnostics.
class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    this.enableAudio = true,
    this.musicPlayer,
    this.soundEffects,
    this.haptics,
  });

  final bool enableAudio;
  final TetrisMusicPlayer? musicPlayer;
  final TetrisSoundEffects? soundEffects;
  final TetrisHaptics? haptics;

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
                      color: _textColor,
                      fontSize: 44,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 10,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '1v1 · garbage battle · online',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _mutedTextColor, fontSize: 12),
                  ),
                  const SizedBox(height: 40),
                  FilledButton(
                    key: const ValueKey('home-play'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _accentColor,
                      foregroundColor: const Color(0xFF07080A),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TetrisGamePage(
                          enableAudio: enableAudio,
                          musicPlayer: musicPlayer,
                          soundEffects: soundEffects,
                          haptics: haptics,
                        ),
                      ),
                    ),
                    child: const Text(
                      'Play',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    key: const ValueKey('home-versus'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _textColor,
                      side: const BorderSide(color: Color(0x33FFFFFF)),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => LobbyPage(
                          enableAudio: enableAudio,
                          musicPlayer: musicPlayer,
                          soundEffects: soundEffects,
                          haptics: haptics,
                        ),
                      ),
                    ),
                    child: const Text(
                      '1v1 Versus',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    key: const ValueKey('home-leaderboard'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _textColor,
                      side: const BorderSide(color: Color(0x33FFFFFF)),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const LeaderboardPage(),
                      ),
                    ),
                    child: const Text(
                      'Leaderboard',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    key: const ValueKey('home-diagnostics'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const DiagnosticsPage(),
                      ),
                    ),
                    child: const Text(
                      'Settings & Diagnostics',
                      style: TextStyle(color: _mutedTextColor),
                    ),
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

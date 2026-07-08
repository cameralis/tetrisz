import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../net/leaderboard_client.dart';
import 'components.dart';
import 'theme.dart';

const tetrisPlayerNamePreferenceKey = 'tetris.playerName';
const _highScorePreferenceKey = 'tetris.highScore';

/// Global top-50 with a display-name setting. Scores are auto-submitted on
/// single-player game over once a name is set; the button here retroactively
/// submits the stored personal best.
class LeaderboardPage extends StatefulWidget {
  const LeaderboardPage({super.key});

  @override
  State<LeaderboardPage> createState() => _LeaderboardPageState();
}

class _LeaderboardPageState extends State<LeaderboardPage> {
  final _client = LeaderboardClient();
  final _nameController = TextEditingController();
  Future<LeaderboardSnapshot>? _snapshotFuture;
  int _highScore = 0;
  bool _submittingBest = false;

  @override
  void initState() {
    super.initState();
    _snapshotFuture = _client.fetch();
    unawaited(_loadPreferences());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _client.close();
    super.dispose();
  }

  Future<void> _loadPreferences() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!mounted) {
        return;
      }
      setState(() {
        _nameController.text =
            preferences.getString(tetrisPlayerNamePreferenceKey) ?? '';
        _highScore = preferences.getInt(_highScorePreferenceKey) ?? 0;
      });
    } catch (_) {}
  }

  Future<void> _saveName(String name) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(tetrisPlayerNamePreferenceKey, name.trim());
    } catch (_) {}
  }

  void _refresh() {
    setState(() {
      _snapshotFuture = _client.fetch();
    });
  }

  Future<void> _submitBest() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _highScore <= 0) {
      return;
    }
    setState(() => _submittingBest = true);
    try {
      final rank = await _client.submit(
        name: name,
        score: _highScore,
        lines: 0,
        level: 1,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            rank == null
                ? 'Submitted — outside the global top list for now.'
                : 'Your best is global rank #$rank',
          ),
        ),
      );
      _refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Submit failed: $error')));
      }
    } finally {
      if (mounted) {
        setState(() => _submittingBest = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text(
          'Global Leaderboard',
          style: TextStyle(color: TetrisColors.text, fontSize: 17),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TetrisIconButton(
              icon: Icons.refresh,
              size: 40,
              tooltip: 'Refresh',
              color: TetrisColors.mutedText,
              onPressed: _refresh,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TetrisTextField(
                      controller: _nameController,
                      maxLength: 16,
                      label: 'Display name',
                      helper: 'Scores submit automatically on game over',
                      onChanged: (value) => unawaited(_saveName(value)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: TetrisButton(
                      variant: TetrisButtonVariant.primary,
                      compact: true,
                      onPressed: _submittingBest ? null : _submitBest,
                      child: Text(_submittingBest ? '…' : 'Submit best'),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder<LeaderboardSnapshot>(
                future: _snapshotFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(
                      child: CircularProgressIndicator(
                        color: TetrisColors.accent,
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Could not load the leaderboard.\n${snapshot.error}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: TetrisColors.danger,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    );
                  }
                  final entries = snapshot.data?.entries ?? const [];
                  if (entries.isEmpty) {
                    return const Center(
                      child: Text(
                        'No scores yet — be the first!',
                        style: TextStyle(color: TetrisColors.mutedText),
                      ),
                    );
                  }
                  final myName = _nameController.text.trim();
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final isMe = myName.isNotEmpty && entry.name == myName;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: TetrisPanel(
                          color: isMe
                              ? Color.lerp(
                                  TetrisColors.panel,
                                  TetrisColors.accent,
                                  0.14,
                                )!
                              : TetrisColors.panel,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 40,
                                child: Text(
                                  '#${index + 1}',
                                  style: TextStyle(
                                    color: index < 3
                                        ? TetrisColors.accent
                                        : TetrisColors.mutedText,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  entry.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: TetrisColors.text,
                                    fontSize: 14,
                                    fontWeight: isMe
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                              Text(
                                '${entry.score}',
                                style: const TextStyle(
                                  color: TetrisColors.text,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../net/leaderboard_client.dart';

const _textColor = Color(0xFFF3F6FA);
const _mutedTextColor = Color(0xFFA5ADBA);
const _accentColor = Color(0xFF44D7FF);
const _errorColor = Color(0xFFFF4D5E);
const _panelColor = Color(0xFF1B1D22);

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
          style: TextStyle(color: _textColor, fontSize: 17),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: _mutedTextColor),
            onPressed: _refresh,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _nameController,
                      maxLength: 16,
                      style: const TextStyle(color: _textColor),
                      decoration: InputDecoration(
                        counterText: '',
                        labelText: 'Display name',
                        labelStyle: const TextStyle(color: _mutedTextColor),
                        helperText:
                            'Scores submit automatically on game over',
                        helperStyle: const TextStyle(
                          color: _mutedTextColor,
                          fontSize: 11,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide:
                              const BorderSide(color: Color(0x33FFFFFF)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: _accentColor),
                        ),
                      ),
                      onChanged: (value) => unawaited(_saveName(value)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: _accentColor,
                      foregroundColor: const Color(0xFF07080A),
                    ),
                    onPressed: _submittingBest ? null : _submitBest,
                    child: Text(
                      _submittingBest ? '…' : 'Submit best',
                      style: const TextStyle(fontSize: 12),
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
                      child: CircularProgressIndicator(color: _accentColor),
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
                            color: _errorColor,
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
                        style: TextStyle(color: _mutedTextColor),
                      ),
                    );
                  }
                  final myName = _nameController.text.trim();
                  return ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final isMe =
                          myName.isNotEmpty && entry.name == myName;
                      return Card(
                        color: isMe
                            ? _accentColor.withValues(alpha: 0.14)
                            : _panelColor,
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 3,
                        ),
                        child: ListTile(
                          dense: true,
                          leading: Text(
                            '#${index + 1}',
                            style: TextStyle(
                              color: index < 3 ? _accentColor : _mutedTextColor,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          title: Text(
                            entry.name,
                            style: TextStyle(
                              color: _textColor,
                              fontSize: 14,
                              fontWeight:
                                  isMe ? FontWeight.w700 : FontWeight.w400,
                            ),
                          ),
                          trailing: Text(
                            '${entry.score}',
                            style: const TextStyle(
                              color: _textColor,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
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

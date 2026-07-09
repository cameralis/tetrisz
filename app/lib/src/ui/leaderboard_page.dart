import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_service.dart';
import '../net/leaderboard_client.dart';
import '../net/rankings_client.dart';
import 'components.dart';
import 'theme.dart';
import 'toasts.dart';

const tetrisPlayerNamePreferenceKey = 'tetris.playerName';
const _highScorePreferenceKey = 'tetris.highScore';

enum _Board { soloScores, versusRating }

/// Global boards: solo top-50 scores (name-keyed, auto-submitted on game
/// over) and the versus ELO ranking for signed-in players.
class LeaderboardPage extends StatefulWidget {
  const LeaderboardPage({super.key, this.rankingsApi});

  /// Defaults to the real backend client; tests inject a fake.
  final RankingsApi? rankingsApi;

  @override
  State<LeaderboardPage> createState() => _LeaderboardPageState();
}

class _LeaderboardPageState extends State<LeaderboardPage> {
  final _client = LeaderboardClient();
  late final RankingsApi _rankings =
      widget.rankingsApi ?? HttpRankingsApi(auth: Auth.instance);
  final _nameController = TextEditingController();
  Future<LeaderboardSnapshot>? _snapshotFuture;
  Future<RankingsSnapshot>? _rankingsFuture;
  _Board _board = _Board.soloScores;
  int _highScore = 0;
  bool _submittingBest = false;

  @override
  void initState() {
    super.initState();
    _snapshotFuture = _client.fetch();
    // Rankings load lazily on first opening that board.
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
      if (_rankingsFuture != null) {
        _rankingsFuture = _rankings.fetchRankings();
      }
    });
  }

  void _openBoard(_Board board) {
    setState(() {
      _board = board;
      if (board == _Board.versusRating) {
        _rankingsFuture ??= _rankings.fetchRankings();
      }
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
      TetrisToastHost.show(
        rank == null
            ? 'Submitted — outside the global top list for now.'
            : 'Your best is global rank #$rank',
        icon: Icons.emoji_events_rounded,
      );
      _refresh();
    } catch (error) {
      if (mounted) {
        TetrisToastHost.show(
          'Submit failed: $error',
          icon: Icons.error_outline_rounded,
          accent: TetrisColors.danger,
        );
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
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TetrisButton(
                      key: const ValueKey('board-solo'),
                      compact: true,
                      variant: _board == _Board.soloScores
                          ? TetrisButtonVariant.primary
                          : TetrisButtonVariant.secondary,
                      onPressed: () => _openBoard(_Board.soloScores),
                      child: const Text('Solo scores'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TetrisButton(
                      key: const ValueKey('board-versus'),
                      compact: true,
                      variant: _board == _Board.versusRating
                          ? TetrisButtonVariant.primary
                          : TetrisButtonVariant.secondary,
                      onPressed: () => _openBoard(_Board.versusRating),
                      child: const Text('Versus rating'),
                    ),
                  ),
                ],
              ),
            ),
            if (_board == _Board.soloScores)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
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
            if (_board == _Board.versusRating)
              Expanded(child: _buildRankings()),
            if (_board == _Board.soloScores)
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

  Widget _buildRankings() {
    return FutureBuilder<RankingsSnapshot>(
      future: _rankingsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(color: TetrisColors.accent),
          );
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not load the rankings.\n${snapshot.error}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: TetrisColors.danger,
                  fontSize: 13,
                ),
              ),
            ),
          );
        }
        final data = snapshot.data!;
        if (data.entries.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No rated matches yet.\nSign in and win 1v1 games to get '
                'ranked!',
                textAlign: TextAlign.center,
                style: TextStyle(color: TetrisColors.mutedText, height: 1.5),
              ),
            ),
          );
        }
        return Column(
          children: [
            if (data.yourRank != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
                child: TetrisPanel(
                  color: Color.lerp(
                    TetrisColors.panel,
                    TetrisColors.accent,
                    0.12,
                  )!,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'YOUR RANK',
                          style: TextStyle(
                            color: TetrisColors.mutedText,
                            fontSize: 11,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        '#${data.yourRank} · ${data.yourRating}',
                        key: const ValueKey('rankings-your-rank'),
                        style: const TextStyle(
                          color: TetrisColors.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                itemCount: data.entries.length,
                itemBuilder: (context, index) {
                  final entry = data.entries[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: TetrisPanel(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 40,
                            child: Text(
                              '#${entry.rank}',
                              style: TextStyle(
                                color: entry.rank <= 3
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
                              entry.displayName,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: TetrisColors.text,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          Text(
                            '${entry.rating}',
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
              ),
            ),
          ],
        );
      },
    );
  }
}

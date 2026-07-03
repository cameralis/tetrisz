import 'dart:convert';

import 'package:http/http.dart' as http;

import 'net_config.dart';

final class LeaderboardEntry {
  const LeaderboardEntry({
    required this.name,
    required this.score,
    required this.lines,
    required this.level,
  });

  static LeaderboardEntry? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    final name = json['name'];
    final score = json['score'];
    if (name is! String || score is! int) {
      return null;
    }
    return LeaderboardEntry(
      name: name,
      score: score,
      lines: json['lines'] as int? ?? 0,
      level: json['level'] as int? ?? 1,
    );
  }

  final String name;
  final int score;
  final int lines;
  final int level;
}

final class LeaderboardSnapshot {
  const LeaderboardSnapshot({required this.entries, required this.total});

  final List<LeaderboardEntry> entries;
  final int total;
}

/// Client for the global leaderboard endpoints. Scores are self-reported
/// (honest-client model), which is fine for a friends-scale game.
class LeaderboardClient {
  LeaderboardClient({http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final http.Client _http;

  Future<LeaderboardSnapshot> fetch() async {
    final response = await _http
        .get(backendHttpUri('/api/leaderboard'))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('Leaderboard fetch failed (HTTP ${response.statusCode})');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final entries = [
      for (final entry in body['entries'] as List? ?? const [])
        ?LeaderboardEntry.fromJson(entry),
    ];
    return LeaderboardSnapshot(
      entries: entries,
      total: body['total'] as int? ?? entries.length,
    );
  }

  /// Submits a score; returns the resulting 1-based rank, or null when the
  /// score did not make the stored top list.
  Future<int?> submit({
    required String name,
    required int score,
    required int lines,
    required int level,
  }) async {
    final response = await _http
        .post(
          backendHttpUri('/api/leaderboard'),
          body: jsonEncode({
            'name': name,
            'score': score,
            'lines': lines,
            'level': level,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('Score submit failed (HTTP ${response.statusCode})');
    }
    return (jsonDecode(response.body) as Map<String, dynamic>)['rank'] as int?;
  }

  void close() => _http.close();
}

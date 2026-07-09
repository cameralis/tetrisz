import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth_service.dart';
import 'net_config.dart';

enum ReportStatus { pending, rated, discarded }

class ReportOutcome {
  const ReportOutcome({required this.status, this.ratingDelta, this.newRating});

  factory ReportOutcome.fromJson(Map<String, dynamic> json) {
    return ReportOutcome(
      status: switch (json['status']) {
        'rated' => ReportStatus.rated,
        'discarded' => ReportStatus.discarded,
        _ => ReportStatus.pending,
      },
      ratingDelta: json['ratingDelta'] as int?,
      newRating: json['newRating'] as int?,
    );
  }

  final ReportStatus status;
  final int? ratingDelta;
  final int? newRating;
}

class RankingEntry {
  const RankingEntry({
    required this.rank,
    required this.displayName,
    required this.rating,
    required this.ratedGames,
  });

  final int rank;
  final String displayName;
  final int rating;
  final int ratedGames;
}

class RankingsSnapshot {
  const RankingsSnapshot({required this.entries, this.yourRank, this.yourRating});

  final List<RankingEntry> entries;
  final int? yourRank;
  final int? yourRating;
}

/// Rated-match reporting + global ranking list; injectable for tests.
abstract interface class RankingsApi {
  /// Reports this player's outcome for (roomCode, matchId). Returns pending
  /// until the opponent's complementary report lands.
  Future<ReportOutcome> reportResult({
    required String roomCode,
    required int matchId,
    required bool won,
  });

  Future<RankingsSnapshot> fetchRankings();
}

class HttpRankingsApi implements RankingsApi {
  HttpRankingsApi({required this.auth, http.Client? client})
    : _client = client ?? http.Client();

  final AuthService auth;
  final http.Client _client;

  @override
  Future<ReportOutcome> reportResult({
    required String roomCode,
    required int matchId,
    required bool won,
  }) async {
    final token = await auth.idToken();
    if (token == null) {
      return const ReportOutcome(status: ReportStatus.discarded);
    }
    final response = await _client
        .post(
          backendHttpUri('/api/versus/result'),
          headers: {'Authorization': 'Bearer $token'},
          body: jsonEncode({
            'roomCode': roomCode,
            'matchId': matchId,
            'outcome': won ? 'won' : 'lost',
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      return const ReportOutcome(status: ReportStatus.discarded);
    }
    return ReportOutcome.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  @override
  Future<RankingsSnapshot> fetchRankings() async {
    final token = await auth.idToken();
    final response = await _client
        .get(
          backendHttpUri('/api/rankings'),
          headers: token == null ? null : {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('Rankings fetch failed (${response.statusCode})');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final entries = (body['entries'] as List<dynamic>? ?? [])
        .map(
          (raw) => RankingEntry(
            rank: (raw as Map<String, dynamic>)['rank'] as int? ?? 0,
            displayName: raw['displayName'] as String? ?? '???',
            rating: raw['rating'] as int? ?? 0,
            ratedGames: raw['ratedGames'] as int? ?? 0,
          ),
        )
        .toList();
    final you = body['you'] as Map<String, dynamic>?;
    return RankingsSnapshot(
      entries: entries,
      yourRank: you?['rank'] as int?,
      yourRating: you?['rating'] as int?,
    );
  }

  void close() => _client.close();
}

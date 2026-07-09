import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth_service.dart';
import 'net_config.dart';

class PlayerProfile {
  const PlayerProfile({
    required this.uid,
    required this.displayName,
    required this.friendCode,
    required this.rating,
    required this.ratedGames,
  });

  factory PlayerProfile.fromJson(Map<String, dynamic> json) {
    return PlayerProfile(
      uid: json['uid'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      friendCode: json['friendCode'] as String? ?? '',
      rating: json['rating'] as int? ?? 0,
      ratedGames: json['ratedGames'] as int? ?? 0,
    );
  }

  final String uid;
  final String displayName;
  final String friendCode;
  final int rating;
  final int ratedGames;
}

/// Backend profile endpoints; injectable so widget tests can fake it.
abstract interface class ProfileApi {
  Future<PlayerProfile> fetch();

  Future<PlayerProfile> updateName(String displayName);
}

class ProfileException implements Exception {
  ProfileException(this.message);

  final String message;

  @override
  String toString() => message;
}

class HttpProfileApi implements ProfileApi {
  HttpProfileApi({required this.auth, http.Client? client})
    : _client = client ?? http.Client();

  final AuthService auth;
  final http.Client _client;

  Future<Map<String, String>> _headers() async {
    final token = await auth.idToken();
    if (token == null) {
      throw ProfileException('Not signed in');
    }
    return {'Authorization': 'Bearer $token'};
  }

  @override
  Future<PlayerProfile> fetch() async {
    final response = await _client
        .get(backendHttpUri('/api/profile'), headers: await _headers())
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw ProfileException('Profile fetch failed (${response.statusCode})');
    }
    return PlayerProfile.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  @override
  Future<PlayerProfile> updateName(String displayName) async {
    final response = await _client
        .put(
          backendHttpUri('/api/profile'),
          headers: await _headers(),
          body: jsonEncode({'displayName': displayName}),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw ProfileException('Name update failed (${response.statusCode})');
    }
    return PlayerProfile.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  void close() => _client.close();
}

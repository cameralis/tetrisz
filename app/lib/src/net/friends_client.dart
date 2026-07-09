import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth_service.dart';
import 'net_config.dart';

class Friend {
  const Friend({
    required this.uid,
    required this.displayName,
    required this.friendCode,
    required this.rating,
  });

  factory Friend.fromJson(Map<String, dynamic> json) {
    return Friend(
      uid: json['uid'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '???',
      friendCode: json['friendCode'] as String? ?? '',
      rating: json['rating'] as int? ?? 0,
    );
  }

  final String uid;
  final String displayName;
  final String friendCode;
  final int rating;
}

class FriendsException implements Exception {
  FriendsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Friend list endpoints; injectable so widget tests can fake it.
abstract interface class FriendsApi {
  Future<List<Friend>> list();

  /// Adds by friend code; throws [FriendsException] with a readable message
  /// for unknown/own/duplicate codes.
  Future<Friend> add(String friendCode);

  Future<void> remove(String uid);
}

class HttpFriendsApi implements FriendsApi {
  HttpFriendsApi({required this.auth, http.Client? client})
    : _client = client ?? http.Client();

  final AuthService auth;
  final http.Client _client;

  Future<Map<String, String>> _headers() async {
    final token = await auth.idToken();
    if (token == null) {
      throw FriendsException('Not signed in');
    }
    return {'Authorization': 'Bearer $token'};
  }

  @override
  Future<List<Friend>> list() async {
    final response = await _client
        .get(backendHttpUri('/api/friends'), headers: await _headers())
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw FriendsException('Friends fetch failed (${response.statusCode})');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['friends'] as List<dynamic>? ?? [])
        .map((raw) => Friend.fromJson(raw as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Friend> add(String friendCode) async {
    final response = await _client
        .post(
          backendHttpUri('/api/friends'),
          headers: await _headers(),
          body: jsonEncode({'friendCode': friendCode}),
        )
        .timeout(const Duration(seconds: 10));
    switch (response.statusCode) {
      case 200:
        return Friend.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>,
        );
      case 404:
        throw FriendsException('No player has that friend code.');
      case 409:
        throw FriendsException('You are already friends.');
      case 400:
        throw FriendsException("That's your own code!");
      default:
        throw FriendsException('Could not add friend '
            '(${response.statusCode}).');
    }
  }

  @override
  Future<void> remove(String uid) async {
    final response = await _client
        .post(
          backendHttpUri('/api/friends/remove'),
          headers: await _headers(),
          body: jsonEncode({'uid': uid}),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw FriendsException('Could not remove friend '
          '(${response.statusCode}).');
    }
  }

  void close() => _client.close();
}

import 'package:flutter/foundation.dart';

/// A signed-in player identity (Firebase uid once real auth is wired).
class PlayerAccount {
  const PlayerAccount({required this.uid, this.email});

  final String uid;
  final String? email;
}

/// Thrown by sign-in attempts when no auth backend is configured in this
/// build (the Firebase project setup is a manual step; see
/// docs/firebase-setup.md).
class AuthUnavailableException implements Exception {
  const AuthUnavailableException();

  @override
  String toString() =>
      'Accounts are not configured in this build yet — see '
      'docs/firebase-setup.md';
}

/// Thrown when the player dismisses the platform sign-in sheet. Callers treat
/// this as a no-op rather than an error.
class AuthCancelledException implements Exception {
  const AuthCancelledException();

  @override
  String toString() => 'Sign-in cancelled';
}

/// Injectable auth backend. Production will use a Firebase implementation
/// once the project is configured; tests and local dev use [FakeAuthService].
abstract interface class AuthService {
  /// Current account; null while signed out.
  ValueListenable<PlayerAccount?> get account;

  /// Whether a real auth backend is wired into this build.
  bool get isConfigured;

  Future<void> signInWithApple();

  Future<void> signInWithGoogle();

  Future<void> signInWithEmail(String email, String password);

  Future<void> signOut();

  /// Fresh bearer token for backend calls; null while signed out.
  Future<String?> idToken();
}

/// Process-wide access point, mirroring UiFeedback: production installs the
/// real service from main(); default keeps everything signed out.
abstract final class Auth {
  static AuthService instance = UnconfiguredAuthService();

  static void install(AuthService service) {
    instance = service;
  }
}

/// Placeholder until the Firebase project exists: permanently signed out and
/// sign-in attempts explain what is missing.
final class UnconfiguredAuthService implements AuthService {
  final ValueNotifier<PlayerAccount?> _account = ValueNotifier(null);

  @override
  ValueListenable<PlayerAccount?> get account => _account;

  @override
  bool get isConfigured => false;

  @override
  Future<void> signInWithApple() async => throw const AuthUnavailableException();

  @override
  Future<void> signInWithGoogle() async =>
      throw const AuthUnavailableException();

  @override
  Future<void> signInWithEmail(String email, String password) async =>
      throw const AuthUnavailableException();

  @override
  Future<void> signOut() async {}

  @override
  Future<String?> idToken() async => null;
}

/// Instant, always-succeeding auth for tests and local development.
final class FakeAuthService implements AuthService {
  FakeAuthService({this.uid = 'fake-user', this.token = 'fake-token'});

  final String uid;
  final String token;
  final ValueNotifier<PlayerAccount?> _account = ValueNotifier(null);

  @override
  ValueListenable<PlayerAccount?> get account => _account;

  @override
  bool get isConfigured => true;

  @override
  Future<void> signInWithApple() async => _signIn();

  @override
  Future<void> signInWithGoogle() async => _signIn();

  @override
  Future<void> signInWithEmail(String email, String password) async =>
      _signIn(email: email);

  void _signIn({String? email}) {
    _account.value = PlayerAccount(uid: uid, email: email);
  }

  @override
  Future<void> signOut() async {
    _account.value = null;
  }

  @override
  Future<String?> idToken() async =>
      _account.value == null ? null : token;
}

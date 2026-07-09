import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'auth_service.dart';

/// Real auth backed by Firebase Auth.
///
/// Installed from `main()` once `firebase_options.dart` exists; see
/// docs/firebase-setup.md. Sign-in mints a Firebase ID token that the
/// Cloudflare Worker verifies against Google's securetoken JWKS
/// (backend/src/auth.ts).
final class FirebaseAuthService implements AuthService {
  FirebaseAuthService({fb.FirebaseAuth? auth, this.googleServerClientId})
    : _auth = auth ?? fb.FirebaseAuth.instance {
    _account.value = _toAccount(_auth.currentUser);
    _auth.idTokenChanges().listen((user) {
      _account.value = _toAccount(user);
    });
  }

  /// OAuth *web* client id from google-services.json. Android needs it as the
  /// `serverClientId` or `authenticate()` returns a null `idToken`, which
  /// Firebase then rejects. Null on Apple platforms, which read the client id
  /// straight out of GoogleService-Info.plist.
  final String? googleServerClientId;

  final fb.FirebaseAuth _auth;
  final ValueNotifier<PlayerAccount?> _account = ValueNotifier(null);
  bool _googleInitialized = false;

  static PlayerAccount? _toAccount(fb.User? user) =>
      user == null ? null : PlayerAccount(uid: user.uid, email: user.email);

  @override
  ValueListenable<PlayerAccount?> get account => _account;

  @override
  bool get isConfigured => true;

  @override
  Future<String?> idToken() async => _auth.currentUser?.getIdToken();

  @override
  Future<void> signInWithApple() async {
    // Firebase binds the credential to a nonce to stop replay: Apple sees the
    // SHA-256 digest, Firebase re-hashes the raw value we hand back.
    final rawNonce = _randomNonce();
    final AuthorizationCredentialAppleID credential;
    try {
      credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: sha256.convert(utf8.encode(rawNonce)).toString(),
      );
    } on SignInWithAppleAuthorizationException catch (error) {
      if (error.code == AuthorizationErrorCode.canceled) {
        throw const AuthCancelledException();
      }
      rethrow;
    }
    await _auth.signInWithCredential(
      fb.OAuthProvider('apple.com').credential(
        idToken: credential.identityToken,
        rawNonce: rawNonce,
      ),
    );
  }

  @override
  Future<void> signInWithGoogle() async {
    final google = GoogleSignIn.instance;
    if (!_googleInitialized) {
      await google.initialize(serverClientId: googleServerClientId);
      _googleInitialized = true;
    }
    final GoogleSignInAccount account;
    try {
      account = await google.authenticate();
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        throw const AuthCancelledException();
      }
      rethrow;
    }
    await _auth.signInWithCredential(
      fb.GoogleAuthProvider.credential(
        idToken: account.authentication.idToken,
      ),
    );
  }

  @override
  Future<void> signInWithEmail(String email, String password) async {
    await _auth.signInWithEmailAndPassword(email: email, password: password);
  }

  @override
  Future<void> signOut() async {
    if (_googleInitialized) {
      await GoogleSignIn.instance.signOut();
    }
    await _auth.signOut();
  }

  static String _randomNonce([int length = 32]) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => charset[random.nextInt(charset.length)],
    ).join();
  }
}

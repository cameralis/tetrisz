import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../net/profile_client.dart';
import 'components.dart';
import 'theme.dart';
import 'toasts.dart';

/// Sign-in and profile screen. Signed out it offers Apple / Google / email
/// sign-in (surfacing a clear message while the Firebase project is not yet
/// configured); signed in it shows the editable display name, the shareable
/// friend code and the versus rating.
class AccountPage extends StatefulWidget {
  const AccountPage({super.key, this.auth, this.profileApi});

  /// Defaults to the process-wide [Auth.instance].
  final AuthService? auth;

  /// Defaults to the real backend client for the resolved auth service.
  final ProfileApi? profileApi;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  late final AuthService _auth = widget.auth ?? Auth.instance;
  late final ProfileApi _profile =
      widget.profileApi ?? HttpProfileApi(auth: _auth);
  final _nameController = TextEditingController();
  Future<PlayerProfile>? _profileFuture;
  bool _savingName = false;
  bool _signingIn = false;

  @override
  void initState() {
    super.initState();
    _auth.account.addListener(_onAccountChanged);
    _onAccountChanged();
  }

  @override
  void dispose() {
    _auth.account.removeListener(_onAccountChanged);
    _nameController.dispose();
    super.dispose();
  }

  void _onAccountChanged() {
    if (!mounted) {
      return;
    }
    setState(() {
      _profileFuture =
          _auth.account.value == null ? null : _profile.fetch();
    });
  }

  Future<void> _runSignIn(Future<void> Function() attempt) async {
    setState(() => _signingIn = true);
    try {
      await attempt();
    } on AuthCancelledException {
      // Dismissing the sheet is not a failure worth reporting.
    } on AuthUnavailableException catch (error) {
      TetrisToastHost.show(
        '$error',
        icon: Icons.info_outline_rounded,
      );
    } catch (error) {
      TetrisToastHost.show(
        'Sign-in failed: $error',
        icon: Icons.error_outline_rounded,
        accent: TetrisColors.danger,
      );
    } finally {
      if (mounted) {
        setState(() => _signingIn = false);
      }
    }
  }

  Future<void> _saveName() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      return;
    }
    setState(() => _savingName = true);
    try {
      final updated = await _profile.updateName(name);
      if (!mounted) {
        return;
      }
      setState(() {
        _profileFuture = Future.value(updated);
      });
      TetrisToastHost.show(
        'Display name saved',
        icon: Icons.check_circle_outline_rounded,
        accent: TetrisColors.ok,
      );
    } catch (error) {
      TetrisToastHost.show(
        '$error',
        icon: Icons.error_outline_rounded,
        accent: TetrisColors.danger,
      );
    } finally {
      if (mounted) {
        setState(() => _savingName = false);
      }
    }
  }

  Future<void> _promptEmailSignIn() async {
    final emailController = TextEditingController();
    final passwordController = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: TetrisColors.panel,
        title: const Text(
          'Sign in with email',
          style: TextStyle(color: TetrisColors.text, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TetrisTextField(
              key: const ValueKey('account-email'),
              controller: emailController,
              label: 'Email',
              autofocus: true,
            ),
            const SizedBox(height: 10),
            TetrisTextField(
              key: const ValueKey('account-password'),
              controller: passwordController,
              label: 'Password',
            ),
          ],
        ),
        actions: [
          TetrisButton(
            variant: TetrisButtonVariant.ghost,
            compact: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TetrisButton(
            variant: TetrisButtonVariant.primary,
            compact: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
    if (submitted != true || !mounted) {
      emailController.dispose();
      passwordController.dispose();
      return;
    }
    final email = emailController.text.trim();
    final password = passwordController.text;
    emailController.dispose();
    passwordController.dispose();
    await _runSignIn(() => _auth.signInWithEmail(email, password));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text(
          'Account',
          style: TextStyle(color: TetrisColors.text, fontSize: 17),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: ValueListenableBuilder<PlayerAccount?>(
                valueListenable: _auth.account,
                builder: (context, account, _) => account == null
                    ? _buildSignedOut()
                    : _buildSignedIn(account),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSignedOut() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(
          Icons.person_rounded,
          size: 56,
          color: TetrisColors.mutedText,
        ),
        const SizedBox(height: 10),
        const Text(
          'Sign in to unlock global rankings,\nfriends and 1v1 invites.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: TetrisColors.mutedText,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 28),
        TetrisButton(
          key: const ValueKey('account-signin-apple'),
          // Pre-focused so a controller lands on a selection when the page
          // opens.
          autofocus: true,
          icon: Icons.apple_rounded,
          onPressed: _signingIn
              ? null
              : () => unawaited(_runSignIn(_auth.signInWithApple)),
          child: const Text('Continue with Apple'),
        ),
        const SizedBox(height: 12),
        TetrisButton(
          key: const ValueKey('account-signin-google'),
          icon: Icons.g_mobiledata_rounded,
          onPressed: _signingIn
              ? null
              : () => unawaited(_runSignIn(_auth.signInWithGoogle)),
          child: const Text('Continue with Google'),
        ),
        const SizedBox(height: 12),
        TetrisButton(
          key: const ValueKey('account-signin-email'),
          variant: TetrisButtonVariant.ghost,
          onPressed: _signingIn ? null : () => unawaited(_promptEmailSignIn()),
          child: const Text('Use email instead'),
        ),
        if (!_auth.isConfigured) ...[
          const SizedBox(height: 20),
          const Text(
            'Heads up: this build has no Firebase project attached yet, so '
            'sign-in is disabled. docs/firebase-setup.md walks through the '
            'one-time setup.',
            textAlign: TextAlign.center,
            style: TextStyle(color: TetrisColors.mutedText, fontSize: 11),
          ),
        ],
      ],
    );
  }

  Widget _buildSignedIn(PlayerAccount account) {
    return FutureBuilder<PlayerProfile>(
      future: _profileFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(48),
            child: Center(
              child: CircularProgressIndicator(color: TetrisColors.accent),
            ),
          );
        }
        if (snapshot.hasError) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Could not load your profile.\n${snapshot.error}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: TetrisColors.danger,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 14),
              TetrisButton(
                autofocus: true,
                compact: true,
                onPressed: _onAccountChanged,
                child: const Text('Retry'),
              ),
            ],
          );
        }
        final profile = snapshot.data!;
        if (_nameController.text.isEmpty && profile.displayName.isNotEmpty) {
          _nameController.text = profile.displayName;
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TetrisTextField(
                    key: const ValueKey('account-name'),
                    controller: _nameController,
                    maxLength: 16,
                    label: 'Display name',
                  ),
                ),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: TetrisButton(
                    key: const ValueKey('account-save-name'),
                    // Controller seed for the signed-in layout; focusing the
                    // name field instead would pop the keyboard on mobile.
                    autofocus: true,
                    variant: TetrisButtonVariant.primary,
                    compact: true,
                    onPressed: _savingName ? null : () => unawaited(_saveName()),
                    child: Text(_savingName ? '…' : 'Save'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            TetrisPanel(
              child: Column(
                children: [
                  const TetrisSectionHeader('YOUR FRIEND CODE'),
                  SelectableText(
                    profile.friendCode,
                    key: const ValueKey('account-friend-code'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: TetrisColors.text,
                      fontSize: 30,
                      letterSpacing: 8,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Friends add you with this code.',
                    style: TextStyle(
                      color: TetrisColors.mutedText,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TetrisListTile(
              leading: const Icon(
                Icons.military_tech_rounded,
                color: TetrisColors.accent,
              ),
              title: const Text('Versus rating'),
              subtitle: Text(
                profile.ratedGames == 0
                    ? 'Play rated 1v1 matches to get ranked'
                    : '${profile.ratedGames} rated matches',
              ),
              trailing: Text(
                '${profile.rating}',
                key: const ValueKey('account-rating'),
                style: const TextStyle(
                  color: TetrisColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 20),
            TetrisButton(
              key: const ValueKey('account-signout'),
              variant: TetrisButtonVariant.ghost,
              onPressed: () => unawaited(_auth.signOut()),
              child: const Text('Sign out'),
            ),
          ],
        );
      },
    );
  }
}

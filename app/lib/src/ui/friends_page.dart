import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/auth_service.dart';
import '../net/friends_client.dart';
import '../net/profile_client.dart';
import 'account_page.dart';
import 'components.dart';
import 'theme.dart';
import 'toasts.dart';

/// Friends list: your shareable code, add-by-code, and the mutual list.
/// Presence and 1v1 invites arrive with the presence slice.
class FriendsPage extends StatefulWidget {
  const FriendsPage({super.key, this.auth, this.friendsApi, this.profileApi});

  final AuthService? auth;
  final FriendsApi? friendsApi;
  final ProfileApi? profileApi;

  @override
  State<FriendsPage> createState() => _FriendsPageState();
}

class _FriendsPageState extends State<FriendsPage> {
  late final AuthService _auth = widget.auth ?? Auth.instance;
  late final FriendsApi _friends =
      widget.friendsApi ?? HttpFriendsApi(auth: _auth);
  late final ProfileApi _profile =
      widget.profileApi ?? HttpProfileApi(auth: _auth);
  final _codeController = TextEditingController();
  Future<(PlayerProfile, List<Friend>)>? _dataFuture;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _auth.account.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _auth.account.removeListener(_reload);
    _codeController.dispose();
    super.dispose();
  }

  void _reload() {
    if (!mounted) {
      return;
    }
    setState(() {
      _dataFuture = _auth.account.value == null
          ? null
          : Future.wait([
              _profile.fetch(),
              _friends.list(),
            ]).then((results) =>
                (results[0] as PlayerProfile, results[1] as List<Friend>));
    });
  }

  Future<void> _addFriend() async {
    final code = _codeController.text.trim().toUpperCase();
    if (code.length < 6) {
      TetrisToastHost.show(
        'Friend codes are 6 characters.',
        icon: Icons.info_outline_rounded,
      );
      return;
    }
    setState(() => _adding = true);
    try {
      final friend = await _friends.add(code);
      _codeController.clear();
      TetrisToastHost.show(
        'You and ${friend.displayName} are now friends!',
        icon: Icons.people_alt_rounded,
        accent: TetrisColors.ok,
      );
      _reload();
    } catch (error) {
      TetrisToastHost.show(
        '$error',
        icon: Icons.error_outline_rounded,
        accent: TetrisColors.danger,
      );
    } finally {
      if (mounted) {
        setState(() => _adding = false);
      }
    }
  }

  Future<void> _removeFriend(Friend friend) async {
    try {
      await _friends.remove(friend.uid);
      TetrisToastHost.show(
        'Removed ${friend.displayName}.',
        icon: Icons.person_off_rounded,
      );
      _reload();
    } catch (error) {
      TetrisToastHost.show(
        '$error',
        icon: Icons.error_outline_rounded,
        accent: TetrisColors.danger,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text(
          'Friends',
          style: TextStyle(color: TetrisColors.text, fontSize: 17),
        ),
      ),
      body: SafeArea(
        child: ValueListenableBuilder<PlayerAccount?>(
          valueListenable: _auth.account,
          builder: (context, account, _) =>
              account == null ? _buildSignedOut() : _buildFriends(),
        ),
      ),
    );
  }

  Widget _buildSignedOut() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.people_alt_rounded,
              size: 56,
              color: TetrisColors.mutedText,
            ),
            const SizedBox(height: 12),
            const Text(
              'Sign in to add friends and\nchallenge them to 1v1.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: TetrisColors.mutedText,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            TetrisButton(
              key: const ValueKey('friends-goto-account'),
              variant: TetrisButtonVariant.primary,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AccountPage()),
              ),
              child: const Text('Go to Account'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFriends() {
    return FutureBuilder<(PlayerProfile, List<Friend>)>(
      future: _dataFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(color: TetrisColors.accent),
          );
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Could not load friends.\n${snapshot.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: TetrisColors.danger,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                TetrisButton(
                  compact: true,
                  onPressed: _reload,
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }
        final (profile, friends) = snapshot.data!;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TetrisPanel(
              child: Column(
                children: [
                  const TetrisSectionHeader('YOUR FRIEND CODE'),
                  SelectableText(
                    profile.friendCode,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: TetrisColors.text,
                      fontSize: 28,
                      letterSpacing: 8,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TetrisTextField(
                    key: const ValueKey('friends-code-field'),
                    controller: _codeController,
                    maxLength: 6,
                    label: "Friend's code",
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9]')),
                    ],
                    onSubmitted: (_) => unawaited(_addFriend()),
                  ),
                ),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: TetrisButton(
                    key: const ValueKey('friends-add'),
                    variant: TetrisButtonVariant.primary,
                    compact: true,
                    onPressed: _adding ? null : () => unawaited(_addFriend()),
                    child: Text(_adding ? '…' : 'Add'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const TetrisSectionHeader('FRIENDS'),
            if (friends.isEmpty)
              const Padding(
                padding: EdgeInsets.all(18),
                child: Text(
                  'No friends yet — swap codes and add each other!',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: TetrisColors.mutedText, fontSize: 13),
                ),
              ),
            for (final friend in friends)
              TetrisListTile(
                key: ValueKey('friend-${friend.uid}'),
                leading: const Icon(
                  // Presence dot arrives with the presence slice.
                  Icons.circle,
                  size: 12,
                  color: TetrisColors.mutedText,
                ),
                title: Text(friend.displayName),
                subtitle: Text(
                  '${friend.friendCode} · rating ${friend.rating}',
                ),
                trailing: TetrisIconButton(
                  key: ValueKey('friend-remove-${friend.uid}'),
                  icon: Icons.person_remove_rounded,
                  size: 36,
                  color: TetrisColors.mutedText,
                  tooltip: 'Remove friend',
                  onPressed: () => unawaited(_removeFriend(friend)),
                ),
              ),
          ],
        );
      },
    );
  }
}

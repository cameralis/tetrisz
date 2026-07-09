import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/auth_service.dart';
import '../net/friends_client.dart';
import '../net/presence_client.dart';
import '../net/profile_client.dart';
import 'account_page.dart';
import 'components.dart';
import 'spectate_page.dart';
import 'theme.dart';
import 'toasts.dart';

const _presencePollInterval = Duration(seconds: 10);

/// Friends list: your shareable code, add-by-code, live presence dots and
/// 1v1 invites for online friends.
class FriendsPage extends StatefulWidget {
  const FriendsPage({
    super.key,
    this.auth,
    this.friendsApi,
    this.profileApi,
    this.presenceQuery,
    this.presenceHub,
  });

  final AuthService? auth;
  final FriendsApi? friendsApi;
  final ProfileApi? profileApi;
  final PresenceQueryApi? presenceQuery;
  final PresenceHub? presenceHub;

  @override
  State<FriendsPage> createState() => _FriendsPageState();
}

class _FriendsPageState extends State<FriendsPage> {
  late final AuthService _auth = widget.auth ?? Auth.instance;
  late final FriendsApi _friends =
      widget.friendsApi ?? HttpFriendsApi(auth: _auth);
  late final ProfileApi _profile =
      widget.profileApi ?? HttpProfileApi(auth: _auth);
  late final PresenceQueryApi _presence =
      widget.presenceQuery ?? HttpPresenceQueryApi(auth: _auth);
  PresenceHub? get _hub => widget.presenceHub ?? PresenceHub.instance;
  final _codeController = TextEditingController();
  Future<(PlayerProfile, List<Friend>)>? _dataFuture;
  Map<String, FriendPresence> _statuses = {};
  List<String> _friendUids = [];
  Timer? _presenceTimer;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _auth.account.addListener(_reload);
    _reload();
    _presenceTimer = Timer.periodic(
      _presencePollInterval,
      (_) => unawaited(_refreshPresence()),
    );
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
    _auth.account.removeListener(_reload);
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _refreshPresence() async {
    if (_friendUids.isEmpty || _auth.account.value == null) {
      return;
    }
    try {
      final statuses = await _presence.query(_friendUids);
      if (mounted) {
        setState(() => _statuses = statuses);
      }
    } catch (_) {}
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
            ]).then((results) {
              final friends = results[1] as List<Friend>;
              _friendUids = friends.map((friend) => friend.uid).toList();
              unawaited(_refreshPresence());
              return (results[0] as PlayerProfile, friends);
            });
    });
  }

  void _invite(Friend friend) {
    final hub = _hub;
    if (hub == null) {
      return;
    }
    hub.sendInvite(friend.uid);
    TetrisToastHost.show(
      'Challenge sent to ${friend.displayName}!',
      icon: Icons.sports_esports_rounded,
      accent: TetrisColors.accent,
    );
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
                leading: Icon(
                  Icons.circle,
                  size: 12,
                  color: switch (_statuses[friend.uid]) {
                    FriendPresence.online => TetrisColors.ok,
                    FriendPresence.solo => TetrisColors.accent,
                    FriendPresence.versus => const Color(0xFFF79E45),
                    _ => TetrisColors.mutedText,
                  },
                ),
                title: Text(friend.displayName),
                subtitle: Text(
                  switch (_statuses[friend.uid]) {
                    FriendPresence.online => 'Online',
                    FriendPresence.solo => 'Playing solo',
                    FriendPresence.versus => 'In a match',
                    _ => '${friend.friendCode} · rating ${friend.rating}',
                  },
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_statuses[friend.uid] == FriendPresence.solo)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: TetrisButton(
                          key: ValueKey('friend-watch-${friend.uid}'),
                          variant: TetrisButtonVariant.danger,
                          compact: true,
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => SpectatePage(
                                friend: friend,
                                hub: _hub,
                              ),
                            ),
                          ),
                          child: const Text('LIVE'),
                        ),
                      ),
                    if (_statuses[friend.uid] == FriendPresence.online ||
                        _statuses[friend.uid] == FriendPresence.solo)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: TetrisButton(
                          key: ValueKey('friend-invite-${friend.uid}'),
                          variant: TetrisButtonVariant.primary,
                          compact: true,
                          onPressed: () => _invite(friend),
                          child: const Text('1v1'),
                        ),
                      ),
                    TetrisIconButton(
                      key: ValueKey('friend-remove-${friend.uid}'),
                      icon: Icons.person_remove_rounded,
                      size: 36,
                      color: TetrisColors.mutedText,
                      tooltip: 'Remove friend',
                      onPressed: () => unawaited(_removeFriend(friend)),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

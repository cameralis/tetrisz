import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preference key shared with the in-game SFX volume slider; UI sounds follow
/// the same setting so one slider rules all effects.
const tetrisSfxVolumePreferenceKey = 'tetris.sfxVolume';

/// Interaction sounds for menus and overlays. They reuse the gameplay SFX
/// assets so the menus speak the same heavy-block language as the board.
enum UiSfx {
  /// Hover / focus move: the soft tick of a piece sliding one cell.
  tick('sfx/slide.mp3', gain: 0.35),

  /// Press / activate: the thunk of a piece locking.
  confirm('sfx/hard_lock.mp3', gain: 0.55),

  /// Back out / cancel / dismiss.
  back('sfx/counter_rotate.mp3', gain: 0.5),

  /// Toast landing (a hard drop's slam).
  toast('sfx/hard_drop.mp3', gain: 0.5);

  const UiSfx(this.assetPath, {required this.gain});

  final String assetPath;

  /// Per-effect attenuation; menu feedback sits under the gameplay mix.
  final double gain;
}

abstract interface class UiSounds {
  void play(UiSfx sfx);

  void dispose();
}

final class NoopUiSounds implements UiSounds {
  const NoopUiSounds();

  @override
  void play(UiSfx sfx) {}

  @override
  void dispose() {}
}

/// Process-wide access point. Production installs [AssetUiSounds] from
/// `main()`; widget tests keep the default noop (or install a recorder) so
/// nothing touches the audio platform channels.
abstract final class UiFeedback {
  static UiSounds sounds = const NoopUiSounds();

  /// Normalized 0..1 master volume, mirroring `tetris.sfxVolume` (0..2).
  static double sfxVolume = 1.0;

  static void install(UiSounds implementation) {
    sounds = implementation;
  }

  static void play(UiSfx sfx) {
    if (sfxVolume <= 0) {
      return;
    }
    sounds.play(sfx);
  }

  /// The in-game slider stores 0..2 (see `_maxSfxVolume` in tetris_app.dart).
  static const _storedVolumeMax = 2.0;

  static void setFromStoredSfxVolume(double stored) {
    sfxVolume = (stored / _storedVolumeMax).clamp(0.0, 1.0);
  }

  /// Picks up the saved slider value without delaying first frame.
  static Future<void> loadVolumeFromPreferences() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final stored = preferences.getDouble(tetrisSfxVolumePreferenceKey);
      if (stored != null) {
        setFromStoredSfxVolume(stored);
      }
    } catch (_) {}
  }
}

final class AssetUiSounds implements UiSounds {
  AssetUiSounds({AudioCache? audioCache})
    : _audioCache = audioCache ?? AudioCache(prefix: '') {
    for (final sfx in UiSfx.values) {
      unawaited(_playersFor(sfx).then<void>((_) {}, onError: (_, _) {}));
    }
  }

  /// Small fixed pool per effect, mirroring AssetTetrisSoundEffects: the
  /// N+1th overlapping copy rewinds the oldest player instead of allocating,
  /// because audioplayers never evicts released players from its native
  /// registry and per-play allocation leaks a player + event channel.
  static const _playersPerEffect = 2;

  /// Rapid focus traversal can fire ticks per frame; keep a floor between
  /// starts of the same effect.
  static const _minimumStartGap = Duration(milliseconds: 45);

  final AudioCache _audioCache;
  final Map<UiSfx, Future<List<AudioPlayer>>> _players = {};
  final Map<UiSfx, int> _nextPlayerIndex = {};
  final Map<UiSfx, int> _lastStartMilliseconds = {};
  final Set<UiSfx> _startsInProgress = {};
  final Stopwatch _clock = Stopwatch()..start();

  @override
  void play(UiSfx sfx) {
    final volume = (UiFeedback.sfxVolume * sfx.gain).clamp(0.0, 1.0);
    if (volume <= 0 || _startsInProgress.contains(sfx)) {
      return;
    }
    final now = _clock.elapsedMilliseconds;
    final lastStart = _lastStartMilliseconds[sfx];
    if (lastStart != null && now - lastStart < _minimumStartGap.inMilliseconds) {
      return;
    }
    _lastStartMilliseconds[sfx] = now;
    _startsInProgress.add(sfx);
    unawaited(_play(sfx, volume));
  }

  Future<void> _play(UiSfx sfx, double volume) async {
    try {
      final players = await _playersFor(sfx);
      final index = _nextPlayerIndex[sfx] ?? 0;
      _nextPlayerIndex[sfx] = (index + 1) % players.length;
      final player = players[index];
      await player.stop();
      await player.setVolume(volume);
      await player.resume();
    } catch (_) {
    } finally {
      _startsInProgress.remove(sfx);
    }
  }

  Future<List<AudioPlayer>> _playersFor(UiSfx sfx) {
    return _players.putIfAbsent(sfx, () async {
      final players = <AudioPlayer>[];
      try {
        for (var i = 0; i < _playersPerEffect; i += 1) {
          final player = AudioPlayer()..audioCache = _audioCache;
          // Position streams are unused; the default frame-based updater
          // would poll getCurrentPosition every frame while a sound plays.
          player.positionUpdater = null;
          players.add(player);
          await player.setReleaseMode(ReleaseMode.stop);
          await player.setSource(AssetSource(sfx.assetPath));
        }
        return players;
      } catch (_) {
        for (final player in players) {
          unawaited(player.dispose());
        }
        rethrow;
      }
    });
  }

  @override
  void dispose() {
    unawaited(_dispose());
  }

  Future<void> _dispose() async {
    for (final playersFuture in _players.values) {
      try {
        final players = await playersFuture;
        await Future.wait(players.map((player) => player.dispose()));
      } catch (_) {}
    }
  }
}

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tetris/src/ui/tetris_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAudioplayersPlatform platform;

  setUp(() {
    platform = _FakeAudioplayersPlatform();
    AudioplayersPlatformInterface.instance = platform;
    GlobalAudioplayersPlatformInterface.instance =
        _FakeGlobalAudioplayersPlatform();
  });

  testWidgets('boosted sound effect volume starts one playback', (
    tester,
  ) async {
    final soundEffects = AssetTetrisSoundEffects(audioCache: _FakeAudioCache());
    addTearDown(soundEffects.dispose);

    soundEffects.play(TetrisSfx.slide, volume: 2);

    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    final starts = platform.calls.where((call) => call.method == 'resume');
    final volumes = platform.calls
        .where((call) => call.method == 'setVolume')
        .map((call) => call.value);

    expect(starts, hasLength(1));
    expect(volumes, [1.0]);
  });

  testWidgets('rapid repeated sound effects do not queue delayed playback', (
    tester,
  ) async {
    final soundEffects = AssetTetrisSoundEffects(audioCache: _FakeAudioCache());
    addTearDown(soundEffects.dispose);

    for (var i = 0; i < 20; i += 1) {
      soundEffects.play(TetrisSfx.slide, volume: 2);
    }

    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });

    final starts = platform.calls.where((call) => call.method == 'resume');

    expect(starts, hasLength(1));
  });

  testWidgets('movement sound effects can restart after the start gap', (
    tester,
  ) async {
    final soundEffects = AssetTetrisSoundEffects(audioCache: _FakeAudioCache());
    addTearDown(soundEffects.dispose);

    soundEffects.play(TetrisSfx.slide, volume: 2);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });

    soundEffects.play(TetrisSfx.slide, volume: 2);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });

    final starts = platform.calls.where((call) => call.method == 'resume');

    expect(starts, hasLength(2));
  });
}

final class _FakeAudioCache extends AudioCache {
  _FakeAudioCache() : super(prefix: '');

  @override
  Future<String> loadPath(String fileName) async => '/tmp/$fileName';
}

final class _FakeCall {
  const _FakeCall({required this.id, required this.method, this.value});

  final String id;
  final String method;
  final Object? value;
}

final class _FakeAudioplayersPlatform extends AudioplayersPlatformInterface {
  final calls = <_FakeCall>[];
  final _eventStreams = <String, StreamController<AudioEvent>>{};

  @override
  Future<void> create(String playerId) async {
    calls.add(_FakeCall(id: playerId, method: 'create'));
    _eventStreams[playerId] = StreamController<AudioEvent>.broadcast();
  }

  @override
  Future<void> dispose(String playerId) async {
    calls.add(_FakeCall(id: playerId, method: 'dispose'));
    await _eventStreams[playerId]?.close();
  }

  @override
  Future<void> emitError(String playerId, String code, String message) async {
    calls.add(_FakeCall(id: playerId, method: 'emitError'));
  }

  @override
  Future<void> emitLog(String playerId, String message) async {
    calls.add(_FakeCall(id: playerId, method: 'emitLog'));
  }

  @override
  Future<int?> getCurrentPosition(String playerId) async {
    calls.add(_FakeCall(id: playerId, method: 'getCurrentPosition'));
    return 0;
  }

  @override
  Future<int?> getDuration(String playerId) async {
    calls.add(_FakeCall(id: playerId, method: 'getDuration'));
    return 0;
  }

  @override
  Future<void> pause(String playerId) async {
    calls.add(_FakeCall(id: playerId, method: 'pause'));
  }

  @override
  Future<void> release(String playerId) async {
    calls.add(_FakeCall(id: playerId, method: 'release'));
  }

  @override
  Future<void> resume(String playerId) async {
    calls.add(_FakeCall(id: playerId, method: 'resume'));
    unawaited(
      Future<void>.microtask(() {
        _eventStreams[playerId]?.add(
          const AudioEvent(eventType: AudioEventType.complete),
        );
      }),
    );
  }

  @override
  Future<void> seek(String playerId, Duration position) async {
    calls.add(_FakeCall(id: playerId, method: 'seek', value: position));
  }

  @override
  Future<void> setAudioContext(
    String playerId,
    AudioContext audioContext,
  ) async {
    calls.add(
      _FakeCall(id: playerId, method: 'setAudioContext', value: audioContext),
    );
  }

  @override
  Future<void> setBalance(String playerId, double balance) async {
    calls.add(_FakeCall(id: playerId, method: 'setBalance', value: balance));
  }

  @override
  Future<void> setPlaybackRate(String playerId, double playbackRate) async {
    calls.add(
      _FakeCall(id: playerId, method: 'setPlaybackRate', value: playbackRate),
    );
  }

  @override
  Future<void> setPlayerMode(String playerId, PlayerMode playerMode) async {
    calls.add(
      _FakeCall(id: playerId, method: 'setPlayerMode', value: playerMode),
    );
  }

  @override
  Future<void> setReleaseMode(String playerId, ReleaseMode releaseMode) async {
    calls.add(
      _FakeCall(id: playerId, method: 'setReleaseMode', value: releaseMode),
    );
  }

  @override
  Future<void> setSourceBytes(
    String playerId,
    Uint8List bytes, {
    String? mimeType,
  }) async {
    calls.add(_FakeCall(id: playerId, method: 'setSourceBytes', value: bytes));
    _markPrepared(playerId);
  }

  @override
  Future<void> setSourceUrl(
    String playerId,
    String url, {
    bool? isLocal,
    String? mimeType,
  }) async {
    calls.add(_FakeCall(id: playerId, method: 'setSourceUrl', value: url));
    _markPrepared(playerId);
  }

  @override
  Future<void> setVolume(String playerId, double volume) async {
    calls.add(_FakeCall(id: playerId, method: 'setVolume', value: volume));
  }

  @override
  Future<void> stop(String playerId) async {
    calls.add(_FakeCall(id: playerId, method: 'stop'));
  }

  @override
  Stream<AudioEvent> getEventStream(String playerId) {
    calls.add(_FakeCall(id: playerId, method: 'getEventStream'));
    return _eventStreams[playerId]!.stream;
  }

  void _markPrepared(String playerId) {
    _eventStreams[playerId]?.add(
      const AudioEvent(eventType: AudioEventType.prepared, isPrepared: true),
    );
  }
}

final class _FakeGlobalAudioplayersPlatform
    extends GlobalAudioplayersPlatformInterface {
  final _eventStream = StreamController<GlobalAudioEvent>.broadcast();

  @override
  Future<void> emitGlobalError(String code, String message) async {
    _eventStream.addError(PlatformException(code: code, message: message));
  }

  @override
  Future<void> emitGlobalLog(String message) async {
    _eventStream.add(
      GlobalAudioEvent(
        eventType: GlobalAudioEventType.log,
        logMessage: message,
      ),
    );
  }

  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() {
    return _eventStream.stream;
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> setGlobalAudioContext(AudioContext ctx) async {}
}

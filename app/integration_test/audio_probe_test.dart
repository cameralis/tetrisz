import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetris/src/ui/tetris_app.dart';
import 'package:tetris/src/ui/ui_sounds.dart';

/// Audio verification drive: launches the real app WITH audio enabled, plays
/// a UI sound and then in-game music, holding each phase long enough for an
/// external watcher to confirm the process owns a CoreAudio output stream
/// (`pmset -g assertions` lists an `audio-out` assertion per playing PID).
///
/// Markers land in E2E_MARKER_DIR: `audio-ui-sfx` while the UI sound plays,
/// `audio-music` while in-game music plays, `audio-probe-done` at the end.
const _markerDir = String.fromEnvironment('E2E_MARKER_DIR');

void _mark(String name) {
  if (_markerDir.isNotEmpty) {
    File('$_markerDir/$name')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('');
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('real app produces audio for UI sfx and game music', (
    tester,
  ) async {
    // A saved game would boot the board paused (music held); start clean.
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(tetrisSavedGamePreferenceKey);
    await preferences.remove(tetrisSfxVolumePreferenceKey);
    await preferences.remove('tetris.musicVolume');

    UiFeedback.install(AssetUiSounds());
    await tester.pumpWidget(const TetrisApp());
    await tester.pump(const Duration(milliseconds: 800));

    // Phase 1: a long UI sound (the level-up fanfare) from the menu.
    UiFeedback.play(UiSfx.win);
    _mark('audio-ui-sfx');
    await tester.pump(const Duration(seconds: 3));

    // Phase 2: start a round; music starts with the game page.
    await tester.tap(find.byKey(const ValueKey('home-play')));
    _mark('audio-music');
    // Music is a multi-minute track; hold long enough for several samples.
    await tester.pump(const Duration(seconds: 8));

    _mark('audio-probe-done');
    await tester.pump(const Duration(milliseconds: 400));
  });
}

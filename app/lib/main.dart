import 'dart:async';

import 'package:flutter/material.dart';

import 'src/input/gamepad_service.dart';
import 'src/ui/tetris_app.dart';
import 'src/ui/ui_sounds.dart';

void main() {
  UiFeedback.install(AssetUiSounds());
  unawaited(UiFeedback.loadVolumeFromPreferences());
  runApp(TetrisApp(gamepad: GamepadService.instance));
}

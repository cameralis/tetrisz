import 'dart:async';

import 'package:flutter/material.dart';

import 'src/auth/auth_service.dart';
import 'src/input/gamepad_service.dart';
import 'src/net/presence_client.dart';
import 'src/ui/tetris_app.dart';
import 'src/ui/ui_sounds.dart';

void main() {
  UiFeedback.install(AssetUiSounds());
  unawaited(UiFeedback.loadVolumeFromPreferences());
  // Presence activates once a real auth service signs someone in; with the
  // default unconfigured auth it stays dormant.
  PresenceHub.install(PresenceHub(auth: Auth.instance));
  runApp(TetrisApp(gamepad: GamepadService.instance));
}

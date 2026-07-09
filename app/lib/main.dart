import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'src/auth/auth_service.dart';
import 'src/auth/firebase_auth_service.dart';
import 'src/input/gamepad_service.dart';
import 'src/net/presence_client.dart';
import 'src/ui/tetris_app.dart';
import 'src/ui/ui_sounds.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  // Must precede PresenceHub, which captures Auth.instance at install time.
  Auth.install(
    FirebaseAuthService(
      // The OAuth *web* client from google-services.json; Apple platforms
      // read theirs from GoogleService-Info.plist instead.
      googleServerClientId:
          defaultTargetPlatform == TargetPlatform.android && !kIsWeb
          ? '249079443387-p8as0spvcbnnu402ukefqst3bbaj74ng.apps.googleusercontent.com'
          : null,
    ),
  );
  UiFeedback.install(AssetUiSounds());
  unawaited(UiFeedback.loadVolumeFromPreferences());
  // Presence activates once a real auth service signs someone in; with the
  // default unconfigured auth it stays dormant.
  PresenceHub.install(PresenceHub(auth: Auth.instance));
  runApp(TetrisApp(gamepad: GamepadService.instance));
}

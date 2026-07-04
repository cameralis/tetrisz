import 'package:flutter/material.dart';

import 'src/input/gamepad_service.dart';
import 'src/ui/tetris_app.dart';

void main() {
  runApp(TetrisApp(gamepad: GamepadService.instance));
}

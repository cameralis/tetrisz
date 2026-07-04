import 'dart:convert';

import 'package:flutter/foundation.dart';

const tetrisGamepadBindingsPreferenceKey = 'tetris.gamepadBindings';
const tetrisTouchBindingsPreferenceKey = 'tetris.touchBindings';

/// A rebindable gameplay command. Gamepad controls and touch gestures both
/// resolve to one of these before reaching the engine.
enum GameAction {
  moveLeft('Move Left'),
  moveRight('Move Right'),
  softDrop('Soft Drop'),
  hardDrop('Hard Drop'),
  rotateClockwise('Rotate Right'),
  rotateCounterClockwise('Rotate Left'),
  hold('Hold'),
  pause('Pause');

  const GameAction(this.label);

  final String label;

  static GameAction? tryParse(String? name) =>
      name == null ? null : values.asNameMap()[name];
}

/// A bindable physical control, named after the standard Xbox layout with the
/// PlayStation equivalent in the label. Stick directions are virtual digital
/// controls derived from the analog axes.
enum GamepadControl {
  dpadUp('D-Pad Up'),
  dpadDown('D-Pad Down'),
  dpadLeft('D-Pad Left'),
  dpadRight('D-Pad Right'),
  buttonSouth('A / Cross'),
  buttonEast('B / Circle'),
  buttonWest('X / Square'),
  buttonNorth('Y / Triangle'),
  leftBumper('LB / L1'),
  rightBumper('RB / R1'),
  leftTrigger('LT / L2'),
  rightTrigger('RT / R2'),
  select('View / Create'),
  start('Menu / Options'),
  leftStickButton('L3'),
  rightStickButton('R3'),
  touchpad('Touchpad Click'),
  leftStickUp('Left Stick Up'),
  leftStickDown('Left Stick Down'),
  leftStickLeft('Left Stick Left'),
  leftStickRight('Left Stick Right'),
  rightStickUp('Right Stick Up'),
  rightStickDown('Right Stick Down'),
  rightStickLeft('Right Stick Left'),
  rightStickRight('Right Stick Right');

  const GamepadControl(this.label);

  final String label;

  static GamepadControl? tryParse(String? name) =>
      name == null ? null : values.asNameMap()[name];
}

/// The gamepad control → action map. Immutable; rebinding produces a new
/// instance. The persisted JSON is the complete truth: a control absent from
/// the map is unbound.
@immutable
class GamepadBindings {
  const GamepadBindings(this._map);

  /// The Tetris Guideline standard mapping (tetris.wiki/Tetris_Guideline):
  /// up performs a locking hard drop, down a non-locking soft drop, left and
  /// right shift the piece, the left fire button (A/Cross, mirrored on
  /// X/Square) rotates counterclockwise and the right fire button (B/Circle,
  /// mirrored on Y/Triangle) rotates clockwise. The left stick doubles as the
  /// d-pad, the bumpers hold, and Menu/Options pauses.
  static const Map<GamepadControl, GameAction> guidelineDefaults = {
    GamepadControl.dpadUp: GameAction.hardDrop,
    GamepadControl.dpadDown: GameAction.softDrop,
    GamepadControl.dpadLeft: GameAction.moveLeft,
    GamepadControl.dpadRight: GameAction.moveRight,
    GamepadControl.leftStickUp: GameAction.hardDrop,
    GamepadControl.leftStickDown: GameAction.softDrop,
    GamepadControl.leftStickLeft: GameAction.moveLeft,
    GamepadControl.leftStickRight: GameAction.moveRight,
    GamepadControl.buttonSouth: GameAction.rotateCounterClockwise,
    GamepadControl.buttonWest: GameAction.rotateCounterClockwise,
    GamepadControl.buttonEast: GameAction.rotateClockwise,
    GamepadControl.buttonNorth: GameAction.rotateClockwise,
    GamepadControl.leftBumper: GameAction.hold,
    GamepadControl.rightBumper: GameAction.hold,
    GamepadControl.start: GameAction.pause,
  };

  factory GamepadBindings.guideline() =>
      const GamepadBindings(guidelineDefaults);

  /// Parses persisted bindings; `null` or malformed input falls back to the
  /// guideline defaults, unknown control/action names are skipped.
  factory GamepadBindings.decode(String? json) {
    if (json == null) {
      return GamepadBindings.guideline();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return GamepadBindings.guideline();
    }
    if (decoded is! Map<String, dynamic>) {
      return GamepadBindings.guideline();
    }
    final map = <GamepadControl, GameAction>{};
    for (final entry in decoded.entries) {
      final control = GamepadControl.tryParse(entry.key);
      final action = GameAction.tryParse(entry.value as String?);
      if (control != null && action != null) {
        map[control] = action;
      }
    }
    return GamepadBindings(map);
  }

  final Map<GamepadControl, GameAction> _map;

  GameAction? actionFor(GamepadControl control) => _map[control];

  List<GamepadControl> controlsFor(GameAction action) => [
    for (final control in GamepadControl.values)
      if (_map[control] == action) control,
  ];

  GamepadBindings bind(GamepadControl control, GameAction action) =>
      GamepadBindings({..._map, control: action});

  GamepadBindings unbind(GamepadControl control) =>
      GamepadBindings({..._map}..remove(control));

  String encode() => jsonEncode({
    for (final entry in _map.entries) entry.key.name: entry.value.name,
  });
}

/// A rebindable touch gesture on the board surface. Horizontal dragging is
/// the movement scheme itself and stays fixed.
enum TouchGesture {
  tapLeft('Tap Left Side'),
  tapRight('Tap Right Side'),
  swipeUp('Swipe Up'),
  swipeDown('Swipe Down'),
  longPress('Long Press');

  const TouchGesture(this.label);

  final String label;
}

/// The touch gesture → action map. Every gesture always has an entry; `null`
/// means explicitly unbound. Held gestures (long press) sustain [GameAction
/// .softDrop]; momentary gestures perform a single soft-drop step.
@immutable
class TouchBindings {
  const TouchBindings(this._map);

  static const Map<TouchGesture, GameAction?> defaultBindings = {
    TouchGesture.tapLeft: GameAction.rotateCounterClockwise,
    TouchGesture.tapRight: GameAction.rotateClockwise,
    TouchGesture.swipeUp: GameAction.hold,
    TouchGesture.swipeDown: GameAction.hardDrop,
    TouchGesture.longPress: GameAction.softDrop,
  };

  factory TouchBindings.defaults() => const TouchBindings(defaultBindings);

  /// Parses persisted bindings; gestures missing from the JSON keep their
  /// default, a persisted `"none"` is an explicit unbind.
  factory TouchBindings.decode(String? json) {
    if (json == null) {
      return TouchBindings.defaults();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return TouchBindings.defaults();
    }
    if (decoded is! Map<String, dynamic>) {
      return TouchBindings.defaults();
    }
    final map = <TouchGesture, GameAction?>{};
    for (final gesture in TouchGesture.values) {
      if (decoded.containsKey(gesture.name)) {
        map[gesture] = GameAction.tryParse(decoded[gesture.name] as String?);
      } else {
        map[gesture] = defaultBindings[gesture];
      }
    }
    return TouchBindings(map);
  }

  final Map<TouchGesture, GameAction?> _map;

  GameAction? actionFor(TouchGesture gesture) =>
      _map.containsKey(gesture) ? _map[gesture] : defaultBindings[gesture];

  TouchBindings bind(TouchGesture gesture, GameAction? action) =>
      TouchBindings({..._map, gesture: action});

  String encode() => jsonEncode({
    for (final gesture in TouchGesture.values)
      gesture.name: actionFor(gesture)?.name ?? 'none',
  });
}

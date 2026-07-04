import 'dart:async';

import 'package:gamepads/gamepads.dart';

import 'control_bindings.dart';

/// A press or release edge on one bindable [GamepadControl].
class GamepadControlEvent {
  const GamepadControlEvent({
    required this.gamepadId,
    required this.control,
    required this.pressed,
  });

  final String gamepadId;
  final GamepadControl control;
  final bool pressed;

  @override
  String toString() =>
      '[$gamepadId] ${control.name} ${pressed ? 'pressed' : 'released'}';
}

/// Converts the plugin's normalized button/axis stream into clean
/// press/release edges on [GamepadControl]s: analog sticks become four
/// digital directions with hysteresis, triggers become digital presses, and
/// duplicate reports (e.g. a trigger surfacing as both a button and an axis)
/// collapse into a single edge by tracking pressed state per pad.
///
/// Works with any controller the platform recognizes — Xbox and PlayStation
/// pads over Bluetooth or USB on Android, iOS, macOS and web.
class GamepadService {
  GamepadService({
    Stream<NormalizedGamepadEvent>? events,
    Future<List<GamepadController>> Function()? list,
  }) : _source = events,
       _list = list;

  static final GamepadService instance = GamepadService();

  // A stick direction engages at 50% deflection and releases below 35%, so
  // jitter around the threshold cannot retrigger DAS.
  static const _axisPressThreshold = 0.5;
  static const _axisReleaseThreshold = 0.35;

  final Stream<NormalizedGamepadEvent>? _source;
  final Future<List<GamepadController>> Function()? _list;
  final _controller = StreamController<GamepadControlEvent>.broadcast();
  final _pressedByPad = <String, Set<GamepadControl>>{};
  StreamSubscription<NormalizedGamepadEvent>? _subscription;
  int _uiNavigationBlocks = 0;

  /// While true, the controller belongs to gameplay (or a binding-capture
  /// dialog) and the UI focus navigator must ignore its events.
  bool get uiNavigationBlocked => _uiNavigationBlocks > 0;

  /// Claims the controller for gameplay-style consumption. Balanced by
  /// [unblockUiNavigation]; claims nest so a capture dialog opened over a
  /// paused game cannot release the game page's claim early.
  void blockUiNavigation() {
    _uiNavigationBlocks += 1;
  }

  void unblockUiNavigation() {
    if (_uiNavigationBlocks > 0) {
      _uiNavigationBlocks -= 1;
    }
  }

  static const _buttonControls = <GamepadButton, GamepadControl>{
    GamepadButton.a: GamepadControl.buttonSouth,
    GamepadButton.b: GamepadControl.buttonEast,
    GamepadButton.x: GamepadControl.buttonWest,
    GamepadButton.y: GamepadControl.buttonNorth,
    GamepadButton.leftBumper: GamepadControl.leftBumper,
    GamepadButton.rightBumper: GamepadControl.rightBumper,
    GamepadButton.leftTrigger: GamepadControl.leftTrigger,
    GamepadButton.rightTrigger: GamepadControl.rightTrigger,
    GamepadButton.back: GamepadControl.select,
    GamepadButton.start: GamepadControl.start,
    GamepadButton.leftStick: GamepadControl.leftStickButton,
    GamepadButton.rightStick: GamepadControl.rightStickButton,
    GamepadButton.dpadUp: GamepadControl.dpadUp,
    GamepadButton.dpadDown: GamepadControl.dpadDown,
    GamepadButton.dpadLeft: GamepadControl.dpadLeft,
    GamepadButton.dpadRight: GamepadControl.dpadRight,
    GamepadButton.touchpad: GamepadControl.touchpad,
    // GamepadButton.home is deliberately unbindable: the guide button is
    // reserved by the OS on most platforms.
  };

  /// Broadcast stream of control edges from all connected gamepads. The
  /// platform stream is subscribed lazily on first access and kept for the
  /// app's lifetime.
  Stream<GamepadControlEvent> get controlEvents {
    _subscription ??= (_source ?? Gamepads.normalizedEvents).listen(
      _handleEvent,
      // Platform errors (e.g. no plugin registered) must not tear down
      // gameplay; a broken channel simply means no gamepad input.
      onError: (Object _) {},
    );
    return _controller.stream;
  }

  /// Currently connected controllers, for display in settings. Returns an
  /// empty list when the platform side is unavailable.
  Future<List<GamepadController>> listGamepads() async {
    try {
      return await (_list ?? Gamepads.list)();
    } catch (_) {
      return const [];
    }
  }

  void _handleEvent(NormalizedGamepadEvent event) {
    final button = event.button;
    if (button != null) {
      final control = _buttonControls[button];
      if (control != null) {
        _setPressed(event.gamepadId, control, event.value >= 0.5);
      }
      return;
    }
    switch (event.axis) {
      case GamepadAxis.leftStickX:
        _updateAxisPair(
          event.gamepadId,
          GamepadControl.leftStickLeft,
          GamepadControl.leftStickRight,
          event.value,
        );
      case GamepadAxis.leftStickY:
        _updateAxisPair(
          event.gamepadId,
          GamepadControl.leftStickDown,
          GamepadControl.leftStickUp,
          event.value,
        );
      case GamepadAxis.rightStickX:
        _updateAxisPair(
          event.gamepadId,
          GamepadControl.rightStickLeft,
          GamepadControl.rightStickRight,
          event.value,
        );
      case GamepadAxis.rightStickY:
        _updateAxisPair(
          event.gamepadId,
          GamepadControl.rightStickDown,
          GamepadControl.rightStickUp,
          event.value,
        );
      case GamepadAxis.leftTrigger:
        _updateWithHysteresis(
          event.gamepadId,
          GamepadControl.leftTrigger,
          event.value,
        );
      case GamepadAxis.rightTrigger:
        _updateWithHysteresis(
          event.gamepadId,
          GamepadControl.rightTrigger,
          event.value,
        );
      case null:
        break;
    }
  }

  /// One stick axis drives two opposing virtual controls; deflection one way
  /// is a release of the other. The receding side is updated first so a fast
  /// flip never reports both directions pressed at once. Values follow the
  /// plugin convention: left/down = -1, right/up = +1.
  void _updateAxisPair(
    String gamepadId,
    GamepadControl negative,
    GamepadControl positive,
    double value,
  ) {
    if (value >= 0) {
      _updateWithHysteresis(gamepadId, negative, -value);
      _updateWithHysteresis(gamepadId, positive, value);
    } else {
      _updateWithHysteresis(gamepadId, positive, value);
      _updateWithHysteresis(gamepadId, negative, -value);
    }
  }

  void _updateWithHysteresis(
    String gamepadId,
    GamepadControl control,
    double deflection,
  ) {
    final pressed = _pressedByPad[gamepadId]?.contains(control) ?? false;
    if (!pressed && deflection >= _axisPressThreshold) {
      _setPressed(gamepadId, control, true);
    } else if (pressed && deflection < _axisReleaseThreshold) {
      _setPressed(gamepadId, control, false);
    }
  }

  void _setPressed(String gamepadId, GamepadControl control, bool down) {
    final pressed = _pressedByPad.putIfAbsent(
      gamepadId,
      () => <GamepadControl>{},
    );
    final changed = down ? pressed.add(control) : pressed.remove(control);
    if (!changed) {
      return;
    }
    _controller.add(
      GamepadControlEvent(
        gamepadId: gamepadId,
        control: control,
        pressed: down,
      ),
    );
  }
}

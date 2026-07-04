import 'dart:async';

import 'package:flutter/widgets.dart';

import 'control_bindings.dart';
import 'gamepad_service.dart';

/// Makes the whole UI controller-navigable: d-pad / left stick move focus,
/// South (A/Cross) activates the focused control, East (B/Circle) pops the
/// current route or dialog.
///
/// Mounted once above the app's Navigator (via `MaterialApp.builder`), so it
/// covers every page, overlay, and dialog. Gameplay surfaces claim the pad
/// through [GamepadService.blockUiNavigation] while the board is accepting
/// input; this layer stays inert until they release it (pause, game over,
/// versus result), so menu navigation never fights piece movement.
class GamepadUiNavigator extends StatefulWidget {
  const GamepadUiNavigator({
    super.key,
    required this.gamepad,
    required this.child,
    this.navigatorKey,
  });

  /// `null` (tests without a pad, platforms without the plugin) renders the
  /// child untouched.
  final GamepadService? gamepad;

  /// Fallback for East-button pops before anything has focus; the primary
  /// path pops from the focused widget's own context so dialogs close first.
  final GlobalKey<NavigatorState>? navigatorKey;

  final Widget child;

  @override
  State<GamepadUiNavigator> createState() => _GamepadUiNavigatorState();
}

class _GamepadUiNavigatorState extends State<GamepadUiNavigator> {
  StreamSubscription<GamepadControlEvent>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.gamepad?.controlEvents.listen(_onControl);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel() ?? Future.value());
    super.dispose();
  }

  void _onControl(GamepadControlEvent event) {
    final gamepad = widget.gamepad;
    if (!mounted ||
        gamepad == null ||
        !event.pressed ||
        gamepad.uiNavigationBlocked) {
      return;
    }

    switch (event.control) {
      case GamepadControl.dpadUp || GamepadControl.leftStickUp:
        _moveFocus(TraversalDirection.up);
      case GamepadControl.dpadDown || GamepadControl.leftStickDown:
        _moveFocus(TraversalDirection.down);
      case GamepadControl.dpadLeft || GamepadControl.leftStickLeft:
        _moveFocus(TraversalDirection.left);
      case GamepadControl.dpadRight || GamepadControl.leftStickRight:
        _moveFocus(TraversalDirection.right);
      case GamepadControl.buttonSouth:
        _activate();
      case GamepadControl.buttonEast:
        _pop();
      default:
        break;
    }
  }

  /// Focus rings only render in traditional highlight mode; pointer-first
  /// sessions run in touch mode where a moving focus would be invisible.
  void _showFocusHighlights() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  }

  void _moveFocus(TraversalDirection direction) {
    _showFocusHighlights();
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) {
      return;
    }
    final context = focus.context;
    if (focus is! FocusScopeNode && context != null) {
      // Dispatch the intent instead of moving focus directly so focused
      // widgets can override it — the volume sliders consume left/right to
      // adjust their value while up/down bubble up to normal traversal.
      Actions.maybeInvoke(context, DirectionalFocusIntent(direction));
      return;
    }
    // Nothing focused yet on this screen: seed on the first control.
    if (!focus.focusInDirection(direction)) {
      focus.nextFocus();
    }
  }

  void _activate() {
    _showFocusHighlights();
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) {
      return;
    }
    Actions.maybeInvoke(context, const ActivateIntent());
  }

  void _pop() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context != null && Navigator.maybeOf(context) != null) {
      unawaited(Navigator.maybePop(context));
      return;
    }
    unawaited(widget.navigatorKey?.currentState?.maybePop() ?? Future.value());
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

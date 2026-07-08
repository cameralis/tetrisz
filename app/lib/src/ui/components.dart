import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';
import 'ui_sounds.dart';

const _hoverDuration = Duration(milliseconds: 120);
const _pressDownDuration = Duration(milliseconds: 70);
const _pressUpDuration = Duration(milliseconds: 150);
const _hoverScale = 1.02;
const _pressScale = 0.96;
const _buttonEdgeHeight = 4.0;
const _buttonRadius = 10.0;
const _panelRadius = 12.0;

/// Sounds played on focus arrival are suppressed this long after mount so an
/// `autofocus` firing while a page builds doesn't tick on every navigation.
const _mountSoundGrace = Duration(milliseconds: 400);

/// Interaction snapshot handed to [TetrisPressable.builder].
class TetrisPressState {
  const TetrisPressState({
    required this.enabled,
    required this.hovered,
    required this.focused,
    required this.depth,
  });

  final bool enabled;
  final bool hovered;
  final bool focused;

  /// 0 at rest → 1 fully pressed; briefly dips below 0 on the release bounce.
  final double depth;
}

/// Core of every custom control: focus + hover + press tracking with the
/// block-slam press animation and menu sounds. Works for mouse, touch,
/// keyboard (Space/Enter) and the gamepad UI navigator (ActivateIntent).
class TetrisPressable extends StatefulWidget {
  const TetrisPressable({
    super.key,
    required this.onPressed,
    required this.builder,
    this.autofocus = false,
    this.pressSfx = UiSfx.confirm,
    this.semanticLabel,
  });

  final VoidCallback? onPressed;
  final Widget Function(BuildContext context, TetrisPressState state) builder;
  final bool autofocus;
  final UiSfx pressSfx;
  final String? semanticLabel;

  @override
  State<TetrisPressable> createState() => _TetrisPressableState();
}

class _TetrisPressableState extends State<TetrisPressable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: _pressDownDuration,
    reverseDuration: _pressUpDuration,
  );
  late final Animation<double> _depth = CurvedAnimation(
    parent: _press,
    curve: Curves.easeOutCubic,
    // Overshoots on the way back so the face pops up past rest and settles —
    // the block bounces off the stack instead of gliding.
    reverseCurve: Curves.easeOutBack.flipped,
  );
  final FocusNode _focusNode = FocusNode(debugLabel: 'TetrisPressable');
  Timer? _mountGraceTimer;
  bool _pastMountGrace = false;
  bool _hovered = false;
  bool _focused = false;
  bool _pointerDown = false;

  bool get _enabled => widget.onPressed != null;

  @override
  void initState() {
    super.initState();
    // Timer (not a wall clock) so widget tests can advance past the grace
    // with pump(); only gates sounds, so no setState.
    _mountGraceTimer = Timer(_mountSoundGrace, () => _pastMountGrace = true);
  }

  @override
  void dispose() {
    _mountGraceTimer?.cancel();
    _press.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onHoverHighlight(bool hovered) {
    if (hovered == _hovered) {
      return;
    }
    setState(() => _hovered = hovered);
    if (hovered && _enabled && _pastMountGrace) {
      UiFeedback.play(UiSfx.tick);
    }
  }

  void _onFocusHighlight(bool focused) {
    if (focused == _focused) {
      return;
    }
    setState(() => _focused = focused);
    // No tick when focus lands via pointer press or page-open autofocus;
    // only deliberate traversal (keyboard/controller) should be audible.
    if (focused && _enabled && _pastMountGrace && !_pointerDown) {
      UiFeedback.play(UiSfx.tick);
    }
  }

  void _onTapDown(TapDownDetails details) {
    if (!_enabled) {
      return;
    }
    _pointerDown = true;
    _focusNode.requestFocus();
    _press.forward();
    UiFeedback.play(widget.pressSfx);
    unawaited(HapticFeedback.selectionClick());
  }

  void _settlePointer() {
    _pointerDown = false;
    _press.reverse();
  }

  void _onTap() {
    widget.onPressed?.call();
  }

  /// Keyboard / gamepad activation: simulate the full press cycle and fire.
  void _activateFromIntent() {
    if (!_enabled) {
      return;
    }
    UiFeedback.play(widget.pressSfx);
    _press.forward().whenComplete(() {
      if (mounted) {
        _press.reverse();
      }
    });
    widget.onPressed?.call();
  }

  late final Map<Type, Action<Intent>> _actions = {
    ActivateIntent: CallbackAction<ActivateIntent>(
      onInvoke: (_) {
        _activateFromIntent();
        return null;
      },
    ),
    ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
      onInvoke: (_) {
        _activateFromIntent();
        return null;
      },
    ),
  };

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        enabled: _enabled,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        mouseCursor: _enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowHoverHighlight: _onHoverHighlight,
        onShowFocusHighlight: _onFocusHighlight,
        actions: _actions,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _onTapDown,
          onTapUp: (_) => _settlePointer(),
          onTapCancel: _settlePointer,
          onTap: _enabled ? _onTap : null,
          child: AnimatedBuilder(
            animation: _depth,
            builder: (context, _) => widget.builder(
              context,
              TetrisPressState(
                enabled: _enabled,
                hovered: _hovered && _enabled,
                focused: _focused && _enabled,
                depth: _depth.value,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum TetrisButtonVariant { primary, secondary, danger, ghost }

/// Chunky block-styled button: rests on a darker edge like a piece on the
/// stack, slams flat when pressed, lifts and glows on hover/focus.
class TetrisButton extends StatelessWidget {
  const TetrisButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.variant = TetrisButtonVariant.secondary,
    this.autofocus = false,
    this.compact = false,
    this.icon,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final TetrisButtonVariant variant;
  final bool autofocus;

  /// Smaller paddings/typography for inline placements (rows, app bars).
  final bool compact;

  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    if (variant == TetrisButtonVariant.ghost) {
      return _buildGhost(context);
    }

    final (face, edge, foreground, border) = switch (variant) {
      TetrisButtonVariant.primary => (
        TetrisColors.accent,
        TetrisColors.accentEdge,
        TetrisColors.onAccent,
        null,
      ),
      TetrisButtonVariant.danger => (
        TetrisColors.panel,
        TetrisColors.panelEdge,
        TetrisColors.danger,
        const Color(0x66FF4D5E),
      ),
      _ => (
        TetrisColors.panel,
        TetrisColors.panelEdge,
        TetrisColors.text,
        TetrisColors.outline,
      ),
    };
    final glow = variant == TetrisButtonVariant.danger
        ? TetrisColors.danger
        : TetrisColors.accent;

    return TetrisPressable(
      onPressed: onPressed,
      autofocus: autofocus,
      builder: (context, state) {
        final pressedDepth = state.depth.clamp(0.0, 1.0);
        final faceWidget = AnimatedContainer(
          duration: _hoverDuration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 14 : 18,
            vertical: compact ? 10 : 15,
          ),
          decoration: BoxDecoration(
            color: state.enabled
                ? face
                : Color.lerp(face, TetrisColors.background, 0.45),
            borderRadius: BorderRadius.circular(_buttonRadius),
            border: Border.all(
              color: state.focused
                  ? TetrisColors.accent
                  : (border ?? Colors.transparent),
              width: 1.2,
            ),
            boxShadow: [
              if (state.hovered || state.focused)
                BoxShadow(
                  color: glow.withValues(alpha: state.focused ? 0.42 : 0.26),
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
            ],
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(
              color: state.enabled
                  ? foreground
                  : foreground.withValues(alpha: 0.55),
              fontSize: compact ? 13 : 16,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
            child: IconTheme.merge(
              data: IconThemeData(color: foreground, size: compact ? 16 : 19),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon),
                    const SizedBox(width: 8),
                  ],
                  Flexible(child: child),
                ],
              ),
            ),
          ),
        );

        return AnimatedScale(
          scale: state.hovered ? _hoverScale : 1.0,
          duration: _hoverDuration,
          curve: Curves.easeOutCubic,
          child: Transform.scale(
            scale: lerpDouble(1.0, _pressScale, pressedDepth)!,
            child: Stack(
              children: [
                Positioned.fill(
                  top: _buttonEdgeHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: state.enabled
                          ? edge
                          : Color.lerp(edge, TetrisColors.background, 0.45),
                      borderRadius: BorderRadius.circular(_buttonRadius),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: _buttonEdgeHeight),
                  child: Transform.translate(
                    offset: Offset(0, _buttonEdgeHeight * state.depth),
                    child: faceWidget,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildGhost(BuildContext context) {
    return TetrisPressable(
      onPressed: onPressed,
      autofocus: autofocus,
      pressSfx: UiSfx.back,
      builder: (context, state) {
        return Transform.scale(
          scale: lerpDouble(1.0, _pressScale, state.depth.clamp(0.0, 1.0))!,
          child: AnimatedContainer(
            duration: _hoverDuration,
            curve: Curves.easeOutCubic,
            alignment: Alignment.center,
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 12 : 16,
              vertical: compact ? 8 : 12,
            ),
            decoration: BoxDecoration(
              color: state.hovered
                  ? const Color(0x0FFFFFFF)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(_buttonRadius),
              border: Border.all(
                color: state.focused
                    ? TetrisColors.accent
                    : Colors.transparent,
                width: 1.2,
              ),
            ),
            child: DefaultTextStyle.merge(
              style: TextStyle(
                color: state.hovered || state.focused
                    ? TetrisColors.text
                    : TetrisColors.mutedText,
                fontSize: compact ? 13 : 14,
                fontWeight: FontWeight.w600,
              ),
              child: IconTheme.merge(
                data: IconThemeData(
                  color: state.hovered || state.focused
                      ? TetrisColors.text
                      : TetrisColors.mutedText,
                  size: compact ? 16 : 18,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (icon != null) ...[
                      Icon(icon),
                      const SizedBox(width: 6),
                    ],
                    Flexible(child: child),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Square icon control with the same chunky press treatment; replaces
/// Material IconButtons in overlays and app bars. Hit area stays >= 40px.
class TetrisIconButton extends StatelessWidget {
  const TetrisIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.autofocus = false,
    this.size = 44,
    this.color = TetrisColors.text,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool autofocus;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const edgeHeight = 3.0;
    final radius = BorderRadius.circular(size * 0.27);
    Widget button = TetrisPressable(
      onPressed: onPressed,
      autofocus: autofocus,
      semanticLabel: tooltip,
      builder: (context, state) {
        return Transform.scale(
          scale: lerpDouble(1.0, _pressScale, state.depth.clamp(0.0, 1.0))!,
          child: Stack(
            children: [
              Positioned.fill(
                top: edgeHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: TetrisColors.panelEdge,
                    borderRadius: radius,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: edgeHeight),
                child: Transform.translate(
                  offset: Offset(0, edgeHeight * state.depth),
                  child: AnimatedContainer(
                    duration: _hoverDuration,
                    curve: Curves.easeOutCubic,
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      color: state.hovered
                          ? Color.lerp(
                              TetrisColors.panelRaised,
                              TetrisColors.accent,
                              0.12,
                            )
                          : TetrisColors.panelRaised,
                      borderRadius: radius,
                      border: Border.all(
                        color: state.focused
                            ? TetrisColors.accent
                            : TetrisColors.outlineFaint,
                        width: 1.2,
                      ),
                      boxShadow: [
                        if (state.hovered || state.focused)
                          BoxShadow(
                            color: TetrisColors.accent.withValues(
                              alpha: state.focused ? 0.4 : 0.24,
                            ),
                            blurRadius: 12,
                          ),
                      ],
                    ),
                    child: Icon(
                      icon,
                      size: size * 0.5,
                      color: state.enabled
                          ? color
                          : color.withValues(alpha: 0.4),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (tooltip != null) {
      button = Tooltip(message: tooltip, child: button);
    }
    return button;
  }
}

/// Flat surface container replacing Material [Card] usage.
class TetrisPanel extends StatelessWidget {
  const TetrisPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin = EdgeInsets.zero,
    this.color = TetrisColors.panel,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(_panelRadius),
        border: Border.all(color: TetrisColors.outlineFaint),
      ),
      child: child,
    );
  }
}

/// Panel-styled list row; interactive when [onTap] is set, with the shared
/// hover/focus/press feedback (scale-only — tiles sit flat, no chunky edge).
class TetrisListTile extends StatelessWidget {
  const TetrisListTile({
    super.key,
    this.onTap,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.margin = const EdgeInsets.only(bottom: 8),
  });

  final VoidCallback? onTap;
  final Widget? leading;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final EdgeInsetsGeometry margin;

  Widget _row() {
    return Row(
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 14)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DefaultTextStyle.merge(
                style: const TextStyle(
                  color: TetrisColors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                child: title,
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                DefaultTextStyle.merge(
                  style: const TextStyle(
                    color: TetrisColors.mutedText,
                    fontSize: 12,
                    height: 1.35,
                  ),
                  child: subtitle!,
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 10), trailing!],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (onTap == null) {
      return Padding(
        padding: margin,
        child: TetrisPanel(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: _row(),
        ),
      );
    }

    return Padding(
      padding: margin,
      child: TetrisPressable(
        onPressed: onTap,
        builder: (context, state) {
          return Transform.scale(
            scale: lerpDouble(1.0, 0.985, state.depth.clamp(0.0, 1.0))!,
            child: AnimatedContainer(
              duration: _hoverDuration,
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              decoration: BoxDecoration(
                color: state.hovered
                    ? Color.lerp(
                        TetrisColors.panel,
                        TetrisColors.panelRaised,
                        0.7,
                      )
                    : TetrisColors.panel,
                borderRadius: BorderRadius.circular(_panelRadius),
                border: Border.all(
                  color: state.focused
                      ? TetrisColors.accent
                      : TetrisColors.outlineFaint,
                  width: state.focused ? 1.2 : 1,
                ),
                boxShadow: [
                  if (state.hovered || state.focused)
                    BoxShadow(
                      color: TetrisColors.accent.withValues(
                        alpha: state.focused ? 0.3 : 0.14,
                      ),
                      blurRadius: 12,
                    ),
                ],
              ),
              child: _row(),
            ),
          );
        },
      ),
    );
  }
}

/// Shared 'CONTROLS' / 'OR JOIN A FRIEND' style section label.
class TetrisSectionHeader extends StatelessWidget {
  const TetrisSectionHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        title,
        style: const TextStyle(
          color: TetrisColors.mutedText,
          fontSize: 11,
          letterSpacing: 1.4,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Themed text input with an animated accent glow while focused.
class TetrisTextField extends StatefulWidget {
  const TetrisTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.helper,
    this.maxLength,
    this.style,
    this.hintStyle,
    this.textAlign = TextAlign.start,
    this.textCapitalization = TextCapitalization.none,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final String? helper;
  final int? maxLength;
  final TextStyle? style;
  final TextStyle? hintStyle;
  final TextAlign textAlign;
  final TextCapitalization textCapitalization;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  State<TetrisTextField> createState() => _TetrisTextFieldState();
}

class _TetrisTextFieldState extends State<TetrisTextField> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'TetrisTextField');
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus != _focused) {
      setState(() => _focused = _focusNode.hasFocus);
      if (_focused) {
        UiFeedback.play(UiSfx.tick);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: _hoverDuration,
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_buttonRadius),
        boxShadow: [
          if (_focused)
            BoxShadow(
              color: TetrisColors.accent.withValues(alpha: 0.22),
              blurRadius: 14,
              spreadRadius: 1,
            ),
        ],
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        maxLength: widget.maxLength,
        textAlign: widget.textAlign,
        textCapitalization: widget.textCapitalization,
        inputFormatters: widget.inputFormatters,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        autofocus: widget.autofocus,
        cursorColor: TetrisColors.accent,
        style: widget.style ??
            const TextStyle(color: TetrisColors.text, fontSize: 15),
        decoration: InputDecoration(
          counterText: '',
          labelText: widget.label,
          labelStyle: const TextStyle(color: TetrisColors.mutedText),
          hintText: widget.hint,
          hintStyle: widget.hintStyle ??
              TextStyle(
                color: TetrisColors.mutedText.withValues(alpha: 0.4),
              ),
          helperText: widget.helper,
          helperStyle: const TextStyle(
            color: TetrisColors.mutedText,
            fontSize: 11,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(_buttonRadius),
            borderSide: const BorderSide(color: TetrisColors.outline),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(_buttonRadius),
            borderSide: const BorderSide(color: TetrisColors.accent),
          ),
        ),
      ),
    );
  }
}

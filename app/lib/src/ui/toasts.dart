import 'dart:async';

import 'package:flutter/material.dart';

import 'theme.dart';
import 'ui_sounds.dart';

const _enterDuration = Duration(milliseconds: 340);
const _exitDuration = Duration(milliseconds: 200);
const _defaultHold = Duration(milliseconds: 2600);
const _maxVisible = 4;

/// App-level toast layer, mounted once above the Navigator (via
/// `MaterialApp.builder`) so notifications land on top of every route,
/// dialog and overlay.
///
/// Toasts are styled as heavy blocks: they accelerate down into place, slam
/// with a small impact bounce (and the hard-drop sound), hold, then drop
/// away softly.
class TetrisToastHost extends StatefulWidget {
  const TetrisToastHost({super.key, required this.child});

  final Widget child;

  static _TetrisToastHostState? _active;

  /// Shows a toast on the app-level host. A no-op when no host is mounted
  /// (single-page widget tests), so callers never need a context.
  static void show(
    String message, {
    IconData? icon,
    Color accent = TetrisColors.accent,
    Duration hold = _defaultHold,
  }) {
    _active?._enqueue(message, icon: icon, accent: accent, hold: hold);
  }

  @override
  State<TetrisToastHost> createState() => _TetrisToastHostState();
}

class _ToastEntry {
  _ToastEntry({
    required this.id,
    required this.message,
    required this.icon,
    required this.accent,
    required this.hold,
  });

  final int id;
  final String message;
  final IconData? icon;
  final Color accent;
  final Duration hold;
}

class _TetrisToastHostState extends State<TetrisToastHost> {
  final List<_ToastEntry> _entries = [];
  int _nextId = 0;

  @override
  void initState() {
    super.initState();
    TetrisToastHost._active = this;
  }

  @override
  void dispose() {
    if (TetrisToastHost._active == this) {
      TetrisToastHost._active = null;
    }
    super.dispose();
  }

  void _enqueue(
    String message, {
    required IconData? icon,
    required Color accent,
    required Duration hold,
  }) {
    setState(() {
      _entries.add(
        _ToastEntry(
          id: _nextId++,
          message: message,
          icon: icon,
          accent: accent,
          hold: hold,
        ),
      );
      if (_entries.length > _maxVisible) {
        _entries.removeAt(0);
      }
    });
  }

  void _remove(int id) {
    if (!mounted) {
      return;
    }
    setState(() => _entries.removeWhere((entry) => entry.id == id));
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          widget.child,
          if (_entries.isNotEmpty)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final entry in _entries)
                        _ToastCard(
                          key: ValueKey(entry.id),
                          entry: entry,
                          onDone: () => _remove(entry.id),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ToastCard extends StatefulWidget {
  const _ToastCard({super.key, required this.entry, required this.onDone});

  final _ToastEntry entry;
  final VoidCallback onDone;

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard>
    with TickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: _enterDuration,
  );
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: _exitDuration,
  );

  /// Falls fast, slams at 70%, pops up a touch on impact, settles.
  static final _dropTween = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: -96.0, end: 0.0)
          .chain(CurveTween(curve: Curves.easeIn)),
      weight: 70,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 0.0, end: -7.0)
          .chain(CurveTween(curve: Curves.easeOut)),
      weight: 15,
    ),
    TweenSequenceItem(
      tween: Tween(begin: -7.0, end: 0.0)
          .chain(CurveTween(curve: Curves.easeIn)),
      weight: 15,
    ),
  ]);

  Timer? _holdTimer;
  bool _landed = false;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _enter.addListener(_onEnterTick);
    _enter.forward().whenComplete(_scheduleDismiss);
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _enter.dispose();
    _exit.dispose();
    super.dispose();
  }

  void _onEnterTick() {
    if (!_landed && _enter.value >= 0.7) {
      _landed = true;
      UiFeedback.play(UiSfx.toast);
    }
  }

  void _scheduleDismiss() {
    if (!mounted || _leaving) {
      return;
    }
    _holdTimer = Timer(widget.entry.hold, _dismiss);
  }

  void _dismiss() {
    if (!mounted || _leaving) {
      return;
    }
    _leaving = true;
    _holdTimer?.cancel();
    _exit.forward().whenComplete(widget.onDone);
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    return SizeTransition(
      sizeFactor: ReverseAnimation(
        CurvedAnimation(parent: _exit, curve: Curves.easeIn),
      ),
      alignment: AlignmentDirectional.topCenter,
      child: FadeTransition(
        opacity: ReverseAnimation(_exit),
        child: AnimatedBuilder(
          animation: Listenable.merge([_enter, _exit]),
          builder: (context, child) => Transform.translate(
            offset: Offset(
              0,
              _dropTween.evaluate(_enter) + 12 * _exit.value,
            ),
            child: child,
          ),
          child: GestureDetector(
            onTap: _dismiss,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 380),
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 11,
              ),
              decoration: BoxDecoration(
                color: TetrisColors.panel,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: TetrisColors.outlineFaint),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 22,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // A single mino in the toast's accent color.
                  Container(
                    width: 11,
                    height: 11,
                    decoration: BoxDecoration(
                      color: entry.accent,
                      borderRadius: BorderRadius.circular(2.5),
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (entry.icon != null) ...[
                    Icon(entry.icon, size: 17, color: entry.accent),
                    const SizedBox(width: 9),
                  ],
                  Flexible(
                    child: Text(
                      entry.message,
                      style: const TextStyle(
                        color: TetrisColors.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

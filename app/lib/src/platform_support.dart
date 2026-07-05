import 'package:flutter/foundation.dart';

/// True on the physical-keyboard desktop targets. Keyboard gameplay controls
/// and their rebinding UI are gated to these; touch and gamepad cover the
/// other platforms. Web is treated as non-desktop so the touch scheme stays
/// the default there.
bool get isDesktopPlatform {
  if (kIsWeb) {
    return false;
  }
  switch (defaultTargetPlatform) {
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return true;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}

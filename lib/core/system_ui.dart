import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Android navigation style detected from the system and the live insets.
enum NavigationStyle { gesture, threeButton, twoButton, none }

class SystemUiInfo {
  const SystemUiInfo({required this.style, required this.bottomInset});

  final NavigationStyle style;
  final double bottomInset;

  /// Combines the native `config_navBarInteractionMode` value with the
  /// MediaQuery insets, so switching gesture/3-button nav adapts instantly.
  static SystemUiInfo of(BuildContext context, {String nativeMode = 'unknown'}) {
    final inset = MediaQuery.viewPaddingOf(context).bottom;
    NavigationStyle style;
    if (inset <= 0) {
      style = NavigationStyle.none;
    } else {
      style = switch (nativeMode) {
        'threeButton' => NavigationStyle.threeButton,
        'twoButton' => NavigationStyle.twoButton,
        'gesture' => NavigationStyle.gesture,
        _ => inset >= 40
            ? NavigationStyle.threeButton
            : inset >= 30
                ? NavigationStyle.twoButton
                : NavigationStyle.gesture,
      };
    }
    return SystemUiInfo(style: style, bottomInset: inset);
  }

  String get label => switch (style) {
        NavigationStyle.gesture => 'Жестовая навигация',
        NavigationStyle.threeButton => '3 кнопки',
        NavigationStyle.twoButton => '2 кнопки',
        NavigationStyle.none => 'Без системной панели',
      };

  IconData get icon => switch (style) {
        NavigationStyle.gesture => Icons.swipe_rounded,
        NavigationStyle.threeButton => Icons.more_horiz_rounded,
        NavigationStyle.twoButton => Icons.drag_handle_rounded,
        NavigationStyle.none => Icons.fullscreen_rounded,
      };

  /// Compact bar for 3-button navigation (the inset is already large),
  /// slightly taller for gesture navigation so labels stay comfortable.
  double get navigationBarHeight => switch (style) {
        NavigationStyle.threeButton => 64,
        NavigationStyle.twoButton => 68,
        NavigationStyle.gesture => 76,
        NavigationStyle.none => 72,
      };

  /// Extra breathing room above the system inset for scrollable content.
  double get scrollBottomPadding => switch (style) {
        NavigationStyle.threeButton => 18,
        NavigationStyle.twoButton => 20,
        NavigationStyle.gesture => 24,
        NavigationStyle.none => 24,
      };

  EdgeInsets scrollPadding({
    double left = 16,
    double top = 4,
    double right = 16,
  }) =>
      EdgeInsets.fromLTRB(left, top, right, scrollBottomPadding);

  static SystemUiOverlayStyle overlayStyle(Brightness brightness) {
    final icons =
        brightness == Brightness.dark ? Brightness.light : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      statusBarBrightness: brightness,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
      systemStatusBarContrastEnforced: false,
    );
  }
}

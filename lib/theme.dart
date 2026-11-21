import 'package:flutter/material.dart';

/// Extra semantic colors that Material 3 does not expose by default.
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.success,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.terminal,
    required this.terminalText,
  });

  final Color success;
  final Color successContainer;
  final Color onSuccessContainer;
  final Color warning;
  final Color warningContainer;
  final Color onWarningContainer;
  final Color terminal;
  final Color terminalText;

  @override
  AppPalette copyWith({
    Color? success,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warning,
    Color? warningContainer,
    Color? onWarningContainer,
    Color? terminal,
    Color? terminalText,
  }) {
    return AppPalette(
      success: success ?? this.success,
      successContainer: successContainer ?? this.successContainer,
      onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
      warning: warning ?? this.warning,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
      terminal: terminal ?? this.terminal,
      terminalText: terminalText ?? this.terminalText,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      success: Color.lerp(success, other.success, t)!,
      successContainer: Color.lerp(successContainer, other.successContainer, t)!,
      onSuccessContainer: Color.lerp(onSuccessContainer, other.onSuccessContainer, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningContainer: Color.lerp(warningContainer, other.warningContainer, t)!,
      onWarningContainer: Color.lerp(onWarningContainer, other.onWarningContainer, t)!,
      terminal: Color.lerp(terminal, other.terminal, t)!,
      terminalText: Color.lerp(terminalText, other.terminalText, t)!,
    );
  }
}

const Color _darkSurface = Color(0xFF111318);
const Color _darkSurfaceLow = Color(0xFF191C22);
const Color _darkSurfaceContainer = Color(0xFF1D2026);
const Color _darkSurfaceHigh = Color(0xFF282A30);
const Color _darkSurfaceHighest = Color(0xFF33363D);
const Color _darkPrimary = Color(0xFFADC6FF);
const Color _darkOnPrimary = Color(0xFF002E69);
const Color _darkPrimaryContainer = Color(0xFF2B4678);
const Color _darkOnPrimaryContainer = Color(0xFFD8E2FF);
const Color _darkSecondaryContainer = Color(0xFF3E4759);
const Color _darkOnSecondaryContainer = Color(0xFFDAE2F9);
const Color _darkOnSurface = Color(0xFFE3E2E6);
const Color _darkOnSurfaceVariant = Color(0xFFC4C6D0);
const Color _darkOutline = Color(0xFF8E9099);
const Color _darkOutlineVariant = Color(0xFF44474F);

const Color _lightSurface = Color(0xFFF9F9FF);
const Color _lightSurfaceLow = Color(0xFFF3F3FA);
const Color _lightSurfaceContainer = Color(0xFFEDEDF4);
const Color _lightSurfaceHigh = Color(0xFFE7E8EE);
const Color _lightSurfaceHighest = Color(0xFFE0E1E9);
const Color _lightPrimary = Color(0xFF445E91);
const Color _lightPrimaryContainer = Color(0xFFD8E2FF);
const Color _lightOnPrimaryContainer = Color(0xFF001A41);
const Color _lightSecondaryContainer = Color(0xFFDBE2F9);
const Color _lightOnSecondaryContainer = Color(0xFF131C2B);
const Color _lightOnSurface = Color(0xFF1A1B20);
const Color _lightOnSurfaceVariant = Color(0xFF44474F);
const Color _lightOutline = Color(0xFF74777F);
const Color _lightOutlineVariant = Color(0xFFC4C6D0);

ThemeData buildAppTheme(Brightness brightness) {
  final bool dark = brightness == Brightness.dark;

  final ColorScheme scheme = dark
      ? ColorScheme.fromSeed(seedColor: _darkPrimary, brightness: Brightness.dark).copyWith(
          primary: _darkPrimary,
          onPrimary: _darkOnPrimary,
          primaryContainer: _darkPrimaryContainer,
          onPrimaryContainer: _darkOnPrimaryContainer,
          secondary: const Color(0xFFBEC6DC),
          onSecondary: const Color(0xFF283141),
          secondaryContainer: _darkSecondaryContainer,
          onSecondaryContainer: _darkOnSecondaryContainer,
          tertiary: const Color(0xFFFFB4A8),
          onTertiary: const Color(0xFF690005),
          tertiaryContainer: const Color(0xFF93000A),
          onTertiaryContainer: const Color(0xFFFFDAD6),
          error: const Color(0xFFFFB4AB),
          onError: const Color(0xFF690005),
          errorContainer: const Color(0xFF690005),
          onErrorContainer: const Color(0xFFFFDAD6),
          surface: _darkSurface,
          onSurface: _darkOnSurface,
          onSurfaceVariant: _darkOnSurfaceVariant,
          surfaceContainerLowest: const Color(0xFF0C0E13),
          surfaceContainerLow: _darkSurfaceLow,
          surfaceContainer: _darkSurfaceContainer,
          surfaceContainerHigh: _darkSurfaceHigh,
          surfaceContainerHighest: _darkSurfaceHighest,
          outline: _darkOutline,
          outlineVariant: _darkOutlineVariant,
          inverseSurface: const Color(0xFFE3E2E6),
          onInverseSurface: const Color(0xFF2F3033),
          inversePrimary: _lightPrimary,
        )
      : ColorScheme.fromSeed(seedColor: _lightPrimary, brightness: Brightness.light).copyWith(
          primary: _lightPrimary,
          onPrimary: Colors.white,
          primaryContainer: _lightPrimaryContainer,
          onPrimaryContainer: _lightOnPrimaryContainer,
          secondary: const Color(0xFF565E71),
          onSecondary: Colors.white,
          secondaryContainer: _lightSecondaryContainer,
          onSecondaryContainer: _lightOnSecondaryContainer,
          error: const Color(0xFFBA1A1A),
          onError: Colors.white,
          errorContainer: const Color(0xFFFFDAD6),
          onErrorContainer: const Color(0xFF410002),
          surface: _lightSurface,
          onSurface: _lightOnSurface,
          onSurfaceVariant: _lightOnSurfaceVariant,
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: _lightSurfaceLow,
          surfaceContainer: _lightSurfaceContainer,
          surfaceContainerHigh: _lightSurfaceHigh,
          surfaceContainerHighest: _lightSurfaceHighest,
          outline: _lightOutline,
          outlineVariant: _lightOutlineVariant,
        );

  final AppPalette palette = dark
      ? const AppPalette(
          success: Color(0xFF8FD5A6),
          successContainer: Color(0xFF0F522C),
          onSuccessContainer: Color(0xFFC4EED0),
          warning: Color(0xFFFFDF9E),
          warningContainer: Color(0xFF4D3800),
          onWarningContainer: Color(0xFFFFDF9E),
          terminal: Color(0xFF0A0C10),
          terminalText: Color(0xFFB8C4D9),
        )
      : const AppPalette(
          success: Color(0xFF2F6A46),
          successContainer: Color(0xFFA6F2B8),
          onSuccessContainer: Color(0xFF00210B),
          warning: Color(0xFF7A5900),
          warningContainer: Color(0xFFFFDF9E),
          onWarningContainer: Color(0xFF261A00),
          terminal: Color(0xFF11151C),
          terminalText: Color(0xFFCBD6E6),
        );

  final TextTheme textTheme = Typography.material2021(platform: TargetPlatform.android)
      .white
      .apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      )
      .copyWith(
        headlineLarge: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: -0.6, color: scheme.onSurface),
        headlineMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.4, color: scheme.onSurface),
        headlineSmall: TextStyle(fontSize: 21, fontWeight: FontWeight.w600, letterSpacing: -0.2, color: scheme.onSurface),
        titleLarge: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: scheme.onSurface),
        titleMedium: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: scheme.onSurface),
        titleSmall: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: scheme.onSurface),
        bodyLarge: TextStyle(fontSize: 15, height: 1.35, color: scheme.onSurface),
        bodyMedium: TextStyle(fontSize: 13.5, height: 1.4, color: scheme.onSurface),
        bodySmall: TextStyle(fontSize: 12, height: 1.4, color: scheme.onSurfaceVariant),
        labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface),
        labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant),
        labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.2, color: scheme.onSurfaceVariant),
      );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    textTheme: textTheme,
    // A soft ripple ("dust") instead of InkSparkle, whose shader paint looked
    // like a white flash on tap.
    splashFactory: InkRipple.splashFactory,
    splashColor: scheme.primary.withValues(alpha: 0.08),
    highlightColor: scheme.primary.withValues(alpha: 0.04),
    hoverColor: scheme.primary.withValues(alpha: 0.05),
    focusColor: scheme.primary.withValues(alpha: 0.06),
    extensions: <ThemeExtension<dynamic>>[palette],
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge,
      foregroundColor: scheme.onSurface,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 72,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 23,
          color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
        );
      }),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.primary,
        side: BorderSide(color: scheme.outline, width: 1),
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.primary,
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainer,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: 0.8), fontSize: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: scheme.primary, width: 1.4),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.surfaceContainerHighest,
      contentTextStyle: TextStyle(color: scheme.onSurface, fontSize: 13.5),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: scheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      showDragHandle: true,
      dragHandleColor: scheme.outlineVariant,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titleTextStyle: textTheme.titleLarge,
      contentTextStyle: textTheme.bodyMedium,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
        if (states.contains(WidgetState.selected)) return scheme.onPrimary;
        return scheme.outline;
      }),
      trackColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
        if (states.contains(WidgetState.selected)) return scheme.primary;
        return scheme.surfaceContainerHighest;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
        if (states.contains(WidgetState.selected)) return Colors.transparent;
        return scheme.outlineVariant;
      }),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.surfaceContainerHighest,
      thumbColor: scheme.primary,
      trackHeight: 4,
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
      linearMinHeight: 6,
      circularTrackColor: scheme.surfaceContainerHighest,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: scheme.surfaceContainer,
      selectedColor: scheme.secondaryContainer,
      labelStyle: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant),
      side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.primary,
      selectionColor: scheme.primary.withValues(alpha: 0.3),
      selectionHandleColor: scheme.primary,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}

extension AppThemeX on BuildContext {
  AppPalette get palette => Theme.of(this).extension<AppPalette>()!;
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get texts => Theme.of(this).textTheme;
}

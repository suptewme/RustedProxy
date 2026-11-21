import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/app_state.dart';
import 'core/platform.dart';
import 'core/system_ui.dart';
import 'onboarding.dart';
import 'screens/home_screen.dart';
import 'screens/proxies_screen.dart';
import 'screens/scan_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/tools_screen.dart';
import 'theme.dart';
import 'widgets/ui.dart';

final GlobalKey<ScaffoldMessengerState> messengerKey =
    GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await AppState.instance.init();
  runApp(const RustedProxyApp());
}

class RustedProxyApp extends StatefulWidget {
  const RustedProxyApp({super.key});

  @override
  State<RustedProxyApp> createState() => _RustedProxyAppState();
}

class _RustedProxyAppState extends State<RustedProxyApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(AppState.instance.refreshIps());
      unawaited(AppState.instance.refreshNavMode());
    }
  }

  // The themes are expensive to build, so cache them for the whole session.
  static final ThemeData _lightTheme = buildAppTheme(Brightness.light);
  static final ThemeData _darkTheme = buildAppTheme(Brightness.dark);

  @override
  Widget build(BuildContext context) {
    // Only the dedicated theme notifier is observed here. Listening to the
    // whole AppState would rebuild (and re-animate) MaterialApp every second,
    // which is what caused the visible flicker on the home screen.
    return ValueListenableBuilder<String>(
      valueListenable: AppState.instance.themeModeNotifier,
      builder: (BuildContext context, String themeMode, _) {
        final mode = switch (themeMode) {
          'light' => ThemeMode.light,
          'system' => ThemeMode.system,
          _ => ThemeMode.dark,
        };
        return MaterialApp(
          title: 'RustedProxy',
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: messengerKey,
          theme: _lightTheme,
          darkTheme: _darkTheme,
          themeMode: mode,
          themeAnimationDuration: const Duration(milliseconds: 320),
          themeAnimationCurve: Curves.easeOutCubic,
          builder: (BuildContext context, Widget? child) {
            final media = MediaQuery.of(context);
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiInfo.overlayStyle(Theme.of(context).brightness),
              child: MediaQuery(
                data: media.copyWith(
                  textScaler: media.textScaler.clamp(
                    minScaleFactor: 0.85,
                    maxScaleFactor: 1.3,
                  ),
                ),
                child: child ?? const SizedBox.shrink(),
              ),
            );
          },
          home: const _RootSwitcher(),
        );
      },
    );
  }
}

class _RootSwitcher extends StatefulWidget {
  const _RootSwitcher();

  @override
  State<_RootSwitcher> createState() => _RootSwitcherState();
}

class _RootSwitcherState extends State<_RootSwitcher> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.instance.onboardingNotifier,
      builder: (BuildContext context, bool done, _) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 420),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: done
              ? const RootShell(key: ValueKey<String>('shell'))
              : OnboardingScreen(
                  key: const ValueKey<String>('onboarding'),
                  onDone: AppState.instance.completeOnboarding,
                ),
        );
      },
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> with SingleTickerProviderStateMixin {
  int _index = 0;
  DateTime _lastThemeTap = DateTime.fromMillisecondsSinceEpoch(0);
  late final AnimationController _pageFade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  late final Animation<double> _pageOpacity =
      CurvedAnimation(parent: _pageFade, curve: Curves.easeOut);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleInitialLink());
    PlatformBridge.onDeepLink(_handleLink);
  }

  @override
  void dispose() {
    _pageFade.dispose();
    super.dispose();
  }

  Future<void> _handleInitialLink() async {
    final link = await PlatformBridge.takeInitialLink();
    if (link == null || link.isEmpty) return;
    await _handleLink(link);
  }

  Future<void> _handleLink(String link) async {
    final count = await AppState.instance.importText(link);
    if (!mounted) return;
    if (count > 0) {
      _go(2);
      showSnack(context, 'Импортировано из ссылки: $count');
    } else {
      showSnack(context, 'Ссылка не содержит поддерживаемого прокси', error: true);
    }
  }

  void _go(int index) {
    if (_index == index) return;
    HapticFeedback.selectionClick();
    AppState.instance.setLogsVisible(index == 3);
    setState(() => _index = index);
    // A short fade between fully-alive pages. PageView built the target page
    // lazily, which showed an empty (white) frame for ~0.3 s on first visit.
    _pageFade.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return ValueListenableBuilder<String>(
      valueListenable: state.navModeNotifier,
      builder: (BuildContext context, String navMode, _) {
        final colors = context.colors;
        final palette = context.palette;
        final systemUi = SystemUiInfo.of(context, nativeMode: navMode);
        return PopScope(
          canPop: _index == 0,
          onPopInvokedWithResult: (bool didPop, Object? result) {
            if (!didPop && _index != 0) _go(0);
          },
          child: Scaffold(
            appBar: AppBar(
              toolbarHeight: 62,
              titleSpacing: 16,
              title: AnimatedBuilder(
                animation: state,
                builder: (BuildContext context, _) => Row(
                  children: <Widget>[
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: <Color>[
                            colors.primaryContainer,
                            Color.lerp(colors.primaryContainer, palette.successContainer, 0.55)!,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Icon(Icons.shield_rounded,
                          size: 21, color: colors.onPrimaryContainer),
                    ),
                    const SizedBox(width: 11),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Text(
                          'RustedProxy',
                          style: context.texts.titleMedium?.copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                        Row(
                          children: <Widget>[
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: state.isOn ? palette.success : colors.outline,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              state.isOn ? state.modeLabel : 'Не подключено',
                              style: context.texts.bodySmall?.copyWith(fontSize: 11),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                AnimatedBuilder(
                  animation: state.themeModeNotifier,
                  builder: (BuildContext context, _) {
                    final light = state.settings.themeMode == 'light';
                    return IconPill(
                      tooltip: light ? 'Тёмная тема' : 'Светлая тема',
                      icon: light ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                      onPressed: () {
                        // Guard against rapid taps: the theme rebuild is heavy
                        // enough that spamming the button looked like a glitch.
                        final now = DateTime.now();
                        if (now.difference(_lastThemeTap) <
                            const Duration(milliseconds: 550)) {
                          return;
                        }
                        _lastThemeTap = now;
                        HapticFeedback.selectionClick();
                        state.updateSettings(
                          (s) => s.themeMode = light ? 'dark' : 'light',
                        );
                      },
                    );
                  },
                ),
                const SizedBox(width: 14),
              ],
            ),
            body: FadeTransition(
              opacity: _pageOpacity,
              child: IndexedStack(
                index: _index,
                children: <Widget>[
                  HomeScreen(onNavigate: _go),
                  ScanScreen(onNavigate: _go),
                  ProxiesScreen(onNavigate: _go),
                  const ToolsScreen(),
                  const SettingsScreen(),
                ],
              ),
            ),
            bottomNavigationBar: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: colors.outlineVariant.withValues(alpha: 0.35),
                  ),
                ),
              ),
              child: NavigationBar(
                height: systemUi.navigationBarHeight,
                selectedIndex: _index,
                onDestinationSelected: _go,
                destinations: const <NavigationDestination>[
                  NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home_rounded),
                    label: 'Главная',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.search_rounded),
                    selectedIcon: Icon(Icons.manage_search_rounded),
                    label: 'Поиск',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.dns_outlined),
                    selectedIcon: Icon(Icons.dns_rounded),
                    label: 'Прокси',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.terminal_outlined),
                    selectedIcon: Icon(Icons.terminal_rounded),
                    label: 'Логи',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings_rounded),
                    label: 'Настройки',
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

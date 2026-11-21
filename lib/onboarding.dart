import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/app_state.dart';
import 'models/settings.dart';
import 'theme.dart';
import 'widgets/ui.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  final PageController _pages = PageController();
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..forward();
  int _page = 0;
  int _modeIndex = 0;
  int _sourceIndex = 0;

  @override
  void dispose() {
    _pages.dispose();
    _intro.dispose();
    super.dispose();
  }

  void _next() {
    if (_page < 2) {
      _pages.nextPage(duration: const Duration(milliseconds: 340), curve: Curves.easeOutCubic);
    } else {
      _finish();
    }
  }

  void _finish() {
    final state = AppState.instance;
    state.updateSettings((s) {
      s.mode = _modeIndex == 1 ? 'proxy' : 'full';
      s.onboardingDone = true;
    });
    HapticFeedback.mediumImpact();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final colors = context.colors;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              Color.lerp(colors.surface, colors.primaryContainer, 0.16)!,
              colors.surface,
              colors.surface,
            ],
            stops: const <double>[0, 0.35, 1],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Row(
                        children: <Widget>[
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: colors.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(Icons.shield_rounded,
                                size: 20, color: colors.onPrimaryContainer),
                          ),
                          const SizedBox(width: 10),
                          Text('RustedProxy',
                              style: context.texts.titleMedium?.copyWith(fontSize: 15)),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: _finish,
                      child: const Text('Пропустить'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PageView(
                  controller: _pages,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (int index) => setState(() => _page = index),
                  children: <Widget>[
                    _IntroPage(animation: _intro),
                    _ModePage(
                      index: _modeIndex,
                      onChanged: (int i) => setState(() => _modeIndex = i),
                    ),
                    _FinishPage(
                      source: _sourceIndex,
                      onSource: (int i) => setState(() => _sourceIndex = i),
                      settings: state.settings,
                      onToggle: state.updateSettings,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Column(
                  children: <Widget>[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List<Widget>.generate(3, (int i) {
                        final active = i == _page;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutCubic,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: active ? 22 : 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: active
                                ? colors.primary
                                : colors.outlineVariant.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 14),
                    FilledButton(
                      onPressed: _next,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          Text(_page == 2 ? 'Начать пользоваться' : 'Продолжить'),
                          const SizedBox(width: 8),
                          Icon(
                            _page == 2
                                ? Icons.check_rounded
                                : Icons.arrow_forward_rounded,
                            size: 19,
                          ),
                        ],
                      ),
                    ),
                    if (_page == 2)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Всё можно изменить в настройках',
                          style: context.texts.bodySmall,
                        ),
                      ),
                    if (_page == 1)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Режим можно переключать на главном экране',
                          style: context.texts.bodySmall,
                        ),
                      ),
                    if (_page == 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Rust + Material 3 · без рекламы и трекеров',
                          style: context.texts.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IntroPage extends StatelessWidget {
  const _IntroPage({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final palette = context.palette;
    return AnimatedBuilder(
      animation: animation,
      builder: (BuildContext context, _) {
        final t = Curves.easeOutCubic.transform(animation.value.clamp(0.0, 1.0));
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                SizedBox(
                  width: 210,
                  height: 210,
                  child: Stack(
                    alignment: Alignment.center,
                    children: <Widget>[
                      Transform.rotate(
                        angle: t * math.pi * 0.5,
                        child: Container(
                          width: 196,
                          height: 196,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: SweepGradient(
                              colors: <Color>[
                                colors.primary.withValues(alpha: 0.0),
                                colors.primary.withValues(alpha: 0.5),
                                palette.success.withValues(alpha: 0.4),
                                colors.primary.withValues(alpha: 0.0),
                              ],
                            ),
                          ),
                          child: Center(
                            child: Container(
                              width: 178,
                              height: 178,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: colors.surface,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Opacity(
                        opacity: t,
                        child: Transform.scale(
                          scale: 0.85 + 0.15 * t,
                          child: Container(
                            width: 150,
                            height: 150,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: <Color>[
                                  colors.primaryContainer,
                                  Color.lerp(colors.primaryContainer, palette.successContainer, 0.5)!,
                                ],
                              ),
                              boxShadow: <BoxShadow>[
                                BoxShadow(
                                  color: colors.primary.withValues(alpha: 0.28),
                                  blurRadius: 44,
                                  spreadRadius: 4,
                                ),
                              ],
                            ),
                            child: Icon(Icons.shield_rounded,
                                size: 74, color: colors.onPrimaryContainer),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),
                Opacity(
                  opacity: t,
                  child: Column(
                    children: <Widget>[
                      Text(
                        'RustedProxy',
                        textAlign: TextAlign.center,
                        style: context.texts.headlineLarge?.copyWith(fontSize: 32),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Свободный интернет на скорости Rust.\nСканер прокси, умная маршрутизация и DPI-обход — всё на устройстве.',
                        textAlign: TextAlign.center,
                        style: context.texts.bodyLarge?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),
                Opacity(
                  opacity: t,
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: const <Widget>[
                      _FeaturePill(icon: Icons.speed_rounded, label: 'Быстрое ядро'),
                      _FeaturePill(icon: Icons.travel_explore_rounded, label: 'Сканер'),
                      _FeaturePill(icon: Icons.security_rounded, label: 'Без утечек'),
                      _FeaturePill(icon: Icons.graphic_eq_rounded, label: 'Обход РФ'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FeaturePill extends StatelessWidget {
  const _FeaturePill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceContainer.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 15, color: colors.primary),
          const SizedBox(width: 6),
          Text(label, style: context.texts.labelMedium?.copyWith(fontSize: 12)),
        ],
      ),
    );
  }
}

class _ModePage extends StatelessWidget {
  const _ModePage({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  static const List<_ModeOption> _options = <_ModeOption>[
    _ModeOption(
      icon: Icons.auto_awesome_rounded,
      title: 'Полная работа',
      subtitle:
          'Рекомендуется. Работают все настройки: выбранные сервисы идут через прокси, '
          'остальное напрямую, плюс обход блокировок РФ, DNS и защита от DPI.',
      badge: 'Все функции',
    ),
    _ModeOption(
      icon: Icons.vpn_lock_rounded,
      title: 'Только прокси',
      subtitle:
          'Весь трафик устройства принудительно идёт через подключённый прокси. '
          'Обход РФ и умная маршрутизация при этом отключены.',
      badge: 'Весь трафик',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      children: <Widget>[
        Text('Как подключаться?', style: context.texts.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'Выберите режим — его всегда можно переключить на главном экране.',
          style: context.texts.bodySmall,
        ),
        const SizedBox(height: 18),
        for (var i = 0; i < _options.length; i++) ...<Widget>[
          _ModeCard(
            option: _options[i],
            selected: i == index,
            onTap: () => onChanged(i),
          ),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 4),
        Row(
          children: <Widget>[
            Icon(Icons.verified_rounded, size: 15, color: colors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Системный туннель запросит VPN-разрешение один раз. В режиме «Локальный прокси» оно не нужно.',
                style: context.texts.bodySmall,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ModeOption {
  const _ModeOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.badge,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String badge;
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final _ModeOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: selected
            ? colors.primaryContainer.withValues(alpha: 0.55)
            : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: selected
              ? colors.primary.withValues(alpha: 0.75)
              : colors.outlineVariant.withValues(alpha: 0.45),
          width: selected ? 1.6 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: selected ? colors.primary : colors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(
                    option.icon,
                    size: 22,
                    color: selected ? colors.onPrimary : colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(option.title,
                                style: context.texts.titleMedium?.copyWith(fontSize: 15)),
                          ),
                          BadgePill(
                            label: option.badge,
                            dense: true,
                            color: selected ? colors.onPrimaryContainer : colors.onSurfaceVariant,
                            background: selected
                                ? colors.primary.withValues(alpha: 0.25)
                                : colors.surfaceContainerHigh,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(option.subtitle, style: context.texts.bodySmall),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: selected ? 1 : 0,
                  child: Icon(Icons.check_circle_rounded,
                      size: 22, color: colors.primary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FinishPage extends StatelessWidget {
  const _FinishPage({
    required this.source,
    required this.onSource,
    required this.settings,
    required this.onToggle,
  });

  final int source;
  final ValueChanged<int> onSource;
  final AppSettings settings;
  final void Function(void Function(AppSettings s) mutate) onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final palette = context.palette;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      children: <Widget>[
        Text('Откуда взять серверы?', style: context.texts.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'Можно пропустить — источники доступны на вкладке «Поиск».',
          style: context.texts.bodySmall,
        ),
        const SizedBox(height: 16),
        for (var i = 0; i < 3; i++) ...<Widget>[
          _SourceCard(
            icon: switch (i) {
              1 => Icons.qr_code_2_rounded,
              2 => Icons.link_rounded,
              _ => Icons.radar_rounded,
            },
            title: switch (i) {
              1 => 'QR-код или буфер',
              2 => 'Подписка',
              _ => 'Найти автоматически',
            },
            subtitle: switch (i) {
              1 => 'Отсканируйте конфигурацию или вставьте ссылку',
              2 => 'Импортируйте список VLESS / Trojan / SS',
              _ => 'Сканер проверит сотни публичных узлов',
            },
            selected: source == i,
            onTap: () => onSource(i),
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 14),
        Text('Защита', style: context.texts.titleMedium),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.4)),
          ),
          child: Column(
            children: <Widget>[
              TileSwitch(
                title: 'Блокировка рекламы',
                subtitle: 'Офлайн-база доменов',
                icon: Icons.block_rounded,
                value: settings.adblock,
                onChanged: (bool v) => onToggle((s) => s.adblock = v),
              ),
              TileSwitch(
                title: 'Обход блокировок РФ',
                subtitle: 'Локальные сайты — напрямую',
                icon: Icons.flag_rounded,
                value: settings.bypassRu,
                onChanged: (bool v) => onToggle((s) => s.bypassRu = v),
              ),
              TileSwitch(
                title: 'Kill Switch',
                subtitle: 'Стоп трафику при обрыве',
                icon: Icons.shield_rounded,
                value: settings.killSwitch,
                onChanged: (bool v) => onToggle((s) => s.killSwitch = v),
              ),
              TileSwitch(
                title: 'DPI-обход',
                subtitle: 'Фрагментация TLS',
                icon: Icons.graphic_eq_rounded,
                value: settings.dpiBypass,
                onChanged: (bool v) => onToggle((s) => s.dpiBypass = v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: palette.successContainer.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.lock_rounded, size: 18, color: palette.success),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Все вычисления и проверки выполняются локально. Никакой аналитики и рекламы.',
                  style: context.texts.bodySmall?.copyWith(color: colors.onSurface),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      decoration: BoxDecoration(
        color: selected
            ? colors.secondaryContainer.withValues(alpha: 0.55)
            : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: selected
              ? colors.primary.withValues(alpha: 0.6)
              : colors.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: <Widget>[
                Icon(icon,
                    size: 21,
                    color: selected ? colors.primary : colors.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title,
                          style: context.texts.titleMedium?.copyWith(fontSize: 14)),
                      Text(subtitle, style: context.texts.bodySmall),
                    ],
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle_rounded, size: 19, color: colors.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


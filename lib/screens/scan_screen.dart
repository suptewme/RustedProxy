import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/system_ui.dart';
import '../models/proxy.dart';
import '../sheets.dart';
import '../theme.dart';
import '../widgets/proxy_card.dart';
import '../widgets/ui.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.onNavigate});

  final ValueChanged<int> onNavigate;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ResultFilters extends StatelessWidget {
  const _ResultFilters({required this.state});

  final AppState state;

  static const List<MapEntry<String, String>> _presets = <MapEntry<String, String>>[
    MapEntry<String, String>('quick', 'Быстрые < 100 мс'),
    MapEntry<String, String>('good', '100–300 мс'),
    MapEntry<String, String>('slow', '> 300 мс'),
  ];

  bool _selected(String key) {
    switch (key) {
      case 'quick':
        return state.scanPingMin == 0 && state.scanPingMax == 100;
      case 'good':
        return state.scanPingMin == 100 && state.scanPingMax == 300;
      case 'slow':
        return state.scanPingMin == 300 && state.scanPingMax == 0;
      default:
        return state.scanPingMin == 0 && state.scanPingMax == 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final countries = state.scanCountries;
    final flags = <String, String>{};
    for (final p in state.scan.found) {
      if (p.countryCode.isNotEmpty) flags.putIfAbsent(p.countryCode, () => p.flag);
    }
    Widget chip({
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
          label: Text(label),
          selected: selected,
          showCheckmark: false,
          onSelected: (_) {
            onTap();
            state.touch();
          },
          backgroundColor: colors.surfaceContainer,
          selectedColor: colors.secondaryContainer,
          labelStyle: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? colors.onSecondaryContainer : colors.onSurfaceVariant,
          ),
          side: BorderSide(
            color: selected ? Colors.transparent : colors.outlineVariant.withValues(alpha: 0.6),
          ),
          shape: const StadiumBorder(),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.filter_alt_outlined, size: 15, color: colors.onSurfaceVariant),
            const SizedBox(width: 6),
            Text('Пинг и страна', style: context.texts.bodySmall),
            const Spacer(),
            chip(
              label: state.scanSortDesc ? 'Сначала медленные' : 'Сначала быстрые',
              selected: false,
              onTap: () => state.scanSortDesc = !state.scanSortDesc,
            ),
          ],
        ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              chip(
                label: 'Любой пинг',
                selected: _selected('any'),
                onTap: () {
                  state.scanPingMin = 0;
                  state.scanPingMax = 0;
                },
              ),
              for (final preset in _presets)
                chip(
                  label: preset.value,
                  selected: _selected(preset.key),
                  onTap: () {
                    switch (preset.key) {
                      case 'quick':
                        state.scanPingMin = 0;
                        state.scanPingMax = 100;
                      case 'good':
                        state.scanPingMin = 100;
                        state.scanPingMax = 300;
                      case 'slow':
                        state.scanPingMin = 300;
                        state.scanPingMax = 0;
                    }
                  },
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              chip(
                label: 'Все страны',
                selected: state.scanCountry.isEmpty,
                onTap: () => state.scanCountry = '',
              ),
              for (final entry in countries.take(14))
                chip(
                  label: '${flags[entry.key] ?? ''} ${entry.key} · ${entry.value}',
                  selected: state.scanCountry == entry.key,
                  onTap: () => state.scanCountry =
                      state.scanCountry == entry.key ? '' : entry.key,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ScanScreenState extends State<ScanScreen> {
  static const List<MapEntry<String, String>> _protocols = <MapEntry<String, String>>[
    MapEntry<String, String>('all', 'Все'),
    MapEntry<String, String>('socks5', 'SOCKS5'),
    MapEntry<String, String>('socks4', 'SOCKS4'),
    MapEntry<String, String>('http', 'HTTP'),
    MapEntry<String, String>('https', 'HTTPS'),
    MapEntry<String, String>('ss', 'Shadowsocks'),
    MapEntry<String, String>('trojan', 'Trojan'),
    MapEntry<String, String>('vless', 'VLESS'),
  ];

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return AnimatedBuilder(
      animation: state,
      builder: (BuildContext context, _) {
        final colors = context.colors;
        final palette = context.palette;
        final results = state.filteredScanResults;
        return ListView(
          padding: SystemUiInfo.of(context, nativeMode: state.navMode)
              .scrollPadding(top: 4),
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          children: <Widget>[
            ScreenTitle(
              'Умный сканер',
              subtitle: state.scan.total > 0
                  ? 'Проверено ${state.scan.checked} из ${state.scan.total} · найдено ${state.scan.found.length}'
                  : 'Проверяем прокси реальным HTTPS-запросом через каждый узел',
            ),
            SegmentedTabs(
              labels: const <String>['Публичные прокси', 'Бесплатные ключи'],
              index: state.scanMode == 'keys' ? 1 : 0,
              onChanged: (int index) {
                state.scanMode = index == 0 ? 'public' : 'keys';
                state.touch();
              },
            ),
            const SizedBox(height: 14),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _protocols.map((MapEntry<String, String> entry) {
                  final selected = state.scanProtocol == entry.key;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(entry.value),
                      selected: selected,
                      showCheckmark: false,
                      onSelected: (_) {
                        state.scanProtocol = entry.key;
                        state.touch();
                      },
                      backgroundColor: colors.surfaceContainer,
                      selectedColor: colors.secondaryContainer,
                      labelStyle: TextStyle(
                        fontSize: 12.5,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected ? colors.onSecondaryContainer : colors.onSurfaceVariant,
                      ),
                      side: BorderSide(
                        color: selected
                            ? Colors.transparent
                            : colors.outlineVariant.withValues(alpha: 0.6),
                      ),
                      shape: const StadiumBorder(),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _qualityChip(
                  context,
                  label: 'Только зашифрованные',
                  icon: Icons.lock_rounded,
                  value: state.scanEncrypted,
                  onChanged: (bool v) {
                    state.scanEncrypted = v;
                    state.touch();
                  },
                ),
                _qualityChip(
                  context,
                  label: 'Для видео > 15 Мбит/с',
                  icon: Icons.play_circle_outline_rounded,
                  value: state.scanVideo,
                  onChanged: (bool v) {
                    state.scanVideo = v;
                    state.touch();
                  },
                ),
                _qualityChip(
                  context,
                  label: 'Поддержка UDP',
                  icon: Icons.swap_vert_rounded,
                  value: state.scanUdp,
                  onChanged: (bool v) {
                    state.scanUdp = v;
                    state.touch();
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (state.scanning)
              OutlinedButton.icon(
                onPressed: state.stopScan,
                icon: const Icon(Icons.stop_circle_outlined, size: 20),
                label: const Text('Остановить сканирование'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  foregroundColor: colors.error,
                  side: BorderSide(color: colors.error.withValues(alpha: 0.5)),
                ),
              )
            else
              FilledButton.icon(
                onPressed: () async {
                  try {
                    await state.startScan();
                  } catch (e) {
                    if (!context.mounted) return;
                    showSnack(context, e.toString(), error: true);
                  }
                },
                icon: const Icon(Icons.radar_rounded, size: 20),
                label: Text(state.scanMode == 'keys'
                    ? 'Собрать бесплатные ключи'
                    : 'Найти и проверить серверы'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              ),
            const SizedBox(height: 16),
            AnimatedSize(
              duration: const Duration(milliseconds: 260),
              alignment: Alignment.topCenter,
              child: state.scanning || state.scan.total > 0 || state.scan.found.isNotEmpty
                  ? AppCard(
                      color: colors.surfaceContainerLow,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              if (state.scanning)
                                SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    value: state.scan.progress > 0 && state.scan.progress < 1
                                        ? state.scan.progress
                                        : null,
                                  ),
                                )
                              else
                                Icon(Icons.check_circle_rounded,
                                    size: 18, color: palette.success),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  state.scan.phaseLabel,
                                  style: context.texts.titleMedium?.copyWith(fontSize: 14),
                                ),
                              ),
                              if (state.scan.elapsed > 0)
                                MonoText(
                                  formatDuration(state.scan.elapsed),
                                  size: 12,
                                  color: colors.onSurfaceVariant,
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: LinearProgressIndicator(
                              value: state.scan.total == 0 ? null : state.scan.progress,
                              minHeight: 7,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  'Проверено ${state.scan.checked} / ${state.scan.total}',
                                  style: context.texts.bodySmall,
                                ),
                              ),
                              Text('Пропущено ${state.scan.skipped}',
                                  style: context.texts.bodySmall),
                            ],
                          ),
                          if (state.scan.errors.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 8),
                            Row(
                              children: <Widget>[
                                Icon(Icons.warning_amber_rounded,
                                    size: 15, color: palette.warning),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    '${state.scan.errors.length} источник(ов) недоступны',
                                    style: context.texts.bodySmall?.copyWith(color: palette.warning),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 14),
            if (state.scan.found.isNotEmpty) ...<Widget>[
              _ResultFilters(state: state),
              const SizedBox(height: 10),
            ],
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Найдено серверов',
                    style: context.texts.titleMedium?.copyWith(fontSize: 15),
                  ),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: Text(
                    '${results.length}',
                    key: ValueKey<int>(results.length),
                    style: context.texts.headlineSmall?.copyWith(color: colors.primary),
                  ),
                ),
              ],
            ),
            if (results.isNotEmpty && !state.scanning)
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        state.scanSortDesc
                            ? 'Сортировка по пингу: сверху самые высокие'
                            : 'Сортировка по пингу: сверху самые быстрые',
                        style: context.texts.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final count = results.length;
                        await state.saveMany(results);
                        if (!context.mounted) return;
                        showSnack(context, 'Сохранено серверов: $count');
                      },
                      child: const Text('Сохранить все'),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            if (results.isEmpty)
              EmptyState(
                icon: Icons.travel_explore_rounded,
                title: state.scanning
                    ? 'Идёт проверка…'
                    : state.scan.found.isEmpty && state.scanRanOnce
                        ? 'Прокси данного типа не найдено'
                        : 'Результатов пока нет',
                subtitle: state.scanning
                    ? 'Ядро параллельно проверяет сотни кандидатов и отбрасывает мёртвые.'
                    : state.scan.found.isNotEmpty
                        ? 'Под текущие фильтры ничего не подошло — ослабьте пинг или страну.'
                        : 'Запустите сканер — живые узлы появятся здесь с пингом, скоростью и геолокацией.',
              )
            else
              ...results.asMap().entries.map((MapEntry<int, ProxyServer> entry) {
                final server = entry.value;
                final isSaved = state.saved.any((ProxyServer p) => p.key == server.key);
                return ProxyCard(
                  key: ValueKey<String>(server.key),
                  server: server,
                  index: entry.key,
                  isActive: state.active?.key == server.key && state.isOn,
                  saved: isSaved,
                  onConnect: () async {
                    await state.saveProxy(server, makeActive: true);
                    if (!context.mounted) return;
                    try {
                      await state.connect(proxy: server);
                      if (!context.mounted) return;
                      showSnack(context, 'Подключено: ${server.displayName}');
                      widget.onNavigate(0);
                    } catch (e) {
                      if (!context.mounted) return;
                      showSnack(context, e.toString().replaceFirst('Bad state: ', ''), error: true);
                    }
                  },
                  onSave: () async {
                    await state.saveProxy(server);
                    if (!context.mounted) return;
                    showSnack(context, 'Сервер сохранён');
                  },
                  onCopy: () async {
                    final link = await state.buildLink(server);
                    if (link == null) return;
                    await Clipboard.setData(ClipboardData(text: link));
                    if (!context.mounted) return;
                    showSnack(context, 'Ссылка скопирована');
                  },
                  onQr: () => showQrSheet(context, server),
                );
              }),
          ],
        );
      },
    );
  }

  Widget _qualityChip(
    BuildContext context, {
    required String label,
    required IconData icon,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final colors = context.colors;
    return FilterChip(
      avatar: Icon(
        icon,
        size: 15,
        color: value ? colors.onSecondaryContainer : colors.onSurfaceVariant,
      ),
      label: Text(label),
      selected: value,
      showCheckmark: false,
      onSelected: onChanged,
      backgroundColor: colors.surfaceContainer,
      selectedColor: colors.secondaryContainer,
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: value ? FontWeight.w700 : FontWeight.w500,
        color: value ? colors.onSecondaryContainer : colors.onSurfaceVariant,
      ),
      side: BorderSide(
        color: value ? Colors.transparent : colors.outlineVariant.withValues(alpha: 0.6),
      ),
      shape: const StadiumBorder(),
    );
  }
}


import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/system_ui.dart';
import '../models/proxy.dart';
import '../sheets.dart';
import '../theme.dart';
import '../widgets/proxy_card.dart';
import '../widgets/ui.dart';

class ProxiesScreen extends StatelessWidget {
  const ProxiesScreen({super.key, required this.onNavigate});

  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return AnimatedBuilder(
      animation: state,
      builder: (BuildContext context, _) {
        final colors = context.colors;
        final palette = context.palette;
        final saved = state.saved;
        return ListView(
          padding: SystemUiInfo.of(context, nativeMode: state.navMode)
              .scrollPadding(top: 4),
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          children: <Widget>[
            ScreenTitle(
              'Мои прокси',
              subtitle: saved.isEmpty
                  ? 'Добавьте сервер любым способом'
                  : '${saved.length} сохранённых · ${state.settings.multiHop ? 'multi-hop включён' : 'один узел'}',
              trailing: saved.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Очистить список',
                      onPressed: () async {
                        final ok = await confirmDialog(
                          context,
                          title: 'Удалить все прокси?',
                          message: 'Сохранённые серверы будут удалены. Настройки останутся.',
                          confirm: 'Удалить',
                          destructive: true,
                        );
                        if (ok) await state.clearSaved();
                      },
                      icon: const Icon(Icons.delete_sweep_outlined),
                    ),
            ),
            _ImportGrid(
              onManual: () => showManualProxySheet(context),
              onClipboard: () => importFromClipboard(context),
              onQr: () => showQrScanSheet(context),
              onSub: () => showSubscriptionSheet(context),
            ),
            const SizedBox(height: 12),
            AppCard(
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text('Цепочка прокси (Multi-Hop)',
                                style: context.texts.titleMedium),
                            const SizedBox(height: 2),
                            Text('Устройство → вход → выход → интернет',
                                style: context.texts.bodySmall),
                          ],
                        ),
                      ),
                      Switch.adaptive(
                        value: state.settings.multiHop,
                        onChanged: (bool value) {
                          if (value && saved.length < 2) {
                            showSnack(
                              context,
                              'Для цепочки нужно минимум два сохранённых сервера',
                              error: true,
                            );
                            return;
                          }
                          state.setMultiHop(value);
                        },
                      ),
                    ],
                  ),
                  AnimatedCrossFade(
                    duration: const Duration(milliseconds: 260),
                    crossFadeState: state.settings.multiHop
                        ? CrossFadeState.showSecond
                        : CrossFadeState.showFirst,
                    firstChild: const SizedBox(width: double.infinity),
                    secondChild: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Column(
                        children: <Widget>[
                          _HopVisual(
                            entry: state.entry,
                            exit: state.exit,
                            enabled: state.settings.multiHop,
                          ),
                          const SizedBox(height: 10),
                          if (saved.length >= 2) ...<Widget>[
                            _HopSelect(
                              label: 'Входной сервер',
                              value: state.entry,
                              items: saved,
                              onChanged: (ProxyServer p) => state.setEntry(p),
                            ),
                            _HopSelect(
                              label: 'Выходной сервер',
                              value: state.exit,
                              items: saved,
                              onChanged: (ProxyServer p) => state.setExit(p),
                            ),
                          ] else
                            Text(
                              'Для цепочки нужно минимум два сохранённых сервера',
                              style: context.texts.bodySmall?.copyWith(color: palette.warning),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: state.pinging || saved.isEmpty
                  ? null
                  : () async {
                      await state.pingAll();
                      if (!context.mounted) return;
                      showSnack(context, 'Пинг обновлён для ${state.saved.length} серверов');
                    },
              icon: state.pinging
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_ping_rounded, size: 18),
              label: Text(state.pinging ? 'Проверяем…' : 'Проверить пинг всех'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
            ),
            const SizedBox(height: 14),
            if (saved.isEmpty)
              EmptyState(
                icon: Icons.lan_outlined,
                title: 'Список пуст',
                subtitle: 'Импортируйте подписку, отсканируйте QR или вставьте ссылку из буфера.',
                action: FilledButton.icon(
                  onPressed: () => showManualProxySheet(context),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Добавить вручную'),
                ),
              )
            else
              ...saved.asMap().entries.map((MapEntry<int, ProxyServer> entry) {
                final server = entry.value;
                final active = state.active?.key == server.key;
                return ProxyCard(
                  key: ValueKey<String>(server.key),
                  server: server,
                  index: entry.key,
                  isActive: active,
                  saved: true,
                  onConnect: () async {
                    state.setActive(server);
                    try {
                      await state.connect(proxy: server);
                      if (!context.mounted) return;
                      showSnack(context, 'Подключено: ${server.displayName}');
                      onNavigate(0);
                    } catch (e) {
                      if (!context.mounted) return;
                      showSnack(context, e.toString().replaceFirst('Bad state: ', ''), error: true);
                    }
                  },
                  onQr: () => showQrSheet(context, server),
                  onCopy: () async {
                    final link = await state.buildLink(server);
                    if (link == null) return;
                    await Clipboard.setData(ClipboardData(text: link));
                    if (!context.mounted) return;
                    showSnack(context, 'Ссылка скопирована');
                  },
                  onDelete: () async {
                    final ok = await confirmDialog(
                      context,
                      title: 'Удалить сервер?',
                      message: server.displayName,
                      confirm: 'Удалить',
                      destructive: true,
                    );
                    if (ok) await state.deleteProxy(server);
                  },
                );
              }),
            if (saved.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              AppCard(
                color: colors.surfaceContainerLow,
                child: Row(
                  children: <Widget>[
                    Icon(Icons.info_outline_rounded,
                        size: 17, color: colors.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Серверы с замком используют TLS/AEAD. При включённом запрете незашифрованных прокси открытые HTTP/SOCKS-узлы будут блокироваться маршрутизатором.',
                        style: context.texts.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> importFromClipboard(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (context.mounted) showSnack(context, 'Буфер обмена пуст', error: true);
      return;
    }
    final count = await AppState.instance.importText(text);
    if (!context.mounted) return;
    if (count == 0) {
      showSnack(context, 'В буфере не найдено поддерживаемых ссылок', error: true);
    } else {
      showSnack(context, 'Импортировано серверов: $count');
    }
  }
}

class _ImportGrid extends StatelessWidget {
  const _ImportGrid({
    required this.onManual,
    required this.onClipboard,
    required this.onQr,
    required this.onSub,
  });

  final VoidCallback onManual;
  final VoidCallback onClipboard;
  final VoidCallback onQr;
  final VoidCallback onSub;

  @override
  Widget build(BuildContext context) {
    final items = <_ImportItem>[
      _ImportItem('Вручную', Icons.add_rounded, onManual),
      _ImportItem('Из буфера', Icons.content_paste_rounded, onClipboard),
      _ImportItem('QR-код', Icons.qr_code_scanner_rounded, onQr),
      _ImportItem('Подписка', Icons.link_rounded, onSub),
    ];
    return Row(
      children: items
          .map((_ImportItem item) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _ImportButton(item: item),
                ),
              ))
          .toList(),
    );
  }
}

class _ImportItem {
  const _ImportItem(this.label, this.icon, this.onTap);

  final String label;
  final IconData icon;
  final VoidCallback onTap;
}

class _ImportButton extends StatelessWidget {
  const _ImportButton({required this.item});

  final _ImportItem item;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: item.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.4)),
          ),
          child: Column(
            children: <Widget>[
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(item.icon, size: 20, color: colors.primary),
              ),
              const SizedBox(height: 7),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.texts.labelMedium?.copyWith(fontSize: 11.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HopVisual extends StatelessWidget {
  const _HopVisual({required this.entry, required this.exit, required this.enabled});

  final ProxyServer? entry;
  final ProxyServer? exit;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final nodes = <String>[
      '📱 Вы',
      entry?.flag ?? '—',
      exit?.flag ?? '—',
      '🌐',
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        for (var i = 0; i < nodes.length; i++) ...<Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: enabled ? colors.primaryContainer.withValues(alpha: 0.5) : colors.surfaceContainer,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: colors.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Text(nodes[i], style: context.texts.bodySmall?.copyWith(
              fontSize: 12,
              color: enabled ? colors.onPrimaryContainer : colors.onSurfaceVariant,
            )),
          ),
          if (i < nodes.length - 1)
            Icon(Icons.arrow_forward_rounded, size: 14, color: colors.onSurfaceVariant),
        ],
      ],
    );
  }
}

class _HopSelect extends StatelessWidget {
  const _HopSelect({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final ProxyServer? value;
  final List<ProxyServer> items;
  final ValueChanged<ProxyServer> onChanged;

  @override
  Widget build(BuildContext context) {
    final current = value != null && items.any((ProxyServer p) => p.key == value!.key)
        ? value!.key
        : null;
    return TileSelect(
      label: label,
      value: current ?? '',
      icon: Icons.alt_route_rounded,
      items: items
          .map((ProxyServer p) => DropdownMenuItem<String>(
                value: p.key,
                child: Text(
                  '${p.flag} ${p.displayName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ))
          .toList(),
      onChanged: (String? key) {
        if (key == null) return;
        final found = items.firstWhere((ProxyServer p) => p.key == key);
        onChanged(found);
      },
    );
  }
}

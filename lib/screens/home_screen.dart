import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/system_ui.dart';
import '../theme.dart';
import '../widgets/power_button.dart';
import '../widgets/proxy_card.dart';
import '../widgets/ui.dart';
import '../sheets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.onNavigate});

  final ValueChanged<int> onNavigate;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return AnimatedBuilder(
      animation: state,
      builder: (BuildContext context, _) {
        final colors = context.colors;
        final palette = context.palette;
        final connected = state.isOn;
        final server = state.active;
        final ip = connected
            ? (state.exitIp.isNotEmpty ? state.exitIp : '—')
            : (state.realIp.isNotEmpty ? state.realIp : '—');
        final location = connected
            ? (state.exitCountry.isNotEmpty
                ? '${state.exitFlag} ${state.exitCountry}${state.exitCity.isNotEmpty ? ', ${state.exitCity}' : ''}'
                : 'Туннель активен')
            : 'Прямое подключение';
        final modeIndex = state.settings.mode == 'proxy' ? 1 : 0;
        final latency = server?.latency ?? 0;

        return ListView(
          padding: SystemUiInfo.of(context, nativeMode: state.navMode)
              .scrollPadding(top: 4),
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          children: <Widget>[
            _IpCard(
              connected: connected,
              ip: ip,
              location: location,
              latency: latency,
              encryption: connected
                  ? (server?.securityLabel.isNotEmpty == true ? server!.securityLabel : 'Tunnel')
                  : '—',
              dns: state.settings.dnsLabel,
              onRefresh: () {
                unawaited(state.refreshIps());
                showSnack(context, 'Обновляем IP и геолокацию…');
              },
            ),
            const SizedBox(height: 12),
            SegmentedTabs(
              labels: const <String>['Полная работа', 'Только прокси'],
              index: modeIndex,
              onChanged: (int index) {
                state.setMode(index == 1 ? 'proxy' : 'full');
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
              child: Text(
                state.settings.modeDescription,
                textAlign: TextAlign.center,
                style: context.texts.bodySmall?.copyWith(fontSize: 11.5),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: PowerButton(
                connected: connected,
                busy: state.busyConnecting,
                onTap: () async {
                  try {
                    await state.toggleConnection();
                    if (!context.mounted) return;
                    if (state.lastError != null && !state.isOn) {
                      showSnack(context, state.lastError!, error: true);
                    }
                  } catch (e) {
                    if (!context.mounted) return;
                    showSnack(context, e.toString().replaceFirst('Bad state: ', ''), error: true);
                  }
                },
              ),
            ),
            Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  state.busyConnecting
                      ? 'Устанавливаем соединение…'
                      : connected
                          ? 'Соединение защищено'
                          : 'Нажмите для подключения',
                  key: ValueKey<String>('${state.busyConnecting}-$connected'),
                  style: context.texts.bodyMedium?.copyWith(
                    color: connected ? palette.success : colors.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: ValueListenableBuilder<LiveStats>(
                valueListenable: state.liveNotifier,
                builder: (BuildContext context, LiveStats live, _) => MonoText(
                  formatDuration(live.uptime),
                  size: 13,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 18),
            if (server != null)
              AppCard(
                padding: const EdgeInsets.all(14),
                onTap: () => showServerPicker(context),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      alignment: Alignment.center,
                      child: Text(server.flag, style: const TextStyle(fontSize: 23)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(server.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.texts.titleMedium),
                          const SizedBox(height: 2),
                          MonoText(
                            '${server.endpoint} · ${server.protoLabel}',
                            size: 11.5,
                            color: colors.onSurfaceVariant,
                            weight: FontWeight.w400,
                          ),
                        ],
                      ),
                    ),
                    if (state.isOn && server.latency > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: BadgePill(
                          label: server.latencyLabel,
                          icon: Icons.speed_rounded,
                          dense: true,
                          color: latencyColor(context, server.latency),
                          background: colors.surfaceContainerHigh,
                        ),
                      ),
                    if (server.encrypted)
                      Icon(Icons.lock_rounded, size: 16, color: palette.success),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: () async {
                        await state.switchToNext();
                        if (!context.mounted) return;
                        showSnack(context, 'Сервер переключён');
                      },
                      icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                      label: const Text('Сменить'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 36),
                      ),
                    ),
                  ],
                ),
              )
            else
              AppCard(
                color: colors.surfaceContainerLow,
                child: Row(
                  children: <Widget>[
                    Icon(Icons.dns_outlined, color: colors.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text('Сервер не выбран', style: context.texts.titleMedium),
                          Text('Найдите прокси или добавьте вручную',
                              style: context.texts.bodySmall),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () => widget.onNavigate(1),
                      child: const Text('Найти'),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            ValueListenableBuilder<LiveStats>(
              valueListenable: state.liveNotifier,
              builder: (BuildContext context, LiveStats live, _) {
                return Row(
                  children: <Widget>[
                    Expanded(
                      child: _TrafficCard(
                        label: 'Получено',
                        icon: Icons.south_rounded,
                        total: formatBytes(live.bytesDown),
                        speed: formatSpeed(live.downRate),
                        rate: live.downRate,
                        connected: live.connected,
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _TrafficCard(
                        label: 'Отправлено',
                        icon: Icons.north_rounded,
                        total: formatBytes(live.bytesUp),
                        speed: formatSpeed(live.upRate),
                        rate: live.upRate,
                        connected: live.connected,
                        color: palette.success,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<LiveStats>(
              valueListenable: state.liveNotifier,
              builder: (BuildContext context, LiveStats live, _) => AppCard(
                color: colors.surfaceContainerLow,
                child: Column(
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: _MiniStat(
                            label: 'Соединений',
                            value: '${live.conns}',
                            icon: Icons.hub_rounded,
                          ),
                        ),
                        _divider(context),
                        Expanded(
                          child: _MiniStat(
                            label: 'Всего',
                            value: '${live.totalConns}',
                            icon: Icons.timeline_rounded,
                          ),
                        ),
                        _divider(context),
                        Expanded(
                          child: _MiniStat(
                            label: 'Порт',
                            value: state.listenPort > 0 ? '${state.listenPort}' : '—',
                            icon: Icons.settings_ethernet_rounded,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        Icon(
                          state.vpnRunning
                              ? Icons.verified_user_rounded
                              : Icons.info_outline_rounded,
                          size: 15,
                          color: state.vpnRunning ? palette.success : colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            state.vpnRunning
                                ? 'TUN-интерфейс активен · ${state.settings.mtu} MTU · DNS ${state.settings.dnsLabel}'
                                : state.settings.androidMode == 'local'
                                    ? 'Локальный прокси 127.0.0.1:${state.settings.listenPort}'
                                    : 'VPN включится при подключении',
                            style: context.texts.bodySmall,
                          ),
                        ),
                        if (connected)
                          InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => widget.onNavigate(3),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              child: Text('Логи',
                                  style: context.texts.labelMedium?.copyWith(color: colors.primary)),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _divider(BuildContext context) => Container(
        width: 1,
        height: 32,
        color: context.colors.outlineVariant.withValues(alpha: 0.5),
      );
}

class _IpCard extends StatelessWidget {
  const _IpCard({
    required this.connected,
    required this.ip,
    required this.location,
    required this.latency,
    required this.encryption,
    required this.dns,
    required this.onRefresh,
  });

  final bool connected;
  final String ip;
  final String location;
  final int latency;
  final String encryption;
  final String dns;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color.lerp(colors.surfaceContainerHigh, colors.primaryContainer, connected ? 0.42 : 0.18)!,
            colors.surfaceContainerLow,
          ],
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: connected ? palette.success : colors.outline,
                  shape: BoxShape.circle,
                  boxShadow: connected
                      ? <BoxShadow>[
                          BoxShadow(color: palette.success.withValues(alpha: 0.5), blurRadius: 8)
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 8),
              Text('ТЕКУЩИЙ IP-АДРЕС',
                  style: context.texts.labelSmall?.copyWith(letterSpacing: 1.2)),
              const Spacer(),
              if (connected && latency > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: BadgePill(
                    label: '$latency мс',
                    icon: Icons.speed_rounded,
                    dense: true,
                    color: latencyColor(context, latency),
                    background: colors.surfaceContainerHigh.withValues(alpha: 0.7),
                  ),
                ),
              IconButton(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh_rounded, size: 19),
                visualDensity: VisualDensity.compact,
                tooltip: 'Обновить IP',
              ),
            ],
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: MonoText(ip, size: 30, weight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(location,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Шифрование: $encryption • DNS: $dns',
            style: context.texts.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _TrafficCard extends StatefulWidget {
  const _TrafficCard({
    required this.label,
    required this.icon,
    required this.total,
    required this.speed,
    required this.rate,
    required this.connected,
    required this.color,
  });

  final String label;
  final IconData icon;
  final String total;
  final String speed;
  final double rate;
  final bool connected;
  final Color color;

  @override
  State<_TrafficCard> createState() => _TrafficCardState();
}

class _TrafficCardState extends State<_TrafficCard> {
  static const int _points = 28;
  final List<double> _history = List<double>.filled(_points, 0, growable: true);
  bool _wasConnected = false;
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    _push();
  }

  @override
  void didUpdateWidget(covariant _TrafficCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rate != widget.rate || oldWidget.connected != widget.connected) {
      _push();
    }
  }

  void _push() {
    if (!_seeded) {
      _seeded = true;
      _wasConnected = widget.connected;
      return;
    }
    if (!widget.connected) {
      // A finished session leaves a clean graph for the next one.
      if (_wasConnected || _history.any((double v) => v != 0)) {
        for (int i = 0; i < _points; i++) {
          _history[i] = 0;
        }
      }
    } else {
      _history.removeAt(0);
      _history.add(widget.rate);
    }
    _wasConnected = widget.connected;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = widget.color;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(widget.icon, size: 14, color: color),
              const SizedBox(width: 6),
              Text(widget.label.toUpperCase(),
                  style: context.texts.labelSmall?.copyWith(letterSpacing: 0.8)),
            ],
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: MonoText(widget.total, size: 20, weight: FontWeight.w700),
          ),
          Text(widget.speed, style: context.texts.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
          const SizedBox(height: 6),
          RepaintBoundary(
            child: Sparkline(values: List<double>.of(_history), color: color, height: 34),
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value, required this.icon});

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 13, color: colors.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(label, style: context.texts.bodySmall),
          ],
        ),
        const SizedBox(height: 3),
        Text(value, style: context.texts.titleMedium?.copyWith(fontSize: 16)),
      ],
    );
  }
}

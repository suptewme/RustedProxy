import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/platform.dart';
import '../core/system_ui.dart';
import '../sheets.dart';
import '../theme.dart';
import '../widgets/ui.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  Map<String, dynamic> _info = <String, dynamic>{};
  Map<String, dynamic> _build = <String, dynamic>{};
  final TextEditingController _customDns = TextEditingController();
  final FocusNode _dnsFocus = FocusNode();
  bool _infoLoaded = false;
  bool _permissionBusy = false;
  bool _rootBusy = false;

  /// Ends the ink reaction of the tapped row right away. Material keeps it
  /// alive on the page route forever when a dialog steals the pointer, which
  /// made the settings list look frozen or greyed out until the app restarted.
  void _finishTaps() => popCurrentRoute(context);
  bool _dnsChecking = false;
  String? _dnsResult;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadInfo();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(AppState.instance.refreshPermissions());
      unawaited(AppState.instance.detectRoot());
    }
  }

  Future<void> _loadInfo() async {
    final info = await PlatformBridge.appInfo();
    final build = AppState.instance.rust.buildInfo();
    await AppState.instance.refreshPermissions();
    await AppState.instance.detectRoot();
    if (!mounted) return;
    setState(() {
      _info = info;
      _build = build;
      _infoLoaded = true;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _customDns.dispose();
    _dnsFocus.dispose();
    super.dispose();
  }

  Future<void> _editNumber({
    required String title,
    required String helper,
    required int initial,
    required int min,
    required int max,
    required ValueChanged<int> onDone,
  }) async {
    _finishTaps();
    final controller = TextEditingController(text: '$initial');
    final result = await showDialog<int>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              decoration: InputDecoration(hintText: '$min – $max'),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(helper, style: ctx.texts.bodySmall),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(
              int.tryParse(controller.text.trim()),
            ),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    onDone(result.clamp(min, max));
  }

  Future<void> _requestPermission(String type) async {
    // The click effect is synchronous and races the dialog that is opened a
    // few frames later; finishing it now prevents a stuck overlay.
    _finishTaps();
    if (_permissionBusy) return;
    setState(() => _permissionBusy = true);
    final state = AppState.instance;
    try {
      if (type == 'battery') {
        if (state.permissions['battery'] == true) {
          if (mounted) setState(() => _permissionBusy = false);
          await PlatformBridge.openBatterySettings();
          return;
        }
        await state.requestBatteryOptimization();
        if (!mounted) return;
        showSnack(context, 'Открыт системный запрос на работу в фоне');
      } else if (type == 'vpn') {
        final ok = await PlatformBridge.prepareVpn();
        await state.refreshPermissions();
        if (!mounted) return;
        showSnack(context, ok ? 'VPN-разрешение выдано' : 'VPN-разрешение не выдано', error: !ok);
      } else if (type == 'notifications' &&
          state.permissions['notifications'] == true) {
        if (mounted) setState(() => _permissionBusy = false);
        await PlatformBridge.openNotificationSettings();
        return;
      } else {
        await state.requestPermission(type);
        final granted = state.permissions[type] == true;
        if (!mounted) return;
        if (!granted) {
          showSnack(context, 'Разрешение не выдано — включите его в настройках', error: true);
        } else {
          showSnack(context, 'Разрешение выдано');
        }
      }
    } finally {
      if (mounted) setState(() => _permissionBusy = false);
    }
  }

  Future<void> _testDns() async {
    if (_dnsChecking) return;
    setState(() {
      _dnsChecking = true;
      _dnsResult = null;
    });
    final result = await AppState.instance.testDns('example.com');
    if (!mounted) return;
    final ok = result['ok'] == true;
    final ips = (result['ips'] as List<dynamic>? ?? <dynamic>[])
        .map((dynamic e) => e.toString())
        .join(', ');
    final elapsed = (result['elapsed'] as num?)?.toInt() ?? 0;
    setState(() {
      _dnsChecking = false;
      _dnsResult = ok
          ? '$ips · $elapsed мс'
          : (result['error'] ?? 'ошибка').toString();
    });
    if (!ok) {
      showSnack(context, 'DNS не работает: ${result['error'] ?? 'ошибка'}', error: true);
    }
  }

  Future<void> _runRoot(Future<bool> Function() action, {String? success}) async {
    // Finish the tap ripple before any dialog shows up; the overlay ticker
    // would otherwise live on the page route and never complete.
    _finishTaps();
    if (_rootBusy) return;
    setState(() => _rootBusy = true);
    final ok = await action();
    if (!mounted) return;
    setState(() => _rootBusy = false);
    if (!ok) {
      showSnack(context, AppState.instance.lastError ?? 'Root-команда не выполнена', error: true);
    } else if (success != null) {
      showSnack(context, success);
    }
  }

  /// Root switches shared by the real (su present) and the debug preview
/// version of the card. Kept as a method of the row itself so Flutter can put
/// its stateful tap handlers into the same list any time.
List<Widget> _rootSwitches() {
    final state = AppState.instance;
    final s = state.settings;
    return <Widget>[
      TileSwitch(
        title: 'TCP BBR и буферы',
        subtitle: 'Ускоряет ядро Android на мобильной сети',
        icon: Icons.rocket_launch_outlined,
        value: s.rootTuning,
        onChanged: (bool v) => _runRoot(() => state.setRootTuning(v)),
      ),
      TileSwitch(
        title: 'Kill Switch (iptables)',
        subtitle: 'Пускает в сеть только UID приложения, пока туннель активен',
        icon: Icons.shield_rounded,
        value: s.rootKillSwitch,
        onChanged: (bool v) async {
          if (v && state.rootAvailable) {
            final confirmed = await confirmDialog(
              context,
              title: 'Включить root kill switch?',
              message:
                  'Пока VPN подключён, весь трафик других приложений в обход туннеля будет заблокирован на уровне iptables. Правило снимается при отключении VPN.',
              confirm: 'Включить',
              destructive: true,
            );
            if (!confirmed) return;
          }
          await _runRoot(() => state.setRootKillSwitch(v));
        },
      ),
      TileSwitch(
        title: 'Принудительный DNS',
        subtitle: 'Перехват UDP/TCP 53 на ${s.dnsIp} для всех приложений',
        icon: Icons.dns_rounded,
        value: s.rootDnsRedirect,
        onChanged: (bool v) => _runRoot(() => state.setRootDnsRedirect(v)),
      ),
      TileSwitch(
        title: 'Always-on VPN',
        subtitle: 'Система будет держать туннель запущенным',
        icon: Icons.all_inclusive_rounded,
        value: s.rootAlwaysOn,
        onChanged: (bool v) => _runRoot(() => state.setRootAlwaysOn(v)),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _rootBusy
              ? null
              : () => _runRoot(
                    state.clearDnsCache,
                    success: 'DNS-кэш очищен',
                  ),
          icon: const Icon(Icons.cleaning_services_rounded, size: 18),
          label: const Text('Очистить DNS-кэш'),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final systemUi = SystemUiInfo.of(context, nativeMode: state.navMode);
    return AnimatedBuilder(
      animation: state,
      builder: (BuildContext context, _) {
        final s = state.settings;
        final colors = context.colors;
        final palette = context.palette;
        if (_customDns.text != s.customDns && !_dnsFocus.hasFocus) {
          _customDns.text = s.customDns;
        }
        final protocolIndex = switch (s.dnsProtocol) {
          'dot' => 1,
          'udp' => 2,
          _ => 0,
        };
        final splitIndex = switch (s.splitMode) {
          'whitelist' => 1,
          'blacklist' => 2,
          _ => 0,
        };
        final modeIndex = s.mode == 'proxy' ? 1 : 0;
        // Only in debug builds; release keeps root rows hidden without su.
        final devRootPreview = kDebugMode && !state.rootAvailable;

        return ListView(
          padding: systemUi.scrollPadding(top: 4),
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          children: <Widget>[
            const ScreenTitle('Настройки',
                subtitle: 'Маршрутизация, DNS, защита и производительность'),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.tune_rounded, size: 19, color: colors.primary),
                      const SizedBox(width: 8),
                      Text('Режим работы', style: context.texts.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SegmentedTabs(
                    labels: const <String>['Полная работа', 'Только прокси'],
                    index: modeIndex,
                    onChanged: (int index) {
                      state.setMode(index == 1 ? 'proxy' : 'full');
                    },
                  ),
                  const SizedBox(height: 10),
                  Text(s.modeDescription, style: context.texts.bodySmall),
                ],
              ),
            ),
            const SectionHeader('Обход блокировок РФ'),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TileSwitch(
                    title: 'Обход блокировок РФ',
                    subtitle: s.bypassRu
                        ? 'Все зарубежные сайты идут через прокси во всех приложениях, российские — напрямую'
                        : 'Выключен — маршрутизация только по режиму работы',
                    icon: Icons.flag_rounded,
                    value: s.bypassRu,
                    onChanged: (bool v) => state.updateSettings(
                      (s) => s.bypassRu = v,
                      restart: state.isOn,
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 240),
                    alignment: Alignment.topCenter,
                    child: s.bypassRu
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              TileSwitch(
                                title: 'Весь интернет через прокси',
                                subtitle: 'Не только список сервисов: весь трафик уходит в туннель',
                                icon: Icons.public_rounded,
                                value: s.bypassAll,
                                onChanged: (bool v) => state.updateSettings(
                                  (s) => s.bypassAll = v,
                                  restart: state.isOn,
                                ),
                              ),
                              TileNav(
                                title: 'Свои домены',
                                subtitle: s.bypassDomains.isEmpty
                                    ? 'Не заданы — используется встроенный список'
                                    : '${s.bypassDomains.length} домен(ов) в списке',
                                leading: Icon(Icons.list_alt_rounded,
                                    size: 20, color: colors.onSurfaceVariant),
                                onTap: () async {
                                  final controller = TextEditingController(
                                    text: s.bypassDomains.join('\n'),
                                  );
                                  _finishTaps();
                                  final value = await showDialog<String>(
                                    context: context,
                                    builder: (BuildContext ctx) => AlertDialog(
                                      title: const Text('Свои домены'),
                                      content: TextField(
                                        controller: controller,
                                        autofocus: true,
                                        minLines: 4,
                                        maxLines: 10,
                                        keyboardType: TextInputType.multiline,
                                        decoration: const InputDecoration(
                                          hintText: 'example.com\n*.example.org',
                                          helperText:
                                              'По одному домену в строке. Они всегда пойдут через прокси.',
                                        ),
                                      ),
                                      actions: <Widget>[
                                        TextButton(
                                          onPressed: () => Navigator.of(ctx).pop(),
                                          child: const Text('Отмена'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.of(ctx).pop(controller.text),
                                          child: const Text('Сохранить'),
                                        ),
                                      ],
                                    ),
                                  );
                                  controller.dispose();
                                  if (value == null) return;
                                  final domains = value
                                      .split(RegExp(r'[\s,;]+'))
                                      .map((String e) => e.trim().toLowerCase())
                                      .where((String e) => e.isNotEmpty)
                                      .toSet()
                                      .toList()
                                    ..sort();
                                  state.updateSettings(
                                    (s) => s.bypassDomains = domains,
                                    restart: state.isOn,
                                  );
                                },
                              ),
                            ],
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Список действует для всех приложений: трафик перехватывается VPN-туннелем. '
                      'Работает и в режиме «Только прокси» — там через прокси идёт вообще всё.',
                      style: context.texts.bodySmall?.copyWith(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
            const SectionHeader('Маршрутизация'),
            AppCard(
              child: Column(
                children: <Widget>[
                  TileSwitch(
                    title: 'Локальная сеть напрямую',
                    subtitle: '192.168.x.x, 10.x.x.x, .local',
                    icon: Icons.lan_rounded,
                    value: s.lanBypass,
                    onChanged: (bool v) =>
                        state.updateSettings((s) => s.lanBypass = v, restart: state.isOn),
                  ),
                  TileSwitch(
                    title: 'Блокировать незашифрованные прокси',
                    subtitle: 'Разрешать только TLS / AEAD узлы',
                    icon: Icons.lock_rounded,
                    value: s.blockUnencrypted,
                    onChanged: (bool v) => state.updateSettings(
                      (s) => s.blockUnencrypted = v,
                      restart: state.isOn,
                    ),
                  ),
                  TileSwitch(
                    title: 'Автоматический failover',
                    subtitle: 'Переключаться на живой сервер при сбое',
                    icon: Icons.swap_horiz_rounded,
                    value: s.autoFailover,
                    onChanged: (bool v) => state.updateSettings(
                      (s) => s.autoFailover = v,
                      restart: state.isOn,
                    ),
                  ),
                  TileNav(
                    title: 'Авторотация серверов',
                    subtitle: s.rotationSecs == 0
                        ? 'Выключена'
                        : 'Каждые ${s.rotationSecs < 60 ? '${s.rotationSecs} сек' : '${s.rotationSecs ~/ 60} мин'}',
                    leading: Icon(Icons.autorenew_rounded,
                        size: 20, color: colors.onSurfaceVariant),
                    onTap: () async {
                      final options = <int>[0, 30, 60, 300, 600, 1800];
                      _finishTaps();
                      final value = await showModalBottomSheet<int>(
                        context: context,
                        builder: (BuildContext ctx) => SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text('Авторотация', style: ctx.texts.titleLarge),
                                ),
                              ),
                              for (final option in options)
                                ListTile(
                                  title: Text(option == 0
                                      ? 'Выключена'
                                      : option < 60
                                          ? '$option секунд'
                                          : '${option ~/ 60} минут'),
                                  trailing: s.rotationSecs == option
                                      ? Icon(Icons.check_rounded, color: ctx.colors.primary)
                                      : null,
                                  onTap: () => Navigator.of(ctx).pop(option),
                                ),
                              const SizedBox(height: 12),
                            ],
                          ),
                        ),
                      );
                      if (value == null) return;
                      state.updateSettings(
                        (s) => s.rotationSecs = value,
                        restart: state.isOn,
                      );
                    },
                  ),
                ],
              ),
            ),
            const SectionHeader('DNS и фильтрация'),
            AppCard(
              child: Column(
                children: <Widget>[
                  SegmentedTabs(
                    labels: const <String>['DoH', 'DoT', 'UDP'],
                    index: protocolIndex,
                    compact: true,
                    onChanged: (int index) {
                      final proto = switch (index) { 1 => 'dot', 2 => 'udp', _ => 'doh' };
                      state.updateSettings(
                        (s) => s.dnsProtocol = proto,
                        restart: state.isOn,
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  TileSelect(
                    label: 'DNS-сервер',
                    value: s.dnsServer,
                    icon: Icons.dns_rounded,
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem<String>(
                          value: 'cloudflare', child: Text('Cloudflare 1.1.1.1')),
                      DropdownMenuItem<String>(
                          value: 'google', child: Text('Google 8.8.8.8')),
                      DropdownMenuItem<String>(
                          value: 'adguard', child: Text('AdGuard 94.140.14.14')),
                      DropdownMenuItem<String>(
                          value: 'quad9', child: Text('Quad9 9.9.9.9')),
                      DropdownMenuItem<String>(
                          value: 'custom', child: Text('Свой сервер')),
                    ],
                    onChanged: (String? value) {
                      if (value == null) return;
                      state.updateSettings((s) => s.dnsServer = value, restart: state.isOn);
                    },
                  ),
                  if (s.dnsServer == 'custom')
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: TextField(
                        controller: _customDns,
                        focusNode: _dnsFocus,
                        decoration: const InputDecoration(
                          labelText: 'Адрес DNS',
                          hintText: 'https://dns.example.com/dns-query',
                          prefixIcon: Icon(Icons.public_rounded),
                        ),
                        onSubmitted: (String value) {
                          state.updateSettings(
                            (s) => s.customDns = value.trim(),
                            restart: state.isOn,
                          );
                        },
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: OutlinedButton.icon(
                      onPressed: _dnsChecking ? null : _testDns,
                      icon: _dnsChecking
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.network_check_rounded, size: 18),
                      label: Text(_dnsChecking ? 'Проверяем DNS…' : 'Проверить DNS'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(42),
                      ),
                    ),
                  ),
                  if (_dnsResult != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Icon(Icons.dns_rounded,
                              size: 15, color: colors.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _dnsResult!,
                              style: context.texts.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  TileSwitch(
                    title: 'Защита от утечек DNS',
                    subtitle: 'Запросы не уходят мимо туннеля',
                    icon: Icons.security_rounded,
                    value: s.dnsLeak,
                    onChanged: (bool v) => state.updateSettings(
                      (s) => s.dnsLeak = v,
                      restart: state.isOn,
                    ),
                  ),
                  TileSwitch(
                    title: 'Блокировка рекламы и трекеров',
                    subtitle: '76 827 доменов в офлайн-базе',
                    icon: Icons.block_rounded,
                    value: s.adblock,
                    onChanged: (bool v) => state.updateSettings(
                      (s) => s.adblock = v,
                      restart: state.isOn,
                    ),
                  ),
                  TileSwitch(
                    title: 'Блокировать QUIC / UDP 443',
                    subtitle: 'Заставляет YouTube идти по TCP',
                    icon: Icons.speed_rounded,
                    value: s.blockQuic,
                    onChanged: (bool v) => state.updateSettings(
                      (s) => s.blockQuic = v,
                      restart: state.isOn,
                    ),
                  ),
                ],
              ),
            ),
            const SectionHeader('Соединение'),
            AppCard(
              child: Column(
                children: <Widget>[
                  SegmentedTabs(
                    labels: const <String>['VPN (TUN)', 'Локальный прокси'],
                    index: s.androidMode == 'vpn' ? 0 : 1,
                    compact: true,
                    onChanged: (int index) {
                      final mode = index == 0 ? 'vpn' : 'local';
                      state.updateSettings((s) => s.androidMode = mode);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    s.androidMode == 'vpn'
                        ? 'Весь телефон идёт через TUN. Требуется системное разрешение VPN.'
                        : 'Ядро слушает 127.0.0.1:${s.listenPort}. Укажите этот адрес в приложениях вручную.',
                    style: context.texts.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  TileSwitch(
                    title: 'Kill Switch',
                    subtitle: 'Блокировать трафик при обрыве туннеля',
                    icon: Icons.shield_rounded,
                    value: s.killSwitch,
                    onChanged: (bool v) => state.updateSettings(
                      (s) => s.killSwitch = v,
                      restart: state.isOn,
                    ),
                  ),
                  TileSwitch(
                    title: 'Отключить IPv6',
                    subtitle: 'Предотвращает утечки через IPv6',
                    icon: Icons.lan_outlined,
                    value: s.disableIpv6,
                    onChanged: (bool v) => state.updateSettings(
                      (s) => s.disableIpv6 = v,
                      restart: state.isOn,
                    ),
                  ),
                  TileSwitch(
                    title: 'UDP-over-TCP',
                    subtitle: 'DNS и UDP через TCP-туннель',
                    icon: Icons.swap_vert_rounded,
                    value: s.udpTcp,
                    onChanged: (bool v) => state.updateSettings(
                      (s) => s.udpTcp = v,
                      restart: state.isOn,
                    ),
                  ),
                  TileSlider(
                    label: 'MTU',
                    value: s.mtu.toDouble(),
                    min: 576,
                    max: 1500,
                    divisions: 36,
                    display: '${s.mtu}',
                    onChanged: (double v) =>
                        state.updateSettings((s) => s.mtu = v.round(), restart: false),
                    onChangeEnd: (_) => state.scheduleRestart(),
                  ),
                  TileNav(
                    title: 'Порт локального прокси',
                    subtitle: '127.0.0.1:${s.listenPort}',
                    leading: Icon(Icons.settings_ethernet_rounded,
                        size: 20, color: colors.onSurfaceVariant),
                    onTap: () => _editNumber(
                      title: 'Порт прокси',
                      helper: 'Слушается только на localhost',
                      initial: s.listenPort,
                      min: 1024,
                      max: 65535,
                      onDone: (int value) => state.updateSettings(
                        (s) => s.listenPort = value,
                        restart: state.isOn,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SectionHeader('Обход DPI'),
            AppCard(
              child: Column(
                children: <Widget>[
                  TileSwitch(
                    title: 'DPI-обход',
                    subtitle: 'Фрагментация TLS ClientHello обходит SNI-фильтры',
                    icon: Icons.graphic_eq_rounded,
                    value: s.dpiBypass,
                    onChanged: (bool v) => state.updateSettings(
                      (s) => s.dpiBypass = v,
                      restart: state.isOn,
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 240),
                    alignment: Alignment.topCenter,
                    child: s.dpiBypass
                        ? TileSlider(
                            label: 'Размер фрагмента',
                            value: s.fragSize.toDouble(),
                            min: 10,
                            max: 120,
                            divisions: 22,
                            display: '${s.fragSize} Б',
                            onChanged: (double v) => state.updateSettings(
                              (s) => s.fragSize = v.round(),
                              restart: false,
                            ),
                            onChangeEnd: (_) => state.scheduleRestart(),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                ],
              ),
            ),
            const SectionHeader('Раздельное туннелирование'),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SegmentedTabs(
                    labels: const <String>['Выкл', 'Белый список', 'Чёрный список'],
                    index: splitIndex,
                    compact: true,
                    onChanged: (int index) {
                      final mode = switch (index) {
                        1 => 'whitelist',
                        2 => 'blacklist',
                        _ => 'off',
                      };
                      state.updateSettings((s) => s.splitMode = mode);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    switch (s.splitMode) {
                      'whitelist' =>
                        'Через VPN идут только выбранные приложения (${s.selectedApps.length}).',
                      'blacklist' =>
                        'Выбранные приложения (${s.selectedApps.length}) работают напрямую.',
                      _ => 'Весь трафик устройства проходит через тоннель.',
                    },
                    style: context.texts.bodySmall,
                  ),
                  if (s.splitMode != 'off') ...<Widget>[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final result = await showAppPickerSheet(
                          context,
                          s.selectedApps.toSet(),
                        );
                        if (result == null) return;
                        state.updateSettings(
                          (s) => s.selectedApps = result.toList()..sort(),
                          restart: state.isOn,
                        );
                      },
                      icon: const Icon(Icons.apps_rounded, size: 18),
                      label: Text('Выбрать приложения (${s.selectedApps.length})'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(44),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SectionHeader('Сканер'),
            AppCard(
              child: Column(
                children: <Widget>[
                  TileSlider(
                    label: 'Параллельных проверок',
                    value: s.workers.toDouble(),
                    min: 20,
                    max: 400,
                    divisions: 19,
                    display: '${s.workers}',
                    onChanged: (double v) => state.updateSettings(
                      (s) => s.workers = (v / 20).round() * 20,
                    ),
                  ),
                  TileSlider(
                    label: 'Таймаут проверки',
                    value: s.timeoutMs.toDouble(),
                    min: 500,
                    max: 8000,
                    divisions: 15,
                    display: '${(s.timeoutMs / 1000).toStringAsFixed(1)} с',
                    onChanged: (double v) => state.updateSettings(
                      (s) => s.timeoutMs = (v / 500).round() * 500,
                    ),
                  ),
                  TileSwitch(
                    title: 'Проверять скорость',
                    subtitle: 'Загрузка тестового файла через узел',
                    icon: Icons.speed_rounded,
                    value: s.speedCheck,
                    onChanged: (bool v) => state.updateSettings((s) => s.speedCheck = v),
                  ),
                  TileSwitch(
                    title: 'Проверять доступ к сервисам',
                    subtitle: 'YouTube, Discord, AI-сервисы',
                    icon: Icons.play_circle_outline_rounded,
                    value: s.serviceCheck,
                    onChanged: (bool v) => state.updateSettings((s) => s.serviceCheck = v),
                  ),
                  TileSwitch(
                    title: 'Определять анонимность',
                    subtitle: 'Elite / Anonymous / Transparent',
                    icon: Icons.visibility_off_rounded,
                    value: s.anonymityCheck,
                    onChanged: (bool v) =>
                        state.updateSettings((s) => s.anonymityCheck = v),
                  ),
                  TileNav(
                    title: 'URL проверки',
                    subtitle: s.checkUrl,
                    leading: Icon(Icons.link_rounded, size: 20, color: colors.onSurfaceVariant),
                    onTap: () async {
                      _finishTaps();
                      final controller = TextEditingController(text: s.checkUrl);
                      final value = await showDialog<String>(
                        context: context,
                        builder: (BuildContext ctx) => AlertDialog(
                          title: const Text('URL проверки'),
                          content: TextField(
                            controller: controller,
                            autofocus: true,
                            keyboardType: TextInputType.url,
                            decoration: const InputDecoration(
                              hintText: 'https://cp.cloudflare.com/generate_204',
                            ),
                          ),
                          actions: <Widget>[
                            TextButton(
                              onPressed: () => Navigator.of(ctx).pop(),
                              child: const Text('Отмена'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.of(ctx).pop(controller.text.trim()),
                              child: const Text('Сохранить'),
                            ),
                          ],
                        ),
                      );
                      controller.dispose();
                      if (value == null || value.isEmpty) return;
                      state.updateSettings((s) => s.checkUrl = value);
                    },
                  ),
                ],
              ),
            ),
            const SectionHeader('Разрешения'),
            AppCard(
              child: Column(
                children: <Widget>[
                  _PermissionTile(
                    icon: Icons.notifications_active_outlined,
                    title: 'Уведомления',
                    subtitle: 'Статус VPN в шторке и события ядра',
                    granted: state.permissions['notifications'] == true,
                    busy: _permissionBusy,
                    onTap: () => _requestPermission('notifications'),
                  ),
                  _PermissionTile(
                    icon: Icons.qr_code_scanner_rounded,
                    title: 'Камера',
                    subtitle: 'Сканирование QR-кодов серверов',
                    granted: state.permissions['camera'] == true,
                    busy: _permissionBusy,
                    onTap: () => _requestPermission('camera'),
                  ),
                  _PermissionTile(
                    icon: Icons.battery_saver_rounded,
                    title: 'Работа в фоне',
                    subtitle: 'Не выключать VPN при оптимизации батареи',
                    granted: state.permissions['battery'] == true,
                    busy: _permissionBusy,
                    onTap: () => _requestPermission('battery'),
                  ),
                  _PermissionTile(
                    icon: Icons.vpn_key_rounded,
                    title: 'VPN-туннель',
                    subtitle: 'Системное разрешение на перехват трафика',
                    granted: state.permissions['vpn'] == true,
                    busy: _permissionBusy,
                    onTap: () => _requestPermission('vpn'),
                  ),
                ],
              ),
            ),
            const SectionHeader('Root-доступ'),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // Debug builds on emulators have no su at all: identical
                  // switches are appended by the builder below, so only the
                  // "ask for root" button is conditional here.
                  if (state.rootAvailable && _rootBusy)
                    const Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.admin_panel_settings_rounded,
                        size: 20,
                        color: state.rootAvailable ? colors.primary : colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text('Расширенные функции',
                                style: context.texts.titleMedium?.copyWith(fontSize: 14.5)),
                            Text(
                              state.rootLabel,
                              style: context.texts.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      BadgePill(
                        label: state.rootAvailable
                            ? (state.rootGranted ? 'АКТИВЕН' : 'НАЙДЕН')
                            : 'НЕТ',
                        dense: true,
                        color: state.rootAvailable ? palette.success : colors.onSurfaceVariant,
                        background: state.rootAvailable
                            ? palette.successContainer.withValues(alpha: 0.5)
                            : colors.surfaceContainerHigh,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    state.rootAvailable
                        ? 'Доступ через su. Команды выполняются только по вашему нажатию и не работают без root.'
                        : 'su не обнаружен. Установите Magisk или KernelSU — раздел станет активным автоматически.',
                    style: context.texts.bodySmall,
                  ),
                  if (devRootPreview)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Режим разработки: su не найден. Переключатели показаны для проверки интерфейса и не меняют систему.',
                        style: context.texts.bodySmall?.copyWith(color: palette.warning),
                      ),
                    ),
                  ..._rootSwitches(),
                ],
              ),
            ),
            const SectionHeader('Внешний вид'),
            AppCard(
              child: Column(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.palette_outlined,
                            size: 20, color: colors.onSurfaceVariant),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text('Тема оформления',
                              style: context.texts.titleMedium?.copyWith(fontSize: 14.5)),
                        ),
                        const SizedBox(width: 10),
                        SegmentedTabs(
                          labels: const <String>['Тёмная', 'Светлая'],
                          index: s.themeMode == 'light' ? 1 : 0,
                          compact: true,
                          onChanged: (int index) {
                            state.updateSettings(
                              (s) => s.themeMode = index == 1 ? 'light' : 'dark',
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SectionHeader('Экспериментально'),
            AppCard(
              child: Column(
                children: <Widget>[
                  TileSwitch(
                    title: 'Автозапуск при загрузке',
                    subtitle: 'Временная функция: восстанавливает последнюю сессию',
                    icon: Icons.restart_alt_rounded,
                    value: s.autostart,
                    onChanged: (bool v) async {
                      state.updateSettings((s) => s.autostart = v);
                      await PlatformBridge.setAutostart(v);
                    },
                  ),
                  TileSwitch(
                    title: 'Умные профили сети',
                    subtitle: 'Wi-Fi → Полная работа, мобильная сеть → Только прокси',
                    icon: Icons.wifi_rounded,
                    value: s.smartProfiles,
                    onChanged: (bool v) =>
                        state.updateSettings((s) => s.smartProfiles = v),
                  ),
                  TileNav(
                    title: 'Системные настройки VPN',
                    subtitle: 'Always-on VPN и исключения',
                    leading: Icon(Icons.vpn_key_outlined,
                        size: 20, color: colors.onSurfaceVariant),
                    onTap: () => PlatformBridge.openVpnSettings(),
                  ),
                  TileNav(
                    title: 'Разрешения приложения',
                    subtitle: 'Батарея, уведомления, камера',
                    leading: Icon(Icons.settings_rounded,
                        size: 20, color: colors.onSurfaceVariant),
                    onTap: () => PlatformBridge.openAppSettings(),
                  ),
                ],
              ),
            ),
            const SectionHeader('О приложении'),
            AppCard(
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: colors.primaryContainer,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Icon(Icons.shield_rounded,
                            size: 28, color: colors.onPrimaryContainer),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text('RustedProxy',
                                style: context.texts.titleMedium?.copyWith(fontSize: 16)),
                            Text(
                              'Версия ${_info['version'] ?? '1.0.0'} · Rust ${_build['version'] ?? '—'}',
                              style: context.texts.bodySmall,
                            ),
                            Text(
                              _infoLoaded
                                  ? '${_info['device'] ?? ''} · ${_info['abi'] ?? ''}'
                                  : 'Загрузка сведений…',
                              style: context.texts.bodySmall?.copyWith(fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Поделиться',
                        onPressed: () => PlatformBridge.shareText(
                          'RustedProxy — быстрый прокси-клиент на Rust. Версия ${_info['version'] ?? '1.0.0'}',
                        ),
                        icon: const Icon(Icons.share_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _infoRow(context, 'Ядро', '${_build['engine'] ?? 'tokio'} · Rust'),
                        _infoRow(context, 'GeoIP', '${_build['geo'] ?? 'DB-IP Lite'}'),
                        _infoRow(
                          context,
                          'Протоколы',
                          'SOCKS4/5 · HTTP(S) · SS · Trojan · VLESS',
                        ),
                        _infoRow(
                          context,
                          'Сборка',
                          '${_build['built'] ?? 'release'} · ${_build['target'] ?? 'android'}',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final ok = await confirmDialog(
                              context,
                              title: 'Сбросить всё?',
                              message:
                                  'Будут удалены сохранённые серверы и настройки. Приложение вернётся к первичной настройке.',
                              confirm: 'Сбросить',
                              destructive: true,
                            );
                            if (!ok) return;
                            await state.disconnect();
                            state.resetAll();
                            if (!context.mounted) return;
                            showSnack(context, 'Настройки сброшены');
                          },
                          icon: const Icon(Icons.restart_alt_rounded, size: 18),
                          label: const Text('Сброс'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: context.colors.error,
                            side: BorderSide(
                              color: context.colors.error.withValues(alpha: 0.5),
                            ),
                            minimumSize: const Size.fromHeight(44),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            state.updateSettings((s) {
                              s.onboardingDone = false;
                            });
                          },
                          icon: const Icon(Icons.school_outlined, size: 18),
                          label: const Text('Обучение'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(44),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Ядро: Rust + tokio + rustls + tun2proxy. Сканер, DNS и GeoIP работают локально на устройстве.',
                    style: context.texts.bodySmall?.copyWith(fontSize: 11),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 84,
            child: Text(label, style: context.texts.bodySmall),
          ),
          Expanded(
            child: Text(
              value,
              style: context.texts.bodySmall?.copyWith(
                color: colors.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.granted,
    required this.busy,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool granted;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final palette = context.palette;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: busy ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 20, color: colors.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title,
                      style: context.texts.titleMedium?.copyWith(fontSize: 14.5)),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle, style: context.texts.bodySmall),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (granted)
              Icon(Icons.check_circle_rounded, size: 20, color: palette.success)
            else
              OutlinedButton(
                onPressed: busy ? null : onTap,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Text('Разрешить'),
              ),
          ],
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'core/app_state.dart';
import 'core/platform.dart';
import 'models/proxy.dart';
import 'theme.dart';
import 'widgets/proxy_card.dart';
import 'widgets/ui.dart';

Future<T?> _sheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isScrollControlled = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: true,
    builder: (BuildContext ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: builder(ctx),
    ),
  );
}

/// Bottom sheet for picking the active server.
Future<void> showServerPicker(BuildContext context) async {
  final state = AppState.instance;
  await _sheet<void>(
    context,
    builder: (BuildContext ctx) {
      return AnimatedBuilder(
        animation: state,
        builder: (BuildContext ctx, _) {
          final servers = state.saved;
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.72,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text('Выбор сервера', style: ctx.texts.titleLarge),
                      ),
                      Text(
                        '${servers.length}',
                        style: ctx.texts.titleMedium?.copyWith(
                          color: ctx.colors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (servers.isEmpty)
                  const EmptyState(
                    icon: Icons.dns_outlined,
                    title: 'Нет сохранённых серверов',
                    subtitle: 'Найдите прокси во вкладке «Поиск» или добавьте вручную.',
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                      itemCount: servers.length,
                      itemBuilder: (BuildContext ctx, int index) {
                        final server = servers[index];
                        final active = state.active?.key == server.key;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Material(
                            color: active
                                ? ctx.colors.primaryContainer.withValues(alpha: 0.35)
                                : ctx.colors.surfaceContainer,
                            borderRadius: BorderRadius.circular(18),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(18),
                              onTap: () async {
                                Navigator.of(ctx).pop();
                                state.setActive(server);
                                if (!state.isOn) {
                                  try {
                                    await state.connect(proxy: server);
                                  } catch (_) {}
                                }
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                child: Row(
                                  children: <Widget>[
                                    Text(server.flag,
                                        style: const TextStyle(fontSize: 22)),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: <Widget>[
                                          Text(
                                            server.displayName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: ctx.texts.titleMedium
                                                ?.copyWith(fontSize: 14),
                                          ),
                                          const SizedBox(height: 2),
                                          MonoText(
                                            '${server.endpoint} · ${server.protoLabel}',
                                            size: 11,
                                            color: ctx.colors.onSurfaceVariant,
                                            weight: FontWeight.w400,
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (server.latency > 0)
                                      BadgePill(
                                        label: server.latencyLabel,
                                        dense: true,
                                        color: latencyColor(ctx, server.latency),
                                      ),
                                    const SizedBox(width: 6),
                                    if (active)
                                      Icon(Icons.check_circle_rounded,
                                          size: 20,
                                          color: ctx.colors.primary)
                                    else
                                      Icon(Icons.chevron_right_rounded,
                                          size: 20,
                                          color: ctx.colors.onSurfaceVariant),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      );
    },
  );
}

/// Manual proxy editor.
Future<void> showManualProxySheet(
  BuildContext context, {
  ProxyServer? initial,
}) async {
  final state = AppState.instance;
  await _sheet<void>(
    context,
    builder: (BuildContext ctx) => _ManualProxyForm(initial: initial),
  );
  if (state.lastError != null) state.lastError = null;
}

class _ManualProxyForm extends StatefulWidget {
  const _ManualProxyForm({this.initial});

  final ProxyServer? initial;

  @override
  State<_ManualProxyForm> createState() => _ManualProxyFormState();
}

class _ManualProxyFormState extends State<_ManualProxyForm> {
  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _pass;
  late final TextEditingController _cipher;
  late final TextEditingController _uuid;
  late final TextEditingController _sni;
  late String _proto;
  late bool _tls;

  static const List<String> _protos = <String>[
    'socks5',
    'socks4',
    'http',
    'https',
    'ss',
    'trojan',
    'vless',
  ];

  @override
  void initState() {
    super.initState();
    final p = widget.initial;
    _name = TextEditingController(text: p?.name ?? '');
    _host = TextEditingController(text: p?.host ?? '');
    _port = TextEditingController(
      text: p != null && p.port > 0 ? '${p.port}' : '1080',
    );
    _user = TextEditingController(text: p?.username ?? '');
    _pass = TextEditingController(text: p?.password ?? '');
    _cipher = TextEditingController(text: p?.cipher ?? 'aes-256-gcm');
    _uuid = TextEditingController(text: p?.uuid ?? '');
    _sni = TextEditingController(text: p?.sni ?? '');
    _proto = p?.proto ?? 'socks5';
    _tls = p?.tls ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _pass.dispose();
    _cipher.dispose();
    _uuid.dispose();
    _sni.dispose();
    super.dispose();
  }

  bool get _needsAuth => _proto == 'socks5' || _proto == 'http' || _proto == 'https';
  bool get _needsUuid => _proto == 'trojan' || _proto == 'vless';
  bool get _usesTls => _proto == 'https' || _proto == 'trojan' || _proto == 'vless';

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final now = DateTime.now().microsecondsSinceEpoch;
    final proxy = ProxyServer(
      id: widget.initial?.id ?? 'manual-$now',
      proto: _proto,
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 0,
      username: _needsAuth ? _user.text.trim() : '',
      password: _needsAuth ? _pass.text : '',
      cipher: _proto == 'ss' ? _cipher.text.trim() : '',
      uuid: _needsUuid ? _uuid.text.trim() : '',
      sni: _sni.text.trim(),
      tls: _usesTls || _tls,
      name: _name.text.trim(),
      source: 'manual',
    );
    await AppState.instance.saveProxy(proxy, makeActive: true);
    if (!mounted) return;
    Navigator.of(context).pop();
    showSnack(context, 'Сервер добавлен');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + bottom),
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        widget.initial == null ? 'Новый сервер' : 'Изменить сервер',
                        style: context.texts.titleLarge,
                      ),
                      Text(
                        'Все поля проверяются ядром при подключении',
                        style: context.texts.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text('Протокол', style: context.texts.labelMedium),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _protos.map((String proto) {
                final selected = proto == _proto;
                return ChoiceChip(
                  label: Text(
                    switch (proto) {
                      'ss' => 'Shadowsocks',
                      _ => proto.toUpperCase(),
                    },
                  ),
                  selected: selected,
                  onSelected: (_) => setState(() {
                    _proto = proto;
                    if (_proto == 'https' || _proto == 'trojan') _tls = true;
                    if (_proto == 'socks5' || _proto == 'socks4' || _proto == 'http') {
                      _tls = false;
                    }
                  }),
                  showCheckmark: false,
                  selectedColor: colors.secondaryContainer,
                  backgroundColor: colors.surfaceContainer,
                  labelStyle: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? colors.onSecondaryContainer
                        : colors.onSurfaceVariant,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _name,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Название (необязательно)',
                prefixIcon: Icon(Icons.label_outline_rounded),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _host,
                    textInputAction: TextInputAction.next,
                    autofillHints: const <String>[],
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Хост или IP',
                      prefixIcon: Icon(Icons.dns_outlined),
                    ),
                    validator: (String? value) {
                      final v = (value ?? '').trim();
                      if (v.isEmpty) return 'Укажите хост';
                      if (v.contains(' ')) return 'Без пробелов';
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(5),
                    ],
                    decoration: const InputDecoration(labelText: 'Порт'),
                    validator: (String? value) {
                      final port = int.tryParse((value ?? '').trim()) ?? 0;
                      if (port < 1 || port > 65535) return '1–65535';
                      return null;
                    },
                  ),
                ),
              ],
            ),
            if (_needsAuth) ...<Widget>[
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextFormField(
                      controller: _user,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Логин',
                        prefixIcon: Icon(Icons.person_outline_rounded),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: _pass,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Пароль',
                        prefixIcon: Icon(Icons.key_rounded),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (_proto == 'ss') ...<Widget>[
              const SizedBox(height: 10),
              TextFormField(
                controller: _cipher,
                decoration: const InputDecoration(
                  labelText: 'Шифр AEAD',
                  prefixIcon: Icon(Icons.enhanced_encryption_rounded),
                ),
                validator: (String? value) {
                  final v = (value ?? '').trim();
                  if (v.isEmpty) return 'Укажите шифр';
                  return null;
                },
              ),
            ],
            if (_needsUuid) ...<Widget>[
              const SizedBox(height: 10),
              TextFormField(
                controller: _uuid,
                decoration: InputDecoration(
                  labelText: _proto == 'trojan' ? 'Пароль Trojan' : 'UUID',
                  prefixIcon: const Icon(Icons.badge_outlined),
                ),
                validator: (String? value) {
                  if ((value ?? '').trim().isEmpty) return 'Обязательное поле';
                  return null;
                },
              ),
            ],
            if (_proto == 'vless' || _proto == 'trojan') ...<Widget>[
              const SizedBox(height: 10),
              TextFormField(
                controller: _sni,
                decoration: const InputDecoration(
                  labelText: 'SNI / домен (для TLS)',
                  prefixIcon: Icon(Icons.public_rounded),
                ),
              ),
            ],
            if (_usesTls && _proto != 'https')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: TileSwitch(
                  title: 'TLS',
                  subtitle: 'Проверка сертификата с SNI',
                  value: _tls,
                  onChanged: (bool v) => setState(() => _tls = v),
                ),
              ),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Отмена'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save_rounded, size: 18),
                    label: const Text('Сохранить'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Subscription importer.
Future<void> showSubscriptionSheet(BuildContext context) async {
  await _sheet<void>(
    context,
    builder: (BuildContext ctx) => const _SubscriptionForm(),
  );
}

class _SubscriptionForm extends StatefulWidget {
  const _SubscriptionForm();

  @override
  State<_SubscriptionForm> createState() => _SubscriptionFormState();
}

class _SubscriptionFormState extends State<_SubscriptionForm> {
  final TextEditingController _url = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    final raw = _url.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = 'Вставьте ссылку на подписку');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final count = await AppState.instance.fetchSubscription(raw);
      if (!mounted) return;
      Navigator.of(context).pop();
      showSnack(context, 'Импортировано серверов: $count');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('Подписка', style: context.texts.titleLarge),
          const SizedBox(height: 2),
          Text(
            'Ссылка на список VLESS / Trojan / Shadowsocks / SOCKS или base64-подписку. Ядро скачает её и разберёт все записи.',
            style: context.texts.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enabled: !_busy,
            decoration: const InputDecoration(
              hintText: 'https://example.com/sub.txt',
              prefixIcon: Icon(Icons.link_rounded),
            ),
            onSubmitted: (_) => _import(),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: context.texts.bodySmall?.copyWith(color: context.colors.error),
            ),
          ],
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _busy ? null : _import,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_rounded, size: 19),
            label: Text(_busy ? 'Загружаем…' : 'Импортировать'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          ),
        ],
      ),
    );
  }
}

/// Shareable QR code for a server link.
Future<void> showQrSheet(BuildContext context, ProxyServer server) async {
  final link = await AppState.instance.buildLink(server);
  if (!context.mounted) return;
  if (link == null) {
    showSnack(context, 'Не удалось собрать ссылку для этого сервера', error: true);
    return;
  }
  await _sheet<void>(
    context,
    builder: (BuildContext ctx) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('QR-код', style: ctx.texts.titleLarge),
                      Text(
                        server.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ctx.texts.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: QrImageView(
                data: link,
                version: QrVersions.auto,
                size: 236,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Color(0xFF101318),
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Color(0xFF101318),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: ctx.colors.surfaceContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: MonoText(
                link,
                size: 10.5,
                color: ctx.colors.onSurfaceVariant,
                weight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: link));
                      if (!ctx.mounted) return;
                      showSnack(ctx, 'Ссылка скопирована');
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('Копировать'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      await PlatformBridge.shareText(link);
                    },
                    icon: const Icon(Icons.share_rounded, size: 18),
                    label: const Text('Поделиться'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

/// Camera QR scanner that feeds the clipboard importer.
Future<void> showQrScanSheet(BuildContext context) async {
  final state = AppState.instance;
  if (state.permissions['camera'] != true) {
    await state.requestPermission('camera');
  }
  if (state.permissions['camera'] != true) {
    if (!context.mounted) return;
    showSnack(
      context,
      'Разрешите доступ к камере, чтобы сканировать QR-код',
      error: true,
    );
    await PlatformBridge.openAppSettings();
    return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.black,
    builder: (BuildContext ctx) => const _QrScannerSheet(),
  );
}

class _QrScannerSheet extends StatefulWidget {
  const _QrScannerSheet();

  @override
  State<_QrScannerSheet> createState() => _QrScannerSheetState();
}

class _QrScannerSheetState extends State<_QrScannerSheet> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );
  bool _handled = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) return;
    final raw = capture.barcodes
        .map((Barcode b) => b.rawValue)
        .whereType<String>()
        .firstWhere((String v) => v.trim().isNotEmpty, orElse: () => '');
    if (raw.isEmpty) return;
    _handled = true;
    try {
      final count = await AppState.instance.importText(raw);
      if (!mounted) return;
      Navigator.of(context).pop();
      showSnack(
        context,
        count == 0
            ? 'В QR-коде не найдено поддерживаемых прокси'
            : 'Импортировано серверов: $count',
        error: count == 0,
      );
    } catch (e) {
      _handled = false;
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.78;
    return SizedBox(
      height: height,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (
                BuildContext context,
                MobileScannerException error,
              ) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Icon(Icons.videocam_off_rounded,
                            size: 42, color: Colors.white70),
                        const SizedBox(height: 12),
                        Text(
                          'Нет доступа к камере\n${error.errorDetails?.message ?? ''}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Закрыть'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Colors.black.withValues(alpha: 0.55),
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.65),
                    ],
                    stops: const <double>[0, 0.22, 0.7, 1],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Row(
              children: <Widget>[
                const SizedBox(width: 4),
                const Expanded(
                  child: Text(
                    'Наведите камеру на QR-код',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black54,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 2.2),
              ),
            ),
          ),
          if (_error != null)
            Positioned(
              left: 20,
              right: 20,
              bottom: 28,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Split-tunneling application picker.
Future<Set<String>?> showAppPickerSheet(
  BuildContext context,
  Set<String> selected,
) async {
  return _sheet<Set<String>>(
    context,
    builder: (BuildContext ctx) => _AppPicker(initial: selected),
  );
}

class _AppPicker extends StatefulWidget {
  const _AppPicker({required this.initial});

  final Set<String> initial;

  @override
  State<_AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<_AppPicker> {
  late final Set<String> _selected = <String>{...widget.initial};
  final TextEditingController _search = TextEditingController();
  List<Map<String, dynamic>> _apps = const <Map<String, dynamic>>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final apps = await PlatformBridge.installedApps();
    if (!mounted) return;
    setState(() {
      _apps = apps;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final filtered = query.isEmpty
        ? _apps
        : _apps.where((Map<String, dynamic> app) {
            final label = (app['label'] ?? '').toString().toLowerCase();
            final pkg = (app['package'] ?? '').toString().toLowerCase();
            return label.contains(query) || pkg.contains(query);
          }).toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.78,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('Приложения', style: context.texts.titleLarge),
                      Text(
                        'Выбрано: ${_selected.length}',
                        style: context.texts.bodySmall,
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(_selected),
                  child: const Text('Готово'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Поиск приложения',
                prefixIcon: Icon(Icons.search_rounded),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                    ? const EmptyState(
                        icon: Icons.apps_rounded,
                        title: 'Ничего не найдено',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                        itemCount: filtered.length,
                        itemBuilder: (BuildContext ctx, int index) {
                          final app = filtered[index];
                          final pkg = (app['package'] ?? '').toString();
                          final checked = _selected.contains(pkg);
                          return CheckboxListTile(
                            value: checked,
                            onChanged: (bool? value) {
                              setState(() {
                                if (value == true) {
                                  _selected.add(pkg);
                                } else {
                                  _selected.remove(pkg);
                                }
                              });
                            },
                            dense: true,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            title: Text(
                              (app['label'] ?? pkg).toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.texts.titleMedium?.copyWith(fontSize: 14),
                            ),
                            subtitle: Text(
                              pkg,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.texts.bodySmall?.copyWith(fontSize: 10.5),
                            ),
                            secondary: app['system'] == true
                                ? Icon(Icons.settings_rounded,
                                    size: 18, color: context.colors.onSurfaceVariant)
                                : null,
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

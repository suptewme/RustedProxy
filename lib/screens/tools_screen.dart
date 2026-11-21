import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/system_ui.dart';
import '../models/log_item.dart';
import '../theme.dart';
import '../widgets/ui.dart';

class ToolsScreen extends StatefulWidget {
  const ToolsScreen({super.key});

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> {
  final ScrollController _logScroll = ScrollController();

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!_logScroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_logScroll.hasClients) return;
      _logScroll.animateTo(
        _logScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return AnimatedBuilder(
      animation: state,
      builder: (BuildContext context, _) {
        final colors = context.colors;
        final palette = context.palette;
        if (!state.logPaused) _scrollToBottom();
        final speed = state.speedResult;
        final download = (speed['download'] as num?)?.toDouble() ?? 0;
        final upload = (speed['upload'] as num?)?.toDouble() ?? 0;
        final ping = (speed['ping'] as num?)?.toInt() ?? 0;
        final bytes = (speed['bytes'] as num?)?.toInt() ?? 0;
        return ListView(
          padding: SystemUiInfo.of(context, nativeMode: state.navMode)
              .scrollPadding(top: 4),
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          children: <Widget>[
            const ScreenTitle('Инструменты',
                subtitle: 'Проверка утечек, скорость и живой лог ядра'),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.security_rounded, size: 19, color: colors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('Проверка утечек', style: context.texts.titleMedium),
                      ),
                      if (state.leakChecks.isNotEmpty)
                        BadgePill(
                          label: state.leakTesting ? 'ТЕСТ…' : 'ГОТОВО',
                          color: palette.success,
                          background: palette.successContainer.withValues(alpha: 0.5),
                          dense: true,
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Сравниваем реальный IP с видимым, проверяем DNS, UDP и Kill Switch.',
                    style: context.texts.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: state.leakTesting
                        ? null
                        : () async {
                            await state.runLeakTest();
                            if (!context.mounted) return;
                            if (state.lastError != null && state.leakChecks.isEmpty) {
                              showSnack(context, state.lastError!, error: true);
                            }
                          },
                    icon: state.leakTesting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow_rounded, size: 20),
                    label: Text(state.leakTesting
                        ? 'Проверяем…'
                        : 'Запустить тест безопасности'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  ),
                  if (state.leakChecks.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 10),
                    ...state.leakChecks.map((Map<String, dynamic> check) {
                      final status = (check['status'] ?? 'info').toString();
                      final (IconData icon, Color color) = switch (status) {
                        'ok' => (Icons.check_circle_rounded, palette.success),
                        'warn' => (Icons.warning_amber_rounded, palette.warning),
                        'err' => (Icons.error_rounded, colors.error),
                        _ => (Icons.info_rounded, colors.onSurfaceVariant),
                      };
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Icon(icon, size: 17, color: color),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text((check['name'] ?? '').toString(),
                                      style: context.texts.titleMedium?.copyWith(fontSize: 13.5)),
                                  const SizedBox(height: 1),
                                  Text((check['value'] ?? '').toString(),
                                      style: context.texts.bodySmall?.copyWith(
                                        color: colors.onSurface,
                                        fontFamily: 'monospace',
                                        fontSize: 11.5,
                                      )),
                                  Text((check['hint'] ?? '').toString(),
                                      style: context.texts.bodySmall?.copyWith(fontSize: 11)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.speed_rounded, size: 19, color: colors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('Speedtest через прокси',
                            style: context.texts.titleMedium),
                      ),
                      if (speed['via'] != null)
                        BadgePill(
                          label: speed['via'] == 'engine' ? 'ЧЕРЕЗ ЯДРО' : 'НАПРЯМУЮ',
                          dense: true,
                          color: speed['via'] == 'engine' ? palette.success : colors.onSurfaceVariant,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: state.speedTesting
                        ? null
                        : () async {
                            await state.runSpeedtest();
                            if (!context.mounted) return;
                            if (state.lastError != null && state.speedResult.isEmpty) {
                              showSnack(context, state.lastError!, error: true);
                            }
                          },
                    icon: state.speedTesting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_check_rounded, size: 19),
                    label: Text(state.speedTesting ? 'Измеряем…' : 'Замерить скорость'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  ),
                  const SizedBox(height: 14),
                  _SpeedRow(
                    label: 'Download ↓',
                    value: speed.isEmpty ? '—' : '${download.toStringAsFixed(1)} Мбит/с',
                    progress: (download / 100).clamp(0.0, 1.0),
                    color: colors.primary,
                  ),
                  _SpeedRow(
                    label: 'Upload ↑',
                    value: speed.isEmpty ? '—' : '${upload.toStringAsFixed(1)} Мбит/с',
                    progress: (upload / 50).clamp(0.0, 1.0),
                    color: palette.success,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: <Widget>[
                        Expanded(child: Text('Ping', style: context.texts.bodyMedium)),
                        Text(
                          speed.isEmpty || ping == 0 ? '—' : '$ping мс',
                          style: context.texts.labelLarge?.copyWith(color: colors.onSurface),
                        ),
                      ],
                    ),
                  ),
                  if (bytes > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text('Тестовый поток',
                                style: context.texts.bodySmall),
                          ),
                          Text(
                            formatBytes(bytes),
                            style: context.texts.labelMedium,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.4)),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                    color: colors.surfaceContainer,
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.terminal_rounded, size: 17, color: colors.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('Rust Core · Live Logs',
                              style: context.texts.titleSmall),
                        ),
                        _LogAction(
                          label: state.logPaused ? 'Продолжить' : 'Пауза',
                          onTap: () {
                            state.logPaused = !state.logPaused;
                            state.touch();
                          },
                        ),
                        _LogAction(
                          label: 'Очистить',
                          onTap: () {
                            state.clearLogs();
                            if (!context.mounted) return;
                            showSnack(context, 'Лог очищен');
                          },
                        ),
                        _LogAction(
                          label: 'Копировать',
                          onTap: () async {
                            final text = state.logs
                                .map((LogItem l) => '${l.timeLabel} ${l.level} ${l.msg}')
                                .join('\n');
                            await Clipboard.setData(ClipboardData(text: text));
                            if (!context.mounted) return;
                            showSnack(context, 'Лог скопирован');
                          },
                        ),
                      ],
                    ),
                  ),
                  Container(
                    height: 280,
                    width: double.infinity,
                    color: palette.terminal,
                    child: state.logs.isEmpty
                        ? Center(
                            child: Text(
                              'Ожидание событий ядра…',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: palette.terminalText.withValues(alpha: 0.5),
                              ),
                            ),
                          )
                        : ListView.builder(
                            controller: _logScroll,
                            padding: const EdgeInsets.all(12),
                            itemCount: state.logs.length,
                            itemBuilder: (BuildContext context, int index) {
                              final log = state.logs[index];
                              final color = _levelColor(context, log.level);
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: Text.rich(
                                  TextSpan(
                                    children: <InlineSpan>[
                                      TextSpan(
                                        text: '${log.timeLabel} ',
                                        style: TextStyle(
                                          color: palette.terminalText.withValues(alpha: 0.45),
                                        ),
                                      ),
                                      TextSpan(
                                        text: '${log.level.padRight(7)} ',
                                        style: TextStyle(
                                          color: color,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      TextSpan(
                                        text: log.msg,
                                        style: TextStyle(color: palette.terminalText),
                                      ),
                                    ],
                                  ),
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontFamilyFallback: <String>['Roboto Mono', 'Consolas'],
                                    fontSize: 11.2,
                                    height: 1.35,
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            AppCard(
              color: colors.surfaceContainerLow,
              child: Row(
                children: <Widget>[
                  Icon(Icons.memory_rounded, size: 18, color: colors.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Логи пишет Rust-ядро: маршруты, ошибки TLS, блокировки рекламы и события tun2proxy.',
                      style: context.texts.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Color _levelColor(BuildContext context, String level) {
    final palette = context.palette;
    return switch (level) {
      'ERROR' => context.colors.error,
      'WARN' => palette.warning,
      'PROXY' => context.colors.primary,
      'DIRECT' => palette.success,
      'BLOCK' => context.colors.error,
      _ => context.colors.onSurfaceVariant,
    };
  }
}

class _SpeedRow extends StatelessWidget {
  const _SpeedRow({
    required this.label,
    required this.value,
    required this.progress,
    required this.color,
  });

  final String label;
  final String value;
  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(label, style: context.texts.bodyMedium)),
              Text(value, style: context.texts.labelLarge?.copyWith(color: colors.onSurface)),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              color: color,
              backgroundColor: colors.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}

class _LogAction extends StatelessWidget {
  const _LogAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
        ),
        child: Text(label),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../models/proxy.dart';
import '../theme.dart';
import 'ui.dart';

Color latencyColor(BuildContext context, int latency) {
  final palette = context.palette;
  if (latency <= 0) return context.colors.onSurfaceVariant;
  if (latency < 120) return palette.success;
  if (latency < 350) return palette.warning;
  return context.colors.error;
}

class ProxyCard extends StatelessWidget {
  const ProxyCard({
    super.key,
    required this.server,
    this.isActive = false,
    this.index = 0,
    this.onConnect,
    this.onSave,
    this.onDelete,
    this.onQr,
    this.onCopy,
    this.showActions = true,
    this.saved = false,
  });

  final ProxyServer server;
  final bool isActive;
  final int index;
  final VoidCallback? onConnect;
  final VoidCallback? onSave;
  final VoidCallback? onDelete;
  final VoidCallback? onQr;
  final VoidCallback? onCopy;
  final bool showActions;
  final bool saved;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final palette = context.palette;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(milliseconds: 260 + (index.clamp(0, 8) * 35)),
      curve: Curves.easeOutCubic,
      builder: (BuildContext context, double value, Widget? child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(offset: Offset(0, 12 * (1 - value)), child: child),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isActive ? colors.primaryContainer.withValues(alpha: 0.32) : colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isActive ? colors.primary.withValues(alpha: 0.55) : colors.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: Text(server.flag, style: const TextStyle(fontSize: 21)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              server.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.texts.titleMedium?.copyWith(fontSize: 14.5),
                            ),
                          ),
                          if (isActive) ...<Widget>[
                            const SizedBox(width: 8),
                            BadgePill(
                              label: 'АКТИВЕН',
                              dense: true,
                              color: colors.onPrimaryContainer,
                              background: colors.primary,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: MonoText(
                              server.endpoint,
                              size: 11.5,
                              color: colors.onSurfaceVariant,
                              weight: FontWeight.w400,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('·', style: context.texts.bodySmall),
                          const SizedBox(width: 6),
                          Text(
                            server.protoLabel,
                            style: context.texts.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (server.encrypted)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(Icons.lock_rounded, size: 15, color: palette.success),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                if (server.latency > 0)
                  BadgePill(
                    label: server.latencyLabel,
                    icon: Icons.speed_rounded,
                    color: latencyColor(context, server.latency),
                    background: colors.surfaceContainerHigh,
                  ),
                if (server.speed > 0)
                  BadgePill(
                    label: '${server.speed.toStringAsFixed(server.speed < 10 ? 1 : 0)} Мбит/с',
                    icon: Icons.download_rounded,
                    color: colors.onSurfaceVariant,
                    background: colors.surfaceContainerHigh,
                  ),
                if (server.anonymity.isNotEmpty)
                  BadgePill(
                    label: server.anonymity,
                    icon: Icons.visibility_off_rounded,
                    color: server.anonymity == 'Elite' ? palette.success : colors.onSurfaceVariant,
                    background: colors.surfaceContainerHigh,
                  ),
                if (server.securityLabel.isNotEmpty)
                  BadgePill(
                    label: server.securityLabel,
                    icon: Icons.enhanced_encryption_rounded,
                    color: palette.success,
                    background: palette.successContainer.withValues(alpha: 0.45),
                  ),
                ...server.tags
                    .where((String t) => t.isNotEmpty)
                    .take(4)
                    .map((String tag) => BadgePill(
                          label: tag,
                          background: colors.surfaceContainerHigh,
                          color: colors.onSurfaceVariant,
                        )),
              ],
            ),
            if (showActions) ...<Widget>[
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  if (onConnect != null)
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: onConnect,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          backgroundColor: isActive ? colors.primary : colors.secondaryContainer,
                          foregroundColor: isActive ? colors.onPrimary : colors.onSecondaryContainer,
                        ),
                        child: Text(isActive ? 'Подключено' : 'Подключить'),
                      ),
                    ),
                  const SizedBox(width: 8),
                  if (onSave != null)
                    _CardIconButton(
                      icon: saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                      tooltip: 'Сохранить',
                      onTap: onSave!,
                      highlighted: saved,
                    ),
                  if (onQr != null) ...<Widget>[
                    const SizedBox(width: 6),
                    _CardIconButton(icon: Icons.qr_code_2_rounded, tooltip: 'QR-код', onTap: onQr!),
                  ],
                  if (onCopy != null) ...<Widget>[
                    const SizedBox(width: 6),
                    _CardIconButton(icon: Icons.copy_rounded, tooltip: 'Копировать', onTap: onCopy!),
                  ],
                  if (onDelete != null) ...<Widget>[
                    const SizedBox(width: 6),
                    _CardIconButton(
                      icon: Icons.delete_outline_rounded,
                      tooltip: 'Удалить',
                      onTap: onDelete!,
                      color: colors.error,
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CardIconButton extends StatelessWidget {
  const _CardIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.highlighted = false,
    this.color,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final bool highlighted;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final button = Material(
      color: highlighted ? colors.primary.withValues(alpha: 0.2) : colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon, size: 19, color: color ?? (highlighted ? colors.primary : colors.onSurfaceVariant)),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../theme.dart';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} КБ';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} МБ';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(2)} ГБ';
}

String formatSpeed(double mbps) {
  if (mbps <= 0) return '0.0 Мбит/с';
  if (mbps < 1) return '${(mbps * 1000).toStringAsFixed(0)} Кбит/с';
  return '${mbps.toStringAsFixed(1)} Мбит/с';
}

String formatDuration(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)}';
}

String formatUptime(int seconds) {
  if (seconds < 60) return '$seconds с';
  final m = seconds ~/ 60;
  if (m < 60) return '$m мин';
  final h = m ~/ 60;
  return '$h ч ${m % 60} мин';
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  final palette = context.palette;
  final colors = context.colors;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Row(
          children: <Widget>[
            Icon(
              error ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
              size: 18,
              color: error ? colors.error : palette.success,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
        duration: Duration(milliseconds: error ? 3800 : 2400),
      ),
    );
}

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color,
    this.radius = 22,
    this.onTap,
    this.gradient,
    this.border,
    this.clip = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final double radius;
  final VoidCallback? onTap;
  final Gradient? gradient;
  final Border? border;
  final bool clip;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: gradient == null ? (color ?? colors.surfaceContainerLow) : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(radius),
        border: border,
      ),
      child: child,
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          color: gradient == null ? (color ?? colors.surfaceContainerLow) : null,
          gradient: gradient,
          borderRadius: BorderRadius.circular(radius),
          border: border,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.label, {super.key, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: context.texts.labelSmall?.copyWith(
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.title, {super.key, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: context.texts.headlineSmall),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle!, style: context.texts.bodySmall),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Ends any pending ink reaction of a tapped row right away. Material keeps
/// one alive on the page route forever when a dialog steals the pointer, which
/// made lists look frozen or greyed out until the app restarted.
void popCurrentRoute(BuildContext context) {
  FocusManager.instance.primaryFocus?.unfocus();
}

class TileSwitch extends StatelessWidget {
  const TileSwitch({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.icon,
    this.padding = const EdgeInsets.symmetric(vertical: 6),
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final IconData? icon;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 20, color: context.colors.onSurfaceVariant),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: context.texts.titleMedium?.copyWith(fontSize: 14.5)),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle!, style: context.texts.bodySmall),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class TileNav extends StatelessWidget {
  const TileNav({
    super.key,
    required this.title,
    this.subtitle,
    this.onTap,
    this.leading,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
        child: Row(
          children: <Widget>[
            if (leading != null) ...<Widget>[leading!, const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: context.texts.titleMedium?.copyWith(fontSize: 14.5)),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(subtitle!, style: context.texts.bodySmall),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing ??
                Icon(Icons.chevron_right_rounded, color: context.colors.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class TileSelect extends StatelessWidget {
  const TileSelect({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.icon,
  });

  final String label;
  final String value;
  final List<DropdownMenuItem<String>> items;
  final ValueChanged<String?> onChanged;
  final IconData? icon;

  Widget? _labelFor(String target) {
    for (final item in items) {
      if (item.value == target) return item.child;
    }
    return null;
  }

  Future<void> _pick(BuildContext context) async {
    final colors = context.colors;
    final selected = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: colors.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (BuildContext ctx) {
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 2, 22, 8),
                child: Text(label, style: ctx.texts.titleMedium),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
                  children: items.map((DropdownMenuItem<String> item) {
                    final isSelected = item.value == value;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        selected: isSelected,
                        selectedTileColor:
                            ctx.colors.primaryContainer.withValues(alpha: 0.35),
                        title: DefaultTextStyle.merge(
                          style: ctx.texts.bodyLarge,
                          child: item.child,
                        ),
                        trailing: isSelected
                            ? Icon(Icons.check_rounded,
                                size: 20, color: ctx.colors.primary)
                            : null,
                        onTap: item.value == null
                            ? null
                            : () => Navigator.of(ctx).pop(item.value),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (selected != null && selected != value) onChanged(selected);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Row(
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  Icon(icon, size: 16, color: colors.onSurfaceVariant),
                  const SizedBox(width: 6),
                ],
                Text(label, style: context.texts.labelMedium),
              ],
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _pick(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: BoxDecoration(
                color: colors.surfaceContainer,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: colors.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: DefaultTextStyle.merge(
                      style: context.texts.bodyLarge?.copyWith(fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      child: _labelFor(value) ?? Text(value),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.expand_more_rounded,
                      size: 20, color: colors.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TileSlider extends StatelessWidget {
  const TileSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
    this.divisions,
    this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;
  final int? divisions;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(label, style: context.texts.titleMedium?.copyWith(fontSize: 14))),
              Text(display, style: context.texts.labelMedium?.copyWith(
                color: context.colors.primary,
                fontWeight: FontWeight.w700,
              )),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ],
      ),
    );
  }
}

class SegmentedTabs extends StatelessWidget {
  const SegmentedTabs({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
    this.compact = false,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: List<Widget>.generate(labels.length, (int i) {
          final selected = i == index;
          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                padding: EdgeInsets.symmetric(vertical: compact ? 8 : 10),
                decoration: BoxDecoration(
                  color: selected ? colors.secondaryContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  labels[i],
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: compact ? 12 : 12.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? colors.onSecondaryContainer : colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class BadgePill extends StatelessWidget {
  const BadgePill({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.background,
    this.dense = false,
  });

  final String label;
  final IconData? icon;
  final Color? color;
  final Color? background;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final fg = color ?? colors.onSurfaceVariant;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 7 : 9, vertical: dense ? 2 : 4),
      decoration: BoxDecoration(
        color: background ?? colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: dense ? 11 : 13, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: dense ? 10 : 11,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

class MonoText extends StatelessWidget {
  const MonoText(this.text, {super.key, this.size = 13, this.color, this.weight = FontWeight.w500});

  final String text;
  final double size;
  final Color? color;
  final FontWeight weight;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: const <String>['Roboto Mono', 'Consolas', 'Menlo'],
        fontSize: size,
        fontWeight: weight,
        color: color ?? context.colors.onSurface,
        letterSpacing: 0.2,
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      child: Column(
        children: <Widget>[
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: colors.surfaceContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 30, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          Text(title, textAlign: TextAlign.center, style: context.texts.titleMedium),
          if (subtitle != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(subtitle!, textAlign: TextAlign.center, style: context.texts.bodySmall),
          ],
          if (action != null) ...<Widget>[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirm = 'Подтвердить',
  String cancel = 'Отмена',
  bool destructive = false,
}) async {
  final colors = context.colors;
  final result = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancel),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: colors.errorContainer,
                  foregroundColor: colors.onErrorContainer,
                )
              : null,
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Reusable themed pill. Used by every top-right button so the tap feedback
/// is the same soft "dust" ripple everywhere (never a white overlay).
class IconPill extends StatelessWidget {
  const IconPill({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = onPressed != null;
    final content = Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: 38,
          height: 38,
          child: Icon(
            icon,
            size: 20,
            color: enabled ? colors.onSurfaceVariant : colors.onSurfaceVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
    if (tooltip == null) return content;
    return Tooltip(message: tooltip!, child: content);
  }
}

class Sparkline extends StatelessWidget {
  const Sparkline({super.key, required this.values, this.color, this.height = 40});

  final List<double> values;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparkPainter(
          values: values,
          color: color ?? context.colors.primary,
        ),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final maxValue = values.reduce((double a, double b) => a > b ? a : b);
    final effectiveMax = maxValue <= 0 ? 1.0 : maxValue;
    final path = Path();
    final fill = Path();
    final step = size.width / (values.length - 1);
    for (var i = 0; i < values.length; i++) {
      final x = step * i;
      final y = size.height - (values[i] / effectiveMax) * (size.height - 4) - 2;
      if (i == 0) {
        path.moveTo(x, y);
        fill.moveTo(x, size.height);
        fill.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fill.lineTo(x, y);
      }
    }
    fill.lineTo(size.width, size.height);
    fill.close();
    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[color.withValues(alpha: 0.35), color.withValues(alpha: 0.0)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawPath(fill, fillPaint);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.values.length != values.length ||
      !listEquals(oldDelegate.values, values);
}

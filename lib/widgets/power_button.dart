import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

class PowerButton extends StatefulWidget {
  const PowerButton({
    super.key,
    required this.connected,
    required this.busy,
    required this.onTap,
    this.size = 168,
  });

  final bool connected;
  final bool busy;
  final VoidCallback onTap;
  final double size;

  @override
  State<PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends State<PowerButton> with TickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 140),
    lowerBound: 0,
    upperBound: 1,
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant PowerButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connected != widget.connected || oldWidget.busy != widget.busy) {
      _sync();
    }
  }

  void _sync() {
    // The halo keeps breathing while the tunnel is up, and the orbit ring
    // keeps rotating both while connecting and after a successful connect.
    // Stopping the ring on connect made the button look frozen.
    if (widget.connected && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!widget.connected) {
      _pulse.stop();
      _pulse.value = 0;
    }
    final spin = widget.busy || widget.connected;
    if (spin && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!spin) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _spin.dispose();
    _press.dispose();
    super.dispose();
  }

  void _handleTap() async {
    HapticFeedback.mediumImpact();
    _press.forward().then((_) => _press.reverse());
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final palette = context.palette;
    final accent = widget.connected ? palette.success : colors.primary;
    final diameter = widget.size;

    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[_pulse, _spin, _press]),
      builder: (BuildContext context, Widget? child) {
        final pulse = widget.connected ? 0.5 + 0.5 * math.sin(_pulse.value * math.pi) : 0.0;
        final scale = 1 - 0.035 * _press.value;
        return SizedBox(
          width: diameter + 44,
          height: diameter + 44,
          child: Center(
            child: Transform.scale(
              scale: scale,
              child: GestureDetector(
                onTap: _handleTap,
                onTapDown: (_) => _press.forward(),
                onTapCancel: () => _press.reverse(),
                onTapUp: (_) => _press.reverse(),
                child: SizedBox(
                  width: diameter + 44,
                  height: diameter + 44,
                  child: Stack(
                    alignment: Alignment.center,
                    children: <Widget>[
                      // Ambient glow.
                      Container(
                        width: diameter + 30 + 18 * pulse,
                        height: diameter + 30 + 18 * pulse,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: <Color>[
                              accent.withValues(alpha: widget.connected ? 0.22 + 0.10 * pulse : 0.10),
                              accent.withValues(alpha: 0.0),
                            ],
                          ),
                        ),
                      ),
                      CustomPaint(
                        size: Size(diameter + 32, diameter + 32),
                        painter: _ArcsPainter(
                          accent: accent,
                          track: colors.outlineVariant.withValues(alpha: 0.45),
                          progress: _spin.value,
                          connected: widget.connected,
                          pulse: pulse,
                        ),
                      ),
                      Container(
                        width: diameter,
                        height: diameter,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: widget.connected
                                ? <Color>[
                                    Color.lerp(colors.primaryContainer, palette.successContainer, 0.55)!,
                                    Color.lerp(colors.surfaceContainerHigh, palette.successContainer, 0.45)!,
                                  ]
                                : <Color>[
                                    colors.surfaceContainerHigh,
                                    colors.surfaceContainerLow,
                                  ],
                          ),
                          border: Border.all(
                            color: accent.withValues(alpha: widget.connected ? 0.75 : 0.4),
                            width: 1.6,
                          ),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: accent.withValues(alpha: widget.connected ? 0.35 + 0.15 * pulse : 0.12),
                              blurRadius: widget.connected ? 34 : 18,
                              spreadRadius: widget.connected ? 4 : 0,
                            ),
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 22,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.power_settings_new_rounded,
                                size: diameter * 0.34,
                                color: widget.connected ? palette.onSuccessContainer : colors.primary,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                widget.connected ? 'ON' : 'OFF',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 2.2,
                                  color: widget.connected
                                      ? palette.onSuccessContainer.withValues(alpha: 0.85)
                                      : colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ArcsPainter extends CustomPainter {
  _ArcsPainter({
    required this.accent,
    required this.track,
    required this.progress,
    required this.connected,
    required this.pulse,
  });

  final Color accent;
  final Color track;
  final double progress;
  final bool connected;
  final double pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 6;
    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, trackPaint);

    final accentPaint = Paint()
      ..color = accent.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round;

    if (connected) {
      final glowPaint = Paint()
        ..color = accent.withValues(alpha: 0.25 + 0.15 * pulse)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        math.pi * 1.35,
        false,
        glowPaint,
      );
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        math.pi * 1.35,
        false,
        accentPaint,
      );
    } else {
      final dashPaint = Paint()
        ..color = accent.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round;
      const segments = 12;
      for (var i = 0; i < segments; i++) {
        final start = (math.pi * 2 / segments) * i;
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          start,
          math.pi / segments * 0.55,
          false,
          dashPaint,
        );
      }
    }

    final arcRect = Rect.fromCircle(center: center, radius: radius + 12);
    final orbitPaint = Paint()
      ..color = accent.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    if (connected) {
      canvas.drawArc(arcRect, progress * math.pi * 2, math.pi * 0.42, false, orbitPaint);
      canvas.drawCircle(
        Offset(
          center.dx + (radius + 12) * math.cos(progress * math.pi * 2 + math.pi * 0.42),
          center.dy + (radius + 12) * math.sin(progress * math.pi * 2 + math.pi * 0.42),
        ),
        2.6,
        Paint()..color = accent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ArcsPainter old) =>
      old.progress != progress || old.connected != connected || old.pulse != pulse || old.accent != accent;
}

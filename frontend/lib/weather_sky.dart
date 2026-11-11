// The moving sky behind the Weather tab. It follows the weather at the farm
// right now (clear, cloudy, fog, drizzle, rain, thunderstorm) and day or
// night: drifting clouds, falling rain, a glowing sun, twinkling stars.
//
// It is decoration only: every number and word on the screen is drawn on top
// by weather_screen.dart. One 60-second loop drives everything, so the motion
// repeats without a jump. With the phone's "remove animations" setting on,
// the sky is drawn once and stands still.

import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Top-to-bottom colours of the sky. The first colour is also used for the
/// app bar, so the bar and the sky read as one surface. All are dark enough
/// for white text.
List<Color> skyColors(String kind, bool night) {
  if (night) {
    switch (kind) {
      case 'Clear':
        return const [Color(0xFF0A1030), Color(0xFF182A5C), Color(0xFF30478A)];
      case 'Thunderstorm':
        return const [Color(0xFF0B0E17), Color(0xFF1A2130), Color(0xFF2C3648)];
      default:
        return const [Color(0xFF0E1626), Color(0xFF1D2B42), Color(0xFF33455F)];
    }
  }
  switch (kind) {
    case 'Clear':
      return const [Color(0xFF1559B8), Color(0xFF2B78D4), Color(0xFF5E9FE6)];
    case 'Clouds':
      return const [Color(0xFF3F5F82), Color(0xFF5B7C9E), Color(0xFF8AA5BF)];
    case 'Fog':
      return const [Color(0xFF55646F), Color(0xFF73838F), Color(0xFF9AA7B1)];
    case 'Thunderstorm':
      return const [Color(0xFF1B2330), Color(0xFF2F3A4B), Color(0xFF4A5567)];
    default: // Drizzle, Rain
      return const [Color(0xFF263B52), Color(0xFF3D5873), Color(0xFF64809A)];
  }
}

class WeatherSky extends StatefulWidget {
  /// Clear, Clouds, Fog, Drizzle, Rain or Thunderstorm (farm_weather.kindOf).
  final String kind;
  final bool night;

  const WeatherSky({super.key, required this.kind, required this.night});

  @override
  State<WeatherSky> createState() => _WeatherSkyState();
}

class _WeatherSkyState extends State<WeatherSky>
    with SingleTickerProviderStateMixin {
  static const double _loopSeconds = 60;
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 60),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 700),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: skyColors(widget.kind, widget.night),
        ),
      ),
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(
            size: Size.infinite,
            painter: _SkyPainter(
              kind: widget.kind,
              night: widget.night,
              t: _c.value * _loopSeconds,
            ),
          ),
        ),
      ),
    );
  }
}

class _Cloud {
  final double x, y, scale;
  final int laps; // crossings of the screen per loop
  const _Cloud(this.x, this.y, this.scale, this.laps);
}

class _Drop {
  final double x, phase, length;
  final int falls; // falls per loop
  const _Drop(this.x, this.phase, this.length, this.falls);
}

class _Star {
  final double x, y, size, phase;
  final int period; // seconds; divides the loop
  const _Star(this.x, this.y, this.size, this.phase, this.period);
}

class _SkyPainter extends CustomPainter {
  final String kind;
  final bool night;
  final double t; // seconds into the 60 s loop

  _SkyPainter({required this.kind, required this.night, required this.t});

  // The same sky every time: positions come from a fixed seed.
  static final math.Random _r = math.Random(7);
  static final List<_Cloud> _clouds = [
    for (var i = 0; i < 7; i++)
      _Cloud(_r.nextDouble(), 0.04 + _r.nextDouble() * 0.42,
          0.7 + _r.nextDouble() * 0.9, 1 + _r.nextInt(2)),
  ];
  static final List<_Drop> _drops = [
    for (var i = 0; i < 120; i++)
      _Drop(_r.nextDouble(), _r.nextDouble(), 14 + _r.nextDouble() * 12,
          [40, 48, 60][_r.nextInt(3)]),
  ];
  static final List<_Star> _stars = [
    for (var i = 0; i < 46; i++)
      _Star(_r.nextDouble(), _r.nextDouble() * 0.6, 0.8 + _r.nextDouble() * 1.4,
          _r.nextDouble(), [3, 4, 5, 6][_r.nextInt(4)]),
  ];

  bool get _wet =>
      kind == 'Drizzle' || kind == 'Rain' || kind == 'Thunderstorm';

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    if (w <= 0 || h <= 0) return;

    if (night && kind == 'Clear') _paintStars(canvas, w, h); // none under cloud
    if (kind == 'Clear') {
      night ? _paintMoon(canvas, w, h) : _paintSun(canvas, w, h);
    }

    final cloudCount = switch (kind) {
      'Clear' => 2,
      'Clouds' => 5,
      'Fog' => 7,
      'Drizzle' => 5,
      'Rain' => 6,
      _ => 7,
    };
    _paintClouds(canvas, w, h, cloudCount);

    if (_wet) {
      final n = switch (kind) { 'Drizzle' => 45, 'Rain' => 90, _ => 120 };
      _paintRain(canvas, w, h, n);
    }
    if (kind == 'Thunderstorm') _paintFlash(canvas, w, h);
  }

  void _paintSun(Canvas canvas, double w, double h) {
    final c = Offset(w * 0.80, h * 0.13);
    final pulse = math.sin(2 * math.pi * t / 6); // 6 s breath
    final glowR = 150 + 12 * pulse;
    canvas.drawCircle(
      c,
      glowR,
      Paint()
        ..shader = RadialGradient(colors: [
          const Color(0xFFFFE9A8).withValues(alpha: 0.55),
          const Color(0xFFFFE9A8).withValues(alpha: 0.0),
        ]).createShader(Rect.fromCircle(center: c, radius: glowR)),
    );
    canvas.drawCircle(c, 40, Paint()..color = const Color(0xFFFFF3C4));
  }

  void _paintMoon(Canvas canvas, double w, double h) {
    final c = Offset(w * 0.80, h * 0.13);
    canvas.drawCircle(
      c,
      90,
      Paint()
        ..shader = RadialGradient(colors: [
          Colors.white.withValues(alpha: 0.22),
          Colors.white.withValues(alpha: 0.0),
        ]).createShader(Rect.fromCircle(center: c, radius: 90)),
    );
    canvas.drawCircle(c, 30, Paint()..color = const Color(0xFFE8EEF8));
    // a soft shadow turns the disc into a crescent
    canvas.drawCircle(c + const Offset(12, -8), 26,
        Paint()..color = const Color(0xFF182A5C).withValues(alpha: 0.85));
  }

  void _paintStars(Canvas canvas, double w, double h) {
    final p = Paint();
    for (final s in _stars) {
      final tw = math.sin(2 * math.pi * (t / s.period + s.phase)).abs();
      p.color = Colors.white.withValues(alpha: 0.25 + 0.65 * tw);
      canvas.drawCircle(Offset(s.x * w, s.y * h), s.size, p);
    }
  }

  void _paintClouds(Canvas canvas, double w, double h, int count) {
    final Color tint;
    final double alpha;
    if (night) {
      tint = const Color(0xFFB7C4D8);
      alpha = kind == 'Clear' ? 0.10 : 0.20;
    } else if (kind == 'Thunderstorm') {
      tint = const Color(0xFF8E99A8);
      alpha = 0.34;
    } else if (_wet) {
      tint = const Color(0xFFCFD9E3);
      alpha = 0.30;
    } else if (kind == 'Fog') {
      tint = Colors.white;
      alpha = 0.26;
    } else {
      tint = Colors.white;
      alpha = kind == 'Clear' ? 0.30 : 0.38;
    }
    final paint = Paint()
      ..color = tint.withValues(alpha: alpha)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);

    for (var i = 0; i < count && i < _clouds.length; i++) {
      final c = _clouds[i];
      // drift left to right, wrapping well outside the screen edges
      final x = ((c.x + t / 60 * c.laps) % 1.0) * (w * 1.8) - w * 0.4;
      final y = c.y * h * (kind == 'Fog' ? 1.6 : 1.0);
      final s = c.scale * (kind == 'Fog' ? 1.5 : 1.0);
      canvas.drawOval(
          Rect.fromCenter(center: Offset(x, y), width: 190 * s, height: 54 * s),
          paint);
      canvas.drawCircle(Offset(x - 38 * s, y - 16 * s), 34 * s, paint);
      canvas.drawCircle(Offset(x + 14 * s, y - 28 * s), 44 * s, paint);
      canvas.drawCircle(Offset(x + 62 * s, y - 10 * s), 30 * s, paint);
    }
  }

  void _paintRain(Canvas canvas, double w, double h, int count) {
    final paint = Paint()
      ..strokeWidth = kind == 'Drizzle' ? 1.1 : 1.6
      ..strokeCap = StrokeCap.round;
    const slant = 0.20;
    for (var i = 0; i < count; i++) {
      final d = _drops[i];
      final f = (d.phase + t / 60 * d.falls) % 1.0;
      final y = f * (h + 60) - 30;
      final x = d.x * (w * 1.25) - y * slant;
      paint.color = Colors.white.withValues(alpha: 0.22 + 0.30 * d.phase);
      canvas.drawLine(
          Offset(x, y), Offset(x - d.length * slant, y + d.length), paint);
    }
  }

  /// One soft flash every 12 seconds (well under 3 flashes per second).
  void _paintFlash(Canvas canvas, double w, double h) {
    final s = t % 12;
    if (s > 0.35) return;
    final a = 0.16 * (1 - s / 0.35);
    canvas.drawRect(Offset.zero & Size(w, h),
        Paint()..color = Colors.white.withValues(alpha: a));
  }

  @override
  bool shouldRepaint(_SkyPainter old) =>
      old.t != t || old.kind != kind || old.night != night;
}

// Small moving parts shared by the screens: content that eases in, numbers
// that count up, and the coloured "hero" card. All of them stand still when
// the phone's "remove animations" accessibility setting is on.

import 'package:flutter/material.dart';

/// Fades and lifts its child into place once, when it first appears.
/// [index] delays it a little so a column of cards arrives one after another.
class Reveal extends StatefulWidget {
  final Widget child;
  final int index;

  const Reveal({super.key, required this.child, this.index = 0});

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final Animation<double> _a =
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.value = 1;
      return;
    }
    Future<void>.delayed(Duration(milliseconds: 60 * widget.index), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _a,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: _a.value,
        child: Transform.translate(
          offset: Offset(0, 18 * (1 - _a.value)),
          child: child,
        ),
      ),
    );
  }
}

/// A number that counts up to [value] when it appears or changes.
class AnimatedCount extends StatelessWidget {
  final double value;
  final int decimals;
  final String suffix;
  final TextStyle style;

  const AnimatedCount({
    super.key,
    required this.value,
    required this.style,
    this.decimals = 1,
    this.suffix = '',
  });

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value),
      duration: still ? Duration.zero : const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) =>
          Text('${v.toStringAsFixed(decimals)}$suffix', style: style),
    );
  }
}

/// The one coloured card of a screen: a deep green (or bronze, for Block B)
/// gradient with soft rings. Text placed on it should be white.
class HeroPanel extends StatelessWidget {
  final Widget child;
  final bool bronze;
  final EdgeInsetsGeometry padding;

  const HeroPanel({
    super.key,
    required this.child,
    this.bronze = false,
    this.padding = const EdgeInsets.all(20),
  });

  @override
  Widget build(BuildContext context) {
    final colors = bronze
        ? const [Color(0xFFB06A12), Color(0xFF6E3F06)]
        : const [Color(0xFF1F8457), Color(0xFF0E4A2F)];
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: colors.last.withValues(alpha: 0.28),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
          ),
          child: Stack(
            children: [
              // Decorative rings, behind the content
              Positioned(
                right: -50,
                top: -60,
                child: _ring(180, 0.07),
              ),
              Positioned(
                right: 40,
                bottom: -90,
                child: _ring(160, 0.05),
              ),
              Padding(padding: padding, child: child),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _ring(double size, double alpha) => IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: alpha),
          ),
        ),
      );
}

/// White text styles for use on a [HeroPanel] or on the weather sky.
class OnHero {
  OnHero._();

  static const Color soft = Color(0xD9FFFFFF); // 85% white

  static const TextStyle label = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: soft,
  );
  static const TextStyle title = TextStyle(
    fontFamily: 'Outfit',
    fontSize: 24,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    color: Colors.white,
    height: 1.2,
  );
  static const TextStyle figure = TextStyle(
    fontFamily: 'Outfit',
    fontSize: 44,
    fontWeight: FontWeight.w700,
    letterSpacing: -1,
    color: Colors.white,
    height: 1.05,
  );
  static const TextStyle body = TextStyle(
    fontSize: 15,
    color: Colors.white,
    height: 1.45,
  );
  static const TextStyle bodyStrong = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: Colors.white,
    height: 1.4,
  );
  static const TextStyle caption = TextStyle(
    fontSize: 13,
    color: soft,
    height: 1.4,
  );
}

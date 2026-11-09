import 'package:flutter/material.dart';

/// One calm palette: warm paper, deep forest green, and a single bronze
/// accent. Colour is used to carry meaning (block, status), not decoration.
class AppColors {
  AppColors._();

  static const Color paper = Color(0xFFF6F2EA); // page background
  static const Color surface = Color(0xFFFFFDF8); // panels
  static const Color ink = Color(0xFF1F2A24); // main text
  static const Color inkSoft = Color(0xFF5C675F); // secondary text
  static const Color inkFaint = Color(0xFF8D978F); // captions, labels
  static const Color line = Color(0xFFE2DBCB); // hairlines

  static const Color forest = Color(0xFF1F4D3A); // primary, Block A
  static const Color forestSoft = Color(0xFFE4ECE6);
  static const Color bronze = Color(0xFFA9742F); // accent, Block B
  static const Color bronzeSoft = Color(0xFFF3E7D5);

  static const Color good = Color(0xFF3F7D5B);
  static const Color caution = Color(0xFFC08A2E);
  static const Color alert = Color(0xFFB3473B);
  static const Color alertSoft = Color(0xFFF6E3E0);
}

/// Block A is always forest green, Block B is always bronze.
Color blockColor(String block) =>
    block == 'Block B' ? AppColors.bronze : AppColors.forest;

/// Headings and big numbers use the system serif (Android); the rest of the
/// app keeps the normal sans-serif for easy reading.
class AppText {
  AppText._();

  static const String serif = 'serif';

  static const TextStyle label = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.3,
    color: AppColors.inkFaint,
  );
  static const TextStyle display = TextStyle(
    fontFamily: serif,
    fontSize: 28,
    fontWeight: FontWeight.w600,
    color: AppColors.ink,
    height: 1.15,
  );
  static const TextStyle title = TextStyle(
    fontFamily: serif,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    color: AppColors.ink,
    height: 1.2,
  );
  static const TextStyle heading = TextStyle(
    fontFamily: serif,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: AppColors.ink,
    height: 1.25,
  );
  static const TextStyle figure = TextStyle(
    fontFamily: serif,
    fontSize: 30,
    fontWeight: FontWeight.w600,
    color: AppColors.ink,
    height: 1.1,
  );
  static const TextStyle figureSmall = TextStyle(
    fontFamily: serif,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    color: AppColors.ink,
    height: 1.1,
  );
  static const TextStyle body = TextStyle(
    fontSize: 14,
    color: AppColors.ink,
    height: 1.45,
  );
  static const TextStyle bodyStrong = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: AppColors.ink,
    height: 1.4,
  );
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    color: AppColors.inkSoft,
    height: 1.35,
  );
}

IconData weatherIcon(String weather) {
  switch (weather) {
    case 'Sunny':
      return Icons.wb_sunny_outlined;
    case 'Cloudy':
      return Icons.cloud_outlined;
    case 'Rainy':
      return Icons.water_drop_outlined;
    case 'Windy':
      return Icons.air;
    default:
      return Icons.wb_cloudy_outlined;
  }
}

/// Small grey capital label that sits above a section.
class SectionLabel extends StatelessWidget {
  final String text;

  const SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: AppText.label);
}

/// Flat surface with a hairline border. No shadow, no gradient.
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.line),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Small squared label, outlined by default.
class Tag extends StatelessWidget {
  final String text;
  final Color color;
  final bool filled;

  const Tag(this.text, {super.key, required this.color, this.filled = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: filled ? color : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: filled ? color : color.withValues(alpha: 0.55),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: filled ? Colors.white : color,
        ),
      ),
    );
  }
}

/// A label, a big number, and an optional one-line note.
class Figure extends StatelessWidget {
  final String label;
  final String value;
  final String? note;
  final bool small;

  const Figure({
    super.key,
    required this.label,
    required this.value,
    this.note,
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SectionLabel(label),
        const SizedBox(height: 8),
        Text(value, style: small ? AppText.figureSmall : AppText.figure),
        if (note != null) ...[
          const SizedBox(height: 2),
          Text(note!, style: AppText.caption),
        ],
      ],
    );
  }
}

/// A message with a thick coloured edge on the left.
class NoteBar extends StatelessWidget {
  final Color color;
  final Color background;
  final Widget child;

  const NoteBar({
    super.key,
    required this.color,
    required this.background,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 3, color: color),
            Expanded(
              child: Container(
                color: background,
                padding: const EdgeInsets.all(14),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Calm empty / error state.
class QuietMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  const QuietMessage({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.inkFaint),
            const SizedBox(height: 14),
            Text(title, style: AppText.heading, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(message, style: AppText.caption, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// Label on the left, value on the right, hairline underneath.
class DetailLine extends StatelessWidget {
  final String label;
  final String value;

  const DetailLine({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppText.caption),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              value,
              style: AppText.bodyStrong,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

/// Tap-to-select option (used instead of dropdown menus).
class ChoicePill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  const ChoicePill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final Color fg = selected ? Colors.white : AppColors.ink;
    return Material(
      color: selected ? AppColors.forest : AppColors.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: selected ? AppColors.forest : AppColors.line),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: fg),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

OutlineInputBorder _fieldBorder(Color color, [double width = 1]) {
  return OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: BorderSide(color: color, width: width),
  );
}

/// Text-field look used in every form.
InputDecoration fieldDecoration(String label, {IconData? icon, String? hint}) {
  return InputDecoration(
    labelText: label,
    hintText: hint,
    prefixIcon:
        icon == null ? null : Icon(icon, size: 20, color: AppColors.inkSoft),
    filled: true,
    fillColor: AppColors.surface,
    labelStyle: const TextStyle(color: AppColors.inkSoft, fontSize: 14),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    border: _fieldBorder(AppColors.line),
    enabledBorder: _fieldBorder(AppColors.line),
    focusedBorder: _fieldBorder(AppColors.forest, 1.5),
    errorBorder: _fieldBorder(AppColors.alert),
    focusedErrorBorder: _fieldBorder(AppColors.alert, 1.5),
  );
}

/// One-line message at the bottom of the screen.
void showNote(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? AppColors.alert : AppColors.ink,
    ),
  );
}

/// App-wide theme.
///
/// The colour scheme is left exactly as it was before the redesign so the
/// bottom navigation bar looks identical. Everything else is restyled here.
ThemeData buildAppTheme() {
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Roboto',
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF2E7D32),
      primary: const Color(0xFF2E7D32),
      secondary: const Color(0xFF66BB6A),
    ),
    scaffoldBackgroundColor: AppColors.paper,
    dividerTheme: const DividerThemeData(
      color: AppColors.line,
      thickness: 1,
      space: 1,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.paper,
      foregroundColor: AppColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: AppText.serif,
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
      ),
      shape: Border(bottom: BorderSide(color: AppColors.line)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.forest,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.forest,
        side: const BorderSide(color: AppColors.forest),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.forest),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: AppColors.forest,
      foregroundColor: Colors.white,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      extendedTextStyle:
          const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.ink,
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      modalBackgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    progressIndicatorTheme:
        const ProgressIndicatorThemeData(color: AppColors.forest),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? AppColors.forest
                : AppColors.surface),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? Colors.white
                : AppColors.ink),
        side: const WidgetStatePropertyAll(BorderSide(color: AppColors.line)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    ),
  );
}
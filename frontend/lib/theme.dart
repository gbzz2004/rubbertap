import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

export 'motion.dart';

/// One calm palette: a cool, clean background with white cards, deep forest
/// green, and a single bronze accent. Colour carries meaning (block, status),
/// not decoration.
class AppColors {
  AppColors._();

  /// Set by the app when the Dark mode setting changes (see main.dart).
  /// Every colour below follows it, so widgets must not keep colours in
  /// `const` values.
  static bool dark = false;

  static Color get paper => // page background
      dark ? const Color(0xFF0D1411) : const Color(0xFFF2F5F1);
  static Color get surface => // cards, sheets
      dark ? const Color(0xFF17201B) : const Color(0xFFFFFFFF);
  static Color get ink => // main text
      dark ? const Color(0xFFEDF3EE) : const Color(0xFF121C16);
  static Color get inkSoft => // secondary text
      dark ? const Color(0xFFB6C3BA) : const Color(0xFF4D5B53);
  static Color get inkFaint => // captions, labels
      dark ? const Color(0xFF8F9D94) : const Color(0xFF6A786F);
  static Color get line => // hairlines
      dark ? const Color(0xFF2A362F) : const Color(0xFFE1E7E1);
  static Color get forest => // primary, Block A
      dark ? const Color(0xFF4CC38A) : const Color(0xFF17603F);
  static Color get forestSoft =>
      dark ? const Color(0xFF1A3226) : const Color(0xFFE2F1E8);
  static Color get bronze => // accent, Block B
      dark ? const Color(0xFFE0A04C) : const Color(0xFFA7620E);
  static Color get bronzeSoft =>
      dark ? const Color(0xFF38290F) : const Color(0xFFFAEDD8);
  static Color get good =>
      dark ? const Color(0xFF4CC38A) : const Color(0xFF1C8553);
  static Color get caution =>
      dark ? const Color(0xFFE0A04C) : const Color(0xFFB8720C);
  static Color get alert =>
      dark ? const Color(0xFFF0786A) : const Color(0xFFBF3B2D);
  static Color get alertSoft =>
      dark ? const Color(0xFF3B1D19) : const Color(0xFFFBE7E4);
  static Color get onFill => // text and icons on forest / bronze fills
      dark ? const Color(0xFF0B130F) : const Color(0xFFFFFFFF);
  static Color get toast => // snackbar background (text is white)
      dark ? const Color(0xFF2C3832) : const Color(0xFF121C16);
}

/// Block A is always forest green, Block B is always bronze.
Color blockColor(String block) =>
    block == 'Block B' ? AppColors.bronze : AppColors.forest;

/// Two bundled fonts: Outfit (geometric) for headings and numbers, Work Sans
/// for everything that is read. Nothing is smaller than 12.
class AppText {
  AppText._();

  static const String displayFont = 'Outfit';
  static const String bodyFont = 'WorkSans';

  static TextStyle get label => TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: AppColors.inkFaint,
  );
  static TextStyle get display => TextStyle(
    fontFamily: displayFont,
    fontSize: 30,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    color: AppColors.ink,
    height: 1.15,
  );
  static TextStyle get title => TextStyle(
    fontFamily: displayFont,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    color: AppColors.ink,
    height: 1.2,
  );
  static TextStyle get heading => TextStyle(
    fontFamily: displayFont,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: AppColors.ink,
    height: 1.25,
  );
  static TextStyle get figure => TextStyle(
    fontFamily: displayFont,
    fontSize: 32,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    color: AppColors.ink,
    height: 1.1,
  );
  static TextStyle get figureSmall => TextStyle(
    fontFamily: displayFont,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    color: AppColors.ink,
    height: 1.1,
  );
  static TextStyle get body => TextStyle(
    fontSize: 15,
    color: AppColors.ink,
    height: 1.45,
  );
  static TextStyle get bodyStrong => TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: AppColors.ink,
    height: 1.4,
  );
  static TextStyle get caption => TextStyle(
    fontSize: 13,
    color: AppColors.inkSoft,
    height: 1.4,
  );
}

/// Small quiet label that sits above a section.
class SectionLabel extends StatelessWidget {
  final String text;

  const SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) =>
      Text(text, style: AppText.label);
}

/// Card with large corners: a very soft shadow in light mode, a hairline
/// in dark mode. [color] replaces the normal card colour (e.g. see-through
/// cards over the weather sky).
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;

  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppColors.dark
            ? null
            : const [
                BoxShadow(
                  color: Color(0x0F0B2416),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
      ),
      child: Material(
        color: color ?? AppColors.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: AppColors.dark
              ? BorderSide(color: AppColors.line)
              : BorderSide.none,
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Small pill label: soft tint by default, solid when [filled].
class Tag extends StatelessWidget {
  final String text;
  final Color color;
  final bool filled;

  const Tag(this.text, {super.key, required this.color, this.filled = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: filled ? AppColors.onFill : color,
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
        const SizedBox(height: 6),
        Text(value, style: small ? AppText.figureSmall : AppText.figure),
        if (note != null) ...[
          const SizedBox(height: 4),
          Text(note!, style: AppText.caption),
        ],
      ],
    );
  }
}

/// A message in a softly tinted box; [color] gives it a faint outline.
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.16)),
      ),
      child: child,
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
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.forestSoft,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 32, color: AppColors.forest),
            ),
            const SizedBox(height: 16),
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
      decoration: BoxDecoration(
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
    final Color fg = selected ? AppColors.onFill : AppColors.ink;
    return Material(
      color: selected ? AppColors.forest : AppColors.surface,
      clipBehavior: Clip.antiAlias,
      shape: StadiumBorder(
        side: BorderSide(color: selected ? AppColors.forest : AppColors.line),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
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
                  fontSize: 14,
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
    borderRadius: BorderRadius.circular(14),
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
    labelStyle: TextStyle(color: AppColors.inkSoft, fontSize: 15),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
      backgroundColor: error ? const Color(0xFFBF3B2D) : AppColors.toast,
    ),
  );
}

/// App-wide theme.
///
/// Built again whenever Dark mode changes (AppColors.dark). In light mode the
/// colour scheme is exactly as it was before the redesigns, so the bottom
/// navigation bar looks identical.
ThemeData buildAppTheme() {
  final dark = AppColors.dark;
  return ThemeData(
    useMaterial3: true,
    brightness: dark ? Brightness.dark : Brightness.light,
    fontFamily: AppText.bodyFont,
    // Material's default tracking is tuned for Roboto; Work Sans is wider
    textTheme: const TextTheme(
      bodyLarge: TextStyle(letterSpacing: 0),
      bodyMedium: TextStyle(letterSpacing: 0),
      bodySmall: TextStyle(letterSpacing: 0),
      labelLarge: TextStyle(letterSpacing: 0),
      labelMedium: TextStyle(letterSpacing: 0),
      labelSmall: TextStyle(letterSpacing: 0),
      titleMedium: TextStyle(letterSpacing: 0),
      titleSmall: TextStyle(letterSpacing: 0),
    ),
    colorScheme: dark
        ? ColorScheme.fromSeed(
            seedColor: const Color(0xFF2E7D32),
            brightness: Brightness.dark,
            primary: AppColors.forest,
            onPrimary: AppColors.onFill,
            surface: AppColors.surface,
            onSurface: AppColors.ink,
          )
        : ColorScheme.fromSeed(
            seedColor: const Color(0xFF2E7D32),
            primary: const Color(0xFF2E7D32),
            secondary: const Color(0xFF66BB6A),
          ),
    scaffoldBackgroundColor: AppColors.paper,
    dividerTheme: DividerThemeData(
      color: AppColors.line,
      thickness: 1,
      space: 1,
    ),
    appBarTheme: AppBarTheme(
      // Clock and battery icons: dark on the light page, light on the dark one
      systemOverlayStyle: (dark
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark)
          .copyWith(statusBarColor: Colors.transparent),
      backgroundColor: AppColors.paper,
      foregroundColor: AppColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: AppText.displayFont,
        fontSize: 22,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: AppColors.ink,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.forest,
        foregroundColor: AppColors.onFill,
        elevation: 0,
        minimumSize: const Size(48, 52),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(
          fontFamily: AppText.bodyFont,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.forest,
        backgroundColor: AppColors.surface,
        side: BorderSide(color: AppColors.line),
        minimumSize: const Size(48, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(
          fontFamily: AppText.bodyFont,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.forest),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: AppColors.forest,
      foregroundColor: AppColors.onFill,
      elevation: 3,
      shape: const StadiumBorder(),
      extendedTextStyle: const TextStyle(
        fontFamily: AppText.bodyFont,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.toast,
      contentTextStyle: const TextStyle(
        fontFamily: AppText.bodyFont,
        color: Colors.white,
        fontSize: 14,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      modalBackgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(24)),
      ),
      titleTextStyle: AppText.heading,
      contentTextStyle: AppText.body.copyWith(fontFamily: AppText.bodyFont),
    ),
    progressIndicatorTheme:
        ProgressIndicatorThemeData(color: AppColors.forest),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? AppColors.forest
                : AppColors.surface),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? AppColors.onFill
                : AppColors.ink),
        side: WidgetStatePropertyAll(BorderSide(color: AppColors.line)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: AppText.bodyFont,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
  );
}
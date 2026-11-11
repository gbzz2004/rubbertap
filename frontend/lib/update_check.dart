// "A new version is available" notice.
//
// The app is not on the Play Store, so phones cannot update themselves.
// New versions are listed in the Supabase table app_versions (the app can only
// READ it; only the developer can add rows) and the APK files are in the
// public, download-only Storage bucket "releases". On start, the app compares
// its own build number (the part after "+" in pubspec.yaml's version) with
// the newest row and, if that is higher, offers the download.
//
// Publish a version with: python backend/publish_release.py (see that file).

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'main.dart';
import 'theme.dart';

const _skippedKey = 'update_skipped_version_code';

/// Checks once for a newer version and shows a dialog if there is one.
/// Never throws: an update check must not get in the way of using the app.
///
/// [manual] is true when the farmer taps "Check for updates" in Settings:
/// the answer is then always shown, also "you have the latest version", and
/// an earlier "Later" is ignored.
Future<void> checkForUpdate(BuildContext context, {bool manual = false}) async {
  try {
    final info = await PackageInfo.fromPlatform();
    // Per-phone-type APKs (--split-per-abi) add 1000 x the type number to the
    // build number (arm64 build 3 reports 2003), so keep only the last 3 digits.
    final current = (int.tryParse(info.buildNumber) ?? 0) % 1000;

    final rows = await supabase
        .from('app_versions')
        .select('version_code, version_name, apk_url, notes')
        .order('version_code', ascending: false)
        .limit(1);
    final list = List<Map<String, dynamic>>.from(rows);
    final latest = list.isEmpty ? null : list.first;
    final latestCode = (latest?['version_code'] as num?)?.toInt() ?? 0;
    if (latest == null || latestCode <= current) {
      if (manual && context.mounted) {
        showNote(context, 'You have the latest version (${info.version}).');
      }
      return;
    }

    // "Later" hides this version until the next app start after a day
    final prefs = await SharedPreferences.getInstance();
    final skipped = prefs.getString(_skippedKey);
    if (skipped != null && !manual) {
      final parts = skipped.split('@');
      final when = DateTime.tryParse(parts.length > 1 ? parts[1] : '');
      if (parts.first == '$latestCode' &&
          when != null &&
          DateTime.now().difference(when) < const Duration(days: 1)) {
        return;
      }
    }

    if (!context.mounted) return;
    final url = Uri.parse(latest['apk_url'].toString());
    final notes = (latest['notes'] ?? '').toString().trim();
    final download = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New version available'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'RubberTap ${latest['version_name']} is ready. '
              'You have ${info.version}.',
              style: AppText.body,
            ),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text("What's new", style: AppText.bodyStrong),
              const SizedBox(height: 4),
              Text(notes, style: AppText.caption),
            ],
            const SizedBox(height: 12),
            Text(
              'Tap Download, then open the file and tap Update. '
              'Your records are kept.',
              style: AppText.caption,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Download'),
          ),
        ],
      ),
    );

    if (download == true) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      await prefs.setString(
          _skippedKey, '$latestCode@${DateTime.now().toIso8601String()}');
    }
  } catch (e) {
    debugPrint('Update check skipped: $e');
    if (manual && context.mounted) {
      showNote(context, 'Could not check right now. Please try again with internet.',
          error: true);
    }
  }
}

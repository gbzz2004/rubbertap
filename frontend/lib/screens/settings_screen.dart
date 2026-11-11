// Settings: opened from the gear icon at the top right of every tab.
// Only settings that really do something: Dark mode, rain alerts (which
// follow the phone's notification permission), and app updates.

import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../rain_alerts.dart';
import '../settings_store.dart';
import '../theme.dart';
import '../update_check.dart';

/// The gear icon for a screen's app bar. [color] is for bars that are not
/// the normal page colour (the Weather tab's sky).
class SettingsButton extends StatelessWidget {
  final Color? color;

  const SettingsButton({super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Settings',
      icon: Icon(Icons.settings_outlined, size: 24, color: color),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  bool? _alertsOn; // null while checking
  String _version = '';
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    // Notice when the farmer comes back from the phone's own Settings
    WidgetsBinding.instance.addObserver(this);
    _loadAlerts();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = info.version);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      RainAlertService.syncBackgroundChecks().catchError((_) {});
      _loadAlerts();
    }
  }

  Future<void> _loadAlerts() async {
    try {
      final on = await RainAlertService.isEnabled();
      if (mounted) setState(() => _alertsOn = on);
    } catch (_) {
      if (mounted) setState(() => _alertsOn = false);
    }
  }

  Future<void> _openNotificationSettings() async {
    try {
      await AppSettings.openAppSettings(type: AppSettingsType.notification);
    } catch (_) {
      if (mounted) {
        showNote(context,
            'Open your phone Settings > Apps > RubberTap > Notifications.');
      }
    }
  }

  Future<void> _sendTest() async {
    try {
      await RainAlertService.sendTest();
      if (mounted) showNote(context, 'A test alert was sent. Check the top of your screen.');
    } catch (_) {
      if (mounted) showNote(context, 'The test alert could not be sent.', error: true);
    }
  }

  Future<void> _checkUpdates() async {
    setState(() => _checking = true);
    await checkForUpdate(context, manual: true);
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final alertsOn = _alertsOn ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          const SectionLabel('Appearance'),
          const SizedBox(height: 10),
          Reveal(
            child: Panel(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
              child: _row(
                icon: AppColors.dark
                    ? Icons.dark_mode_outlined
                    : Icons.light_mode_outlined,
                title: 'Dark mode',
                text: 'Easier on the eyes at night and before sunrise.',
                trailing: Switch(
                  value: AppPrefs.darkMode.value,
                  activeThumbColor: AppColors.onFill,
                  activeTrackColor: AppColors.forest,
                  onChanged: (on) async {
                    await AppPrefs.setDarkMode(on);
                    if (mounted) setState(() {});
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 26),
          const SectionLabel('Rain alerts'),
          const SizedBox(height: 10),
          Reveal(
            index: 1,
            child: Panel(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row(
                    icon: alertsOn
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_off_outlined,
                    iconColor: alertsOn ? AppColors.good : AppColors.inkFaint,
                    title: _alertsOn == null
                        ? 'Checking…'
                        : (alertsOn
                            ? 'Rain alerts are on'
                            : 'Rain alerts are off'),
                    text: alertsOn
                        ? 'You get a notification when rain is coming to the farm.'
                        : 'Notifications for RubberTap are turned off on this '
                            'phone, so rain warnings cannot be shown.',
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _openNotificationSettings,
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: Text(alertsOn
                            ? 'Phone notification settings'
                            : 'Turn on in phone settings'),
                      ),
                      if (alertsOn)
                        OutlinedButton.icon(
                          onPressed: _sendTest,
                          icon: const Icon(Icons.notifications_none, size: 18),
                          label: const Text('Send a test alert'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 26),
          const SectionLabel('App'),
          const SizedBox(height: 10),
          Reveal(
            index: 2,
            child: Panel(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row(
                    icon: Icons.system_update_outlined,
                    title: _version.isEmpty
                        ? 'RubberTap'
                        : 'RubberTap $_version',
                    text: 'New versions are offered when you open the app.',
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: _checking ? null : _checkUpdates,
                    icon: const Icon(Icons.refresh, size: 18),
                    label:
                        Text(_checking ? 'Checking…' : 'Check for updates'),
                  ),
                  const SizedBox(height: 16),
                  Divider(color: AppColors.line),
                  const SizedBox(height: 14),
                  _row(
                    icon: Icons.swipe_down_outlined,
                    title: 'Reloading a screen',
                    text: 'Pull the screen down to load the newest records, '
                        'forecast and weather.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 26),
          const SectionLabel('About'),
          const SizedBox(height: 10),
          Reveal(
            index: 3,
            child: Panel(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row(
                    icon: Icons.forest_outlined,
                    title: 'Mr. Arnel’s farm',
                    text: 'Ipil, Zamboanga Sibugay. Block A and Block B, '
                        'tapped on alternate days in 15-day cycles.',
                  ),
                  const SizedBox(height: 14),
                  _row(
                    icon: Icons.cloud_outlined,
                    title: 'Weather',
                    text: 'An estimate for the farm’s area from a weather '
                        'service. It is not measured at the farm.',
                  ),
                  const SizedBox(height: 14),
                  _row(
                    icon: Icons.auto_graph_outlined,
                    title: 'Forecast',
                    text: 'Worked out again every morning from the recorded '
                        'harvests. It becomes more reliable as more cycles '
                        'are recorded.',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Icon in a soft circle, a title, a line of explanation, and an optional
  /// control at the right.
  Widget _row({
    required IconData icon,
    required String title,
    required String text,
    Color? iconColor,
    Widget? trailing,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.forestSoft,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 20, color: iconColor ?? AppColors.forest),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppText.bodyStrong),
              const SizedBox(height: 2),
              Text(text, style: AppText.caption),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing],
      ],
    );
  }
}

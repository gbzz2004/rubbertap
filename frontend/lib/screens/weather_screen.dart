import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_settings/app_settings.dart';
import '../theme.dart';
import '../weather_sky.dart';
import 'settings_screen.dart';
import '../farm_weather.dart';
import '../rain_alerts.dart';
import '../tapping_advice.dart';

class WeatherScreen extends StatefulWidget {
  const WeatherScreen({super.key});

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

class _Advice {
  final String title;
  final String text;
  final Color color;
  final Color soft;

  const _Advice({
    required this.title,
    required this.text,
    required this.color,
    required this.soft,
  });
}

class _WeatherScreenState extends State<WeatherScreen>
    with WidgetsBindingObserver {
  bool _isLoading = true;
  // Weather now + hour by hour (Open-Meteo, the app's one weather source)
  FarmWeather? _weather;
  DateTime? _lastUpdated;
  Timer? _timer;
  bool _alertsOn = false;
  // Advice for the next tapping MORNING (Open-Meteo, same source as the
  // calendar). Null while loading or if it could not be downloaded.
  TappingAdvice? _morningAdvice;


  @override
  void initState() {
    super.initState();
    // Notice when the farmer comes back from the phone's Settings
    WidgetsBinding.instance.addObserver(this);
    _fetchWeather();
    _loadAlertSetting();
    // Refresh every 10 minutes while the screen is open
    _timer = Timer.periodic(const Duration(minutes: 10), (_) {
      _fetchWeather();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------------ data

  Future<void> _fetchWeather() async {
    if (mounted) setState(() => _isLoading = true);
    // The morning advice loads on its own: if it fails, the rest still shows
    fetchTappingAdvice().then((a) {
      if (mounted) setState(() => _morningAdvice = a);
    }).catchError((_) {});
    try {
      final w = await fetchFarmWeather();
      if (!mounted) return;
      setState(() {
        _weather = w;
        _lastUpdated = DateTime.now();
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      // Keep showing the last good reading if we have one
      if (_weather != null) {
        showNote(context, 'Could not update the weather just now.',
            error: true);
      }
    }
  }

  // ------------------------------------------------------------ rain alerts
  // Rain alerts follow the phone's notification setting for RubberTap
  // (asked once on the first start). There is no switch inside the app.

  Future<void> _loadAlertSetting() async {
    final on = await RainAlertService.isEnabled();
    if (!mounted) return;
    setState(() => _alertsOn = on);
  }

  /// Opens the phone's notification settings for RubberTap.
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

  /// Back from the phone's Settings: show the new state and start or stop
  /// the background checks to match.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      RainAlertService.syncBackgroundChecks().catchError((_) {});
      _loadAlertSetting();
    }
  }

  // --------------------------------------------------------------- helpers

  IconData _icon(String main) {
    switch (main.toLowerCase()) {
      case 'rain':
      case 'drizzle':
        return Icons.water_drop_outlined;
      case 'thunderstorm':
        return Icons.thunderstorm_outlined;
      case 'clouds':
        return Icons.cloud_outlined;
      case 'clear':
        return Icons.wb_sunny_outlined;
      case 'snow':
        return Icons.ac_unit;
      default:
        return Icons.cloud_outlined;
    }
  }

  String _formatHour(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h ${t.hour >= 12 ? 'PM' : 'AM'}';
  }

  String _updatedText() {
    final t = _lastUpdated;
    if (t == null) return '';
    final mins = DateTime.now().difference(t).inMinutes;
    if (mins < 1) return 'Updated just now';
    if (mins == 1) return 'Updated 1 minute ago';
    return 'Updated $mins minutes ago';
  }

  _Advice _advice(String weatherMain, double humidity) {
    final w = weatherMain.toLowerCase();
    if (w.contains('thunderstorm')) {
      return _Advice(
        title: 'Do not tap today',
        text: 'Thunderstorms are dangerous for outdoor farm work.',
        color: AppColors.alert,
        soft: AppColors.alertSoft,
      );
    }
    if (w.contains('rain') || w.contains('drizzle')) {
      return _Advice(
        title: 'Better to wait',
        text:
            'Tapping in the rain is not recommended. Waiting for drier conditions protects the latex.',
        color: AppColors.caution,
        soft: AppColors.bronzeSoft,
      );
    }
    if (w.contains('clear') && humidity < 70) {
      return _Advice(
        title: 'Good day for tapping',
        text: 'Clear skies and lower humidity are generally good for tapping.',
        color: AppColors.good,
        soft: AppColors.forestSoft,
      );
    }
    if (w.contains('cloud')) {
      return _Advice(
        title: 'Fine for tapping',
        text: 'Cloudy but dry. Conditions are suitable for tapping.',
        color: AppColors.good,
        soft: AppColors.forestSoft,
      );
    }
    if (humidity > 85) {
      return _Advice(
        title: 'Watch the humidity',
        text:
            'Very humid air may affect latex quality. Early morning tapping can help.',
        color: AppColors.caution,
        soft: AppColors.bronzeSoft,
      );
    }
    return _Advice(
      title: 'Fine for tapping',
      text: 'Conditions are suitable. Keep an eye on the weather during the day.',
      color: AppColors.good,
      soft: AppColors.forestSoft,
    );
  }

  // ------------------------------------------------------------------ build

  /// The page sits on a moving sky that follows the weather right now
  /// (weather_sky.dart). The app bar takes the sky's top colour so the two
  /// read as one surface; everything on the sky is white.
  @override
  Widget build(BuildContext context) {
    // For showing or testing a sky that is not today's weather, the app can
    // be started with e.g. --dart-define=SKY=Rain:day (or Clear:night...).
    // Only the background changes; the readings stay real. Empty in releases.
    const demoSky = String.fromEnvironment('SKY');
    final demo = demoSky.split(':');
    final hour = DateTime.now().hour;
    final night = demoSky.isNotEmpty
        ? demo.last == 'night'
        : (hour < 6 || hour >= 18);
    // Before the first reading arrives: a plain cloudy sky
    final kind =
        demoSky.isNotEmpty ? demo.first : (_weather?.now.kind ?? 'Clouds');
    final top = skyColors(kind, night).first;
    return Scaffold(
      backgroundColor: top,
      appBar: AppBar(
        backgroundColor: top,
        foregroundColor: Colors.white,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        titleTextStyle: Theme.of(context)
            .appBarTheme
            .titleTextStyle
            ?.copyWith(color: Colors.white),
        title: const Text('Weather'),
        actions: const [
          SettingsButton(color: Colors.white),
          SizedBox(width: 4),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: WeatherSky(kind: kind, night: night)),
          _buildBody(),
        ],
      ),
    );
  }

  /// Cards on the sky let a little of it show through.
  Color get _card => AppColors.surface.withValues(alpha: 0.94);

  Widget _skyLabel(String text) => Text(text, style: OnHero.label);

  Widget _buildBody() {
    if (_weather == null) {
      if (_isLoading) {
        return const Center(
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
        );
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Panel(
            color: _card,
            padding: EdgeInsets.zero,
            child: QuietMessage(
              icon: Icons.cloud_off_outlined,
              title: 'Weather is not available',
              message: 'Please check your internet connection and try again.',
              action: ElevatedButton(
                onPressed: _fetchWeather,
                child: const Text('Try again'),
              ),
            ),
          ),
        ),
      );
    }

    final w = _weather!;
    final main = w.now.kind;
    final humidity = w.now.humidity;
    // Prefer the advice for the tapping morning; fall back to "right now"
    final morning = _morningAdvice;
    final nowAdvice = _advice(main, humidity);
    final advice = morning == null
        ? _Advice(
            title: 'Right now: ${nowAdvice.title.toLowerCase()}',
            text: nowAdvice.text,
            color: nowAdvice.color,
            soft: nowAdvice.soft)
        : _Advice(
            title: morning.title,
            text: morning.text,
            color: morning.color,
            soft: morning.soft);

    return RefreshIndicator(
      color: AppColors.forest,
      onRefresh: _fetchWeather,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Reveal(child: _buildNow(w, main)),
          const SizedBox(height: 28),
          _skyLabel('Tapping advice'),
          const SizedBox(height: 10),
          Reveal(
            index: 1,
            child: NoteBar(
            color: advice.color,
            background: advice.soft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(advice.title, style: AppText.bodyStrong),
                const SizedBox(height: 4),
                Text(advice.text, style: AppText.body),
                const SizedBox(height: 6),
                Text(
                  morning == null
                      ? 'Based on the weather right now. The morning forecast could not be loaded.'
                      : 'For the tapping morning (4–11 AM), from the hourly forecast. General guidance.',
                  style: TextStyle(fontSize: 12, color: AppColors.inkFaint),
                ),
              ],
            ),
            ),
          ),
          const SizedBox(height: 28),
          _skyLabel('Next 24 hours'),
          const SizedBox(height: 10),
          Reveal(index: 2, child: _buildHourly()),
          const SizedBox(height: 28),
          _skyLabel('Rain alerts'),
          const SizedBox(height: 10),
          Reveal(index: 3, child: _buildAlerts()),
          const SizedBox(height: 28),
          _skyLabel('General guide'),
          const SizedBox(height: 10),
          Reveal(index: 4, child: _buildGuide()),
        ],
      ),
    );
  }

  Widget _buildAlerts() {
    return Panel(
      color: _card,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _alertsOn
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
                size: 22,
                color: _alertsOn ? AppColors.good : AppColors.inkFaint,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _alertsOn ? 'Rain alerts are on' : 'Rain alerts are off',
                  style: AppText.bodyStrong,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _alertsOn
                ? 'You get a notification when rain is coming to the farm. '
                    'To turn them off, use your phone Settings > Apps > '
                    'RubberTap > Notifications.'
                : 'Notifications for RubberTap are turned off on this phone, '
                    'so rain warnings cannot be shown.',
            style: AppText.caption,
          ),
          if (!_alertsOn) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _openNotificationSettings,
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const Text('Turn on in phone settings'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNow(FarmWeather w, String main) {
    final description = w.now.description;
    final temp = w.now.temp.toStringAsFixed(0);
    final feels = w.now.feelsLike.toStringAsFixed(0);
    final humidity = w.now.humidity.toStringAsFixed(0);
    final wind = w.now.windKmh.toStringAsFixed(0);

    Widget cell(IconData icon, String label, String value) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 20, color: OnHero.soft),
                const SizedBox(height: 8),
                Text(value,
                    style: OnHero.title.copyWith(fontSize: 20, height: 1.1)),
                const SizedBox(height: 2),
                Text(label, style: OnHero.caption),
              ],
            ),
          ),
        );
    final divider = Container(width: 1, color: const Color(0x33FFFFFF));

    // Straight on the sky, no card: the reading is the headline
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Mr. Arnel’s farm · Zamboanga Sibugay',
            style: OnHero.caption),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedCount(
                    value: double.parse(temp),
                    decimals: 0,
                    suffix: '°',
                    style: const TextStyle(
                      fontFamily: AppText.displayFont,
                      fontSize: 96,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -3,
                      color: Colors.white,
                      height: 1,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(description,
                      style: OnHero.title.copyWith(fontSize: 20)),
                  const SizedBox(height: 4),
                  Text('At the farm now · ${_updatedText()}',
                      style: OnHero.caption),
                ],
              ),
            ),
            // On a clear sky the painted sun or moon sits in this corner, so
            // no icon is drawn on top of it
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: main == 'Clear'
                  ? const SizedBox(width: 76, height: 76)
                  : Icon(_icon(main), size: 76, color: Colors.white),
            ),
          ],
        ),
        const SizedBox(height: 22),
        // "Glass" strip: see-through, so the sky keeps moving behind it
        Container(
          decoration: BoxDecoration(
            color: const Color(0x29FFFFFF),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0x40FFFFFF)),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                cell(Icons.water_drop_outlined, 'Humidity', '$humidity%'),
                divider,
                cell(Icons.air, 'Wind', '$wind km/h'),
                divider,
                cell(Icons.thermostat_outlined, 'Feels like', '$feels°'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHourly() {
    // The next 24 hours, every 3 hours (from hourly data)
    final hours = _weather?.hours ?? <FarmHour>[];
    final strip = [
      for (var i = 0; i < hours.length && i < 24; i += 3) hours[i],
    ];
    return Panel(
      color: _card,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: SizedBox(
        height: 108,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          itemCount: strip.length,
          separatorBuilder: (_, __) => const SizedBox(width: 24),
          itemBuilder: (context, index) {
            final h = strip[index];
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_formatHour(h.time),
                    style: TextStyle(
                        fontSize: 12, color: AppColors.inkSoft)),
                const SizedBox(height: 6),
                Icon(_icon(h.kind), size: 22, color: AppColors.inkSoft),
                const SizedBox(height: 6),
                Text('${h.temp.toStringAsFixed(0)}°', style: AppText.heading),
                const SizedBox(height: 2),
                // Chance of rain, shown when it matters
                Text(h.rainChance >= 30 ? '${h.rainChance}%' : ' ',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.inkSoft)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildGuide() {
    Widget line(String title, String text, {bool last = false}) => Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: last
                ? null
                : Border(bottom: BorderSide(color: AppColors.line)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppText.bodyStrong),
              const SizedBox(height: 2),
              Text(text, style: AppText.caption),
            ],
          ),
        );

    return Panel(
      color: _card,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          line('Heavy rain',
              'Tapping is usually postponed because rain dilutes the latex.'),
          line('Light rain', 'Often manageable once it eases.'),
          line('Dry and clear', 'Comfortable conditions for tapping.'),
          line('High humidity (above 80%)', 'May affect latex quality.',
              last: true),
          const SizedBox(height: 10),
          Text(
            'General guidance only. These are not measurements from your farm.',
            style: TextStyle(fontSize: 12, color: AppColors.inkFaint),
          ),
        ],
      ),
    );
  }
}
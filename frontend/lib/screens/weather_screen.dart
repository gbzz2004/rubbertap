import 'dart:async';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../theme.dart';
import '../rain_alerts.dart';
import '../record_store.dart';

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

class _WeatherScreenState extends State<WeatherScreen> {
  bool _isLoading = true;
  Map<String, dynamic>? _currentWeather;
  List<Map<String, dynamic>> _forecast = [];
  DateTime? _lastUpdated;
  Timer? _timer;
  bool _alertsOn = false;
  bool _alertsBusy = false;

  static const double _farmLat = 7.762639;
  static const double _farmLon = 122.567028;
  static const String _apiKey = 'b4bf1e412a554e1efae968eda1f8b25e';

  @override
  void initState() {
    super.initState();
    _fetchWeather();
    _loadAlertSetting();
    // Refresh every 10 minutes while the screen is open
    _timer = Timer.periodic(const Duration(minutes: 10), (_) {
      _fetchWeather();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------------ data

  Future<void> _fetchWeather() async {
    if (mounted) setState(() => _isLoading = true);
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ));

      // Current weather
      final currentResponse = await dio.get(
        'https://api.openweathermap.org/data/2.5/weather',
        queryParameters: {
          'lat': _farmLat,
          'lon': _farmLon,
          'appid': _apiKey,
          'units': 'metric',
        },
      );

      // Next 24 hours (every 3 hours)
      final forecastResponse = await dio.get(
        'https://api.openweathermap.org/data/2.5/forecast',
        queryParameters: {
          'lat': _farmLat,
          'lon': _farmLon,
          'appid': _apiKey,
          'units': 'metric',
          'cnt': 8,
        },
      );

      final forecastList = List<Map<String, dynamic>>.from(
        forecastResponse.data['list'],
      );

      if (!mounted) return;
      setState(() {
        _currentWeather = currentResponse.data;
        _forecast = forecastList;
        _lastUpdated = DateTime.now();
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      // Keep showing the last good reading if we have one
      if (_currentWeather != null) {
        showNote(context, 'Could not update the weather just now.',
            error: true);
      }
    }
  }

  // ------------------------------------------------------------ rain alerts

  Future<void> _loadAlertSetting() async {
    final on = await RainAlertService.isEnabled();
    if (!mounted) return;
    setState(() => _alertsOn = on);
  }

  Future<void> _toggleAlerts(bool on) async {
    setState(() => _alertsBusy = true);
    try {
      if (on) {
        final granted = await RainAlertService.requestPermission();
        if (!granted) {
          if (mounted) {
            showNote(
              context,
              'Please allow notifications for RubberTap in your phone settings.',
              error: true,
            );
          }
          return;
        }
        await RainAlertService.setEnabled(true);
        await RainAlertService.startBackgroundChecks();
        if (mounted) {
          setState(() => _alertsOn = true);
          showNote(context, 'Rain alerts are on.');
        }
      } else {
        await RainAlertService.setEnabled(false);
        await RainAlertService.stopBackgroundChecks();
        if (mounted) {
          setState(() => _alertsOn = false);
          showNote(context, 'Rain alerts are off.');
        }
      }
    } catch (e) {
      if (mounted) {
        showNote(context, 'Could not change rain alerts. ${plainError(e)}', error: true);
      }
    } finally {
      if (mounted) setState(() => _alertsBusy = false);
    }
  }

  Future<void> _sendTest() async {
    try {
      await RainAlertService.sendTest();
      if (mounted) showNote(context, 'Test alert sent. Check your notifications.');
    } catch (e) {
      if (mounted) showNote(context, 'Could not send the test. ${plainError(e)}', error: true);
    }
  }

  Future<void> _checkNow() async {
    setState(() => _alertsBusy = true);
    try {
      final summary = await RainAlertService.checkAndNotify(force: true);
      if (mounted) showNote(context, summary);
    } catch (e) {
      if (mounted) {
        showNote(context, 'Could not check the weather. ${plainError(e)}', error: true);
      }
    } finally {
      if (mounted) setState(() => _alertsBusy = false);
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

  String _formatTime(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final hour = dt.hour;
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
    return '$displayHour $period';
  }

  String _sentence(String text) {
    if (text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1);
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
      return const _Advice(
        title: 'Do not tap today',
        text: 'Thunderstorms are dangerous for outdoor farm work.',
        color: AppColors.alert,
        soft: AppColors.alertSoft,
      );
    }
    if (w.contains('rain') || w.contains('drizzle')) {
      return const _Advice(
        title: 'Better to wait',
        text:
            'Tapping in the rain is not recommended. Waiting for drier conditions protects the latex.',
        color: AppColors.caution,
        soft: AppColors.bronzeSoft,
      );
    }
    if (w.contains('clear') && humidity < 70) {
      return const _Advice(
        title: 'Good day for tapping',
        text: 'Clear skies and lower humidity are generally good for tapping.',
        color: AppColors.good,
        soft: AppColors.forestSoft,
      );
    }
    if (w.contains('cloud')) {
      return const _Advice(
        title: 'Fine for tapping',
        text: 'Cloudy but dry. Conditions are suitable for tapping.',
        color: AppColors.good,
        soft: AppColors.forestSoft,
      );
    }
    if (humidity > 85) {
      return const _Advice(
        title: 'Watch the humidity',
        text:
            'Very humid air may affect latex quality. Early morning tapping can help.',
        color: AppColors.caution,
        soft: AppColors.bronzeSoft,
      );
    }
    return const _Advice(
      title: 'Fine for tapping',
      text: 'Conditions are suitable. Keep an eye on the weather during the day.',
      color: AppColors.good,
      soft: AppColors.forestSoft,
    );
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Weather'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh, size: 22),
            onPressed: _isLoading ? null : _fetchWeather,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_currentWeather == null) {
      if (_isLoading) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      return QuietMessage(
        icon: Icons.cloud_off_outlined,
        title: 'Weather is not available',
        message: 'Please check your internet connection and try again.',
        action: ElevatedButton(
          onPressed: _fetchWeather,
          child: const Text('Try again'),
        ),
      );
    }

    final w = _currentWeather!;
    final main = w['weather'][0]['main'].toString();
    final humidity = (w['main']['humidity'] as num).toDouble();
    final advice = _advice(main, humidity);

    return RefreshIndicator(
      color: AppColors.forest,
      onRefresh: _fetchWeather,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Mr. Arnel’s farm · Zamboanga Sibugay',
                  style: AppText.caption),
              Text(_updatedText(),
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.inkFaint)),
            ],
          ),
          const SizedBox(height: 12),
          _buildNow(w, main),
          const SizedBox(height: 28),
          const SectionLabel('Tapping advice'),
          const SizedBox(height: 10),
          NoteBar(
            color: advice.color,
            background: advice.soft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(advice.title, style: AppText.bodyStrong),
                const SizedBox(height: 4),
                Text(advice.text, style: AppText.body),
              ],
            ),
          ),
          const SizedBox(height: 28),
          const SectionLabel('Rain alerts'),
          const SizedBox(height: 10),
          _buildAlerts(),
          const SizedBox(height: 28),
          const SectionLabel('Next 24 hours'),
          const SizedBox(height: 10),
          _buildHourly(),
          const SizedBox(height: 28),
          const SectionLabel('General guide'),
          const SizedBox(height: 10),
          _buildGuide(),
        ],
      ),
    );
  }

  Widget _buildAlerts() {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Rain alerts', style: AppText.bodyStrong),
                    SizedBox(height: 2),
                    Text(
                      'A phone notification when rain is coming, with advice on what to do.',
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
              Switch(
                value: _alertsOn,
                onChanged: _alertsBusy ? null : _toggleAlerts,
              ),
            ],
          ),
          if (_alertsOn) ...[
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 12),
            const Text(
              'The forecast is checked about every 30 minutes, even when the app is closed. Phones can delay checks to save battery, so it helps to allow RubberTap to run in the background.',
              style: AppText.caption,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _alertsBusy ? null : _sendTest,
                  child: const Text('Send a test alert'),
                ),
                TextButton(
                  onPressed: _alertsBusy ? null : _checkNow,
                  child: const Text('Check now'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNow(Map<String, dynamic> w, String main) {
    final description = _sentence(w['weather'][0]['description'].toString());
    final temp = (w['main']['temp'] as num).toStringAsFixed(0);
    final feels = (w['main']['feels_like'] as num).toStringAsFixed(0);
    final humidity = (w['main']['humidity'] as num).toStringAsFixed(0);
    final wind = (w['wind']['speed'] as num).toStringAsFixed(1);

    Widget cell(String label, String value) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionLabel(label),
                const SizedBox(height: 6),
                Text(value, style: AppText.heading),
              ],
            ),
          ),
        );

    return Panel(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionLabel('At the farm now'),
                      const SizedBox(height: 10),
                      Text(
                        '$temp°',
                        style: const TextStyle(
                          fontFamily: AppText.serif,
                          fontSize: 64,
                          fontWeight: FontWeight.w500,
                          color: AppColors.ink,
                          height: 1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(description, style: AppText.body),
                    ],
                  ),
                ),
                Icon(_icon(main), size: 52, color: AppColors.forest),
              ],
            ),
          ),
          const Divider(),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                cell('Humidity', '$humidity%'),
                const VerticalDivider(width: 1),
                cell('Wind', '$wind m/s'),
                const VerticalDivider(width: 1),
                cell('Feels like', '$feels°'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHourly() {
    return Panel(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: SizedBox(
        height: 92,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          itemCount: _forecast.length,
          separatorBuilder: (_, __) => const SizedBox(width: 24),
          itemBuilder: (context, index) {
            final item = _forecast[index];
            final main = item['weather'][0]['main'].toString();
            final temp = (item['main']['temp'] as num).toStringAsFixed(0);
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_formatTime(item['dt'] as int),
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.inkSoft)),
                const SizedBox(height: 8),
                Icon(_icon(main), size: 22, color: AppColors.inkSoft),
                const SizedBox(height: 8),
                Text('$temp°', style: AppText.heading),
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
                : const Border(bottom: BorderSide(color: AppColors.line)),
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
          const Text(
            'General guidance only. These are not measurements from your farm.',
            style: TextStyle(fontSize: 11, color: AppColors.inkFaint),
          ),
        ],
      ),
    );
  }
}
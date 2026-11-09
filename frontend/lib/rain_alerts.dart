import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

/// One warning that can be shown to the farmer.
class RainAlert {
  final String type; // thunder, now, likely, possible
  final int rank; // higher = more serious
  final String title;
  final String body;

  const RainAlert({
    required this.type,
    required this.rank,
    required this.title,
    required this.body,
  });
}

/// Runs in the background (even when the app is closed) every ~30 minutes.
@pragma('vm:entry-point')
void rainAlertCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      DartPluginRegistrant.ensureInitialized();
      await RainAlertService.init();
      await RainAlertService.checkAndNotify();
      return true;
    } catch (_) {
      // Returning false asks Android to try again later
      return false;
    }
  });
}

class RainAlertService {
  RainAlertService._();

  // --- Farm and weather source -------------------------------------------
  static const double _farmLat = 7.762639;
  static const double _farmLon = 122.567028;
  static const String _apiKey = 'b4bf1e412a554e1efae968eda1f8b25e';

  // --- Rules (our own choices, easy to change) ---------------------------
  /// How many 3-hour forecast steps to look at (4 steps = next 12 hours).
  static const int _lookAheadSlots = 4;

  /// Chance of rain at or above this = "rain is coming".
  static const double _likelyPop = 0.6;

  /// Chance of rain at or above this = "rain is possible".
  static const double _possiblePop = 0.3;

  /// Do not repeat the same (or a weaker) alert within this time.
  static const Duration _cooldown = Duration(hours: 3);

  /// How often the background check runs. Android never goes below 15 min,
  /// and the free OpenWeatherMap data only changes every couple of hours.
  static const Duration checkEvery = Duration(minutes: 30);

  // --- Names ---------------------------------------------------------------
  static const String _uniqueName = 'rain-alert-check';
  static const String _taskName = 'rainAlertCheck';
  static const String _channelId = 'rain_alerts';
  static const String _channelName = 'Rain alerts';
  static const int _notificationId = 1001;

  static const String _kAsked = 'notifications_permission_asked';
  static const String _kLastRank = 'rain_alerts_last_rank';
  static const String _kLastTime = 'rain_alerts_last_time';

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static bool _workmanagerReady = false;

  // ------------------------------------------------------------------ setup

  static Future<void> init() async {
    if (_initialized) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      settings: const InitializationSettings(android: android),
    );
    _initialized = true;
  }

  /// Asks the user for permission to show notifications (Android 13+).
  static Future<bool> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission();
    return granted ?? false;
  }

  /// Rain alerts are ON whenever the phone allows RubberTap's notifications.
  /// There is no separate switch in the app: the farmer turns them on or off
  /// in the phone's Settings > Apps > RubberTap > Notifications, like any app.
  static Future<bool> isEnabled() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.areNotificationsEnabled() ?? false;
  }

  /// On the first start, shows Android's own "Allow notifications?" prompt
  /// (Android 13+; older phones allow them by default). Asked only once, like
  /// other apps. Then starts or stops the background checks to match.
  static Future<void> askOnceAndSync() async {
    await init();
    final prefs = SharedPreferencesAsync();
    if (!((await prefs.getBool(_kAsked)) ?? false)) {
      await prefs.setBool(_kAsked, true);
      await requestPermission();
    }
    await syncBackgroundChecks();
  }

  /// Background checks run only while notifications are allowed.
  static Future<void> syncBackgroundChecks() async {
    if (await isEnabled()) {
      await startBackgroundChecks();
    } else {
      await stopBackgroundChecks();
    }
  }

  static Future<void> _ensureWorkmanager() async {
    if (_workmanagerReady) return;
    await Workmanager().initialize(rainAlertCallbackDispatcher);
    _workmanagerReady = true;
  }

  static Future<void> startBackgroundChecks() async {
    await _ensureWorkmanager();
    await Workmanager().registerPeriodicTask(
      _uniqueName,
      _taskName,
      frequency: checkEvery,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  static Future<void> stopBackgroundChecks() async {
    await _ensureWorkmanager();
    await Workmanager().cancelByUniqueName(_uniqueName);
  }

  // --------------------------------------------------------------- the rules

  static String _timeLabel(int unixSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour12 $period';
  }

  static double _pop(Map<String, dynamic> slot) =>
      ((slot['pop'] ?? 0) as num).toDouble();

  static String _main(Map<String, dynamic> weather) =>
      weather['weather'][0]['main'].toString();

  /// Looks at the weather now and the next 12 hours and decides what (if
  /// anything) to warn about. The most serious warning wins.
  static RainAlert? decide(
    Map<String, dynamic> current,
    List<Map<String, dynamic>> forecast,
  ) {
    final nowMain = _main(current);
    final slots = forecast.take(_lookAheadSlots).toList();

    // 1) Thunderstorm
    if (nowMain == 'Thunderstorm') {
      return const RainAlert(
        type: 'thunder',
        rank: 4,
        title: 'Thunderstorm at the farm',
        body:
            'Stay out of the plantation and do not tap until it passes. Keep tools and latex cups secured.',
      );
    }
    final storms = slots.where((s) => _main(s) == 'Thunderstorm').toList();
    if (storms.isNotEmpty) {
      final at = _timeLabel(storms.first['dt'] as int);
      return RainAlert(
        type: 'thunder',
        rank: 4,
        title: 'Thunderstorm expected around $at',
        body:
            'Finish work early, stay out of the plantation while it passes, and do not tap during the storm.',
      );
    }

    // 2) Raining now
    if (nowMain == 'Rain' || nowMain == 'Drizzle') {
      return const RainAlert(
        type: 'now',
        rank: 3,
        title: 'Rain at the farm now',
        body:
            'Pause tapping and keep the latex cups covered or emptied, since rain dilutes the latex. Resume when it stops.',
      );
    }

    // 3) Rain is coming
    final likely = slots.where((s) => _pop(s) >= _likelyPop).toList();
    if (likely.isNotEmpty) {
      final slot = likely.first;
      final at = _timeLabel(slot['dt'] as int);
      final pct = (_pop(slot) * 100).round();
      return RainAlert(
        type: 'likely',
        rank: 2,
        title: 'Rain is coming around $at',
        body:
            'About a $pct% chance of rain. If today is a tapping day, try to finish collecting before then and have the cup covers ready.',
      );
    }

    // 4) Rain is possible
    final possible = slots.where((s) => _pop(s) >= _possiblePop).toList();
    if (possible.isNotEmpty) {
      final slot = possible.first;
      final at = _timeLabel(slot['dt'] as int);
      final pct = (_pop(slot) * 100).round();
      return RainAlert(
        type: 'possible',
        rank: 1,
        title: 'Rain is possible around $at',
        body:
            'About a $pct% chance of rain. Keep the cup covers and rain gear close by and watch the sky.',
      );
    }

    return null;
  }

  // ----------------------------------------------------------- check + notify

  static Future<Map<String, dynamic>> _fetchWeather() async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ));
    final params = {
      'lat': _farmLat,
      'lon': _farmLon,
      'appid': _apiKey,
      'units': 'metric',
    };
    final current = await dio.get(
      'https://api.openweathermap.org/data/2.5/weather',
      queryParameters: params,
    );
    final forecast = await dio.get(
      'https://api.openweathermap.org/data/2.5/forecast',
      queryParameters: {...params, 'cnt': 8},
    );
    return {
      'current': Map<String, dynamic>.from(current.data),
      'forecast': List<Map<String, dynamic>>.from(forecast.data['list']),
    };
  }

  /// Checks the weather and shows a notification if needed. Returns a short
  /// plain-language summary (used by the "Check now" button).
  ///
  /// [force] skips the on/off switch and the repeat limit.
  static Future<String> checkAndNotify({bool force = false}) async {
    if (!force && !await isEnabled()) return 'Rain alerts are off.';

    final data = await _fetchWeather();
    final alert = decide(
      data['current'] as Map<String, dynamic>,
      data['forecast'] as List<Map<String, dynamic>>,
    );

    final prefs = SharedPreferencesAsync();

    if (alert == null) {
      // Nothing to warn about, so the next rain gets a fresh alert
      await prefs.setInt(_kLastRank, 0);
      return 'No rain expected in the next 12 hours.';
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!force) {
      final lastRank = (await prefs.getInt(_kLastRank)) ?? 0;
      final lastTime = (await prefs.getInt(_kLastTime)) ?? 0;
      final recent = nowMs - lastTime < _cooldown.inMilliseconds;
      if (recent && alert.rank <= lastRank) {
        return 'Already warned recently: ${alert.title}';
      }
    }

    await _show(alert.title, alert.body);
    await prefs.setInt(_kLastRank, alert.rank);
    await prefs.setInt(_kLastTime, nowMs);
    return alert.title;
  }

  /// Sends an example alert so the farmer can see what it looks like.
  static Future<void> sendTest() {
    return _show(
      'Test: rain is coming around 2 PM',
      'About a 80% chance of rain. If today is a tapping day, try to finish collecting before then and have the cup covers ready.',
    );
  }

  static Future<void> _show(String title, String body) async {
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: 'Warnings when rain is coming to the farm',
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(body),
      ),
    );
    await _plugin.show(
      id: _notificationId,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }
}
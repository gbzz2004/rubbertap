// Per-day yield plan for one 15-day tapping cycle, made on the phone.
//
// Dart version of backend/app/ml/cycle.py, so "New cycle" works without the
// PC. The ML models (run on GitHub, saved in forecast_runs) give each block's
// cycle TOTAL; this file splits that total across the block's tap days using
// each day's weather forecast from Open-Meteo (free, no key), so the daily
// numbers always add up to the ML forecast.
//
// IMPORTANT: the weather weights below are ASSUMED values, not learned from
// data. Mr. Arnel records one total per block per cycle, so there is nothing
// to learn a per-day weather effect from yet. Keep them identical to cycle.py.

import 'package:dio/dio.dart';
import 'main.dart';

const int cycleLength = 15;
const Set<int> blockADays = {1, 3, 5, 7, 9, 11, 13}; // 7 tap days
const Set<int> blockBDays = {2, 4, 6, 8, 10, 12, 14, 15}; // 8 tap days

// --- ASSUMED weather weights (same as backend/app/ml/cycle.py) ---
const Map<String, double> _baseWeight = {
  'Sunny': 1.0,
  'Cloudy': 0.95,
  'Windy': 0.85,
};
const double _rainStartWeight = 0.85; // rainy day with ~0 mm of rain
const double _rainPenaltyPerMm = 0.02; // each mm lowers the weight this much
const double _rainMinWeight = 0.40; // heavy rain never goes below this
const double _windyKmh = 30.0;

// A day counts as rainy from this much rain. The weather service reports a
// trace of drizzle on almost every day, so "any rain" made every day Rainy.
const double _rainyMm = 1.0;

const double farmLat = 7.762639;
const double farmLon = 122.567028;

/// Something the user should be told in plain words.
class PlanException implements Exception {
  final String message;
  const PlanException(this.message);
  @override
  String toString() => message;
}

/// Which block is tapped on day [n] of a cycle (day 1 = first day).
/// Day 16 (only in cycles that include a 31st) goes to Block B like day 15.
String blockForDay(int n) => blockADays.contains(n) ? 'Block A' : 'Block B';

/// The farm's cycle containing [d], as (first day, last day): the calendar
/// halves of the month, 1st-15th and 16th-end of month (a 31st belongs to
/// the second half; February's ends on the 28th/29th).
/// Same rule as cycle_bounds() in backend/app/ml/cycle.py.
(DateTime, DateTime) cycleBounds(DateTime d) {
  if (d.day <= 15) {
    return (DateTime(d.year, d.month, 1), DateTime(d.year, d.month, 15));
  }
  // Day 0 of next month = last day of this month
  return (DateTime(d.year, d.month, 16), DateTime(d.year, d.month + 1, 0));
}

/// Same rule as weather_label() in backend/app/ml/cycle.py.
String _weatherLabel(int code, double windKmh, double rainMm) {
  if (rainMm >= _rainyMm) return 'Rainy';
  if (windKmh >= _windyKmh) return 'Windy';
  if (code == 0 || code == 1) return 'Sunny';
  return 'Cloudy';
}

// A day with at least this much sunshine reads as sunny, even with a shower
// (May-Nov 2026: 173 of 187 days had 6+ hours of sun, yet all had some rain).
const double _sunnyHours = 6.0;

// On screen, a day's total under this is not called a rain day: it reads
// Sunny or Cloudy, and from 1 mm the small amount is still mentioned.
const double _lightRainMm = 2.5;

/// One day's weather in words, from THAT day's own rain and sunshine:
/// "Heavy rain (17.8 mm)", "Rainy (6.0 mm)", "Sunny with light rain (3.0 mm)",
/// "Light rain (3.0 mm)", "Sunny, very light rain (2.0 mm)", "Sunny",
/// "Cloudy". [sunHours] is null when only the saved label and rain are known
/// (no internet). The cut-offs are the app's own grouping of the day's total.
String dayWeatherText(dynamic label, dynamic rainMm, [double? sunHours]) {
  final rain = rainMm is num ? rainMm.toDouble() : 0.0;
  final mm = '(${rain.toStringAsFixed(1)} mm)';
  final sunny = sunHours != null && sunHours >= _sunnyHours;
  if (rain >= 10) return 'Heavy rain $mm';
  if (rain >= 5) return 'Rainy $mm';
  if (rain >= _lightRainMm) {
    return sunny ? 'Sunny with light rain $mm' : 'Light rain $mm';
  }
  // Under 2.5 mm: described by the sky (older saved days were all 'Rainy')
  final String base;
  if (label == 'Windy') {
    base = 'Windy';
  } else if (sunHours != null) {
    base = sunny ? 'Sunny' : 'Cloudy';
  } else {
    base = (label == null || label == 'Rainy') ? 'Cloudy' : label.toString();
  }
  if (rain >= _rainyMm) return '$base, very light rain $mm';
  // Without sunshine data, say why a saved 'Rainy' day reads as Cloudy
  return sunHours == null && rain >= 0.1 ? '$base, almost no rain $mm' : base;
}

double _weatherWeight(String label, double rainMm) {
  if (label == 'Rainy') {
    final w = _rainStartWeight - _rainPenaltyPerMm * rainMm;
    return w < _rainMinWeight ? _rainMinWeight : w;
  }
  return _baseWeight[label]!;
}

String isoDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Each block's forecast cycle total (best model) from the newest finished run.
Future<Map<String, double>> latestBlockTotals() async {
  final runs = await supabase
      .from('forecast_runs')
      .select('results')
      .eq('status', 'done')
      .order('id', ascending: false)
      .limit(1);
  final list = List<Map<String, dynamic>>.from(runs);
  if (list.isEmpty) {
    throw const PlanException(
        'No forecast has been made yet. It is updated every morning at 6:00.');
  }
  final results = Map<String, dynamic>.from(list.first['results'] as Map);
  final totals = <String, double>{};
  for (final block in ['Block A', 'Block B']) {
    final r = results[block];
    if (r == null) {
      throw PlanException(
          'There are not enough saved harvest records for $block yet to plan a cycle.');
    }
    final res = Map<String, dynamic>.from(r as Map);
    final bestName = res['best_model'];
    final best = res.values.whereType<Map>().firstWhere(
          (m) => m['model'] == bestName,
          orElse: () => throw PlanException('The saved forecast for $block is incomplete.'),
        );
    final kg = (best['forecast_kg'] as num).toDouble();
    totals[block] = kg < 0 ? 0 : kg;
  }
  return totals;
}

/// Daily weather from Open-Meteo for [start] .. [end] (default 15 days).
Future<Map<String, Map<String, double>>> fetchDailyWeather(DateTime start,
    [DateTime? end]) async {
  end ??= start.add(const Duration(days: cycleLength - 1));
  try {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ));
    final resp = await dio.get(
      'https://api.open-meteo.com/v1/forecast',
      queryParameters: {
        'latitude': farmLat,
        'longitude': farmLon,
        'daily':
            'weather_code,precipitation_sum,temperature_2m_max,wind_speed_10m_max',
        'timezone': 'Asia/Manila',
        'start_date': isoDate(start),
        'end_date': isoDate(end),
      },
    );
    final daily = Map<String, dynamic>.from(resp.data['daily'] as Map);
    final times = List<String>.from(daily['time'] as List);
    double at(String key, int i) => ((daily[key] as List)[i] as num?)?.toDouble() ?? 0.0;
    return {
      for (var i = 0; i < times.length; i++)
        times[i]: {
          'code': at('weather_code', i),
          'rain': at('precipitation_sum', i),
          'temp': at('temperature_2m_max', i),
          'wind': at('wind_speed_10m_max', i),
        },
    };
  } on DioException {
    throw const PlanException(
        'Could not get the weather forecast. Please check the internet connection and try again.');
  }
}

/// Split each block's cycle total across its tap days by weather.
///
/// [start]..[end] are the days to plan (default: 15 days from [start]).
/// [anchor] is the first day of the farm's cycle (default: [start]); day
/// numbers, and so which block is tapped, count from it. When planning starts
/// part-way into a cycle, each block's total is scaled to the share of its
/// tap days that are still planned. Same as build_daily_plan() in Python.
List<Map<String, dynamic>> buildDailyPlan(DateTime start,
    Map<String, double> blockTotals, Map<String, Map<String, double>> weather,
    {DateTime? end, DateTime? anchor}) {
  // Whole-day arithmetic in UTC, so a timezone change can never skip a day
  DateTime day(DateTime d) => DateTime.utc(d.year, d.month, d.day);
  final s = day(start);
  final e = day(end ?? start.add(const Duration(days: cycleLength - 1)));
  final a = day(anchor ?? start);
  final cycleDays = e.difference(a).inDays + 1;

  final days = <Map<String, dynamic>>[];
  for (var i = 0; i <= e.difference(s).inDays; i++) {
    final d = s.add(Duration(days: i));
    final n = d.difference(a).inDays + 1;
    final w = weather[isoDate(d)];
    if (w == null) {
      throw PlanException('No weather forecast for ${isoDate(d)}.');
    }
    final label =
        _weatherLabel(w['code']!.round(), w['wind']!, w['rain'] ?? 0);
    days.add({
      'day': n,
      'date': isoDate(d),
      'block': blockForDay(n),
      'weather': label,
      'temperature': w['temp'],
      'rainfall': double.parse(w['rain']!.toStringAsFixed(2)),
      '_weight': _weatherWeight(label, w['rain']!),
    });
  }
  blockTotals.forEach((block, total) {
    final blockDays = days.where((x) => x['block'] == block).toList();
    if (blockDays.isEmpty) return;
    var allTapDays = 0;
    for (var n = 1; n <= cycleDays; n++) {
      if (blockForDay(n) == block) allTapDays++;
    }
    final share = total * blockDays.length / allTapDays;
    final weightSum =
        blockDays.fold<double>(0, (s, x) => s + (x['_weight'] as double));
    for (final x in blockDays) {
      x['predicted_yield'] = double.parse(
          (share * (x['_weight'] as double) / weightSum).toStringAsFixed(2));
    }
  });
  for (final x in days) {
    x.remove('_weight');
  }
  return days;
}

// One request per cycle half, remembered while the app is open
final Map<String, Future<Map<String, String>>> _dayWeatherCache = {};

/// The weather of one day at the farm in words, e.g. "Sunny with light rain
/// (2.2 mm)": what the weather service has for THAT date (past days: what
/// happened; today and the next ~2 weeks: the forecast). It is an estimate
/// for the farm's area, not a measurement at the farm.
Future<String> fetchDayWeather(DateTime day) async {
  final (start, end) = cycleBounds(day);
  final key = isoDate(start);
  final days = await (_dayWeatherCache[key] ??= () async {
    try {
      return await _fetchCycleDays(start, end);
    } catch (_) {
      _dayWeatherCache.remove(key); // try again next time
      rethrow;
    }
  }());
  final text = days[isoDate(day)];
  if (text == null) throw const PlanException('No weather data for this day.');
  return text;
}

Future<Map<String, String>> _fetchCycleDays(DateTime start, DateTime end) async {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final horizon = DateTime(today.year, today.month, today.day + 15);
  if (start.isAfter(horizon)) {
    throw const PlanException('No weather data for this day.');
  }
  if (end.isAfter(horizon)) end = horizon;
  // Recent days and the forecast: forecast service (keeps ~3 months).
  // Older: history archive, which can take ~15 s to wake up: be patient.
  final old = today.difference(end).inDays > 60;
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 40),
  ));
  Response<dynamic>? resp;
  for (var attempt = 0; resp == null; attempt++) {
    try {
      resp = await dio.get(
        old
            ? 'https://archive-api.open-meteo.com/v1/archive'
            : 'https://api.open-meteo.com/v1/forecast',
        queryParameters: {
          'latitude': farmLat,
          'longitude': farmLon,
          'daily': 'weather_code,precipitation_sum,wind_speed_10m_max,'
              'sunshine_duration',
          'timezone': 'Asia/Manila',
          'start_date': isoDate(start),
          'end_date': isoDate(end),
        },
      );
    } on DioException {
      if (attempt >= 2) rethrow; // three tries in total
      await Future<void>.delayed(Duration(seconds: 3 * (attempt + 1)));
    }
  }
  final daily = Map<String, dynamic>.from(resp.data['daily'] as Map);
  final dates = daily['time'] as List;
  final out = <String, String>{};
  for (var i = 0; i < dates.length; i++) {
    final code = ((daily['weather_code'] as List)[i] as num?)?.round();
    if (code == null) continue; // not available yet
    final rain =
        ((daily['precipitation_sum'] as List)[i] as num?)?.toDouble() ?? 0;
    final wind =
        ((daily['wind_speed_10m_max'] as List)[i] as num?)?.toDouble() ?? 0;
    final sunSeconds = (daily['sunshine_duration'] as List?)?[i] as num?;
    out[dates[i].toString()] = dayWeatherText(
        _weatherLabel(code, wind, rain), rain,
        sunSeconds == null ? null : sunSeconds / 3600);
  }
  return out;
}

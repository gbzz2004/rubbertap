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

// WMO weather codes (Open-Meteo) that mean drizzle / rain / showers / storm
const Set<int> _rainCodes = {
  51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99,
};

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

String _weatherLabel(int code, double windKmh) {
  if (_rainCodes.contains(code)) return 'Rainy';
  if (windKmh >= _windyKmh) return 'Windy';
  if (code == 0 || code == 1) return 'Sunny';
  return 'Cloudy';
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
    final label = _weatherLabel(w['code']!.round(), w['wind']!);
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

/// The real weather of one farm cycle, as one label plus a short reason.
class CycleWeather {
  final String label; // Sunny, Cloudy, Rainy or Windy
  final String reason; // e.g. "1-15 Jun: 15 of 15 days with rain (97 mm)"
  const CycleWeather(this.label, this.reason);
}

/// Labels a cycle from its daily weather, with the SAME rule used when Sir
/// Arnel's records were imported (see data/README.md): Rainy if at least half
/// the days had >= 1 mm of rain, else Windy if at least half had wind
/// >= 30 km/h, else Sunny if at least half were clear, else Cloudy.
CycleWeather labelCycleWeather(List<Map<String, double>> days, String period) {
  final n = days.length;
  final rainDays = days.where((d) => d['rain']! >= 1.0).length;
  final windyDays = days.where((d) => d['wind']! >= _windyKmh).length;
  final clearDays = days.where((d) => d['code']! <= 1).length;
  final mm = days.fold<double>(0, (s, d) => s + d['rain']!);
  final rainText =
      '$rainDays of $n days with rain (${mm.toStringAsFixed(0)} mm)';
  if (rainDays * 2 >= n) return CycleWeather('Rainy', '$period: $rainText');
  if (windyDays * 2 >= n) {
    return CycleWeather('Windy', '$period: $windyDays of $n windy days');
  }
  if (clearDays * 2 >= n) {
    return CycleWeather('Sunny', '$period: $clearDays of $n clear days, $rainText');
  }
  return CycleWeather('Cloudy', '$period: mostly cloudy, $rainText');
}

/// The real weather at the farm for the cycle containing [weighDate], from
/// its first day up to the weigh date (or today, if earlier). Uses Open-Meteo
/// (the same source as the calendar). Throws if it cannot be downloaded.
Future<CycleWeather> fetchCycleWeather(DateTime weighDate) async {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final (start, _) = cycleBounds(weighDate);
  var end = DateTime(weighDate.year, weighDate.month, weighDate.day);
  if (end.isAfter(today)) end = today;

  // Recent days: forecast service (keeps ~3 months). Older: history archive.
  final old = today.difference(end).inDays > 60;
  // The free history archive can take ~15 s to wake up after a quiet spell,
  // and farm signal is slow: be patient (measured 2026-11-10).
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 40),
  ));
  // The free service sometimes answers slowly: try twice before giving up
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
          'daily': 'weather_code,precipitation_sum,wind_speed_10m_max',
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
  final codes = daily['weather_code'] as List;
  final days = <Map<String, double>>[];
  for (var i = 0; i < codes.length; i++) {
    if (codes[i] == null) continue; // not available yet
    days.add({
      'code': (codes[i] as num).toDouble(),
      'rain': ((daily['precipitation_sum'] as List)[i] as num?)?.toDouble() ?? 0,
      'wind': ((daily['wind_speed_10m_max'] as List)[i] as num?)?.toDouble() ?? 0,
    });
  }
  if (days.isEmpty) throw const PlanException('No weather data for this cycle.');
  final period = start.month == end.month
      ? '${start.day}–${end.day} ${months[end.month - 1]}'
      : '${start.day} ${months[start.month - 1]} – ${end.day} ${months[end.month - 1]}';
  return labelCycleWeather(days, period);
}

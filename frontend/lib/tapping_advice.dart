// Tapping advice for the next tapping MORNING (not the weather right now).
//
// Uses Open-Meteo hourly data: the same free source as the calendar and the
// 15-day plan, so the app never says "fine" in one place and "rainy" in
// another. Used by the Weather tab and the Dashboard's Today card.
//
// The morning, in farm time (Asia/Manila):
//   01:00-03:59  night before: rain here can leave the bark wet
//   04:00-07:59  tapping
//   08:00-10:59  latex flow and collection
// These hours and thresholds are GENERAL GUIDANCE, not farm measurements.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'cycle_plan.dart' show farmLat, farmLon;
import 'theme.dart';

/// One hour of forecast.
class HourWeather {
  final int hour; // 0-23, farm time
  final double rainMm;
  final int rainChance; // 0-100 %
  final int code; // WMO weather code
  const HourWeather(this.hour, this.rainMm, this.rainChance, this.code);
}

enum AdviceLevel { good, caution, bad }

class TappingAdvice {
  final AdviceLevel level;
  final String title;
  final String text;
  const TappingAdvice(this.level, this.title, this.text);

  Color get color => switch (level) {
        AdviceLevel.good => AppColors.good,
        AdviceLevel.caution => AppColors.caution,
        AdviceLevel.bad => AppColors.alert,
      };
  Color get soft => switch (level) {
        AdviceLevel.good => AppColors.forestSoft,
        AdviceLevel.caution => AppColors.bronzeSoft,
        AdviceLevel.bad => AppColors.alertSoft,
      };
}

const _stormCodes = {95, 96, 99};

bool _wet(HourWeather h) => h.rainMm >= 0.5 || h.rainChance >= 70;

String _clock(int hour) {
  final h = hour % 12 == 0 ? 12 : hour % 12;
  return '$h ${hour < 12 ? 'AM' : 'PM'}';
}

/// The advice for one morning, from that day's hourly forecast.
/// [when] is "this morning" or "tomorrow morning".
TappingAdvice adviceForMorning(List<HourWeather> day, String when) {
  List<HourWeather> between(int from, int to) =>
      day.where((h) => h.hour >= from && h.hour < to).toList();
  final night = between(1, 4);
  final tapping = between(4, 8);
  final collect = between(8, 11);
  final later = between(11, 18);
  double mm(List<HourWeather> hs) => hs.fold(0.0, (s, h) => s + h.rainMm);

  String laterNote() {
    final firstLater = later.where(_wet).toList();
    return firstLater.isEmpty
        ? ''
        : ' Rain is expected later, from ${_clock(firstLater.first.hour)}.';
  }

  if ([...tapping, ...collect].any((h) => _stormCodes.contains(h.code))) {
    return TappingAdvice(AdviceLevel.bad, 'Do not tap $when',
        'Thunderstorms are expected during tapping hours. It is not safe to work under the trees.');
  }
  final tapRain = mm(tapping);
  if (tapRain >= 1.0 || tapping.where(_wet).length >= 2) {
    return TappingAdvice(AdviceLevel.bad, 'Not good for tapping $when',
        'Rain is expected while tapping (about ${tapRain.toStringAsFixed(1)} mm between 4 and 8 AM). '
        'Rain can wash out or dilute the latex. Better to wait for a dry morning.');
  }
  final wetCollect = collect.where(_wet).toList();
  if (wetCollect.isNotEmpty) {
    final from = wetCollect.first.hour;
    return TappingAdvice(AdviceLevel.caution, 'Tap early $when',
        'Dry while tapping, but rain is expected from ${_clock(from)}. '
        'Collect the latex before then.');
  }
  if (mm(night) >= 1.0) {
    return TappingAdvice(AdviceLevel.caution, 'Bark may be wet $when',
        'Rain is expected during the night (about ${mm(night).toStringAsFixed(1)} mm). '
        'Start tapping once the bark has dried.${laterNote()}');
  }
  return TappingAdvice(AdviceLevel.good, 'Good for tapping $when',
      'A dry morning is expected from 4 to 11 AM.${laterNote()}');
}

/// Advice for the next tapping morning: this morning until 8 AM, otherwise
/// tomorrow morning. Throws if the forecast cannot be downloaded.
Future<TappingAdvice> fetchTappingAdvice({DateTime? now}) async {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
  ));
  // The free service sometimes answers slowly: try twice before giving up
  Response<dynamic>? resp;
  for (var attempt = 0; resp == null; attempt++) {
    try {
      resp = await dio.get('https://api.open-meteo.com/v1/forecast',
          queryParameters: {
            'latitude': farmLat,
            'longitude': farmLon,
            'hourly': 'precipitation,precipitation_probability,weather_code',
            'timezone': 'Asia/Manila',
            'forecast_days': 2,
          });
    } on DioException {
      if (attempt >= 1) rethrow;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
  final hourly = Map<String, dynamic>.from(resp.data['hourly'] as Map);
  final times = List<String>.from(hourly['time'] as List);
  double num0(List l, int i) => (l[i] as num?)?.toDouble() ?? 0;

  // Farm time: the times come back as local Manila clock times
  final farmNow = (now ?? DateTime.now().toUtc()).toUtc().add(const Duration(hours: 8));
  final morningIsToday = farmNow.hour < 8;
  final target = morningIsToday ? farmNow : farmNow.add(const Duration(days: 1));
  final day =
      '${target.year}-${target.month.toString().padLeft(2, '0')}-${target.day.toString().padLeft(2, '0')}';

  final hours = <HourWeather>[];
  for (var i = 0; i < times.length; i++) {
    if (!times[i].startsWith(day)) continue;
    hours.add(HourWeather(
      int.parse(times[i].substring(11, 13)),
      num0(hourly['precipitation'] as List, i),
      num0(hourly['precipitation_probability'] as List, i).round(),
      num0(hourly['weather_code'] as List, i).round(),
    ));
  }
  if (hours.isEmpty) throw StateError('No hourly forecast for $day');
  return adviceForMorning(
      hours, morningIsToday ? 'this morning' : 'tomorrow morning');
}

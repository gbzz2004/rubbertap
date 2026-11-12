// Weather at the farm, now and hour by hour, from Open-Meteo.
//
// The ONE weather source for the whole app (the calendar, the plan, the
// tapping advice, the harvest form, the Weather tab and the rain alerts all
// use Open-Meteo), so no two screens can disagree. Free, no key.
//
// Weather codes are the WMO codes Open-Meteo returns; kindOf() turns them into
// the simple kinds the screens use: Clear, Clouds, Fog, Drizzle, Rain,
// Thunderstorm.

import 'package:dio/dio.dart';
import 'cycle_plan.dart' show farmLat, farmLon;

/// Rain in one hour from which the app says it is raining. The weather
/// service often labels an hour "drizzle" for a trace (0.1 mm) under a mostly
/// sunny sky; phone weather apps call that sunny, and so does RubberTap.
const double rainingMmPerHour = 0.5;

/// One hour of forecast at the farm (Manila clock time).
class FarmHour {
  final DateTime time;
  final double temp;
  final int rainChance; // 0-100 %
  final double rainMm;
  final int code;
  final double? cloud; // cloud cover %, if known
  const FarmHour(this.time, this.temp, this.rainChance, this.rainMm, this.code,
      [this.cloud]);
  String get kind => kindFor(code, rainMm, cloud);
}

/// The weather at the farm right now.
class FarmNow {
  final double temp;
  final double feelsLike;
  final double humidity; // %
  final double windKmh;
  final double rainMm; // rain in the current hour
  final int code;
  final double? cloud; // cloud cover %, if known
  const FarmNow(this.temp, this.feelsLike, this.humidity, this.windKmh,
      this.rainMm, this.code, [this.cloud]);
  String get kind => kindFor(code, rainMm, cloud);
  String get description => describeNow(code, rainMm, cloud);
}

/// True when the service's label says rain or drizzle but the amount in the
/// hour is too small to count as raining.
bool _onlyATrace(int code, double rainMm) {
  final k = kindOf(code);
  return (k == 'Rain' || k == 'Drizzle') && rainMm < rainingMmPerHour;
}

/// The kind the screens use: the service's label, except that a trace of
/// drizzle or rain is described by the sky instead (cloud cover).
String kindFor(int code, double rainMm, double? cloud) {
  if (!_onlyATrace(code, rainMm)) return kindOf(code);
  return (cloud != null && cloud < 50) ? 'Clear' : 'Clouds';
}

/// Plain words for right now, e.g. "Mostly sunny, a few drops (0.1 mm)".
String describeNow(int code, double rainMm, double? cloud) {
  if (!_onlyATrace(code, rainMm)) return describe(code);
  final String sky;
  if (cloud == null) {
    sky = 'Cloudy';
  } else if (cloud < 20) {
    sky = 'Sunny';
  } else if (cloud < 50) {
    sky = 'Mostly sunny';
  } else if (cloud < 85) {
    sky = 'Partly cloudy';
  } else {
    sky = 'Overcast';
  }
  return rainMm >= 0.05
      ? '$sky, a few drops (${rainMm.toStringAsFixed(1)} mm)'
      : sky;
}

class FarmWeather {
  final FarmNow now;
  final List<FarmHour> hours; // from the current hour on, 48 hours
  const FarmWeather(this.now, this.hours);
}

/// WMO weather code -> simple kind used by the screens.
String kindOf(int code) {
  if (code >= 95) return 'Thunderstorm';
  if ((code >= 61 && code <= 67) || (code >= 80 && code <= 82)) return 'Rain';
  if (code >= 51 && code <= 57) return 'Drizzle';
  if (code == 45 || code == 48) return 'Fog';
  if (code <= 1) return 'Clear';
  return 'Clouds';
}

/// WMO weather code -> plain words.
String describe(int code) {
  switch (code) {
    case 0:
      return 'Clear sky';
    case 1:
      return 'Mostly clear';
    case 2:
      return 'Partly cloudy';
    case 3:
      return 'Overcast';
    case 45:
    case 48:
      return 'Fog';
    case 51:
    case 53:
    case 55:
      return 'Drizzle';
    case 56:
    case 57:
      return 'Freezing drizzle';
    case 61:
      return 'Light rain';
    case 63:
      return 'Rain';
    case 65:
      return 'Heavy rain';
    case 80:
      return 'Light showers';
    case 81:
      return 'Showers';
    case 82:
      return 'Heavy showers';
    case 95:
      return 'Thunderstorm';
    case 96:
    case 99:
      return 'Thunderstorm with hail';
    default:
      return kindOf(code);
  }
}

/// Downloads the weather now and for the next 48 hours.
/// Patient (the free service can be slow to wake) and tries 3 times.
Future<FarmWeather> fetchFarmWeather() async {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 40),
  ));
  Response<dynamic>? resp;
  for (var attempt = 0; resp == null; attempt++) {
    try {
      resp = await dio.get('https://api.open-meteo.com/v1/forecast',
          queryParameters: {
            'latitude': farmLat,
            'longitude': farmLon,
            'current':
                'temperature_2m,apparent_temperature,relative_humidity_2m,'
                    'wind_speed_10m,precipitation,weather_code,cloud_cover',
            'hourly': 'temperature_2m,precipitation_probability,precipitation,'
                'weather_code,cloud_cover',
            'timezone': 'Asia/Manila',
            'forecast_days': 3,
          });
    } on DioException {
      if (attempt >= 2) rethrow;
      await Future<void>.delayed(Duration(seconds: 3 * (attempt + 1)));
    }
  }
  final data = resp.data as Map;
  double n(dynamic v) => (v as num?)?.toDouble() ?? 0;

  final c = Map<String, dynamic>.from(data['current'] as Map);
  final now = FarmNow(
    n(c['temperature_2m']),
    n(c['apparent_temperature']),
    n(c['relative_humidity_2m']),
    n(c['wind_speed_10m']),
    n(c['precipitation']),
    n(c['weather_code']).round(),
    (c['cloud_cover'] as num?)?.toDouble(),
  );

  // Hours from the current one on. Times are Manila clock times, compared
  // with the current time as given by the service (same clock).
  final nowTime = DateTime.parse(c['time'].toString());
  final thisHour = DateTime(nowTime.year, nowTime.month, nowTime.day, nowTime.hour);
  final h = Map<String, dynamic>.from(data['hourly'] as Map);
  final times = List<String>.from(h['time'] as List);
  final hours = <FarmHour>[];
  for (var i = 0; i < times.length; i++) {
    final t = DateTime.parse(times[i]);
    if (t.isBefore(thisHour)) continue;
    hours.add(FarmHour(
      t,
      n((h['temperature_2m'] as List)[i]),
      n((h['precipitation_probability'] as List)[i]).round(),
      n((h['precipitation'] as List)[i]),
      n((h['weather_code'] as List)[i]).round(),
      ((h['cloud_cover'] as List?)?[i] as num?)?.toDouble(),
    ));
    if (hours.length == 48) break;
  }
  return FarmWeather(now, hours);
}

// Rain alert rules on hourly Open-Meteo data (lib/rain_alerts.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/farm_weather.dart';
import 'package:frontend/rain_alerts.dart';

/// Now (dry, cloudy unless given) and the next 24 hours from 6 AM.
FarmWeather weather({
  int nowCode = 3,
  double nowRain = 0,
  Map<int, int> chance = const {},
  Map<int, int> code = const {},
}) =>
    FarmWeather(
      FarmNow(26, 28, 85, 8, nowRain, nowCode),
      [
        for (var i = 0; i < 24; i++)
          FarmHour(DateTime(2026, 11, 10, 6 + i), 27, chance[i] ?? 10, 0,
              code[i] ?? 3),
      ],
    );

void main() {
  test('dry day: no alert', () {
    expect(RainAlertService.decide(weather()), isNull);
  });

  test('thunderstorm now beats everything', () {
    final a = RainAlertService.decide(weather(nowCode: 95, chance: {1: 90}))!;
    expect(a.type, 'thunder');
    expect(a.title, 'Thunderstorm at the farm');
  });

  test('thunderstorm later, with its hour', () {
    final a = RainAlertService.decide(weather(code: {4: 95}))!;
    expect(a.type, 'thunder');
    expect(a.title, contains('10 AM'));
  });

  test('raining now', () {
    expect(RainAlertService.decide(weather(nowCode: 61))!.type, 'now');
    expect(RainAlertService.decide(weather(nowRain: 0.5))!.type, 'now');
  });

  test('rain likely at a given hour (hourly, not 3-hourly)', () {
    final a = RainAlertService.decide(weather(chance: {5: 75}))!;
    expect(a.type, 'likely');
    expect(a.title, 'Rain is coming around 11 AM');
    expect(a.body, contains('75%'));
  });

  test('rain only possible', () {
    expect(RainAlertService.decide(weather(chance: {2: 40}))!.type, 'possible');
  });

  test('only the next 12 hours count', () {
    expect(RainAlertService.decide(weather(chance: {15: 90})), isNull);
  });

  test('weather codes map to simple kinds', () {
    expect(kindOf(0), 'Clear');
    expect(kindOf(3), 'Clouds');
    expect(kindOf(53), 'Drizzle');
    expect(kindOf(63), 'Rain');
    expect(kindOf(81), 'Rain');
    expect(kindOf(95), 'Thunderstorm');
  });
}

// The phone's 15-day plan (lib/cycle_plan.dart) must match the backend's
// (backend/app/ml/cycle.py). The expected values below were produced by
// build_daily_plan() in Python from the same weather and totals.

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/cycle_plan.dart';

void main() {
  test('daily plan matches the Python backend exactly', () {
    final start = DateTime(2026, 11, 10);
    const codes = [0, 1, 3, 61, 63, 2, 95, 0, 80, 45, 1, 65, 3, 0, 51];
    const rain = [0, 0, 0, 2.5, 12.0, 0, 30.0, 0, 6.2, 0, 0, 18.4, 0, 0, 0.8];
    const wind = [10, 12, 35, 8, 15, 9, 40, 5, 22, 11, 31, 14, 7, 6, 12];
    const temp = [31, 32, 30, 28, 27, 31, 26, 33, 29, 30, 32, 27, 30, 31, 29];
    final weather = {
      for (var i = 0; i < 15; i++)
        isoDate(start.add(Duration(days: i))): {
          'code': codes[i].toDouble(),
          'rain': rain[i].toDouble(),
          'temp': temp[i].toDouble(),
          'wind': wind[i].toDouble(),
        },
    };

    final days = buildDailyPlan(
        start, {'Block A': 37.89, 'Block B': 43.57}, weather);

    const expected = [
      ['2026-11-10', 'Block A', 'Sunny', 7.03],
      ['2026-11-11', 'Block B', 'Sunny', 6.21],
      ['2026-11-12', 'Block A', 'Windy', 5.98],
      ['2026-11-13', 'Block B', 'Rainy', 4.97],
      ['2026-11-14', 'Block A', 'Rainy', 4.29],
      ['2026-11-15', 'Block B', 'Cloudy', 5.9],
      ['2026-11-16', 'Block A', 'Rainy', 2.81],
      ['2026-11-17', 'Block B', 'Sunny', 6.21],
      ['2026-11-18', 'Block A', 'Rainy', 5.11],
      ['2026-11-19', 'Block B', 'Cloudy', 5.9],
      ['2026-11-20', 'Block A', 'Windy', 5.98],
      ['2026-11-21', 'Block B', 'Rainy', 2.99],
      ['2026-11-22', 'Block A', 'Cloudy', 6.68],
      ['2026-11-23', 'Block B', 'Sunny', 6.21],
      ['2026-11-24', 'Block B', 'Rainy', 5.18],
    ];

    expect(days.length, 15);
    for (var i = 0; i < 15; i++) {
      expect(days[i]['date'], expected[i][0], reason: 'day ${i + 1} date');
      expect(days[i]['block'], expected[i][1], reason: 'day ${i + 1} block');
      expect(days[i]['weather'], expected[i][2], reason: 'day ${i + 1} weather');
      expect(days[i]['predicted_yield'], expected[i][3],
          reason: 'day ${i + 1} kg');
    }
  });

  test('daily amounts add up to each block\'s forecast total', () {
    final start = DateTime(2026, 11, 10);
    final weather = {
      for (var i = 0; i < 15; i++)
        isoDate(start.add(Duration(days: i))): {
          'code': (i.isEven ? 61 : 0).toDouble(),
          'rain': (i * 2).toDouble(),
          'temp': 30.0,
          'wind': 10.0,
        },
    };
    final days = buildDailyPlan(
        start, {'Block A': 40.0, 'Block B': 44.0}, weather);
    double sum(String b) => days
        .where((d) => d['block'] == b)
        .fold(0.0, (s, d) => s + (d['predicted_yield'] as double));
    expect(sum('Block A'), closeTo(40.0, 0.05));
    expect(sum('Block B'), closeTo(44.0, 0.05));
  });
}

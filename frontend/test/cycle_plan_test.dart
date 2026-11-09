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

  test('cycles follow the 15th / 30th weigh dates (same as Python)', () {
    (DateTime, DateTime) b(int y, int m, int d) => cycleBounds(DateTime(y, m, d));
    // Sir Arnel's real weigh dates are cycle ends
    for (final w in ['2026-05-15', '2026-05-30', '2026-06-30', '2026-09-15',
        '2026-10-15', '2026-10-30']) {
      final d = DateTime.parse(w);
      expect(cycleBounds(d).$2, d, reason: w);
    }
    expect(b(2026, 11, 10), (DateTime(2026, 10, 31), DateTime(2026, 11, 15)));
    expect(b(2026, 11, 20), (DateTime(2026, 11, 16), DateTime(2026, 11, 30)));
    expect(b(2026, 12, 31), (DateTime(2026, 12, 31), DateTime(2027, 1, 15)));
    expect(b(2027, 1, 5), (DateTime(2026, 12, 31), DateTime(2027, 1, 15)));
    expect(b(2027, 2, 20), (DateTime(2027, 2, 16), DateTime(2027, 2, 28)));
    expect(b(2027, 3, 3), (DateTime(2027, 3, 1), DateTime(2027, 3, 15)));
    expect(b(2028, 2, 20), (DateTime(2028, 2, 16), DateTime(2028, 2, 29)));

    // Three years: every day in exactly one cycle, no gaps, 13-16 days long
    var d = DateTime(2026, 1, 1);
    (DateTime, DateTime)? prev;
    while (d.isBefore(DateTime(2029, 1, 1))) {
      final (s, e) = cycleBounds(d);
      expect(!d.isBefore(s) && !d.isAfter(e), true, reason: '$d');
      final len = DateTime.utc(e.year, e.month, e.day)
              .difference(DateTime.utc(s.year, s.month, s.day))
              .inDays +
          1;
      expect(len >= 13 && len <= 16, true, reason: '$s..$e');
      if (prev != null && (s, e) != prev) {
        expect(DateTime(s.year, s.month, s.day),
            DateTime(prev.$2.year, prev.$2.month, prev.$2.day + 1),
            reason: 'gap before $s');
      }
      prev = (s, e);
      d = DateTime(d.year, d.month, d.day + 1);
    }
  });

  test('partial cycle is scaled like the Python version', () {
    final start = DateTime(2026, 10, 31);
    final weather = {
      for (var i = 0; i < 16; i++)
        isoDate(DateTime(2026, 10, 31 + i)): {
          'code': 0.0, 'rain': 0.0, 'temp': 30.0, 'wind': 5.0,
        },
    };
    final full = buildDailyPlan(start, {'Block A': 60, 'Block B': 45}, weather,
        end: DateTime(2026, 11, 15));
    expect(full.where((x) => x['block'] == 'Block A').length, 7);
    expect(full.where((x) => x['block'] == 'Block B').length, 9);
    final part = buildDailyPlan(
        DateTime(2026, 11, 14), {'Block A': 60, 'Block B': 45}, weather,
        end: DateTime(2026, 11, 15), anchor: start);
    expect(part.map((x) => x['day']).toList(), [15, 16]);
    expect(part.map((x) => x['block']).toSet(), {'Block B'});
    expect(part.fold<double>(0, (s, x) => s + (x['predicted_yield'] as double)),
        closeTo(10.0, 0.05));
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

// The tapping advice must follow the rules in lib/tapping_advice.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/tapping_advice.dart';

/// A day of hourly forecast: dry unless [rain] gives mm for some hours.
List<HourWeather> day({Map<int, double> rain = const {}, Map<int, int> code = const {}}) => [
      for (var h = 0; h < 24; h++)
        HourWeather(h, rain[h] ?? 0, (rain[h] ?? 0) > 0 ? 80 : 10, code[h] ?? 1),
    ];

void main() {
  test('dry morning is good', () {
    final a = adviceForMorning(day(), 'tomorrow morning');
    expect(a.level, AdviceLevel.good);
    expect(a.title, 'Good for tapping tomorrow morning');
  });

  test('rain while tapping is not good', () {
    final a = adviceForMorning(day(rain: {5: 1.2, 6: 2.0}), 'tomorrow morning');
    expect(a.level, AdviceLevel.bad);
    expect(a.text, contains('3.2 mm'));
  });

  test('rain only at collection time: tap early', () {
    final a = adviceForMorning(day(rain: {9: 3.0, 10: 4.0}), 'this morning');
    expect(a.level, AdviceLevel.caution);
    expect(a.title, 'Tap early this morning');
    expect(a.text, contains('9 AM'));
  });

  test('rain overnight: bark may be wet', () {
    final a = adviceForMorning(day(rain: {2: 3.0}), 'tomorrow morning');
    expect(a.level, AdviceLevel.caution);
    expect(a.title, startsWith('Bark may be wet'));
  });

  test('thunderstorm during the morning: do not tap', () {
    final a = adviceForMorning(day(code: {9: 95}), 'tomorrow morning');
    expect(a.level, AdviceLevel.bad);
    expect(a.title, 'Do not tap tomorrow morning');
  });

  test('afternoon rain is mentioned but the morning is still good', () {
    final a = adviceForMorning(day(rain: {14: 5.0}), 'tomorrow morning');
    expect(a.level, AdviceLevel.good);
    expect(a.text, contains('from 2 PM'));
  });
}

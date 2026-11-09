import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../main.dart';

class TappingCycleScreen extends StatefulWidget {
  const TappingCycleScreen({super.key});

  @override
  State<TappingCycleScreen> createState() => _TappingCycleScreenState();
}

class _TappingCycleScreenState extends State<TappingCycleScreen> {
  bool _isLoading = true;
  Map<String, dynamic>? _activeCycle;
  List<Map<String, dynamic>> _dailyPredictions = [];

  static const double _farmLat = 7.762639;
  static const double _farmLon = 122.567028;
  static const String _weatherApiKey = 'b4bf1e412a554e1efae968eda1f8b25e';

  // Tapping pattern: Block A on odd days (1,3,5,7,9,11,13)
  // Block B on even days + day 15 (2,4,6,8,10,12,14,15)
  String _getBlockForDay(int day) {
    if ([1, 3, 5, 7, 9, 11, 13].contains(day)) return 'Block A';
    return 'Block B';
  }

  @override
  void initState() {
    super.initState();
    _fetchActiveCycle();
  }

  Future<void> _fetchActiveCycle() async {
    setState(() => _isLoading = true);
    try {
      final cycles = await supabase
          .from('tapping_cycles')
          .select()
          .eq('status', 'active')
          .order('created_at', ascending: false)
          .limit(1);

      final cycleList = List<Map<String, dynamic>>.from(cycles);

      if (cycleList.isNotEmpty) {
        final cycle = cycleList.first;
        final predictions = await supabase
            .from('daily_predictions')
            .select()
            .eq('cycle_id', cycle['id'])
            .order('tap_date', ascending: true);

        setState(() {
          _activeCycle = cycle;
          _dailyPredictions = List<Map<String, dynamic>>.from(predictions);
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<List<Map<String, dynamic>>> _fetchWeatherForecast() async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ));
      final response = await dio.get(
        'https://api.openweathermap.org/data/2.5/forecast',
        queryParameters: {
          'lat': _farmLat,
          'lon': _farmLon,
          'appid': _weatherApiKey,
          'units': 'metric',
          'cnt': 40, // 5 days of 3-hour forecasts
        },
      );
      return List<Map<String, dynamic>>.from(response.data['list']);
    } catch (e) {
      return [];
    }
  }

  String _getWeatherForDate(List<Map<String, dynamic>> forecasts, DateTime date) {
    for (var forecast in forecasts) {
      final dt = DateTime.fromMillisecondsSinceEpoch(forecast['dt'] * 1000);
      if (dt.year == date.year && dt.month == date.month && dt.day == date.day) {
        final main = forecast['weather'][0]['main'].toString().toLowerCase();
        if (main.contains('rain') || main.contains('drizzle')) return 'Rainy';
        if (main.contains('cloud')) return 'Cloudy';
        if (main.contains('clear')) return 'Sunny';
        if (main.contains('wind')) return 'Windy';
        return 'Cloudy';
      }
    }
    return 'Sunny'; // Default if no forecast available
  }

  double _predictYield(String weather, String block, double baseYield) {
    // Simple yield prediction based on weather
    // Will be replaced by real ML model later
    double multiplier = 1.0;
    switch (weather) {
      case 'Sunny':
        multiplier = 1.0;
        break;
      case 'Cloudy':
        multiplier = 0.95;
        break;
      case 'Rainy':
        multiplier = 0.75;
        break;
      case 'Windy':
        multiplier = 0.85;
        break;
    }
    return baseYield * multiplier;
  }

  Future<void> _startNewCycle() async {
    final startDate = DateTime.now();
    final endDate = startDate.add(const Duration(days: 14));

    try {
      // Show loading
      setState(() => _isLoading = true);

      // Get base yield from recent logs
      final logs = await supabase
          .from('production_logs')
          .select()
          .order('date', ascending: false)
          .limit(10);
      final logList = List<Map<String, dynamic>>.from(logs);

      double baseYieldA = 45.0;
      double baseYieldB = 50.0;

      if (logList.isNotEmpty) {
        final aLogs = logList.where((l) => l['block'] == 'Block A').toList();
        final bLogs = logList.where((l) => l['block'] == 'Block B').toList();
        if (aLogs.isNotEmpty) {
          baseYieldA = aLogs.fold(0.0, (sum, l) => sum + (l['yield_kg'] as num)) /
              aLogs.length / 7; // Per tap day
        }
        if (bLogs.isNotEmpty) {
          baseYieldB = bLogs.fold(0.0, (sum, l) => sum + (l['yield_kg'] as num)) /
              bLogs.length / 8; // Per tap day
        }
      }

      // Fetch weather forecast
      final forecasts = await _fetchWeatherForecast();

      // Create new cycle
      final cycleResponse = await supabase
          .from('tapping_cycles')
          .insert({
            'start_date': startDate.toIso8601String().substring(0, 10),
            'end_date': endDate.toIso8601String().substring(0, 10),
            'status': 'active',
          })
          .select()
          .single();

      final cycleId = cycleResponse['id'];

      // Generate daily predictions
      List<Map<String, dynamic>> predictions = [];
      for (int day = 1; day <= 15; day++) {
        final tapDate = startDate.add(Duration(days: day - 1));
        final block = _getBlockForDay(day);
        final weather = _getWeatherForDate(forecasts, tapDate);
        final baseYield = block == 'Block A' ? baseYieldA : baseYieldB;
        final predictedYield = _predictYield(weather, block, baseYield);

        predictions.add({
          'cycle_id': cycleId,
          'tap_date': tapDate.toIso8601String().substring(0, 10),
          'block': block,
          'predicted_yield': double.parse(predictedYield.toStringAsFixed(2)),
          'weather': weather,
        });
      }

      await supabase.from('daily_predictions').insert(predictions);
      await _fetchActiveCycle();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('New 15-day cycle started!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _recordActualYield(Map<String, dynamic> prediction) async {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Record Yield — ${prediction['block']}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Date: ${prediction['tap_date']}'),
            Text('Predicted: ${prediction['predicted_yield']} kg'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Actual Yield (kg)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final yield_kg = double.tryParse(controller.text);
              if (yield_kg == null) return;
              Navigator.pop(context);
              try {
                await supabase
                    .from('daily_predictions')
                    .update({'actual_yield': yield_kg})
                    .eq('id', prediction['id']);
                await _fetchActiveCycle();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Yield recorded!'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
                  );
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _completeCycle() async {
    if (_activeCycle == null) return;

    // Calculate totals
    final aTotal = _dailyPredictions
        .where((p) => p['block'] == 'Block A' && p['actual_yield'] != null)
        .fold(0.0, (sum, p) => sum + (p['actual_yield'] as num));
    final bTotal = _dailyPredictions
        .where((p) => p['block'] == 'Block B' && p['actual_yield'] != null)
        .fold(0.0, (sum, p) => sum + (p['actual_yield'] as num));

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Complete Cycle'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Are you sure you want to complete this cycle?'),
            const SizedBox(height: 12),
            Text('Block A Total: ${aTotal.toStringAsFixed(1)} kg'),
            Text('Block B Total: ${bTotal.toStringAsFixed(1)} kg'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await supabase
                    .from('tapping_cycles')
                    .update({
                      'status': 'completed',
                      'block_a_total_yield': aTotal,
                      'block_b_total_yield': bTotal,
                    })
                    .eq('id', _activeCycle!['id']);

                // Also log to production_logs
                if (aTotal > 0) {
                  await supabase.from('production_logs').insert({
                    'date': _activeCycle!['end_date'],
                    'block': 'Block A',
                    'yield_kg': aTotal,
                    'weather': 'Cycle',
                    'notes': '15-day cycle total',
                  });
                }
                if (bTotal > 0) {
                  await supabase.from('production_logs').insert({
                    'date': _activeCycle!['end_date'],
                    'block': 'Block B',
                    'yield_kg': bTotal,
                    'weather': 'Cycle',
                    'notes': '15-day cycle total',
                  });
                }

                setState(() => _activeCycle = null);
                await _fetchActiveCycle();

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Cycle completed!'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
                  );
                }
              }
            },
            child: const Text('Complete'),
          ),
        ],
      ),
    );
  }

  Color _getWeatherColor(String weather) {
    switch (weather) {
      case 'Sunny': return Colors.orange;
      case 'Cloudy': return Colors.grey;
      case 'Rainy': return Colors.blue;
      case 'Windy': return Colors.teal;
      default: return Colors.grey;
    }
  }

  IconData _getWeatherIcon(String weather) {
    switch (weather) {
      case 'Sunny': return Icons.wb_sunny;
      case 'Cloudy': return Icons.cloud;
      case 'Rainy': return Icons.umbrella;
      case 'Windy': return Icons.air;
      default: return Icons.wb_sunny;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tapping Cycle'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchActiveCycle,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _activeCycle == null
              ? _buildNoCycleView()
              : _buildActiveCycleView(),
    );
  }

  Widget _buildNoCycleView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.calendar_today, size: 80, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'No Active Tapping Cycle',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Start a new 15-day cycle to get\ndaily yield predictions.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: _startNewCycle,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start New Cycle'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveCycleView() {
    final aTotal = _dailyPredictions
        .where((p) => p['block'] == 'Block A')
        .fold(0.0, (sum, p) => sum + (p['predicted_yield'] as num));
    final bTotal = _dailyPredictions
        .where((p) => p['block'] == 'Block B')
        .fold(0.0, (sum, p) => sum + (p['predicted_yield'] as num));

    final aActual = _dailyPredictions
        .where((p) => p['block'] == 'Block A' && p['actual_yield'] != null)
        .fold(0.0, (sum, p) => sum + (p['actual_yield'] as num));
    final bActual = _dailyPredictions
        .where((p) => p['block'] == 'Block B' && p['actual_yield'] != null)
        .fold(0.0, (sum, p) => sum + (p['actual_yield'] as num));

    return Column(
      children: [
        // Cycle Header
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.white,
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Active Cycle',
                          style: TextStyle(color: Colors.grey, fontSize: 12)),
                      Text(
                        '${_activeCycle!['start_date']} → ${_activeCycle!['end_date']}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ],
                  ),
                  ElevatedButton(
                    onPressed: _completeCycle,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                    ),
                    child: const Text('Complete Cycle'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _CycleStat(
                      label: 'Block A Predicted',
                      value: '${aTotal.toStringAsFixed(1)} kg',
                      subValue: aActual > 0
                          ? 'Actual: ${aActual.toStringAsFixed(1)} kg'
                          : null,
                      color: Colors.green,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _CycleStat(
                      label: 'Block B Predicted',
                      value: '${bTotal.toStringAsFixed(1)} kg',
                      subValue: bActual > 0
                          ? 'Actual: ${bActual.toStringAsFixed(1)} kg'
                          : null,
                      color: Colors.blue,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Daily Calendar
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _dailyPredictions.length,
            itemBuilder: (context, index) {
              final prediction = _dailyPredictions[index];
              final isBlockA = prediction['block'] == 'Block A';
              final hasActual = prediction['actual_yield'] != null;
              final today = DateTime.now().toIso8601String().substring(0, 10);
              final isToday = prediction['tap_date'] == today;

              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: isToday
                      ? const BorderSide(color: Color(0xFF2E7D32), width: 2)
                      : BorderSide.none,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      // Day number
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: isBlockA
                              ? Colors.green.withValues(alpha: 0.1)
                              : Colors.blue.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Text(
                            'D${index + 1}',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: isBlockA ? Colors.green : Colors.blue,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),

                      // Block and date
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: isBlockA
                                        ? Colors.green.withValues(alpha: 0.1)
                                        : Colors.blue.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    prediction['block'],
                                    style: TextStyle(
                                      color: isBlockA ? Colors.green : Colors.blue,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                if (isToday) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF2E7D32),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: const Text(
                                      'TODAY',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              prediction['tap_date'],
                              style: const TextStyle(
                                  color: Colors.grey, fontSize: 12),
                            ),
                          ],
                        ),
                      ),

                      // Weather
                      Column(
                        children: [
                          Icon(
                            _getWeatherIcon(prediction['weather'] ?? 'Sunny'),
                            color: _getWeatherColor(prediction['weather'] ?? 'Sunny'),
                            size: 20,
                          ),
                          Text(
                            prediction['weather'] ?? 'Sunny',
                            style: const TextStyle(fontSize: 10, color: Colors.grey),
                          ),
                        ],
                      ),
                      const SizedBox(width: 12),

                      // Yield prediction
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${prediction['predicted_yield']} kg',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: Color(0xFF2E7D32),
                            ),
                          ),
                          if (hasActual)
                            Text(
                              'Actual: ${prediction['actual_yield']} kg',
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey),
                            )
                          else
                            GestureDetector(
                              onTap: () => _recordActualYield(prediction),
                              child: const Text(
                                'Record actual',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.blue,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CycleStat extends StatelessWidget {
  final String label;
  final String value;
  final String? subValue;
  final Color color;

  const _CycleStat({
    required this.label,
    required this.value,
    required this.color,
    this.subValue,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          Text(
            value,
            style: TextStyle(
                fontWeight: FontWeight.bold, fontSize: 16, color: color),
          ),
          if (subValue != null)
            Text(subValue!,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
    );
  }
}
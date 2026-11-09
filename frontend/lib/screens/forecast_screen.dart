import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:fl_chart/fl_chart.dart';
import '../main.dart';
import '../theme.dart';

double _num(dynamic v) => (v as num).toDouble();

/// Plain-language description of one forecasting method.
class _ModelInfo {
  final String friendlyName;
  final String howItWorks;
  final String looksAt;
  final IconData icon;

  const _ModelInfo({
    required this.friendlyName,
    required this.howItWorks,
    required this.looksAt,
    required this.icon,
  });
}

/// One finished forecast run, plus the farm's own numbers for comparison.
class _ForecastData {
  final Map<String, dynamic> api;
  final double? lastKg;
  final String? lastDate;
  final double? avgKg;
  final DateTime fetchedAt;

  const _ForecastData({
    required this.api,
    required this.lastKg,
    required this.lastDate,
    required this.avgKg,
    required this.fetchedAt,
  });
}

class ForecastScreen extends StatefulWidget {
  const ForecastScreen({super.key});

  @override
  State<ForecastScreen> createState() => _ForecastScreenState();
}

class _ForecastScreenState extends State<ForecastScreen> {
  // 10.0.2.2 = your PC's localhost as seen from the Android emulator.
  // Override with --dart-define=API_URL=... (phone over USB, or Render later).
  static const String _apiBaseUrl =
      String.fromEnvironment('API_URL', defaultValue: 'http://10.0.2.2:8000');

  // Results are remembered while the app is open, so tapping the tab again
  // shows them instantly instead of re-training for a minute.
  static final Map<String, _ForecastData> _cache = {};
  static final Map<String, Future<_ForecastData>> _inFlight = {};
  static const Duration _cacheLife = Duration(minutes: 30);

  // Keys must match the FastAPI response
  static const List<String> _modelKeys = [
    'sarima',
    'lstm',
    'sarima_lstm',
    'sarima_lgbm',
    'random_forest',
  ];
  static const List<String> _chartLabels = [
    'Seasonal',
    'Learning',
    'Seas.+Learn',
    'Seas.+Trees',
    'Forest',
  ];

  // Keyed by the model name the backend returns
  static const Map<String, _ModelInfo> _info = {
    'SARIMA': _ModelInfo(
      friendlyName: 'Seasonal Pattern',
      howItWorks:
          'Looks at how your harvests rose and fell in the past, including seasons that repeat, and carries that pattern forward into the next cycle.',
      looksAt: 'Your past harvest totals and how they change over the year.',
      icon: Icons.show_chart,
    ),
    'LSTM': _ModelInfo(
      friendlyName: 'Learning Program',
      howItWorks:
          'A computer program that studies your past harvests, the time of year and the weather, and finds patterns on its own. A bit like an experienced farmer who remembers many seasons.',
      looksAt: 'Past harvests, the time of year and the weather.',
      icon: Icons.psychology,
    ),
    'SARIMA+LSTM': _ModelInfo(
      friendlyName: 'Seasonal + Learning Program',
      howItWorks:
          'Works in two steps. First it follows the seasonal pattern of your harvests. Then a learning program looks at where that pattern was wrong in the past and corrects for it.',
      looksAt:
          'Past harvests and seasons first, then its own past mistakes and the time of year.',
      icon: Icons.layers,
    ),
    'SARIMA+LightGBM': _ModelInfo(
      friendlyName: 'Seasonal + Decision Trees',
      howItWorks:
          'Works in two steps. First it follows the seasonal pattern of your harvests. Then a set of simple yes-or-no questions (like "was it a rainy month?") adjusts for what the pattern missed.',
      looksAt:
          'Past harvests and seasons first, then the time of year, the weather and the last two cycles.',
      icon: Icons.account_tree,
    ),
    'Random Forest': _ModelInfo(
      friendlyName: 'Decision Forest',
      howItWorks:
          'Asks many small yes-or-no questions about past harvests, such as the month, the weather and the last cycle\'s result, then averages all the answers.',
      looksAt: 'Past harvests, the time of year, the weather and recent cycles.',
      icon: Icons.forest,
    ),
  };

  String _selectedBlock = 'Block A';
  bool _isLoading = true;
  String? _error;
  _ForecastData? _data;

  @override
  void initState() {
    super.initState();
    // Run automatically as soon as the screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  // ---------------------------------------------------------------- loading

  Future<_ForecastData> _fetchForecast(String block) async {
    try {
      final dio = Dio(BaseOptions(
        baseUrl: _apiBaseUrl,
        connectTimeout: const Duration(seconds: 10),
        // Training 5 models can take a while
        receiveTimeout: const Duration(seconds: 120),
      ));
      // periods: 1 = the next 15-day cycle (each record is a 15-day total)
      final response = await dio
          .post('/forecast/run', data: {'block': block, 'periods': 1});
      final api = Map<String, dynamic>.from(response.data);

      // The farm's own numbers, used to explain the forecast in plain words
      double? lastKg;
      String? lastDate;
      double? avgKg;
      try {
        final logs = await supabase
            .from('production_logs')
            .select('date, yield_kg')
            .eq('block', block)
            .order('date', ascending: false);
        final list = List<Map<String, dynamic>>.from(logs);
        if (list.isNotEmpty) {
          lastKg = _num(list.first['yield_kg']);
          lastDate = list.first['date'].toString();
          avgKg = list.fold<double>(0, (s, l) => s + _num(l['yield_kg'])) /
              list.length;
        }
      } catch (_) {
        // The comparison with past harvests is a bonus; ignore failures.
      }

      final data = _ForecastData(
        api: api,
        lastKg: lastKg,
        lastDate: lastDate,
        avgKg: avgKg,
        fetchedAt: DateTime.now(),
      );
      _cache[block] = data;
      return data;
    } finally {
      _inFlight.remove(block);
    }
  }

  Future<void> _load({bool force = false}) async {
    final block = _selectedBlock;
    final cached = _cache[block];

    if (!force &&
        cached != null &&
        DateTime.now().difference(cached.fetchedAt) < _cacheLife) {
      setState(() {
        _data = cached;
        _error = null;
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _data = null;
      _error = null;
      _isLoading = true;
    });

    try {
      // If a run for this block is already going (user left and came back),
      // wait for it instead of starting a second one.
      final Future<_ForecastData> future =
          (!force && _inFlight.containsKey(block))
              ? _inFlight[block]!
              : (_inFlight[block] = _fetchForecast(block));
      final data = await future;
      if (!mounted || _selectedBlock != block) return;
      setState(() {
        _data = data;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || _selectedBlock != block) return;
      setState(() {
        _error = _friendlyError(e);
        _isLoading = false;
      });
    }
  }

  String _friendlyError(Object e) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map && data['detail'] != null) {
        final detail = data['detail'].toString();
        if (detail.contains('Not enough data')) {
          return 'There are not enough saved harvest records for this block yet. Add more records in the Production tab, then try again.';
        }
        return detail;
      }
      if (e.response == null) {
        return 'Cannot reach the forecast server. Please make sure it is running and try again.';
      }
      return 'The forecast server had a problem (code ${e.response?.statusCode}).';
    }
    return 'Something went wrong: $e';
  }

  // ---------------------------------------------------------- plain language

  bool _wasChecked(Map<String, dynamic> m) =>
      _num(m['mae']) != 0 || _num(m['rmse']) != 0 || _num(m['r2']) != 0;

  String _reliabilityLabel(Map<String, dynamic> m) {
    if (!_wasChecked(m)) return 'Not enough history to check';
    final r2 = _num(m['r2']);
    if (r2 >= 0.8) return 'Closely matched past harvests';
    if (r2 >= 0.5) return 'Fairly close to past harvests';
    if (r2 > 0) return 'Rough guide only';
    return 'Not reliable yet';
  }

  Color _reliabilityColor(Map<String, dynamic> m) {
    if (!_wasChecked(m)) return AppColors.inkFaint;
    final r2 = _num(m['r2']);
    if (r2 >= 0.8) return AppColors.good;
    if (r2 >= 0.5) return AppColors.caution;
    if (r2 > 0) return AppColors.bronze;
    return AppColors.alert;
  }

  _ModelInfo _infoFor(String name) =>
      _info[name] ??
      _ModelInfo(
        friendlyName: name,
        howItWorks: 'A forecasting method.',
        looksAt: 'Your past harvests.',
        icon: Icons.auto_graph,
      );

  String? _compareText(double forecast, _ForecastData d) {
    final last = d.lastKg;
    if (last == null || last <= 0) return null;
    final pct = (forecast - last) / last * 100;
    final when = d.lastDate == null
        ? 'your last recorded cycle'
        : 'your last recorded cycle (${d.lastDate})';
    if (pct.abs() < 1) {
      return 'That is about the same as $when: ${last.toStringAsFixed(1)} kg.';
    }
    final dir = pct > 0 ? 'more' : 'less';
    return 'That is about ${pct.abs().toStringAsFixed(0)}% $dir than $when: ${last.toStringAsFixed(1)} kg.';
  }

  String _updatedText(DateTime t) {
    final mins = DateTime.now().difference(t).inMinutes;
    if (mins < 1) return 'Updated just now';
    if (mins == 1) return 'Updated 1 minute ago';
    return 'Updated $mins minutes ago';
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Harvest forecast'),
        actions: [
          IconButton(
            tooltip: 'Update forecast',
            icon: const Icon(Icons.refresh, size: 22),
            onPressed: _isLoading ? null : () => _load(force: true),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          _buildBlockSelector(),
          const SizedBox(height: 20),
          if (_isLoading) _buildLoading(),
          if (_error != null) _buildError(),
          if (_data != null) ..._buildResults(_data!),
        ],
      ),
    );
  }

  Widget _buildBlockSelector() {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<String>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 'Block A', label: Text('Block A')),
          ButtonSegment(value: 'Block B', label: Text('Block B')),
        ],
        selected: {_selectedBlock},
        onSelectionChanged: (s) {
          setState(() => _selectedBlock = s.first);
          _load();
        },
      ),
    );
  }

  Widget _buildLoading() {
    return const Panel(
      padding: EdgeInsets.all(28),
      child: Column(
        children: [
          CircularProgressIndicator(strokeWidth: 2),
          SizedBox(height: 18),
          Text('Studying your past harvests…',
              style: AppText.heading, textAlign: TextAlign.center),
          SizedBox(height: 6),
          Text(
            'Testing 5 forecasting methods. This can take up to a minute.',
            style: AppText.caption,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NoteBar(
          color: AppColors.alert,
          background: AppColors.alertSoft,
          child: Text(_error!, style: AppText.body),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => _load(force: true),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Try again'),
        ),
      ],
    );
  }

  List<Widget> _buildResults(_ForecastData d) {
    final models = _modelKeys
        .map((k) => Map<String, dynamic>.from(d.api[k] as Map))
        .toList();
    final bestName = d.api['best_model'] as String;
    final best = models.firstWhere((m) => m['model'] == bestName,
        orElse: () => models.first);
    final bestInfo = _infoFor(best['model'].toString());
    final bestForecast = _num(best['forecast_kg']);
    final compare = _compareText(bestForecast, d);

    final String checkSentence = _wasChecked(best)
        ? 'We tested ${models.length} methods against your past harvests. "${bestInfo.friendlyName}" came closest, usually off by about ${_num(best['mae']).toStringAsFixed(1)} kg per cycle.'
        : 'There are not enough past records yet to check how accurate these methods are. The forecast becomes more trustworthy as more cycles are recorded.';

    final maxMae = models
        .map((m) => _num(m['mae']))
        .fold<double>(0, (a, b) => a > b ? a : b);

    return [
      // Main forecast
      Panel(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionLabel('Next 15-day harvest · $_selectedBlock'),
            const SizedBox(height: 10),
            Text(
              '${bestForecast.toStringAsFixed(1)} kg',
              style: const TextStyle(
                fontFamily: AppText.serif,
                fontSize: 46,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
                height: 1.05,
              ),
            ),
            const SizedBox(height: 6),
            Text('Forecast by ${bestInfo.friendlyName}',
                style: AppText.caption),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 14),
            if (compare != null) ...[
              Text(compare, style: AppText.body),
              const SizedBox(height: 8),
            ],
            Text(checkSentence, style: AppText.caption),
            const SizedBox(height: 10),
            Text(_updatedText(d.fetchedAt),
                style:
                    const TextStyle(fontSize: 11, color: AppColors.inkFaint)),
          ],
        ),
      ),
      const SizedBox(height: 28),

      // Methods
      const SectionLabel('Compare the methods'),
      const SizedBox(height: 4),
      const Text('Tap any method to see how it reached its forecast.',
          style: AppText.caption),
      const SizedBox(height: 12),
      Panel(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            for (var i = 0; i < models.length; i++) ...[
              if (i > 0) const Divider(),
              _buildModelRow(models[i], models[i]['model'] == bestName, d),
            ],
          ],
        ),
      ),

      // Chart
      if (models.any(_wasChecked)) ...[
        const SizedBox(height: 28),
        const SectionLabel('How far off each method was'),
        const SizedBox(height: 4),
        const Text(
          'Typical miss on past harvests, in kg. A shorter bar is closer to what really happened.',
          style: AppText.caption,
        ),
        const SizedBox(height: 12),
        Panel(
          padding: const EdgeInsets.fromLTRB(8, 20, 16, 10),
          child: SizedBox(
            height: 200,
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: maxMae <= 0 ? 1 : maxMae * 1.2,
                barGroups: List.generate(models.length, (i) {
                  final isBest = models[i]['model'] == bestName;
                  return BarChartGroupData(
                    x: i,
                    barRods: [
                      BarChartRodData(
                        toY: _num(models[i]['mae']),
                        color: isBest
                            ? AppColors.forest
                            : AppColors.inkFaint.withValues(alpha: 0.5),
                        width: 22,
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(4)),
                      ),
                    ],
                  );
                }),
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (value, meta) {
                        final i = value.toInt();
                        if (i < 0 || i >= _chartLabels.length) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(_chartLabels[i],
                              style: const TextStyle(
                                  fontSize: 9, color: AppColors.inkSoft)),
                        );
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 36,
                      getTitlesWidget: (value, meta) => Text(
                        value.toStringAsFixed(1),
                        style: const TextStyle(
                            fontSize: 9, color: AppColors.inkSoft),
                      ),
                    ),
                  ),
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                ),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (value) =>
                      const FlLine(color: AppColors.line, strokeWidth: 1),
                ),
                borderData: FlBorderData(show: false),
              ),
            ),
          ),
        ),
      ],
    ];
  }

  Widget _buildModelRow(Map<String, dynamic> m, bool isBest, _ForecastData d) {
    final info = _infoFor(m['model'].toString());
    final checked = _wasChecked(m);

    return InkWell(
      onTap: () => _showDetails(m, d, isBest),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: AppColors.forestSoft,
                  child: Icon(info.icon, size: 18, color: AppColors.forest),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(info.friendlyName, style: AppText.bodyStrong),
                      Text(m['model'].toString(),
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.inkFaint)),
                    ],
                  ),
                ),
                Text('${_num(m['forecast_kg']).toStringAsFixed(1)} kg',
                    style: AppText.heading),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, color: AppColors.inkFaint),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (isBest)
                  const Tag('Closest match', color: AppColors.forest, filled: true),
                Tag(_reliabilityLabel(m), color: _reliabilityColor(m)),
                if (checked)
                  Text(
                    'usually off by ±${_num(m['mae']).toStringAsFixed(1)} kg',
                    style: AppText.caption,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ----------------------------------------------------------- detail sheet

  void _showDetails(Map<String, dynamic> m, _ForecastData d, bool isBest) {
    final info = _infoFor(m['model'].toString());
    final forecast = _num(m['forecast_kg']);
    final checked = _wasChecked(m);
    final mae = _num(m['mae']);
    final rmse = _num(m['rmse']);
    final r2 = _num(m['r2']);
    final compare = _compareText(forecast, d);

    final avg = d.avgKg;
    final String missText = (avg != null && avg > 0)
        ? 'Usually off by about ±${mae.toStringAsFixed(1)} kg per 15-day cycle (about ${(mae / avg * 100).toStringAsFixed(0)}% of a typical cycle).'
        : 'Usually off by about ±${mae.toStringAsFixed(1)} kg per 15-day cycle.';
    final String patternText = r2 <= 0
        ? 'Did not follow the ups and downs of your past harvests any better than simply guessing the average.'
        : 'Followed about ${(r2.clamp(0.0, 1.0) * 100).round()}% of the ups and downs in your past harvests.';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: AppColors.forestSoft,
                  child: Icon(info.icon, color: AppColors.forest),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(info.friendlyName, style: AppText.title),
                      Text('Technical name: ${m['model']}',
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.inkFaint)),
                    ],
                  ),
                ),
              ],
            ),
            if (isBest) ...[
              const SizedBox(height: 14),
              const Tag('Closest match to your past harvests',
                  color: AppColors.forest, filled: true),
            ],
            const SizedBox(height: 22),
            _Section(
              title: 'Its forecast',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'About ${forecast.toStringAsFixed(1)} kg for $_selectedBlock over the next 15 days.',
                    style: AppText.body,
                  ),
                  if (compare != null) ...[
                    const SizedBox(height: 4),
                    Text(compare, style: AppText.caption),
                  ],
                ],
              ),
            ),
            _Section(
              title: 'How it works',
              child: Text(info.howItWorks, style: AppText.body),
            ),
            _Section(
              title: 'What it looks at',
              child: Text(info.looksAt, style: AppText.body),
            ),
            _Section(
              title: 'How it did on your past harvests',
              child: checked
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Point(missText),
                        _Point(patternText),
                        _Point(
                            'Its bigger misses were around ${rmse.toStringAsFixed(1)} kg.'),
                        const SizedBox(height: 6),
                        Tag(_reliabilityLabel(m), color: _reliabilityColor(m)),
                      ],
                    )
                  : const Text(
                      'There are not enough past records to check this method yet.',
                      style: AppText.body,
                    ),
            ),
            if (isBest) ...[
              NoteBar(
                color: AppColors.forest,
                background: AppColors.forestSoft,
                child: Text(
                  'This method came closest, so the app uses it for the daily predictions on the calendar for $_selectedBlock.',
                  style: AppText.body,
                ),
              ),
              const SizedBox(height: 16),
            ],
            const Text(
              'Accuracy is measured on the harvest records saved in the app and updates as new cycles are recorded. A forecast is a guide, not a promise: weather and tapping conditions can change the real result.',
              style: TextStyle(
                  fontSize: 11, color: AppColors.inkFaint, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionLabel(title),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _Point extends StatelessWidget {
  final String text;

  const _Point(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 8, right: 10),
            child: Icon(Icons.circle, size: 5, color: AppColors.inkFaint),
          ),
          Expanded(child: Text(text, style: AppText.body)),
        ],
      ),
    );
  }
}
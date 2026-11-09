import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../main.dart';
import '../theme.dart';

double _num(dynamic v) => (v as num).toDouble();

/// A clear message for the screen when there is no forecast to show.
class _NoForecast implements Exception {
  final String message;
  const _NoForecast(this.message);
}

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
  final DateTime fetchedAt; // when the models made this forecast

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
  // The models run on GitHub (backend/run_forecasts.py) every morning and
  // save each run in the forecast_runs table. This screen only READS the
  // newest finished run, so it opens instantly and needs no PC.
  // Remembered while the app is open; cleared when a new run arrives.
  static final Map<String, _ForecastData> _cache = {};
  RealtimeChannel? _channel;

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
    // Load as soon as the screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
    // When a new run finishes on GitHub, show it without any button press
    _channel = supabase
        .channel('forecast-runs')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'forecast_runs',
          callback: (payload) {
            if (payload.newRecord['status'] == 'done' && mounted) {
              _cache.clear();
              _load();
            }
          },
        )
        .subscribe();
  }

  @override
  void dispose() {
    final channel = _channel;
    if (channel != null) supabase.removeChannel(channel);
    super.dispose();
  }

  // ---------------------------------------------------------------- loading

  Future<_ForecastData> _fetchForecast(String block) async {
    // The newest finished run (both blocks are saved together)
    final runs = await supabase
        .from('forecast_runs')
        .select('created_at, results')
        .eq('status', 'done')
        .order('id', ascending: false)
        .limit(1);
    final list = List<Map<String, dynamic>>.from(runs);
    if (list.isEmpty) {
      throw const _NoForecast(
          'No forecast has been made yet. It is updated every morning at 6:00.');
    }
    final results = Map<String, dynamic>.from(list.first['results'] as Map);
    final blockResult = results[block];
    if (blockResult == null) {
      throw _NoForecast(
          'There are not enough saved harvest records for $block yet. Add more records in the Production tab. The forecast is updated every morning.');
    }
    final api = Map<String, dynamic>.from(blockResult as Map);
    final madeAt =
        DateTime.parse(list.first['created_at'].toString()).toLocal();

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
      final rows = List<Map<String, dynamic>>.from(logs);
      if (rows.isNotEmpty) {
        lastKg = _num(rows.first['yield_kg']);
        lastDate = rows.first['date'].toString();
        avgKg = rows.fold<double>(0, (s, l) => s + _num(l['yield_kg'])) /
            rows.length;
      }
    } catch (_) {
      // The comparison with past harvests is a bonus; ignore failures.
    }

    final data = _ForecastData(
      api: api,
      lastKg: lastKg,
      lastDate: lastDate,
      avgKg: avgKg,
      fetchedAt: madeAt,
    );
    _cache[block] = data;
    return data;
  }

  /// Shows the remembered forecast at once, then always checks Supabase for
  /// a newer run (a quick read, not a model run). This matters because the
  /// screen is closed while another tab is open and can miss live updates.
  Future<void> _load() async {
    final block = _selectedBlock;
    final cached = _cache[block];
    setState(() {
      _data = cached;
      _error = null;
      _isLoading = true;
    });

    try {
      final data = await _fetchForecast(block);
      if (!mounted || _selectedBlock != block) return;
      setState(() {
        _data = data;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || _selectedBlock != block) return;
      debugPrint('Forecast load failed: $e');
      setState(() {
        _error = _friendlyError(e);
        _isLoading = false;
      });
    }
  }

  String _friendlyError(Object e) {
    if (e is _NoForecast) return e.message;
    return 'Could not load the forecast. Please check the internet connection and try again.';
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

  /// When the models made this forecast, e.g. "Updated today, 6:02 AM".
  String _updatedText(DateTime t) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final now = DateTime.now();
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(t.year, t.month, t.day))
        .inDays;
    final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final time =
        '$hour:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
    if (days == 0) return 'Updated today, $time';
    if (days == 1) return 'Updated yesterday, $time';
    return 'Updated ${months[t.month - 1]} ${t.day}, $time';
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Harvest forecast'),
        actions: [
          IconButton(
            tooltip: 'Reload forecast',
            icon: const Icon(Icons.refresh, size: 22),
            onPressed: _isLoading ? null : () => _load(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          _buildBlockSelector(),
          const SizedBox(height: 20),
          // A reload keeps the current numbers on screen until the new ones arrive
          if (_isLoading && _data == null) _buildLoading(),
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
          Text('Loading the latest forecast…',
              style: AppText.heading, textAlign: TextAlign.center),
          SizedBox(height: 6),
          Text(
            'The forecast is updated every morning.',
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
          onPressed: () => _load(),
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

    // The backend says when the records it learned from are sample data
    final evaluation = d.api['evaluation'];
    final sampleData =
        evaluation is Map && (evaluation['synthetic_rows'] ?? 0) > 0;

    return [
      if (sampleData) ...[
        const NoteBar(
          color: AppColors.alert,
          background: AppColors.alertSoft,
          child: Text(
            'Sample data: this forecast was made from practice records, not '
            'the farm\'s real harvests. Do not rely on these numbers yet.',
            style: AppText.body,
          ),
        ),
        const SizedBox(height: 16),
      ],
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
    // A method that could not be trained has no real forecast to show
    final untrained = m['error'] != null && !checked;

    return InkWell(
      onTap: () => untrained
          ? showNote(context,
              '"${info.friendlyName}" needs more recorded cycles before it can '
              'learn. It will start working as more harvests are recorded.')
          : _showDetails(m, d, isBest),
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
                Text(
                    untrained
                        ? '—'
                        : '${_num(m['forecast_kg']).toStringAsFixed(1)} kg',
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
                  Tag(checked ? 'Closest match' : 'Used for the forecast',
                      color: AppColors.forest, filled: true),
                if (untrained)
                  const Tag('Not enough data yet', color: AppColors.inkFaint)
                else
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
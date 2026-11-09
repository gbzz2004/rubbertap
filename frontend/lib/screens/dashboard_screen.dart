import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import '../cycle_plan.dart';
import '../main.dart';
import '../record_store.dart';
import '../theme.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _isLoading = true;
  int _totalBlocks = 0;
  double _thisMonthYield = 0;
  double _lastForecast = 0;
  int _anomalies = 0;

  // Calendar
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  Map<DateTime, Map<String, dynamic>> _calendarData = {};

  // Check if a date is a tapping day within any cycle
  bool _isTappingDay(DateTime date) {
    for (var cycle in _cycles) {
      final start = DateTime.parse(cycle['start_date']);
      final end = DateTime.parse(cycle['end_date']);
      if (!date.isBefore(start) && !date.isAfter(end)) {
        final day = date.difference(start).inDays + 1;
        if (day >= 1 && day <= 15) return true;
      }
    }
    return false;
  }

  List<Map<String, dynamic>> _cycles = [];

  @override
  void initState() {
    super.initState();
    _fetchAll();
  }

  // True when the last load failed for lack of internet
  bool _offline = false;

  Future<void> _fetchAll() async {
    setState(() {
      _isLoading = true;
      _offline = false;
    });
    await Future.wait([
      _fetchDashboardData(),
      _fetchCalendarData(),
    ]);
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _fetchDashboardData() async {
    try {
      final logs = await supabase
          .from('production_logs')
          .select()
          .order('date', ascending: false);
      final allLogs = List<Map<String, dynamic>>.from(logs);

      final blocks = allLogs.map((l) => l['block']).toSet();
      final now = DateTime.now();
      final thisMonth = allLogs.where((l) {
        final date = DateTime.parse(l['date']);
        return date.month == now.month && date.year == now.year;
      });
      final monthYield =
          thisMonth.fold(0.0, (sum, l) => sum + (l['yield_kg'] as num));

      double avgYield = allLogs.isEmpty
          ? 0
          : allLogs.fold(0.0, (sum, l) => sum + (l['yield_kg'] as num)) /
              allLogs.length;
      final anomalyCount = allLogs
          .where((l) => (l['yield_kg'] as num) < avgYield * 0.7)
          .length;

      // Next cycle for the whole farm: both blocks' forecasts added together
      double latestForecast = 0;
      try {
        final totals = await latestBlockTotals();
        latestForecast = totals.values.fold(0.0, (a, b) => a + b);
      } catch (_) {
        // No saved forecast yet; the card shows 0
      }

      setState(() {
        _totalBlocks = blocks.length;
        _thisMonthYield = monthYield;
        _lastForecast = latestForecast;
        _anomalies = anomalyCount;
      });
    } catch (e) {
      if (isOffline(e) && mounted) setState(() => _offline = true);
    }
  }

  Future<void> _fetchCalendarData() async {
    try {
      // Fetch all cycles
      final cycles = await supabase
          .from('tapping_cycles')
          .select()
          .order('start_date', ascending: true);
      _cycles = List<Map<String, dynamic>>.from(cycles);

      // Fetch all daily predictions
      final predictions = await supabase
          .from('daily_predictions')
          .select()
          .order('tap_date', ascending: true);
      final predList = List<Map<String, dynamic>>.from(predictions);

      // Fetch all production logs
      final logs = await supabase
          .from('production_logs')
          .select()
          .order('date', ascending: true);
      final logList = List<Map<String, dynamic>>.from(logs);

      // Build calendar data map
      Map<DateTime, Map<String, dynamic>> calData = {};

      // Add predictions to calendar
      for (var pred in predList) {
        final date = DateTime.parse(pred['tap_date']);
        final normalizedDate = DateTime(date.year, date.month, date.day);
        calData[normalizedDate] = {
          'block': pred['block'],
          'predicted_yield': pred['predicted_yield'],
          'actual_yield': pred['actual_yield'],
          'weather': pred['weather'],
          'type': 'prediction',
        };
      }

      // Add production logs to calendar (for dates without predictions)
      for (var log in logList) {
        final date = DateTime.parse(log['date']);
        final normalizedDate = DateTime(date.year, date.month, date.day);
        if (!calData.containsKey(normalizedDate)) {
          calData[normalizedDate] = {
            'block': log['block'],
            'actual_yield': log['yield_kg'],
            'weather': log['weather'],
            'type': 'log',
          };
        }
      }

      setState(() => _calendarData = calData);
    } catch (e) {
      if (isOffline(e) && mounted) setState(() => _offline = true);
    }
  }

  /// Asks before replacing a cycle that is still running.
  /// Returns false if the user cancels.
  Future<bool> _confirmReplace(String runningUntil) async {
    final until = DateTime.parse(runningUntil);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        title: const Text('A cycle is already running', style: AppText.heading),
        content: Text(
          'The current cycle runs until ${until.day} ${_months[until.month - 1]}. '
          'Re-plan from today to the end of this cycle instead?\n\n'
          'The rest of the current plan will be replaced. '
          'Days with a recorded harvest are kept.',
          style: AppText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep current',
                style: TextStyle(color: AppColors.inkSoft)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Start new'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _startNewCycle() async {
    final startStr = isoDate(DateTime.now());

    try {
      // 0) Is a cycle still running? Ask before starting a second one,
      //    otherwise two plans would overlap on the calendar.
      final running = List<Map<String, dynamic>>.from(await supabase
          .from('tapping_cycles')
          .select('id, start_date, end_date')
          .eq('status', 'active')
          .gte('end_date', startStr)
          .order('end_date', ascending: false));
      if (running.isNotEmpty) {
        if (!await _confirmReplace(running.first['end_date'].toString())) {
          return;
        }
      }

      setState(() => _isLoading = true);

      // 1) Make the per-day plan on the phone, from today to the end of the
      //    farm's calendar cycle (weighed on the 15th and 30th). Each block's
      //    cycle total comes from the latest saved ML forecast and is split
      //    across its tap days by the Open-Meteo weather forecast
      //    (see lib/cycle_plan.dart).
      final start = DateTime.parse(startStr);
      final (cycleStart, cycleEnd) = cycleBounds(start);
      final totals = await latestBlockTotals();
      final weather = await fetchDailyWeather(start, cycleEnd);
      final days = buildDailyPlan(start, totals, weather,
          end: cycleEnd, anchor: cycleStart);
      final plan = {
        'start_date': startStr,
        'end_date': isoDate(cycleEnd),
      };

      // 1b) Only now that the new plan is ready: end the running cycle(s).
      //     Their days from today on that have no recorded harvest are
      //     removed; recorded harvests and past days are never touched.
      final yesterday = isoDate(start.subtract(const Duration(days: 1)));
      for (final old in running) {
        await supabase
            .from('daily_predictions')
            .delete()
            .eq('cycle_id', old['id'])
            .gte('tap_date', startStr)
            .isFilter('actual_yield', null);
        final startedToday = old['start_date'].toString() == startStr;
        await supabase.from('tapping_cycles').update({
          // A cycle started today and replaced today never really ran
          'status': startedToday ? 'cancelled' : 'ended',
          if (!startedToday) 'end_date': yesterday,
        }).eq('id', old['id']);
      }

      // 2) Save the cycle
      final cycleResponse = await supabase
          .from('tapping_cycles')
          .insert({
            'start_date': plan['start_date'],
            'end_date': plan['end_date'],
            'status': 'active',
          })
          .select()
          .single();
      final cycleId = cycleResponse['id'];

      // 3) Save the daily predictions
      final rows = days
          .map<Map<String, dynamic>>((d) => {
                'cycle_id': cycleId,
                'tap_date': d['date'],
                'block': d['block'],
                'predicted_yield': d['predicted_yield'],
                'weather': d['weather'],
                'temperature': d['temperature'],
                'rainfall': d['rainfall'],
              })
          .toList();
      await supabase.from('daily_predictions').insert(rows);
      await _fetchAll();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('New 15-day cycle planned from the latest forecast.'),
            backgroundColor: AppColors.good,
          ),
        );
      }
    } on PlanException catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: AppColors.alert),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(plainError(e)), backgroundColor: AppColors.alert),
      );
    }
  }

  static const List<String> _weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  static const List<String> _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  String _dateLine() {
    final now = DateTime.now();
    return '${_weekdays[now.weekday - 1]}, ${now.day} ${_months[now.month - 1]}';
  }

  String _kg(dynamic value) {
    if (value is num) return value.toStringAsFixed(1);
    return value.toString();
  }

  // ----------------------------------------------------------- day details

  void _showDayDetail(DateTime day) {
    final normalized = DateTime(day.year, day.month, day.day);
    final data = _calendarData[normalized];
    if (data == null) return;

    final block = data['block'].toString();
    final color = blockColor(block);
    final hasActual = data['actual_yield'] != null;
    final isPast = day.isBefore(DateTime.now());

    showModalBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Tag(block, color: color),
                const SizedBox(width: 12),
                Text(
                  '${day.day} ${_months[day.month - 1]} ${day.year}',
                  style: AppText.heading,
                ),
              ],
            ),
            const SizedBox(height: 16),
            DetailLine(
              label: 'Weather',
              value: (data['weather'] ?? 'Unknown').toString(),
            ),
            if (data['predicted_yield'] != null)
              DetailLine(
                label: 'Expected harvest',
                value: '${_kg(data['predicted_yield'])} kg',
              ),
            if (hasActual)
              DetailLine(
                label: 'Recorded harvest',
                value: '${_kg(data['actual_yield'])} kg',
              ),
            if (isPast) ...[
              const SizedBox(height: 16),
              // One place to record harvests: the Production tab's cycle
              // totals are what the forecast learns from
              const NoteBar(
                color: AppColors.forest,
                background: AppColors.forestSoft,
                child: Text(
                  'Harvests are recorded once per cycle: each block\'s '
                  '15-day total, in the Production tab. That is what the '
                  'forecast learns from.',
                  style: AppText.body,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------- calendar

  Widget? _dayCell(DateTime day, {bool today = false, bool selected = false}) {
    final key = DateTime(day.year, day.month, day.day);
    final data = _calendarData[key];
    if (data == null) return null;

    final color = blockColor(data['block'].toString());
    final recorded = data['actual_yield'] != null;
    final predicted = data['predicted_yield'];
    final marked = today || selected;

    return Container(
      margin: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: recorded ? color : color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: marked
              ? AppColors.ink
              : color.withValues(alpha: recorded ? 1.0 : 0.35),
          width: marked ? 1.6 : 1,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '${day.day}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: recorded ? Colors.white : color,
            ),
          ),
          if (predicted != null)
            Text(
              _kg(predicted),
              style: TextStyle(
                fontSize: 9,
                color: recorded ? Colors.white70 : color,
              ),
            ),
        ],
      ),
    );
  }

  Widget _plainDay(DateTime day, {bool today = false, bool selected = false}) {
    final marked = today || selected;
    return Container(
      margin: const EdgeInsets.all(3),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: marked ? Border.all(color: AppColors.ink, width: 1.6) : null,
      ),
      child: Text(
        '${day.day}',
        style: TextStyle(
          fontSize: 13,
          fontWeight: marked ? FontWeight.w700 : FontWeight.w400,
          color: AppColors.ink,
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RubberTap'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh, size: 22),
            onPressed: _isLoading ? null : _fetchAll,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : RefreshIndicator(
              color: AppColors.forest,
              onRefresh: _fetchAll,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
                children: [
                  _buildHeader(),
                  const SizedBox(height: 24),
                  _buildOverview(),
                  if (_anomalies > 0) ...[
                    const SizedBox(height: 16),
                    _buildAttention(),
                  ],
                  const SizedBox(height: 32),
                  _buildCalendarSection(),
                ],
              ),
            ),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(_dateLine()),
        const SizedBox(height: 6),
        Text('${_greeting()}, Arnel', style: AppText.display),
        if (_offline) ...[
          const SizedBox(height: 14),
          const NoteBar(
            color: AppColors.caution,
            background: AppColors.bronzeSoft,
            child: Text(
              'No internet. The numbers below may be missing or out of date. '
              'Pull the refresh button when there is signal.',
              style: AppText.body,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildOverview() {
    final hasForecast = _lastForecast > 0;
    return Panel(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Figure(
                      label: 'This month',
                      value: '${_thisMonthYield.toStringAsFixed(1)} kg',
                      note: 'harvested so far',
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Figure(
                      label: 'Next cycle forecast',
                      value: hasForecast
                          ? '${_lastForecast.toStringAsFixed(1)} kg'
                          : '—',
                      note: hasForecast
                          ? 'both blocks, 15 days'
                          : 'updated every morning',
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Figure(
                      label: 'Blocks tapped',
                      value: '$_totalBlocks',
                      note: 'in your records',
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Figure(
                      label: 'Needs a look',
                      value: '$_anomalies',
                      note: _anomalies == 0
                          ? 'all records normal'
                          : 'unusually low',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttention() {
    final plural = _anomalies == 1 ? 'record is' : 'records are';
    return NoteBar(
      color: AppColors.alert,
      background: AppColors.alertSoft,
      child: Text(
        '$_anomalies $plural well below your usual harvest. It may be worth checking those blocks.',
        style: AppText.body,
      ),
    );
  }

  Widget _buildCalendarSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionLabel('Tapping calendar'),
                  SizedBox(height: 4),
                  Text('15-day cycles', style: AppText.heading),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: _startNewCycle,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New cycle'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        const Wrap(
          spacing: 18,
          runSpacing: 6,
          children: [
            _LegendDot(color: AppColors.forest, label: 'Block A'),
            _LegendDot(color: AppColors.bronze, label: 'Block B'),
            Text(
              'Filled = recorded · small figure = expected kg',
              style: AppText.caption,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Panel(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
          child: TableCalendar(
            firstDay: DateTime(2024, 1, 1),
            lastDay: DateTime(2027, 12, 31),
            focusedDay: _focusedDay,
            selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
            calendarFormat: CalendarFormat.month,
            availableCalendarFormats: const {CalendarFormat.month: 'Month'},
            startingDayOfWeek: StartingDayOfWeek.sunday,
            rowHeight: 56,
            daysOfWeekHeight: 28,
            onDaySelected: (selectedDay, focusedDay) {
              setState(() {
                _selectedDay = selectedDay;
                _focusedDay = focusedDay;
              });
              final normalized = DateTime(
                selectedDay.year,
                selectedDay.month,
                selectedDay.day,
              );
              if (_calendarData.containsKey(normalized)) {
                _showDayDetail(selectedDay);
              }
            },
            onPageChanged: (focusedDay) {
              _focusedDay = focusedDay;
            },
            calendarBuilders: CalendarBuilders(
              defaultBuilder: (context, day, focusedDay) => _dayCell(day),
              todayBuilder: (context, day, focusedDay) =>
                  _dayCell(day, today: true) ?? _plainDay(day, today: true),
              selectedBuilder: (context, day, focusedDay) =>
                  _dayCell(day, selected: true) ??
                  _plainDay(day, selected: true),
            ),
            calendarStyle: const CalendarStyle(
              outsideDaysVisible: false,
              defaultTextStyle: TextStyle(fontSize: 13, color: AppColors.ink),
              weekendTextStyle: TextStyle(fontSize: 13, color: AppColors.ink),
            ),
            headerStyle: const HeaderStyle(
              formatButtonVisible: false,
              titleCentered: false,
              titleTextStyle: AppText.heading,
              leftChevronIcon:
                  Icon(Icons.chevron_left, color: AppColors.ink),
              rightChevronIcon:
                  Icon(Icons.chevron_right, color: AppColors.ink),
            ),
            daysOfWeekStyle: const DaysOfWeekStyle(
              weekdayStyle: AppText.label,
              weekendStyle: AppText.label,
            ),
          ),
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: AppText.caption),
      ],
    );
  }
}
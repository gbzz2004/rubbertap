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
  double _lastForecast = 0;
  // Latest recorded cycle per block: {'Block A': {'kg': 70.0, 'date': '2026-10-30'}}
  Map<String, Map<String, dynamic>> _lastCycle = {};
  int _cyclesRecorded = 0;
  // Plain-language warnings about the latest cycle of each block
  List<String> _lowNotes = [];

  // Calendar
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  Map<DateTime, Map<String, dynamic>> _calendarData = {};

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
      final allLogs = List<Map<String, dynamic>>.from(logs); // newest first

      // Latest cycle per block, and whether it was unusually low for THAT
      // block (Block B is naturally smaller, so blocks are never compared
      // with each other). Only the latest cycle is checked: it is the one a
      // tapper can still do something about.
      final lastCycle = <String, Map<String, dynamic>>{};
      final lowNotes = <String>[];
      var cycles = 0;
      for (final block in ['Block A', 'Block B']) {
        final mine = allLogs.where((l) => l['block'] == block).toList();
        if (mine.isEmpty) continue;
        cycles = mine.length > cycles ? mine.length : cycles;
        final kg = (mine.first['yield_kg'] as num).toDouble();
        lastCycle[block] = {'kg': kg, 'date': mine.first['date']};
        if (mine.length >= 4) {
          final usual =
              mine.fold(0.0, (s, l) => s + (l['yield_kg'] as num)) / mine.length;
          if (kg < usual * 0.7) {
            lowNotes.add('$block\'s last cycle (${_prettyDay(mine.first['date'])}): '
                '${kg.toStringAsFixed(1)} kg, well below its usual '
                '${usual.toStringAsFixed(1)} kg. It may be worth checking the trees.');
          }
        }
      }

      // Next cycle for the whole farm: both blocks' forecasts added together
      double latestForecast = 0;
      try {
        final totals = await latestBlockTotals();
        latestForecast = totals.values.fold(0.0, (a, b) => a + b);
      } catch (_) {
        // No saved forecast yet; the card shows 0
      }

      setState(() {
        _lastForecast = latestForecast;
        _lastCycle = lastCycle;
        _cyclesRecorded = cycles;
        _lowNotes = lowNotes;
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

      // Recorded cycle totals by (weigh date, block), to explain past days
      final recordedTotals = <String, double>{
        for (final l in logList)
          '${l['date']}|${l['block']}': (l['yield_kg'] as num).toDouble(),
      };

      // Which cycle each plan day belongs to. Past cycles with a recorded
      // total have status 'recorded' (filled by the daily job from the real
      // total); they win over older forecast plans for the same day.
      const priority = {'recorded': 3, 'active': 2, 'ended': 1};
      final cycleById = {for (final c in _cycles) c['id']: c};

      for (var pred in predList) {
        final cycle = cycleById[pred['cycle_id']];
        final status = (cycle?['status'] ?? 'ended').toString();
        final rank = priority[status];
        if (rank == null) continue; // cancelled plans are not shown
        final date = DateTime.parse(pred['tap_date']);
        final normalizedDate = DateTime(date.year, date.month, date.day);
        final current = calData[normalizedDate];
        if (current != null && (current['rank'] as int) > rank) continue;
        final estimated = status == 'recorded';
        final cycleEnd = cycle?['end_date']?.toString();
        calData[normalizedDate] = {
          'block': pred['block'],
          'predicted_yield': pred['predicted_yield'],
          'actual_yield': pred['actual_yield'],
          'weather': pred['weather'],
          'rainfall': pred['rainfall'],
          'type': 'prediction',
          'rank': rank,
          // Past day: share of a REAL recorded total, not a measurement
          'estimated': estimated,
          'cycle_end': cycleEnd,
          'cycle_total': estimated
              ? recordedTotals['$cycleEnd|${pred['block']}']
              : null,
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

      // History: every past day from the first recorded cycle on is shown.
      // Days of cycles with no recorded total are marked "not recorded".
      if (logList.isNotEmpty) {
        final first = cycleBounds(DateTime.parse(logList.first['date'])).$1;
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        for (var d = first; d.isBefore(today);
            d = DateTime(d.year, d.month, d.day + 1)) {
          if (calData.containsKey(d)) continue;
          final (cStart, cEnd) = cycleBounds(d);
          calData[d] = {
            'block': blockForDay(d.day - cStart.day + 1),
            'missing': true,
            'cycle_start': isoDate(cStart),
            'cycle_end': isoDate(cEnd),
            'rank': 0,
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
          'This cycle is already planned until ${until.day} ${_months[until.month - 1]}. '
          'Make a fresh plan for it with the latest forecast and weather?\n\n'
          'The old plan is hidden, not deleted.',
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
            child: const Text('Re-plan'),
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

      // 1) Plan the whole calendar cycle containing today (1st-15th or
      //    16th-end), the same as the daily job does. Each block's cycle total
      //    comes from the latest saved ML forecast and is split across its
      //    tap days by the Open-Meteo weather (see lib/cycle_plan.dart).
      final (cycleStart, cycleEnd) = cycleBounds(DateTime.parse(startStr));
      final totals = await latestBlockTotals();
      final weather = await fetchDailyWeather(cycleStart, cycleEnd);
      final days = buildDailyPlan(cycleStart, totals, weather, end: cycleEnd);
      final plan = {
        'start_date': isoDate(cycleStart),
        'end_date': isoDate(cycleEnd),
      };

      // 1b) Only now that the new plan is ready: hide the old plan(s).
      //     Status only; nothing is deleted.
      for (final old in running) {
        await supabase
            .from('tapping_cycles')
            .update({'status': 'cancelled'}).eq('id', old['id']);
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

  /// "2026-06-15" -> "15 Jun"
  String _prettyDay(dynamic iso) {
    final d = DateTime.tryParse(iso?.toString() ?? '');
    if (d == null) return '';
    return '${d.day} ${_months[d.month - 1].substring(0, 3)}';
  }

  void _showDayDetail(DateTime day) {
    final normalized = DateTime(day.year, day.month, day.day);
    final data = _calendarData[normalized];
    if (data == null) return;

    final block = data['block'].toString();
    final color = blockColor(block);
    final hasActual = data['actual_yield'] != null;
    final isPast = day.isBefore(DateTime.now());
    final estimated = data['estimated'] == true && data['cycle_total'] != null;

    // A past day of a cycle whose total was never recorded
    if (data['missing'] == true) {
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
                  const Tag('Not recorded', color: AppColors.inkFaint),
                  const SizedBox(width: 12),
                  Text('${day.day} ${_months[day.month - 1]} ${day.year}',
                      style: AppText.heading),
                ],
              ),
              const SizedBox(height: 16),
              NoteBar(
                color: AppColors.inkFaint,
                background: AppColors.line.withValues(alpha: 0.4),
                child: Text(
                  'No harvest total was recorded for the cycle '
                  '${_prettyDay(data['cycle_start'])} – ${_prettyDay(data['cycle_end'])}, '
                  'so this day has no estimate. If the total is known, add it '
                  'in the Production tab and the calendar fills in by itself.',
                  style: AppText.body,
                ),
              ),
            ],
          ),
        ),
      );
      return;
    }

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
              value: data['rainfall'] is num && (data['rainfall'] as num) > 0
                  ? '${data['weather'] ?? 'Unknown'} '
                      '(${(data['rainfall'] as num).toStringAsFixed(1)} mm rain)'
                  : (data['weather'] ?? 'Unknown').toString(),
            ),
            if (data['predicted_yield'] != null)
              DetailLine(
                label: estimated ? 'Estimated harvest' : 'Expected harvest',
                value: '${_kg(data['predicted_yield'])} kg',
              ),
            if (hasActual)
              DetailLine(
                label: 'Recorded harvest',
                value: '${_kg(data['actual_yield'])} kg',
              ),
            if (estimated) ...[
              const SizedBox(height: 16),
              NoteBar(
                color: color,
                background: color.withValues(alpha: 0.08),
                child: Text(
                  'Estimated from the real cycle total: '
                  '$block\'s ${_kg(data['cycle_total'])} kg weighed on '
                  '${_prettyDay(data['cycle_end'])}, shared across its tapping '
                  'days by each day\'s actual weather. The harvest is weighed '
                  'once per cycle, so single days are not measured.',
                  style: AppText.body,
                ),
              ),
            ] else if (isPast) ...[
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

    // A past day whose cycle total was never recorded: grey, no figure
    final missing = data['missing'] == true;
    final color =
        missing ? AppColors.inkFaint : blockColor(data['block'].toString());
    // Filled = backed by a real recorded harvest (a day measured, or a past
    // day estimated from its cycle's recorded total)
    final recorded = data['actual_yield'] != null || data['estimated'] == true;
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
                  const SizedBox(height: 20),
                  _buildToday(),
                  const SizedBox(height: 16),
                  _buildOverview(),
                  if (_lowNotes.isNotEmpty) ...[
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

  /// What a tapper needs first: which block to tap today, roughly how much,
  /// the weather, and a reminder on weigh days (15th and end of month).
  Widget _buildToday() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final (cycleStart, cycleEnd) = cycleBounds(today);
    final data = _calendarData[today];
    final block = (data?['block'] ??
            blockForDay(today.day - cycleStart.day + 1))
        .toString();
    final color = blockColor(block);
    final expected = data?['predicted_yield'];
    final weather = data?['weather'];
    final rain = data?['rainfall'];
    final weighDay = today == cycleEnd;

    final details = <String>[
      if (expected != null) 'about ${_kg(expected)} kg expected',
      if (weather != null)
        rain is num && rain > 0
            ? '$weather (${rain.toStringAsFixed(1)} mm rain today)'
            : weather.toString(),
    ];

    return Panel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('Today'),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text('Tap $block', style: AppText.title)),
            ],
          ),
          if (details.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(details.join(' · '), style: AppText.body),
          ],
          const SizedBox(height: 4),
          Text(
            'Cycle ${_prettyDay(isoDate(cycleStart))} – ${_prettyDay(isoDate(cycleEnd))}',
            style: AppText.caption,
          ),
          if (weighDay) ...[
            const SizedBox(height: 12),
            const NoteBar(
              color: AppColors.forest,
              background: AppColors.forestSoft,
              child: Text(
                'Weigh day: record each block\'s total for this cycle in the '
                'Production tab.',
                style: AppText.body,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOverview() {
    final hasForecast = _lastForecast > 0;
    final a = _lastCycle['Block A'];
    final b = _lastCycle['Block B'];
    final lastDate = (a ?? b)?['date'];
    return Panel(
      padding: EdgeInsets.zero,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Figure(
                  label: 'Last cycle',
                  value: _lastCycle.isEmpty
                      ? '—'
                      : [
                          if (a != null) 'A ${(a['kg'] as double).toStringAsFixed(0)}',
                          if (b != null) 'B ${(b['kg'] as double).toStringAsFixed(0)}',
                        ].join(' · '),
                  small: true, // two numbers must fit on one line
                  note: _lastCycle.isEmpty
                      ? 'no records yet'
                      : 'kg, weighed ${_prettyDay(lastDate)} · $_cyclesRecorded cycles recorded',
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
    );
  }

  Widget _buildAttention() {
    return NoteBar(
      color: AppColors.alert,
      background: AppColors.alertSoft,
      child: Text(_lowNotes.join('\n\n'), style: AppText.body),
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
              'Filled = from a recorded harvest · light = forecast · grey = not recorded',
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
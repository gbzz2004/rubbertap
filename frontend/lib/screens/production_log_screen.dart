import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../main.dart';
import '../record_store.dart';
import '../theme.dart';

class ProductionLogScreen extends StatefulWidget {
  const ProductionLogScreen({super.key});

  @override
  State<ProductionLogScreen> createState() => _ProductionLogScreenState();
}

class _ProductionLogScreenState extends State<ProductionLogScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _selectedBlock = 'All';
  String _sortBy = 'Newest first';
  bool _isLoading = true;
  bool _isFetchingWeather = false;
  List<Map<String, dynamic>> _logs = [];
  // Offline support (see lib/record_store.dart)
  bool _offline = false;
  DateTime? _cachedAt;
  List<Map<String, dynamic>> _pending = [];

  static const List<String> _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  static String _prettyDate(DateTime d) =>
      '${d.day} ${_monthNames[d.month - 1]} ${d.year}';
  static String _isoDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static const List<String> _blocks = ['All', 'Block A', 'Block B'];
  static const List<String> _sortOptions = [
    'Newest first',
    'Oldest first',
    'Highest harvest',
    'Lowest harvest',
  ];
  static const List<String> _weatherOptions = [
    'Sunny',
    'Cloudy',
    'Rainy',
    'Windy',
  ];
  static const List<String> _months = [
    'JAN',
    'FEB',
    'MAR',
    'APR',
    'MAY',
    'JUN',
    'JUL',
    'AUG',
    'SEP',
    'OCT',
    'NOV',
    'DEC',
  ];

  // Mr. Arnel's farm
  static const double _farmLat = 7.762639;
  static const double _farmLon = 122.567028;
  static const String _weatherApiKey = 'b4bf1e412a554e1efae968eda1f8b25e';

  @override
  void initState() {
    super.initState();
    _fetchLogs();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ data

  Future<String> _fetchCurrentWeather() async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ));
      final response = await dio.get(
        'https://api.openweathermap.org/data/2.5/weather',
        queryParameters: {
          'lat': _farmLat,
          'lon': _farmLon,
          'appid': _weatherApiKey,
          'units': 'metric',
        },
      );
      final weatherMain =
          response.data['weather'][0]['main'].toString().toLowerCase();
      if (weatherMain.contains('rain') ||
          weatherMain.contains('drizzle') ||
          weatherMain.contains('thunderstorm')) {
        return 'Rainy';
      } else if (weatherMain.contains('cloud')) {
        return 'Cloudy';
      } else if (weatherMain.contains('clear') ||
          weatherMain.contains('sun')) {
        return 'Sunny';
      } else if (weatherMain.contains('wind') ||
          weatherMain.contains('squall')) {
        return 'Windy';
      } else {
        return 'Cloudy';
      }
    } catch (e) {
      return 'Sunny';
    }
  }

  Future<void> _fetchLogs() async {
    setState(() => _isLoading = true);
    // First send any records that were saved on the phone without internet
    final sent = await RecordStore.syncPending();
    try {
      final response = await supabase
          .from('production_logs')
          .select()
          .order('date', ascending: false);
      final logs = List<Map<String, dynamic>>.from(response);
      await RecordStore.saveCache(logs);
      final pending = await RecordStore.pending();
      if (!mounted) return;
      setState(() {
        _logs = logs;
        _pending = pending;
        _offline = false;
        _cachedAt = null;
        _isLoading = false;
      });
      if (sent > 0) {
        showNote(context,
            sent == 1 ? '1 waiting record was sent.' : '$sent waiting records were sent.');
      }
    } catch (e) {
      // No internet: show the copy kept on the phone instead of "no records"
      final (cached, at) = await RecordStore.loadCache();
      final pending = await RecordStore.pending();
      if (!mounted) return;
      setState(() {
        _logs = cached;
        _pending = pending;
        _offline = isOffline(e);
        _cachedAt = at;
        _isLoading = false;
      });
      if (!isOffline(e)) showNote(context, plainError(e), error: true);
    }
  }

  /// Saved records plus the ones still waiting on the phone (marked).
  List<Map<String, dynamic>> get _allLogs => [
        ..._pending.map((p) => {...p, '_pending': true}),
        ..._logs,
      ];

  List<Map<String, dynamic>> get _filteredLogs {
    List<Map<String, dynamic>> result = List.from(_allLogs);
    if (_selectedBlock != 'All') {
      result = result.where((l) => l['block'] == _selectedBlock).toList();
    }
    if (_searchController.text.isNotEmpty) {
      final query = _searchController.text.toLowerCase();
      result = result
          .where((l) =>
              l['block'].toString().toLowerCase().contains(query) ||
              l['date'].toString().contains(query))
          .toList();
    }
    switch (_sortBy) {
      case 'Newest first':
        result.sort((a, b) => b['date'].compareTo(a['date']));
        break;
      case 'Oldest first':
        result.sort((a, b) => a['date'].compareTo(b['date']));
        break;
      case 'Highest harvest':
        result.sort(
            (a, b) => (b['yield_kg'] as num).compareTo(a['yield_kg'] as num));
        break;
      case 'Lowest harvest':
        result.sort(
            (a, b) => (a['yield_kg'] as num).compareTo(b['yield_kg'] as num));
        break;
    }
    return result;
  }

  Future<void> _addLog(Map<String, dynamic> data) async {
    try {
      await supabase.from('production_logs').insert(data);
      await _fetchLogs();
      if (mounted) showNote(context, 'Record saved.');
    } catch (e) {
      if (isOffline(e)) {
        // Keep it on the phone; it is sent the next time the app connects
        await RecordStore.addPending(data);
        final pending = await RecordStore.pending();
        if (!mounted) return;
        setState(() {
          _pending = pending;
          _offline = true;
        });
        showNote(context,
            'No internet. The record is saved on this phone and will be sent automatically.');
      } else if (mounted) {
        showNote(context, plainError(e), error: true);
      }
    }
  }

  Future<void> _updateLog(int id, Map<String, dynamic> data) async {
    try {
      await supabase.from('production_logs').update(data).eq('id', id);
      await _fetchLogs();
      if (mounted) showNote(context, 'Changes saved.');
    } catch (e) {
      if (mounted) {
        showNote(
            context,
            isOffline(e)
                ? 'No internet. Changing a record needs a connection; nothing was changed.'
                : plainError(e),
            error: true);
      }
    }
  }

  Future<void> _confirmDelete(int id) async {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete this record?', style: AppText.heading),
        content: const Text(
          'It will be removed from the records and the forecast.',
          style: AppText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Keep it',
                style: TextStyle(color: AppColors.inkSoft)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              try {
                await supabase.from('production_logs').delete().eq('id', id);
                await _fetchLogs();
                if (mounted) showNote(context, 'Record deleted.');
              } catch (e) {
                if (mounted) {
                  showNote(
                      context,
                      isOffline(e)
                          ? 'No internet. Deleting needs a connection; nothing was deleted.'
                          : plainError(e),
                      error: true);
                }
              }
            },
            child: const Text('Delete',
                style: TextStyle(color: AppColors.alert)),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------- sanity checks

  /// Plain-language warnings for a record that looks like a typo or a
  /// repeat. Empty list = nothing unusual.
  List<String> _sanityWarnings(
      String block, double kg, DateTime date, dynamic editId) {
    final warnings = <String>[];
    final others = _allLogs
        .where((l) => l['block'] == block && (editId == null || l['id'] != editId))
        .toList();

    // 1) Far from this block's usual cycle total (needs some history)
    if (others.length >= 3) {
      final avg = others.fold<double>(
              0, (s, l) => s + (l['yield_kg'] as num).toDouble()) /
          others.length;
      if (kg > avg * 2) {
        warnings.add('${kg.toStringAsFixed(1)} kg is much MORE than usual for '
            '$block (usually about ${avg.toStringAsFixed(1)} kg per cycle). '
            'Check for a typing mistake, e.g. 448 instead of 44.8.');
      } else if (kg < avg / 3) {
        warnings.add('${kg.toStringAsFixed(1)} kg is much LESS than usual for '
            '$block (usually about ${avg.toStringAsFixed(1)} kg per cycle). '
            'Is this one day instead of the whole cycle?');
      }
    }

    // 2) Another record for this block within the same 15-day cycle
    for (final l in others) {
      final d = DateTime.tryParse(l['date'].toString());
      if (d != null && d.difference(date).inDays.abs() < 10) {
        warnings.add('$block already has a record on ${_prettyDate(d)} '
            '(${(l['yield_kg'] as num).toStringAsFixed(1)} kg), in the same '
            '15-day cycle. Each block needs only one total per cycle.');
        break;
      }
    }
    return warnings;
  }

  Future<bool> _confirmUnusual(BuildContext ctx, List<String> warnings) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        title: const Text('Please check this record', style: AppText.heading),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final w in warnings) ...[
              Text(w, style: AppText.body),
              const SizedBox(height: 10),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Go back and fix',
                style: TextStyle(color: AppColors.inkSoft)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Save anyway'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  // ------------------------------------------------------- add / edit sheet

  Future<void> _openAddDialog() async {
    setState(() => _isFetchingWeather = true);
    final weather = await _fetchCurrentWeather();
    if (!mounted) return;
    setState(() => _isFetchingWeather = false);
    _showLogSheet(detectedWeather: weather);
  }

  void _showLogSheet({
    Map<String, dynamic>? existing,
    String detectedWeather = 'Sunny',
  }) {
    final dynamic editId = existing?['id'];
    final isEdit = editId != null;
    final yieldController =
        TextEditingController(text: existing?['yield_kg']?.toString() ?? '');
    final notesController =
        TextEditingController(text: existing?['notes']?.toString() ?? '');
    // The date is kept as a DateTime and shown as "9 Nov 2026"
    DateTime pickedDate =
        DateTime.tryParse(existing?['date']?.toString() ?? '') ??
            DateTime.now();
    final dateController =
        TextEditingController(text: _prettyDate(pickedDate));
    String block = existing?['block']?.toString() ?? 'Block A';
    String weather = existing?['weather']?.toString() ?? detectedWeather;
    final formKey = GlobalKey<FormState>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            0,
            24,
            MediaQuery.of(sheetContext).viewInsets.bottom + 24,
          ),
          child: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(isEdit ? 'Edit cycle total' : 'Cycle harvest total',
                      style: AppText.title),
                  const SizedBox(height: 6),
                  const NoteBar(
                    color: AppColors.forest,
                    background: AppColors.forestSoft,
                    child: Text(
                      'Enter ONE block\'s total for the whole 15-day cycle, '
                      'not one day\'s harvest. Record Block A and Block B '
                      'separately.',
                      style: AppText.body,
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: dateController,
                    readOnly: true,
                    decoration: fieldDecoration('Date weighed',
                        icon: Icons.calendar_today_outlined),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: sheetContext,
                        initialDate: pickedDate,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) {
                        pickedDate = picked;
                        dateController.text = _prettyDate(picked);
                      }
                    },
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Please pick a date' : null,
                  ),
                  const SizedBox(height: 18),
                  const SectionLabel('Block'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      ChoicePill(
                        label: 'Block A',
                        selected: block == 'Block A',
                        onTap: () => setSheetState(() => block = 'Block A'),
                      ),
                      const SizedBox(width: 10),
                      ChoicePill(
                        label: 'Block B',
                        selected: block == 'Block B',
                        onTap: () => setSheetState(() => block = 'Block B'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  TextFormField(
                    controller: yieldController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: fieldDecoration('Total for the cycle (kg)',
                        icon: Icons.scale_outlined),
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Please enter the kg';
                      final n = double.tryParse(v);
                      if (n == null) return 'Please enter a number';
                      if (n <= 0) return 'It must be more than 0';
                      return null;
                    },
                  ),
                  const SizedBox(height: 18),
                  const SectionLabel('Weather'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _weatherOptions
                        .map((w) => ChoicePill(
                              label: w,
                              icon: weatherIcon(w),
                              selected: weather == w,
                              onTap: () => setSheetState(() => weather = w),
                            ))
                        .toList(),
                  ),
                  if (!isEdit) ...[
                    const SizedBox(height: 6),
                    const Text(
                      'Filled in from the weather at the farm right now. Change it if the harvest day was different.',
                      style: AppText.caption,
                    ),
                  ],
                  const SizedBox(height: 18),
                  TextFormField(
                    controller: notesController,
                    maxLines: 2,
                    decoration: fieldDecoration('Notes (optional)',
                        icon: Icons.notes_outlined),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () async {
                        if (!formKey.currentState!.validate()) return;
                        final kg = double.parse(yieldController.text);
                        // Unusual amounts and repeat records go straight
                        // into the forecast, so ask before saving them
                        final warnings = _sanityWarnings(
                            block, kg, pickedDate, isEdit ? editId : null);
                        if (warnings.isNotEmpty &&
                            !await _confirmUnusual(sheetContext, warnings)) {
                          return;
                        }
                        if (!sheetContext.mounted) return;
                        Navigator.pop(sheetContext);
                        final data = {
                          'date': _isoDate(pickedDate),
                          'block': block,
                          'yield_kg': kg,
                          'weather': weather,
                          'notes': notesController.text,
                        };
                        if (isEdit) {
                          await _updateLog(editId as int, data);
                        } else {
                          await _addLog(data);
                        }
                      },
                      child: Text(isEdit ? 'Save changes' : 'Save record'),
                    ),
                  ),
                  if (isEdit) ...[
                    const SizedBox(height: 8),
                    Center(
                      child: TextButton.icon(
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _confirmDelete(editId as int);
                        },
                        icon: const Icon(Icons.delete_outline,
                            size: 18, color: AppColors.alert),
                        label: const Text('Delete this record',
                            style: TextStyle(color: AppColors.alert)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final logs = _filteredLogs;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Harvest records'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh, size: 22),
            onPressed: _isLoading ? null : _fetchLogs,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isFetchingWeather ? null : _openAddDialog,
        icon: _isFetchingWeather
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.add),
        label: Text(_isFetchingWeather ? 'Checking weather…' : 'Add record'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 110),
              children: [
                if (_offline) ...[
                  NoteBar(
                    color: AppColors.caution,
                    background: AppColors.bronzeSoft,
                    child: Text(
                      _cachedAt == null
                          ? 'No internet. New records are saved on this phone and sent later.'
                          : 'No internet. Showing the records saved on this phone '
                              '(${_prettyDate(_cachedAt!)}). New records are sent '
                              'automatically when there is signal.',
                      style: AppText.body,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (_logs.any((l) => l['notes'] == 'SYNTHETIC')) ...[
                  const NoteBar(
                    color: AppColors.alert,
                    background: AppColors.alertSoft,
                    child: Text(
                      'Sample data: records marked SYNTHETIC are practice '
                      'numbers, not real harvests. Forecasts made from them are '
                      'not real results.',
                      style: AppText.body,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                _buildSummary(logs),
                const SizedBox(height: 16),
                _buildSearch(),
                const SizedBox(height: 12),
                _buildFilters(),
                const SizedBox(height: 16),
                if (logs.isEmpty)
                  QuietMessage(
                    icon: _offline
                        ? Icons.cloud_off_outlined
                        : Icons.menu_book_outlined,
                    title: _offline
                        ? 'No internet'
                        : (_allLogs.isEmpty
                            ? 'No records here yet'
                            : 'No records match'),
                    message: _offline
                        ? 'Records will show when there is signal. You can still add a record; it is kept on this phone.'
                        : 'Tap “Add record” to write down a cycle total.',
                  )
                else
                  Panel(
                    padding: EdgeInsets.zero,
                    child: Column(children: _buildRows(logs)),
                  ),
              ],
            ),
    );
  }

  Widget _buildSummary(List<Map<String, dynamic>> logs) {
    final total = logs.fold<double>(
        0, (sum, l) => sum + (l['yield_kg'] as num).toDouble());
    final average = logs.isEmpty ? 0.0 : total / logs.length;

    Widget cell(Widget child) => Expanded(
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        );

    return Panel(
      padding: EdgeInsets.zero,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            cell(Figure(label: 'Records', value: '${logs.length}', small: true)),
            const VerticalDivider(width: 1),
            cell(Figure(
                label: 'Total',
                value: '${total.toStringAsFixed(1)} kg',
                small: true)),
            const VerticalDivider(width: 1),
            cell(Figure(
                label: 'Average',
                value: '${average.toStringAsFixed(1)} kg',
                small: true)),
          ],
        ),
      ),
    );
  }

  Widget _buildSearch() {
    return TextField(
      controller: _searchController,
      onChanged: (_) => setState(() {}),
      decoration: fieldDecoration('Search by block or date',
              icon: Icons.search)
          .copyWith(
        suffixIcon: _searchController.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  _searchController.clear();
                  setState(() {});
                },
              ),
      ),
    );
  }

  Widget _buildFilters() {
    return Row(
      children: [
        ..._blocks.expand<Widget>((b) => <Widget>[
              ChoicePill(
                label: b,
                selected: _selectedBlock == b,
                onTap: () => setState(() => _selectedBlock = b),
              ),
              const SizedBox(width: 8),
            ]),
        const Spacer(),
        PopupMenuButton<String>(
          tooltip: 'Sort records',
          onSelected: (value) => setState(() => _sortBy = value),
          itemBuilder: (context) => _sortOptions
              .map((s) => PopupMenuItem<String>(
                    value: s,
                    child: Text(
                      s,
                      style: TextStyle(
                        fontWeight:
                            s == _sortBy ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ))
              .toList(),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.swap_vert, size: 18, color: AppColors.inkSoft),
                SizedBox(width: 4),
                Text('Sort',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.inkSoft)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildRows(List<Map<String, dynamic>> logs) {
    final rows = <Widget>[];
    for (var i = 0; i < logs.length; i++) {
      if (i > 0) rows.add(const Divider());
      rows.add(_buildRow(logs[i]));
    }
    return rows;
  }

  Widget _buildRow(Map<String, dynamic> log) {
    final date = DateTime.tryParse(log['date'].toString());
    final block = log['block'].toString();
    final weather = (log['weather'] ?? '').toString();
    final notes = (log['notes'] ?? '').toString();
    final kg = (log['yield_kg'] as num).toStringAsFixed(1);
    final isPending = log['_pending'] == true;

    return InkWell(
      onTap: () => isPending
          ? showNote(context,
              'This record is saved on the phone and will be sent when there is internet.')
          : _showLogSheet(existing: log),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            SizedBox(
              width: 62,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(date == null ? '–' : '${date.day}',
                      style: AppText.title),
                  Text(
                    date == null
                        ? ''
                        : '${_months[date.month - 1]} ${date.year}',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                      color: AppColors.inkFaint,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: blockColor(block),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(block, style: AppText.bodyStrong),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (isPending) ...[
                    const Tag('Waiting to send', color: AppColors.caution),
                    const SizedBox(height: 4),
                  ],
                  Row(
                    children: [
                      if (weather.isNotEmpty) ...[
                        Icon(weatherIcon(weather),
                            size: 14, color: AppColors.inkSoft),
                        const SizedBox(width: 4),
                        Text(weather, style: AppText.caption),
                      ],
                      if (notes.isNotEmpty)
                        Expanded(
                          child: Text(
                            weather.isEmpty ? notes : '  ·  $notes',
                            style: AppText.caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text('$kg kg', style: AppText.heading),
          ],
        ),
      ),
    );
  }
}
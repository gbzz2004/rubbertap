import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../main.dart';
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
    try {
      final response = await supabase
          .from('production_logs')
          .select()
          .order('date', ascending: false);
      if (!mounted) return;
      setState(() {
        _logs = List<Map<String, dynamic>>.from(response);
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      showNote(context, 'Could not load records: $e', error: true);
    }
  }

  List<Map<String, dynamic>> get _filteredLogs {
    List<Map<String, dynamic>> result = List.from(_logs);
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
      if (mounted) showNote(context, 'Error: $e', error: true);
    }
  }

  Future<void> _updateLog(int id, Map<String, dynamic> data) async {
    try {
      await supabase.from('production_logs').update(data).eq('id', id);
      await _fetchLogs();
      if (mounted) showNote(context, 'Changes saved.');
    } catch (e) {
      if (mounted) showNote(context, 'Error: $e', error: true);
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
          'This cannot be undone.',
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
                if (mounted) showNote(context, 'Error: $e', error: true);
              }
            },
            child: const Text('Delete',
                style: TextStyle(color: AppColors.alert)),
          ),
        ],
      ),
    );
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
    final dateController = TextEditingController(
      text: existing?['date']?.toString() ??
          DateTime.now().toIso8601String().substring(0, 10),
    );
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
                  Text(isEdit ? 'Edit record' : 'New harvest record',
                      style: AppText.title),
                  const SizedBox(height: 4),
                  Text(
                    isEdit
                        ? 'Change the details, then save.'
                        : 'Write down what you collected.',
                    style: AppText.caption,
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: dateController,
                    readOnly: true,
                    decoration: fieldDecoration('Date',
                        icon: Icons.calendar_today_outlined),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: sheetContext,
                        initialDate:
                            DateTime.tryParse(dateController.text) ??
                                DateTime.now(),
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) {
                        dateController.text =
                            picked.toIso8601String().substring(0, 10);
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
                    decoration: fieldDecoration('Harvest (kg)',
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
                        Navigator.pop(sheetContext);
                        final data = {
                          'date': dateController.text,
                          'block': block,
                          'yield_kg': double.parse(yieldController.text),
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
                _buildSummary(logs),
                const SizedBox(height: 16),
                _buildSearch(),
                const SizedBox(height: 12),
                _buildFilters(),
                const SizedBox(height: 16),
                if (logs.isEmpty)
                  const QuietMessage(
                    icon: Icons.menu_book_outlined,
                    title: 'No records here yet',
                    message:
                        'Tap “Add record” to write down your first harvest.',
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

    return InkWell(
      onTap: () => _showLogSheet(existing: log),
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
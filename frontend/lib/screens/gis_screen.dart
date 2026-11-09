import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../main.dart';
import '../theme.dart';

class GisScreen extends StatefulWidget {
  const GisScreen({super.key});

  @override
  State<GisScreen> createState() => _GisScreenState();
}

class _GisScreenState extends State<GisScreen> {
  bool _isLoading = true;
  Map<String, dynamic>? _selectedBlock;
  List<Map<String, dynamic>> _blocks = [];
  Map<String, double> _blockYields = {};
  Map<String, double> _blockForecasts = {};

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  // ------------------------------------------------------------------ data

  Future<void> _fetchData() async {
    setState(() => _isLoading = true);
    try {
      final blocksResponse = await supabase.from('farm_blocks').select();
      final blocks = List<Map<String, dynamic>>.from(blocksResponse);

      final logsResponse = await supabase
          .from('production_logs')
          .select()
          .order('date', ascending: false);
      final logs = List<Map<String, dynamic>>.from(logsResponse);

      Map<String, List<double>> blockYieldMap = {};
      for (var log in logs) {
        final block = log['block'] as String;
        final yieldKg = (log['yield_kg'] as num).toDouble();
        blockYieldMap.putIfAbsent(block, () => []).add(yieldKg);
      }

      Map<String, double> avgYields = {};
      blockYieldMap.forEach((block, yields) {
        avgYields[block] = yields.reduce((a, b) => a + b) / yields.length;
      });

      final forecastsResponse = await supabase
          .from('forecast_results')
          .select()
          .order('created_at', ascending: false);
      final forecasts = List<Map<String, dynamic>>.from(forecastsResponse);

      Map<String, double> forecastMap = {};
      for (var forecast in forecasts) {
        final block = forecast['block'] as String? ?? '';
        if (block.isNotEmpty && !forecastMap.containsKey(block)) {
          forecastMap[block] = (forecast['forecast_kg'] as num).toDouble();
        }
      }

      if (!mounted) return;
      setState(() {
        _blocks = blocks;
        _blockYields = avgYields;
        _blockForecasts = forecastMap;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      showNote(context, 'Could not load the map data: $e', error: true);
    }
  }

  String _getBlockStatus(String blockName) {
    if (_blockYields.isEmpty) return 'unknown';
    final avgAll =
        _blockYields.values.reduce((a, b) => a + b) / _blockYields.length;
    final blockYield = _blockYields[blockName] ?? 0;
    if (blockYield >= avgAll * 0.9) return 'good';
    if (blockYield >= avgAll * 0.7) return 'low';
    return 'critical';
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'good':
        return AppColors.good;
      case 'low':
        return AppColors.caution;
      case 'critical':
        return AppColors.alert;
      default:
        return AppColors.inkFaint;
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'good':
        return 'On track';
      case 'low':
        return 'Below usual';
      case 'critical':
        return 'Needs attention';
      default:
        return 'No data yet';
    }
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Farm map'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh, size: 22),
            onPressed: _isLoading ? null : _fetchData,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : Stack(
              children: [
                _buildMap(),
                Positioned(top: 12, left: 12, child: _buildLegend()),
                Positioned(
                  top: 12,
                  right: 12,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      '© OpenStreetMap contributors',
                      style: TextStyle(fontSize: 9, color: AppColors.inkSoft),
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: _selectedBlock == null
                      ? _buildHint()
                      : _buildDetail(_selectedBlock!),
                ),
              ],
            ),
    );
  }

  Widget _buildMap() {
    return FlutterMap(
      options: MapOptions(
        initialCenter: _blocks.isNotEmpty
            ? LatLng(
                (_blocks.first['latitude'] as num).toDouble(),
                (_blocks.first['longitude'] as num).toDouble(),
              )
            : const LatLng(7.762639, 122.567028),
        initialZoom: 17,
        onTap: (_, __) => setState(() => _selectedBlock = null),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.rubbertap.app',
        ),
        MarkerLayer(
          markers: _blocks.map((block) {
            final name = block['name'].toString();
            final color = _statusColor(_getBlockStatus(name));
            final selected = _selectedBlock != null &&
                _selectedBlock!['name'].toString() == name;
            final letter = name.split(' ').last;
            return Marker(
              point: LatLng(
                (block['latitude'] as num).toDouble(),
                (block['longitude'] as num).toDouble(),
              ),
              width: 64,
              height: 64,
              child: GestureDetector(
                onTap: () => setState(() => _selectedBlock = block),
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: selected ? 50 : 42,
                    height: selected ? 50 : 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Colors.white, width: selected ? 4 : 3),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x40000000),
                          blurRadius: 6,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Text(
                      letter,
                      style: const TextStyle(
                        fontFamily: AppText.serif,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildLegend() {
    Widget row(Color color, String label) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(label, style: AppText.caption),
            ],
          ),
        );

    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('Harvest vs. usual'),
          const SizedBox(height: 8),
          row(AppColors.good, 'On track'),
          row(AppColors.caution, 'Below usual'),
          row(AppColors.alert, 'Needs attention'),
        ],
      ),
    );
  }

  Widget _buildHint() {
    return const Panel(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.touch_app_outlined, size: 18, color: AppColors.inkSoft),
          SizedBox(width: 8),
          Text('Tap a block on the map for details', style: AppText.caption),
        ],
      ),
    );
  }

  Widget _buildDetail(Map<String, dynamic> block) {
    final name = block['name'].toString();
    final status = _getBlockStatus(name);
    final average = _blockYields[name];
    final forecast = _blockForecasts[name];

    return Panel(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(name, style: AppText.title)),
              Tag(_statusLabel(status), color: _statusColor(status)),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Figure(
                  label: 'Average',
                  value: average == null
                      ? '—'
                      : '${average.toStringAsFixed(1)} kg',
                  small: true,
                ),
              ),
              Expanded(
                child: Figure(
                  label: 'Forecast',
                  value: forecast == null
                      ? '—'
                      : '${forecast.toStringAsFixed(1)} kg',
                  small: true,
                ),
              ),
              Expanded(
                child: Figure(
                  label: 'Trees',
                  value: '${block['tree_count'] ?? '—'}',
                  small: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('Area: ${block['area_hectares'] ?? '—'} hectares',
              style: AppText.caption),
        ],
      ),
    );
  }
}
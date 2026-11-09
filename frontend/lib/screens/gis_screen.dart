import 'dart:convert';
import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import '../farm_geometry.dart';
import '../main.dart';
import '../record_store.dart';
import '../theme.dart';

// Free map sources (no key, no billing). Esri imagery must be credited.
const _satelliteTiles =
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
const _streetTiles = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const _glyphs = 'https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf';

// Tallest block on the map, in metres, when its forecast is the biggest
const double _maxBlockHeight = 60;

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

  MapLibreMapController? _map;
  bool _styleReady = false;
  bool _is3D = false;
  bool _satellite = true;

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  // ------------------------------------------------------------------ data

  Future<void> _fetchData() async {
    // The map is rebuilt after loading, so forget the old one
    setState(() {
      _isLoading = true;
      _map = null;
      _styleReady = false;
    });
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
      _refreshBlockLayers();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      showNote(context, 'Could not load the map data. ${plainError(e)}', error: true);
    }
  }

  /// The block's next-cycle forecast compared with ITS OWN usual harvest.
  /// (Blocks are never compared with each other: Block B is naturally smaller.)
  String _getBlockStatus(String blockName) {
    final usual = _blockYields[blockName];
    final forecast = _blockForecasts[blockName];
    if (usual == null || usual <= 0 || forecast == null) return 'unknown';
    if (forecast >= usual * 0.9) return 'good';
    if (forecast >= usual * 0.7) return 'low';
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
        return 'Normal';
      case 'low':
        return 'Below usual';
      case 'critical':
        return 'Much lower';
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
                Positioned(top: 12, right: 12, child: _buildControls()),
                Positioned(
                  left: 12,
                  bottom: 0,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _satellite
                          ? 'Imagery © Esri, Maxar, Earthstar Geographics'
                          : '© OpenStreetMap contributors',
                      style:
                          const TextStyle(fontSize: 9, color: AppColors.inkSoft),
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 22,
                  child: _selectedBlock == null
                      ? _buildHint()
                      : _buildDetail(_selectedBlock!),
                ),
              ],
            ),
    );
  }

  // ------------------------------------------------------------------ map

  List<List<double>> _outline(Map<String, dynamic> block) => outlineFor(
        block['name'].toString(),
        (block['latitude'] as num).toDouble(),
        (block['longitude'] as num).toDouble(),
      );

  String _hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  /// Centre of all blocks, used for the starting view.
  LatLng _farmCentre() {
    if (_blocks.isEmpty) return const LatLng(7.763, 122.5685);
    var lat = 0.0, lon = 0.0;
    for (final b in _blocks) {
      final c = outlineCentre(_outline(b));
      lon += c[0];
      lat += c[1];
    }
    return LatLng(lat / _blocks.length, lon / _blocks.length);
  }

  /// One 3D shape per block: colour = status, height = forecast.
  Map<String, dynamic> _blocksGeoJson() {
    final maxForecast =
        _blockForecasts.values.fold<double>(0, (a, b) => b > a ? b : a);
    final features = <Map<String, dynamic>>[];
    for (final b in _blocks) {
      final name = b['name'].toString();
      final ring = _outline(b);
      final forecast = _blockForecasts[name];
      final selected = _selectedBlock?['name'].toString() == name;
      // Flat view: blocks lie on the ground. 3D view: height = forecast.
      final height = !_is3D
          ? 0.0
          : (forecast == null || maxForecast <= 0)
              ? 3.0
              : 8 + (_maxBlockHeight - 8) * forecast / maxForecast;
      features.add({
        'type': 'Feature',
        'properties': {
          'name': name,
          'color': _hex(_statusColor(_getBlockStatus(name))),
          'height': height,
          'outline': selected ? '#FFFFFF' : '#F6F2EA',
          'outlineWidth': selected ? 4.0 : 1.5,
        },
        'geometry': {
          'type': 'Polygon',
          'coordinates': [
            [...ring, ring.first],
          ],
        },
      });
    }
    return {'type': 'FeatureCollection', 'features': features};
  }

  /// A label at the centre of each block: name and forecast.
  Map<String, dynamic> _labelsGeoJson() {
    final features = <Map<String, dynamic>>[];
    for (final b in _blocks) {
      final name = b['name'].toString();
      final forecast = _blockForecasts[name];
      features.add({
        'type': 'Feature',
        'properties': {
          'label': forecast == null
              ? name
              : '$name\n${forecast.toStringAsFixed(1)} kg',
        },
        'geometry': {'type': 'Point', 'coordinates': outlineCentre(_outline(b))},
      });
    }
    return {'type': 'FeatureCollection', 'features': features};
  }

  String _styleJson() => jsonEncode({
        'version': 8,
        'glyphs': _glyphs,
        'sources': {
          'satellite': {
            'type': 'raster',
            'tiles': [_satelliteTiles],
            'tileSize': 256,
            'maxzoom': 18, // sharper tiles do not exist here
          },
          'streets': {
            'type': 'raster',
            'tiles': [_streetTiles],
            'tileSize': 256,
            'maxzoom': 19,
          },
        },
        'layers': [
          {
            'id': 'background',
            'type': 'background',
            'paint': {'background-color': '#E4ECE6'},
          },
          {
            'id': 'satellite',
            'type': 'raster',
            'source': 'satellite',
            'layout': {'visibility': _satellite ? 'visible' : 'none'},
          },
          {
            'id': 'streets',
            'type': 'raster',
            'source': 'streets',
            'layout': {'visibility': _satellite ? 'none' : 'visible'},
          },
        ],
      });

  Future<void> _onStyleLoaded() async {
    final map = _map;
    if (map == null) return;
    try {
      await map.addGeoJsonSource('blocks', _blocksGeoJson());
      await map.addGeoJsonSource('labels', _labelsGeoJson());
      await map.addFillExtrusionLayer(
        'blocks',
        'blocks-3d',
        const FillExtrusionLayerProperties(
          fillExtrusionColor: ['get', 'color'],
          fillExtrusionHeight: ['get', 'height'],
          fillExtrusionBase: 0,
          fillExtrusionOpacity: 0.82,
        ),
        enableInteraction: false,
      );
      await map.addLineLayer(
        'blocks',
        'blocks-outline',
        const LineLayerProperties(
          lineColor: ['get', 'outline'],
          lineWidth: ['get', 'outlineWidth'],
        ),
        enableInteraction: false,
      );
      _styleReady = true;
    } catch (e) {
      if (mounted) {
        showNote(context, 'Could not draw the blocks. ${plainError(e)}', error: true);
      }
      return;
    }
    // Labels are optional: the map still works if the font cannot load
    try {
      await map.addSymbolLayer(
        'labels',
        'block-labels',
        const SymbolLayerProperties(
          textField: ['get', 'label'],
          // A plain list would be read as an expression, so wrap it
          textFont: [
            'literal',
            ['Open Sans Semibold']
          ],
          textSize: 14,
          textColor: '#FFFFFF',
          textHaloColor: '#1F2A24',
          textHaloWidth: 1.6,
          textAllowOverlap: true,
          textIgnorePlacement: true,
        ),
        enableInteraction: false,
      );
    } catch (e) {
      debugPrint('Block labels could not be added: $e');
    }
  }

  /// Push new colours, heights, labels and selection to the map.
  Future<void> _refreshBlockLayers() async {
    final map = _map;
    if (map == null || !_styleReady) return;
    try {
      await map.setGeoJsonSource('blocks', _blocksGeoJson());
      await map.setGeoJsonSource('labels', _labelsGeoJson());
    } catch (_) {
      // The map was closed while updating; nothing to do
    }
  }

  Future<void> _onMapClick(Point<double> point, LatLng tap) async {
    String? name;
    // In 3D the tap lands on the raised shape, which the map itself can find
    try {
      final hits =
          await _map?.queryRenderedFeatures(point, ['blocks-3d'], null);
      if (hits != null && hits.isNotEmpty) {
        final first = hits.first;
        final f = first is String ? jsonDecode(first) : first;
        name = (f['properties'] as Map?)?['name']?.toString();
      }
    } catch (_) {}
    // Otherwise check which outline contains the tapped ground point
    if (name == null) {
      for (final b in _blocks) {
        if (outlineContains(_outline(b), tap.longitude, tap.latitude)) {
          name = b['name'].toString();
          break;
        }
      }
    }
    if (!mounted) return;
    Map<String, dynamic>? block;
    for (final b in _blocks) {
      if (b['name'].toString() == name) block = b;
    }
    setState(() => _selectedBlock = block);
    _refreshBlockLayers();
    if (block != null) _flyTo(block);
  }

  void _moveCamera(LatLng target, double zoom) {
    _map?.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(
        target: target,
        zoom: zoom,
        tilt: _is3D ? 60 : 0,
        bearing: _is3D ? -25 : 0,
      )),
      duration: const Duration(milliseconds: 900),
    );
  }

  void _flyTo(Map<String, dynamic> block) {
    final c = outlineCentre(_outline(block));
    _moveCamera(LatLng(c[1], c[0]), 17.3);
  }

  void _toggle3D() {
    setState(() => _is3D = !_is3D);
    _refreshBlockLayers();
    final current = _map?.cameraPosition;
    _moveCamera(current?.target ?? _farmCentre(), current?.zoom ?? 16.4);
  }

  void _recentre() {
    setState(() => _selectedBlock = null);
    _refreshBlockLayers();
    _moveCamera(_farmCentre(), 16.4);
  }

  void _toggleBaseMap() {
    setState(() => _satellite = !_satellite);
    _map?.setLayerVisibility('satellite', _satellite);
    _map?.setLayerVisibility('streets', !_satellite);
  }

  Widget _buildMap() {
    return MapLibreMap(
      styleString: _styleJson(),
      initialCameraPosition: CameraPosition(target: _farmCentre(), zoom: 16.4),
      minMaxZoomPreference: const MinMaxZoomPreference(13, 20),
      trackCameraPosition: true,
      tiltGesturesEnabled: true,
      rotateGesturesEnabled: true,
      compassEnabled: true,
      logoEnabled: false,
      attributionEnabled: false, // credits are shown on screen instead
      onMapCreated: (c) => _map = c,
      onStyleLoadedCallback: _onStyleLoaded,
      onMapClick: _onMapClick,
    );
  }

  Widget _buildControls() {
    Widget button(String tip, VoidCallback onTap,
            {IconData? icon, String? text, bool active = false}) =>
        Tooltip(
          message: tip,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active ? AppColors.forest : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: text != null
                  ? Text(text,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: active ? Colors.white : AppColors.ink,
                      ))
                  : Icon(icon, size: 22, color: AppColors.ink),
            ),
          ),
        );

    return Panel(
      padding: const EdgeInsets.all(4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(_is3D ? 'Flat view' : '3D view', _toggle3D,
              text: '3D', active: _is3D),
          button(_satellite ? 'Show road map' : 'Show satellite',
              _toggleBaseMap,
              icon: _satellite
                  ? Icons.map_outlined
                  : Icons.satellite_alt_outlined),
          button('Show whole farm', _recentre,
              icon: Icons.center_focus_strong_outlined),
        ],
      ),
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
          const SectionLabel('Next cycle vs. its usual'),
          const SizedBox(height: 8),
          row(AppColors.good, 'Normal'),
          row(AppColors.caution, 'Below usual'),
          row(AppColors.alert, 'Much lower'),
          if (_is3D) ...[
            const SizedBox(height: 6),
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.height, size: 12, color: AppColors.inkSoft),
                SizedBox(width: 5),
                Text('Taller = bigger forecast', style: AppText.caption),
              ],
            ),
          ],
          if (blockOutlinesArePlaceholders) ...[
            const SizedBox(height: 6),
            const Text('Block outlines are approximate',
                style: TextStyle(
                    fontSize: 10,
                    fontStyle: FontStyle.italic,
                    color: AppColors.inkFaint)),
          ],
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
          Flexible(
            child: Text('Tap a block for details. Tilt with two fingers.',
                style: AppText.caption),
          ),
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
          Text(
              blockOutlinesArePlaceholders
                  ? 'Area: ${block['area_hectares'] ?? '—'} hectares'
                  : 'Area: ${outlineHectares(_outline(block)).toStringAsFixed(2)} hectares (measured from the map)',
              style: AppText.caption),
        ],
      ),
    );
  }
}
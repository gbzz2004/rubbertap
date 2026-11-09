import 'dart:math' as math;

/// Block outlines for the farm map, as [longitude, latitude] corners in order
/// around each block.
///
/// PLACEHOLDER OUTLINES: these are rectangles of about 2 hectares drawn from
/// each block's point in the farm_blocks table. They are NOT the real
/// boundaries. To fix: walk each block's boundary with a phone GPS app, paste
/// the corners below (in order around the block), then set
/// [blockOutlinesArePlaceholders] to false.
const bool blockOutlinesArePlaceholders = true;

const Map<String, List<List<double>>> blockOutlines = {
  // Starts at Block A's first corner (the farm reference point)
  'Block A': [
    [122.567028, 7.762639],
    [122.568310, 7.762639],
    [122.568310, 7.763909],
    [122.567028, 7.763909],
  ],
  // Centred on Block B's point in farm_blocks
  'Block B': [
    [122.568609, 7.762337],
    [122.569891, 7.762337],
    [122.569891, 7.763607],
    [122.568609, 7.763607],
  ],
};

/// The outline for [name], or a 1-hectare square around its point if the
/// block has no outline yet.
List<List<double>> outlineFor(String name, double lat, double lon) {
  final known = blockOutlines[name];
  if (known != null) return known;
  const half = 50.0; // metres
  const dLat = half / 111320.0;
  final dLon = half / (111320.0 * math.cos(lat * math.pi / 180));
  return [
    [lon - dLon, lat - dLat],
    [lon + dLon, lat - dLat],
    [lon + dLon, lat + dLat],
    [lon - dLon, lat + dLat],
  ];
}

/// Average of the corners, good enough for a label or camera target.
List<double> outlineCentre(List<List<double>> ring) {
  var lon = 0.0, lat = 0.0;
  for (final p in ring) {
    lon += p[0];
    lat += p[1];
  }
  return [lon / ring.length, lat / ring.length];
}

/// Whether the point lies inside the outline (ray casting).
bool outlineContains(List<List<double>> ring, double lon, double lat) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final xi = ring[i][0], yi = ring[i][1];
    final xj = ring[j][0], yj = ring[j][1];
    if ((yi > lat) != (yj > lat) &&
        lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

/// Area in hectares (local flat-earth approximation, accurate for a farm).
double outlineHectares(List<List<double>> ring) {
  final lat0 = outlineCentre(ring)[1] * math.pi / 180;
  const mPerDeg = 111320.0;
  var sum = 0.0;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final xi = ring[i][0] * mPerDeg * math.cos(lat0), yi = ring[i][1] * mPerDeg;
    final xj = ring[j][0] * mPerDeg * math.cos(lat0), yj = ring[j][1] * mPerDeg;
    sum += xj * yi - xi * yj;
  }
  return sum.abs() / 2 / 10000;
}

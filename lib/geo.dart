import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Prüft, ob ein Punkt innerhalb des Spielfelds liegt (Strahlverfahren).
bool pointInPolygon(LatLng p, List<LatLng> poly) {
  if (poly.length < 3) return true;
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final xi = poly[i].longitude, yi = poly[i].latitude;
    final xj = poly[j].longitude, yj = poly[j].latitude;
    final intersect = ((yi > p.latitude) != (yj > p.latitude)) &&
        (p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi) + xi);
    if (intersect) inside = !inside;
  }
  return inside;
}

/// Kürzester Abstand in Metern vom Punkt zum Rand des Spielfelds.
double distanceToEdge(LatLng p, List<LatLng> poly) {
  if (poly.length < 2) return double.infinity;
  const r = 6371000.0;
  final lat0 = p.latitude * math.pi / 180;
  math.Point<double> proj(LatLng q) => math.Point(
        (q.longitude - p.longitude) * math.pi / 180 * r * math.cos(lat0),
        (q.latitude - p.latitude) * math.pi / 180 * r,
      );
  var best = double.infinity;
  for (var i = 0; i < poly.length; i++) {
    final a = proj(poly[i]);
    final b = proj(poly[(i + 1) % poly.length]);
    final dx = b.x - a.x, dy = b.y - a.y;
    final len2 = dx * dx + dy * dy;
    final raw = len2 == 0 ? 0.0 : -(a.x * dx + a.y * dy) / len2;
    final t = math.max(0.0, math.min(1.0, raw));
    final cx = a.x + t * dx, cy = a.y + t * dy;
    final d = math.sqrt(cx * cx + cy * cy);
    if (d < best) best = d;
  }
  return best;
}

LatLng centerOf(List<LatLng> pts) {
  var lat = 0.0, lng = 0.0;
  for (final p in pts) {
    lat += p.latitude;
    lng += p.longitude;
  }
  return LatLng(lat / pts.length, lng / pts.length);
}

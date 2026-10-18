import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models.dart';
import '../theme.dart';

const _fallbackCenter = LatLng(51.16, 10.45); // Mitte Deutschlands

/// Gemeinsame Karte für Spieler, Spielleitung und Zuschauer.
class GameMap extends StatelessWidget {
  const GameMap({
    super.key,
    required this.controller,
    required this.area,
    this.markers = const [],
    this.polylines = const [],
    this.initialCenter,
  });

  final MapController controller;
  final List<LatLng> area;
  final List<Marker> markers;
  final List<Polyline> polylines;
  final LatLng? initialCenter;

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      mapController: controller,
      options: MapOptions(
        initialCenter: initialCenter ?? (area.isNotEmpty ? area.first : _fallbackCenter),
        initialZoom: initialCenter != null || area.isNotEmpty ? 15 : 6,
        initialCameraFit: area.length >= 3
            ? CameraFit.bounds(
                bounds: LatLngBounds.fromPoints(area),
                padding: const EdgeInsets.all(48),
              )
            : null,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        backgroundColor: PH.bg,
      ),
      children: [
        darkTiles(context),
        if (area.length >= 3)
          PolygonLayer(polygons: [
            Polygon(
              points: area,
              color: PH.accent.withOpacity(0.08),
              borderColor: PH.accent,
              borderStrokeWidth: 3,
            ),
          ]),
        if (polylines.isNotEmpty) PolylineLayer(polylines: polylines),
        MarkerLayer(markers: markers),
        const SimpleAttributionWidget(
          source: Text('© OpenStreetMap-Mitwirkende'),
          backgroundColor: Color(0xAA0B0E13),
        ),
      ],
    );
  }
}

Widget darkTiles(BuildContext context) => TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'de.pinghunt.pinghunt',
      maxZoom: 19,
      tileBuilder: darkModeTileBuilder,
    );

/// Punkt mit Namensschild darunter; der Punkt liegt genau auf der Position.
Marker labelMarker({
  required LatLng point,
  required Color color,
  required String label,
  double size = 16,
  bool live = false,
  bool ring = false,
  double opacity = 1,
}) {
  const h = 60.0;
  return Marker(
    point: point,
    width: 150,
    height: h,
    child: Opacity(
      opacity: opacity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: h / 2 - size / 2),
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: ring || live ? Colors.white : PH.bg,
                width: ring || live ? 3 : 2,
              ),
              boxShadow: live
                  ? [BoxShadow(color: color.withOpacity(0.6), blurRadius: 14, spreadRadius: 4)]
                  : null,
            ),
          ),
          const SizedBox(height: 2),
          if (label.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: live ? color : PH.surface.withOpacity(0.92),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: live ? PH.bg : PH.text,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// Ping-Verlauf: Linien je Spieler, alte Pings mit Uhrzeit, neuester Ping groß.
/// [count] 1 = nur der neueste, 3/6 = so viele, 0 = alle.
(List<Polyline>, List<Marker>) pingHistory({
  required Game game,
  required List<Ping> pings,
  required int count,
  Set<String>? teamFilter,
  DateTime? cutoff,
  required DateTime now,
}) {
  final byPlayer = <String, List<Ping>>{};
  for (final p in pings) {
    final team = game.team(p.teamId);
    if (team == null || team.isHunter) continue;
    if (teamFilter != null && teamFilter.isNotEmpty && !teamFilter.contains(team.id)) continue;
    if (cutoff != null && p.t.isAfter(cutoff)) continue;
    byPlayer.putIfAbsent(p.uid, () => []).add(p);
  }
  final lines = <Polyline>[];
  final markers = <Marker>[];
  for (final list in byPlayer.values) {
    list.sort((a, b) => a.t.compareTo(b.t));
    final shown = count == 0 || list.length <= count ? list : list.sublist(list.length - count);
    final team = game.team(shown.last.teamId)!;
    final c = Color(team.color);
    if (shown.length > 1) {
      lines.add(Polyline(
        points: [for (final p in shown) p.pos],
        color: c.withOpacity(0.55),
        strokeWidth: 2.5,
      ));
    }
    for (var i = 0; i < shown.length; i++) {
      final p = shown[i];
      final latest = i == shown.length - 1;
      final age = shown.length - 1 - i;
      markers.add(labelMarker(
        point: p.pos,
        color: c,
        size: latest ? 18 : 10,
        label: latest ? '${p.name} · ${ago(p.t, now)}' : hhmm(p.t),
        opacity: latest ? 1 : (1 - age * 0.12).clamp(0.35, 0.9).toDouble(),
      ));
    }
  }
  return (lines, markers);
}

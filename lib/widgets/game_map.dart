import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../geo.dart';
import '../models.dart';
import '../theme.dart';

const _fallbackCenter = LatLng(51.16, 10.45); // Mitte Deutschlands

/// Kartenstil: map = dunkle Karte, sat = Satellit, hybrid = Satellit + Straßennamen.
final mapStyle = ValueNotifier<String>('map');
bool _styleLoaded = false;

Future<void> _loadStyle() async {
  if (_styleLoaded) return;
  _styleLoaded = true;
  try {
    final p = await SharedPreferences.getInstance();
    final v = p.getString('mapStyle');
    if (v == 'map' || v == 'sat' || v == 'hybrid') mapStyle.value = v!;
  } catch (_) {}
}

Future<void> _saveStyle(String v) async {
  mapStyle.value = v;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString('mapStyle', v);
  } catch (_) {}
}

const _esri = 'https://server.arcgisonline.com/ArcGIS/rest/services';

/// Kartenkacheln passend zum gewählten Stil (inkl. Quellenangabe und Umschalter).
List<Widget> baseLayers(BuildContext context, String style) => [
      if (style == 'map')
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'de.pinghunt.pinghunt',
          maxZoom: 19,
          tileBuilder: darkModeTileBuilder,
        )
      else ...[
        TileLayer(
          urlTemplate: '$_esri/World_Imagery/MapServer/tile/{z}/{y}/{x}',
          userAgentPackageName: 'de.pinghunt.pinghunt',
          maxNativeZoom: 19,
          maxZoom: 20,
        ),
        if (style == 'hybrid') ...[
          TileLayer(
            urlTemplate: '$_esri/Reference/World_Transportation/MapServer/tile/{z}/{y}/{x}',
            userAgentPackageName: 'de.pinghunt.pinghunt',
            maxNativeZoom: 19,
            maxZoom: 20,
          ),
          TileLayer(
            urlTemplate: '$_esri/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
            userAgentPackageName: 'de.pinghunt.pinghunt',
            maxNativeZoom: 19,
            maxZoom: 20,
          ),
        ],
      ],
    ];

/// Quellenangabe und Stil-Umschalter – als letzte Kinder einer FlutterMap.
List<Widget> mapOverlays(String style) => [
      SimpleAttributionWidget(
        source: Text(style == 'map'
            ? '© OpenStreetMap-Mitwirkende'
            : 'Esri, Maxar, Earthstar Geographics'),
        backgroundColor: const Color(0xAA0B0E13),
      ),
      const Align(alignment: Alignment.centerRight, child: MapStyleButton()),
    ];

/// Kleiner Knopf rechts auf der Karte: Karte / Satellit / Satellit + Straßen.
class MapStyleButton extends StatelessWidget {
  const MapStyleButton({super.key});

  @override
  Widget build(BuildContext context) {
    _loadStyle();
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: ValueListenableBuilder<String>(
        valueListenable: mapStyle,
        builder: (context, style, _) => Material(
          color: PH.surface.withOpacity(0.95),
          shape: const CircleBorder(side: BorderSide(color: PH.line)),
          child: PopupMenuButton<String>(
            tooltip: 'Kartenansicht',
            icon: Icon(style == 'map' ? Icons.map_outlined : Icons.satellite_alt, color: PH.text),
            color: PH.surface2,
            onSelected: _saveStyle,
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: 'map', checked: style == 'map', child: const Text('Karte')),
              CheckedPopupMenuItem(value: 'sat', checked: style == 'sat', child: const Text('Satellit')),
              CheckedPopupMenuItem(
                  value: 'hybrid', checked: style == 'hybrid', child: const Text('Satellit + Straßen')),
            ],
          ),
        ),
      ),
    );
  }
}

/// Karte, die automatisch dem gewählten Stil folgt.
class StyledMap extends StatelessWidget {
  const StyledMap({super.key, required this.mapController, required this.options, required this.children});

  final MapController mapController;
  final MapOptions options;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    _loadStyle();
    return ValueListenableBuilder<String>(
      valueListenable: mapStyle,
      builder: (context, style, _) => FlutterMap(
        mapController: mapController,
        options: options,
        children: [...baseLayers(context, style), ...children, ...mapOverlays(style)],
      ),
    );
  }
}

/// Gemeinsame Karte für Spieler, Spielleitung und Zuschauer.
class GameMap extends StatelessWidget {
  const GameMap({
    super.key,
    required this.controller,
    required this.area,
    this.markers = const [],
    this.polylines = const [],
    this.initialCenter,
    this.zones = const [],
  });

  final MapController controller;
  final List<LatLng> area;
  final List<Marker> markers;
  final List<Polyline> polylines;
  final LatLng? initialCenter;
  final List<Zone> zones;

  @override
  Widget build(BuildContext context) {
    return StyledMap(
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
        if (area.length >= 3)
          PolygonLayer(polygons: [
            Polygon(
              points: area,
              color: PH.accent.withOpacity(0.08),
              borderColor: PH.accent,
              borderStrokeWidth: 3,
            ),
          ]),
        if (zones.isNotEmpty)
          PolygonLayer(polygons: [
            for (final z in zones)
              Polygon(
                points: z.points,
                color: Color(z.color).withOpacity(z.isBlocked ? 0.38 : 0.2),
                borderColor: Color(z.color),
                borderStrokeWidth: z.isBlocked ? 3.5 : 2,
              ),
          ]),
        if (polylines.isNotEmpty) PolylineLayer(polylines: polylines),
        if (zones.isNotEmpty)
          MarkerLayer(markers: [
            for (final z in zones)
              Marker(
                point: centerOf(z.points),
                width: 160,
                height: 26,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Color(z.color).withOpacity(0.85),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      z.isBlocked ? '⛔ ${z.name}' : z.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: PH.bg),
                    ),
                  ),
                ),
              ),
          ]),
        MarkerLayer(markers: markers),
      ],
    );
  }
}

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

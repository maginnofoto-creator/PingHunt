import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../repo.dart';
import '../theme.dart';
import '../widgets/game_map.dart';

enum _Mode { view, freehand, points }

/// Spielfeld freihand oder Punkt für Punkt zeichnen.
class AreaEditor extends StatefulWidget {
  const AreaEditor({
    super.key,
    required this.code,
    required this.initial,
    this.title = 'Spielfeld zeichnen',
    this.color = PH.accent,
    this.reference = const [],
    this.onSave,
  });

  final String code;
  final List<LatLng> initial;
  final String title;
  final Color color;

  /// Spielfeld als Orientierung beim Zeichnen einer Zone.
  final List<LatLng> reference;

  /// Eigene Speicherfunktion (z. B. für Zonen). Ohne: Spielfeld speichern.
  final Future<void> Function(List<LatLng>)? onSave;

  @override
  State<AreaEditor> createState() => _AreaEditorState();
}

class _AreaEditorState extends State<AreaEditor> {
  final _map = MapController();
  late List<LatLng> _pts = [...widget.initial];
  _Mode _mode = _Mode.view;
  Offset? _lastOffset;
  bool _saving = false;

  List<LatLng> get _fitPts => _pts.length >= 3 ? _pts : widget.reference;

  void _msg(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  void _addFromOffset(Offset o) {
    final last = _lastOffset;
    if (last != null && (o - last).distance < 10) return;
    _lastOffset = o;
    setState(() => _pts.add(_map.camera.offsetToCrs(o)));
  }

  void _finishStroke() {
    _lastOffset = null;
    if (_pts.length > 300) {
      final step = (_pts.length / 300).ceil();
      _pts = [for (var i = 0; i < _pts.length; i += step) _pts[i]];
    }
    setState(() => _mode = _Mode.view);
  }

  Future<void> _myLocation() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      final p = await Geolocator.getCurrentPosition();
      _map.move(LatLng(p.latitude, p.longitude), 16);
    } catch (e) {
      _msg('Standort nicht verfügbar: $e');
    }
  }

  Future<void> _save() async {
    if ((_pts.isNotEmpty || widget.onSave != null) && _pts.length < 3) {
      _msg('Bitte mindestens 3 Punkte zeichnen.');
      return;
    }
    setState(() => _saving = true);
    try {
      if (widget.onSave != null) {
        await widget.onSave!(_pts);
      } else {
        await Repo.i.saveArea(widget.code, _pts);
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _msg('Speichern fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = switch (_mode) {
      _Mode.view => 'Karte verschieben und zoomen, dann einen Zeichenmodus wählen.',
      _Mode.freehand => 'Mit dem Finger oder der Maus das Spielfeld umfahren.',
      _Mode.points => 'Auf die Karte tippen, um Eckpunkte zu setzen.',
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: const Text('Speichern'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: FlutterMap(
                    mapController: _map,
                    options: MapOptions(
                      initialCenter: _fitPts.isNotEmpty ? _fitPts.first : const LatLng(51.16, 10.45),
                      initialZoom: _fitPts.isNotEmpty ? 15 : 6,
                      initialCameraFit: _fitPts.length >= 3
                          ? CameraFit.bounds(
                              bounds: LatLngBounds.fromPoints(_fitPts),
                              padding: const EdgeInsets.all(40),
                            )
                          : null,
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                      ),
                      backgroundColor: PH.bg,
                      onTap: (_, latLng) {
                        if (_mode == _Mode.points) setState(() => _pts.add(latLng));
                      },
                    ),
                    children: [
                      darkTiles(context),
                      if (widget.reference.length >= 3)
                        PolygonLayer(polygons: [
                          Polygon(
                            points: widget.reference,
                            borderColor: PH.accent.withOpacity(0.6),
                            borderStrokeWidth: 2,
                          ),
                        ]),
                      if (_pts.length >= 3)
                        PolygonLayer(polygons: [
                          Polygon(
                            points: _pts,
                            color: widget.color.withOpacity(0.18),
                            borderColor: widget.color,
                            borderStrokeWidth: 3,
                          ),
                        ])
                      else if (_pts.length == 2)
                        PolylineLayer(polylines: [
                          Polyline(points: _pts, color: widget.color, strokeWidth: 3),
                        ]),
                      if (_mode == _Mode.points)
                        MarkerLayer(markers: [
                          for (final p in _pts)
                            Marker(
                              point: p,
                              width: 14,
                              height: 14,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: widget.color,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 2),
                                ),
                              ),
                            ),
                        ]),
                    ],
                  ),
                ),
                if (_mode == _Mode.freehand)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (d) {
                        _lastOffset = null;
                        setState(() => _pts = []);
                        _addFromOffset(d.localPosition);
                      },
                      onPanUpdate: (d) => _addFromOffset(d.localPosition),
                      onPanEnd: (_) => _finishStroke(),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            color: PH.surface,
            padding: const EdgeInsets.all(12),
            child: SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(hint, style: const TextStyle(color: PH.muted)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SegmentedButton<_Mode>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: _Mode.view, icon: Icon(Icons.pan_tool), label: Text('Karte')),
                          ButtonSegment(value: _Mode.freehand, icon: Icon(Icons.gesture), label: Text('Freihand')),
                          ButtonSegment(value: _Mode.points, icon: Icon(Icons.place), label: Text('Punkte')),
                        ],
                        selected: {_mode},
                        onSelectionChanged: (s) => setState(() => _mode = s.first),
                      ),
                      OutlinedButton.icon(
                        onPressed: _pts.isEmpty ? null : () => setState(() => _pts.removeLast()),
                        icon: const Icon(Icons.undo),
                        label: const Text('Zurück'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _pts.isEmpty ? null : () => setState(() => _pts = []),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Löschen'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _myLocation,
                        icon: const Icon(Icons.my_location),
                        label: const Text('Mein Standort'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

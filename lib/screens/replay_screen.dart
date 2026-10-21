import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../jokers.dart';
import '../models.dart';
import '../repo.dart';
import '../theme.dart';
import '../widgets/game_map.dart';
import '../widgets/ui.dart';

/// Wiederholung eines Spiels im Zeitraffer – mit allen Wegen, Pings und Kilometern.
class ReplayScreen extends StatefulWidget {
  const ReplayScreen({super.key, required this.code});

  final String code;

  @override
  State<ReplayScreen> createState() => _ReplayScreenState();
}

class _ReplayScreenState extends State<ReplayScreen> {
  final _map = MapController();
  Game? _game;
  ReplayData? _data;
  String? _error;

  late DateTime _from;
  late DateTime _to;
  DateTime? _t;
  bool _playing = false;
  int _speed = 60;
  Timer? _timer;

  // Vorberechnet: Spur pro Spieler und kumulierte Strecke
  final Map<String, List<TrailPos>> _byUid = {};
  final Map<String, List<double>> _cumDist = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final g = await Repo.i.getGame(widget.code);
      final d = await Repo.i.loadReplay(widget.code);
      if (g == null) throw Exception('Spiel nicht gefunden');
      for (final t in d.trail) {
        _byUid.putIfAbsent(t.uid, () => []).add(t);
      }
      for (final e in _byUid.entries) {
        final cum = <double>[0];
        for (var i = 1; i < e.value.length; i++) {
          final a = e.value[i - 1], b = e.value[i];
          final m = metersBetween(a.pos, b.pos);
          final dt = b.t.difference(a.t).inMilliseconds / 1000;
          cum.add(cum.last + (dt > 0 && m / dt < 60 ? m : 0));
        }
        _cumDist[e.key] = cum;
      }
      final times = [
        ...d.trail.map((x) => x.t),
        ...d.pings.map((x) => x.t),
      ]..sort();
      _from = g.startedAt ?? (times.isNotEmpty ? times.first : DateTime.now());
      _to = times.isNotEmpty ? times.last : (g.endsAt ?? DateTime.now());
      if (_to.isBefore(_from)) _to = _from.add(const Duration(minutes: 1));
      setState(() {
        _game = g;
        _data = d;
        _t = _from;
      });
    } catch (e) {
      setState(() => _error = 'Wiederholung konnte nicht geladen werden: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _toggle() {
    if (_playing) {
      _timer?.cancel();
      setState(() => _playing = false);
      return;
    }
    if (_t != null && !_t!.isBefore(_to)) _t = _from;
    setState(() => _playing = true);
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final next = _t!.add(Duration(milliseconds: 200 * _speed));
      setState(() {
        if (next.isAfter(_to)) {
          _t = _to;
          _playing = false;
          _timer?.cancel();
        } else {
          _t = next;
        }
      });
    });
  }

  int _indexAt(List<TrailPos> list, DateTime t) {
    var lo = 0, hi = list.length - 1, res = -1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (!list[mid].t.isAfter(t)) {
        res = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return res;
  }

  String _km(double m) => m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(1)} km';

  @override
  Widget build(BuildContext context) {
    final g = _game, d = _data, t = _t;
    if (_error != null) {
      return Scaffold(appBar: AppBar(), body: Center(child: Text(_error!)));
    }
    if (g == null || d == null || t == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final markers = <Marker>[];
    final lines = <Polyline>[];
    final standings = <(String, String, int, double)>[]; // uid, name, color, meter

    for (final e in _byUid.entries) {
      final list = e.value;
      final i = _indexAt(list, t);
      if (i < 0) continue;
      final last = list[i];
      final team = g.team(last.teamId);
      final color = team?.color ?? 0xFF9AA4B2;
      final c = Color(color);
      // ganzer bisheriger Weg (dünn) und letzte 5 Minuten (kräftig)
      final path = list.sublist(0, i + 1).map((p) => p.pos).toList();
      if (path.length > 1) lines.add(Polyline(points: path, color: c.withOpacity(0.25), strokeWidth: 2));
      final tail = list
          .sublist(0, i + 1)
          .where((p) => t.difference(p.t).inMinutes <= 5)
          .map((p) => p.pos)
          .toList();
      if (tail.length > 1) lines.add(Polyline(points: tail, color: c.withOpacity(0.9), strokeWidth: 4));
      final stale = t.difference(last.t).inMinutes >= 10;
      markers.add(labelMarker(
        point: last.pos,
        color: c,
        label: last.name,
        size: team?.isHunter ?? false ? 14 : 16,
        ring: true,
        opacity: stale ? 0.4 : 1,
      ));
      standings.add((e.key, last.name, color, _cumDist[e.key]![i]));
    }
    // Pings bis zum Zeitpunkt (verblasst)
    final (pl, pm) = pingHistory(game: g, pings: d.pings, count: 1, cutoff: t, now: t, fade: 0.6);
    lines.addAll(pl);
    markers.addAll(pm);
    standings.sort((a, b) => b.$4.compareTo(a.$4));

    final events = d.events.where((e) => !e.t.isAfter(t)).toList().reversed.take(6).toList();
    final total = _to.difference(_from).inSeconds.clamp(1, 1 << 31);
    final pos = t.difference(_from).inSeconds.clamp(0, total).toDouble();

    final side = ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('GELAUFEN', style: label()),
        const SizedBox(height: 6),
        for (final s in standings)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Dot(Color(s.$3), size: 10),
                const SizedBox(width: 8),
                Expanded(child: Text(s.$2)),
                Text(_km(s.$4), style: mono(13, color: PH.accent)),
              ],
            ),
          ),
        const SizedBox(height: 14),
        Text('EREIGNISSE', style: label()),
        const SizedBox(height: 6),
        for (final e in events)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 44, child: Text(hhmm(e.t), style: mono(12, color: PH.muted))),
                Padding(padding: const EdgeInsets.only(top: 4, right: 8), child: Dot(Color(e.color), size: 8)),
                Expanded(child: Text(e.text, style: const TextStyle(fontSize: 12))),
              ],
            ),
          ),
      ],
    );

    final controls = Container(
      color: PH.surface,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton.filled(
                  onPressed: _toggle,
                  icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                  tooltip: _playing ? 'Pause' : 'Abspielen',
                ),
                const SizedBox(width: 8),
                Text('${hhmm(t)}  ', style: mono(16, color: PH.accent)),
                Expanded(
                  child: Slider(
                    value: pos,
                    max: total.toDouble(),
                    onChanged: (v) => setState(() => _t = _from.add(Duration(seconds: v.round()))),
                  ),
                ),
              ],
            ),
            SegmentedButton<int>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: 10, label: Text('10×')),
                ButtonSegment(value: 60, label: Text('60×')),
                ButtonSegment(value: 300, label: Text('300×')),
                ButtonSegment(value: 1200, label: Text('1200×')),
              ],
              selected: {_speed},
              onSelectionChanged: (s) => setState(() => _speed = s.first),
            ),
          ],
        ),
      ),
    );

    final map = GameMap(controller: _map, area: g.area, markers: markers, polylines: lines, zones: g.zones);

    return Scaffold(
      appBar: AppBar(title: Text('Wiederholung · Spiel ${g.code}')),
      body: LayoutBuilder(builder: (context, box) {
        if (box.maxWidth >= 900) {
          return Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(child: map),
                    SizedBox(width: 300, child: side),
                  ],
                ),
              ),
              controls,
            ],
          );
        }
        return Column(
          children: [
            Expanded(child: map),
            SizedBox(height: 170, child: side),
            controls,
          ],
        );
      }),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../models.dart';
import '../repo.dart';
import '../theme.dart';
import '../widgets/game_map.dart';
import '../widgets/ui.dart';

/// Zuschauer-Ansicht – mit der von der Spielleitung eingestellten Verzögerung.
class SpectatorScreen extends StatefulWidget {
  const SpectatorScreen({super.key, required this.code});

  final String code;

  @override
  State<SpectatorScreen> createState() => _SpectatorScreenState();
}

class _SpectatorScreenState extends State<SpectatorScreen> {
  final _repo = Repo.i;
  final _map = MapController();

  Game? _game;
  bool _loaded = false;
  List<Player> _players = [];
  List<Ping> _pings = [];
  List<GameEvent> _events = [];
  List<TrailPos> _trail = [];
  int _history = 3;

  final _subs = <StreamSubscription>[];
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    final c = widget.code;
    _subs.add(_repo.gameStream(c).listen((g) => setState(() {
          _game = g;
          _loaded = true;
        })));
    _subs.add(_repo.playersStream(c).listen((p) => setState(() => _players = p)));
    _subs.add(_repo.pingsStream(c).listen((p) => setState(() => _pings = p)));
    _subs.add(_repo.eventsStream(c).listen((e) => setState(() => _events = e)));
    // Jäger-Positionen der letzten 30 Minuten
    _subs.add(_repo
        .trailStream(c, DateTime.now().subtract(const Duration(minutes: 30)))
        .listen((t) => setState(() => _trail = t), onError: (_) {}));
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = _game;
    final now = DateTime.now();
    if (!_loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (g == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Spiel nicht gefunden.')));
    }
    final delay = Duration(minutes: g.spectatorDelayMin);
    final cutoff = now.subtract(delay);

    final (lines, markers) = pingHistory(
        game: g, pings: _pings, count: _history, cutoff: cutoff, now: now);
    if (delay == Duration.zero) {
      for (final p in _players) {
        final t = g.team(p.teamId);
        if (t == null || t.isHunter || p.exposed == null || !p.isLive(now)) continue;
        markers.add(labelMarker(
          point: p.exposed!,
          color: Color(t.color),
          label: '${p.name} · LIVE',
          size: 18,
          live: true,
        ));
      }
    }
    // Jäger: immer ohne Verzögerung (letzte bekannte Position)
    final hunters = <String, TrailPos>{};
    for (final t in _trail) {
      if (now.difference(t.t).inMinutes > 30) continue;
      final team = g.team(t.teamId);
      if (team == null || !team.isHunter) continue;
      hunters[t.uid] = t;
    }
    for (final h in hunters.values) {
      markers.add(labelMarker(
        point: h.pos,
        color: Color(g.team(h.teamId)?.color ?? PH.hunterColor),
        label: now.difference(h.t).inMinutes >= 2 ? '${h.name} · ${ago(h.t, now)}' : h.name,
        size: 14,
        ring: true,
      ));
    }
    final events = _events.where((e) => !e.t.isAfter(cutoff)).toList();

    final map = Stack(
      children: [
        Positioned.fill(
            child: GameMap(controller: _map, area: g.area, markers: markers, polylines: lines, zones: g.zones)),
        Positioned(
          left: 12,
          top: 12,
          right: 12,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in g.teamList) Pill(dot: Color(t.color), child: Text(t.name)),
              Pill(
                dot: PH.accent,
                child: Text(delay == Duration.zero
                    ? 'Live ohne Verzögerung'
                    : '${g.spectatorDelayMin} min verzögert'),
              ),
              Container(
                decoration: BoxDecoration(color: PH.surface, borderRadius: BorderRadius.circular(999)),
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 1, label: Text('Letzter')),
                    ButtonSegment(value: 3, label: Text('3')),
                    ButtonSegment(value: 6, label: Text('6')),
                    ButtonSegment(value: 0, label: Text('Alle')),
                  ],
                  selected: {_history},
                  onSelectionChanged: (s) => setState(() => _history = s.first),
                ),
              ),
            ],
          ),
        ),
        if (g.isRunning)
          Positioned(
            right: 12,
            bottom: 28,
            child: Panel(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('NÄCHSTER PING', style: label()),
                  Text(
                    g.nextPing(now) == null ? '--:--' : countdown(g.nextPing(now)!.difference(now)),
                    style: mono(40, color: PH.accent),
                  ),
                ],
              ),
            ),
          ),
      ],
    );

    final eventList = ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('EREIGNISSE', style: label()),
        const SizedBox(height: 8),
        for (final e in events)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 44, child: Text(hhmm(e.t), style: mono(12, color: PH.muted))),
                Padding(padding: const EdgeInsets.only(top: 4, right: 8), child: Dot(Color(e.color), size: 8)),
                Expanded(child: Text(e.text, style: const TextStyle(fontSize: 13))),
              ],
            ),
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text('PINGHUNT · Spiel ${g.code} · Zuschauer',
            style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2)),
      ),
      body: LayoutBuilder(builder: (context, box) {
        if (box.maxWidth >= 900) {
          return Row(
            children: [
              Expanded(child: map),
              SizedBox(width: 320, child: eventList),
            ],
          );
        }
        return Column(
          children: [
            Expanded(child: map),
            SizedBox(height: 180, child: eventList),
          ],
        );
      }),
    );
  }
}

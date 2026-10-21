import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../jokers.dart';
import '../models.dart';
import '../repo.dart';
import '../theme.dart';
import '../widgets/game_map.dart';
import '../widgets/big_toast.dart';
import '../widgets/ui.dart';

/// Zuschauer-Ansicht – was sichtbar ist, legt die Spielleitung fest.
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
  List<Ping> _pings = [];
  List<GameEvent> _events = [];
  List<TrailPos> _trail = [];
  int _history = 1;

  final _subs = <StreamSubscription>[];
  StreamSubscription? _trailSub;
  final Map<String, StreamSubscription> _chatSubs = {};
  final Map<String, List<ChatMsg>> _chats = {};
  Timer? _clock;
  Timer? _trailRefresh;
  final _toasts = ToastQueue();
  final DateTime _openedAt = DateTime.now();
  List<CatchReport> _catches = [];
  List<Effect> _effects = [];
  final Set<String> _shown = {};

  /// Große Einblendungen für Fänge und Joker – mit der Zuschauer-Verzögerung.
  void _releaseToasts(Game g, DateTime now) {
    final delay = Duration(minutes: g.spectatorDelayMin);
    for (final c in _catches) {
      final at = c.decidedAt;
      if (c.status != 'confirmed' || at == null) continue;
      final showAt = at.add(delay);
      if (showAt.isBefore(_openedAt) || showAt.isAfter(now) || !_shown.add('c${c.id}')) continue;
      _toasts.show(ToastItem(Icons.back_hand, 'GEFANGEN!', '${c.targetName} wurde von ${c.byName} gefangen',
          color: PH.danger));
    }
    for (final e in _effects) {
      final showAt = e.start.add(delay);
      if (showAt.isBefore(_openedAt) || showAt.isAfter(now) || !_shown.add('e${e.id}')) continue;
      final d = jokerDef(e.type);
      if (d == null) continue;
      final who = d.forHunters ? 'Jäger ${e.byName}' : '${g.team(e.byTeam)?.name ?? ''} · ${e.byName}';
      _toasts.show(ToastItem(d.icon, d.name, '🃏 $who', color: d.forHunters ? PH.danger : PH.accent));
    }
  }

  @override
  void initState() {
    super.initState();
    final c = widget.code;
    _subs.add(_repo.gameStream(c).listen((g) {
      setState(() {
        _game = g;
        _loaded = true;
      });
      _updateChats();
    }));
    _subs.add(_repo.pingsStream(c).listen((p) => setState(() => _pings = p)));
    _subs.add(_repo.eventsStream(c).listen((e) => setState(() => _events = e)));
    _subscribeTrail();
    _subs.add(_repo.catchesStream(c).listen((l) => _catches = l, onError: (_) {}));
    _subs.add(_repo.effectsStream(c).listen((l) => _effects = l, onError: (_) {}));
    // Spur-Abfrage regelmäßig erneuern, damit sie nicht endlos wächst
    _trailRefresh = Timer.periodic(const Duration(minutes: 15), (_) => _subscribeTrail());
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final g = _game;
      if (g != null) _releaseToasts(g, DateTime.now());
      setState(() {});
    });
  }

  void _subscribeTrail() {
    _trailSub?.cancel();
    // Maximal 60 min Verzögerung + 30 min Spur
    _trailSub = _repo
        .trailStream(widget.code, DateTime.now().subtract(const Duration(minutes: 95)))
        .listen((t) => setState(() => _trail = t), onError: (_) {});
  }

  void _updateChats() {
    final g = _game;
    final wanted = <String>{
      if (g != null && g.spec.announcements) 'all',
      if (g != null && g.spec.teamChats != 'off')
        for (final id in g.spec.chatTeams) 'team:$id',
    };
    for (final ch in _chatSubs.keys.toList()) {
      if (!wanted.contains(ch)) {
        _chatSubs.remove(ch)?.cancel();
        _chats.remove(ch);
      }
    }
    for (final ch in wanted) {
      if (_chatSubs.containsKey(ch)) continue;
      _chatSubs[ch] = _repo.messagesStream(widget.code, ch).listen(
            (l) => setState(() => _chats[ch] = l),
            onError: (_) {},
          );
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    for (final s in _chatSubs.values) {
      s.cancel();
    }
    _trailSub?.cancel();
    _clock?.cancel();
    _trailRefresh?.cancel();
    _toasts.dispose();
    super.dispose();
  }

  /// Zeitgrenze für eine Sichtbarkeits-Stufe (null = nichts zeigen).
  DateTime? _cutoffFor(String mode, Game g, DateTime now) {
    if (mode == 'off') return null;
    if (mode == 'delay') return now.subtract(Duration(minutes: g.spectatorDelayMin));
    return now;
  }

  @override
  Widget build(BuildContext context) {
    final g = _game;
    final now = DateTime.now();
    if (!_loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (g == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Spiel nicht gefunden.')));
    }
    final sp = g.spec;
    final huntedCut = _cutoffFor(sp.hunted, g, now);
    final hunterCut = _cutoffFor(sp.hunters, g, now);
    final delayCut = now.subtract(Duration(minutes: g.spectatorDelayMin));

    final markers = <Marker>[];
    final lines = <Polyline>[];

    // Letzte Pings verblasst (zeitlich wie die Gejagten bzw. die Verzögerung)
    if (sp.lastPings) {
      final (pl, pm) = pingHistory(
        game: g,
        pings: _pings,
        count: _history,
        cutoff: huntedCut ?? delayCut,
        now: now,
        fade: 0.55,
      );
      lines.addAll(pl);
      markers.addAll(pm);
    }

    // Live-Verfolgung aus der Spur: letzte Position vor der Zeitgrenze + kurzer Schweif
    final byUid = <String, List<TrailPos>>{};
    for (final t in _trail) {
      final team = g.team(t.teamId);
      if (team == null) continue;
      final cut = team.isHunter ? hunterCut : huntedCut;
      if (cut == null || t.t.isAfter(cut)) continue;
      if (cut.difference(t.t).inMinutes > 30) continue;
      byUid.putIfAbsent(t.uid, () => []).add(t);
    }
    for (final list in byUid.values) {
      list.sort((a, b) => a.t.compareTo(b.t));
      final last = list.last;
      final team = g.team(last.teamId)!;
      final c = Color(team.color);
      final cut = (team.isHunter ? hunterCut : huntedCut)!;
      final tail = list.where((p) => cut.difference(p.t).inMinutes <= 10).map((p) => p.pos).toList();
      if (tail.length > 1) {
        lines.add(Polyline(points: tail, color: c.withOpacity(0.8), strokeWidth: 3));
      }
      final age = cut.difference(last.t).inMinutes;
      markers.add(labelMarker(
        point: last.pos,
        color: c,
        label: age >= 2 ? '${last.name} · vor $age min' : last.name,
        size: team.isHunter ? 14 : 16,
        ring: true,
      ));
    }

    final events = _events.where((e) => !e.t.isAfter(delayCut)).toList();

    // Nachrichten (Durchsagen live, Team-Chats je nach Einstellung)
    final msgs = <(ChatMsg, String)>[];
    for (final e in _chats.entries) {
      final isAll = e.key == 'all';
      final teamId = isAll ? null : e.key.substring(5);
      final title = isAll ? 'Durchsage' : (g.team(teamId)?.name ?? 'Team');
      for (final m in e.value) {
        if (!isAll && sp.teamChats == 'delay' && m.t.isAfter(delayCut)) continue;
        msgs.add((m, title));
      }
    }
    msgs.sort((a, b) => b.$1.t.compareTo(a.$1.t));

    String modeText(String mode) => switch (mode) {
          'live' => 'live',
          'delay' => '${g.spectatorDelayMin} min verzögert',
          _ => 'ausgeblendet',
        };

    final map = Stack(
      children: [
        Positioned.fill(
            child: GameMap(controller: _map, area: g.area, markers: markers, polylines: lines, zones: g.zones)),
        Positioned(
          left: 12,
          top: 12,
          right: 64,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in g.teamList) Pill(dot: Color(t.color), child: Text(t.name)),
              Pill(dot: PH.danger, child: Text('Jäger ${modeText(sp.hunters)}')),
              Pill(dot: PH.accent, child: Text('Gejagte ${modeText(sp.hunted)}')),
              if (sp.lastPings)
                Container(
                  decoration: BoxDecoration(color: PH.surface, borderRadius: BorderRadius.circular(999)),
                  child: SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 1, label: Text('Letzter Ping')),
                      ButtonSegment(value: 3, label: Text('3')),
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

    Widget eventList() => ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (events.isEmpty) const Text('Noch nichts passiert.', style: TextStyle(color: PH.muted)),
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

    Widget chatList() => ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (msgs.isEmpty)
              Text(
                _chats.isEmpty ? 'Die Spielleitung hat keine Chats freigegeben.' : 'Noch keine Nachrichten.',
                style: const TextStyle(color: PH.muted),
              ),
            for (final (m, title) in msgs)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: m.fromLeader ? PH.accent.withOpacity(0.15) : PH.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: m.fromLeader ? PH.accent : PH.line),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$title · ${m.fromName} · ${hhmm(m.t)}',
                        style: const TextStyle(fontSize: 11, color: PH.muted, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(m.kind == 'loc' ? '📍 hat einen Standort geteilt' : m.text,
                        style: TextStyle(fontWeight: m.kind == 'quick' ? FontWeight.w800 : FontWeight.w400)),
                  ],
                ),
              ),
          ],
        );

    final side = DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(tabs: [Tab(text: 'Ereignisse'), Tab(text: 'Chats')]),
          Expanded(child: TabBarView(children: [eventList(), chatList()])),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text('PINGHUNT · Spiel ${g.code} · Zuschauer',
            style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2)),
      ),
      body: Stack(children: [
        Positioned.fill(child: _body(map, side)),
        Positioned.fill(child: BigToastView(queue: _toasts)),
      ]),
    );
  }

  Widget _body(Widget map, Widget side) {
    return LayoutBuilder(builder: (context, box) {
        if (box.maxWidth >= 900) {
          return Row(
            children: [
              Expanded(child: map),
              SizedBox(width: 340, child: side),
            ],
          );
        }
        return Column(
          children: [
            Expanded(child: map),
            SizedBox(height: 240, child: side),
          ],
        );
      });
  }
}


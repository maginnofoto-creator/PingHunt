import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../models.dart';
import '../player_engine.dart';
import '../repo.dart';
import '../theme.dart';
import '../widgets/game_map.dart';
import '../widgets/ui.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.code});

  final String code;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final _repo = Repo.i;
  final _map = MapController();
  late final PlayerEngine _engine;

  Game? _game;
  List<Player> _players = [];
  List<Ping> _pings = [];
  List<LivePos> _live = [];
  String? _liveTeam;
  bool _gameLoaded = false;

  final _subs = <StreamSubscription>[];
  StreamSubscription? _liveSub;
  Timer? _clock;

  int _history = 3; // 1, 3, 6, 0 = alle
  final Set<String> _teamFilter = {};
  bool _centered = false;

  Player? get _me {
    for (final p in _players) {
      if (p.uid == _repo.uid) return p;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _engine = PlayerEngine(widget.code)..addListener(_onEngine);
    _engine.start();
    _subs.add(_repo.gameStream(widget.code).listen((g) {
      setState(() {
        _game = g;
        _gameLoaded = true;
      });
      _engine.update(g, _me);
    }));
    _subs.add(_repo.playersStream(widget.code).listen((ps) {
      setState(() => _players = ps);
      final me = _me;
      _engine.update(_game, me);
      if (me?.teamId != _liveTeam) _subscribeLive(me?.teamId);
    }));
    _subs.add(_repo.pingsStream(widget.code).listen((ps) => setState(() => _pings = ps)));
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _onEngine() {
    if (!mounted) return;
    if (!_centered && _engine.latLng != null && (_game?.area.length ?? 0) < 3) {
      _centered = true;
      _map.move(_engine.latLng!, 16);
    }
    setState(() {});
  }

  void _subscribeLive(String? teamId) {
    _liveSub?.cancel();
    _liveTeam = teamId;
    _live = [];
    if (teamId == null) return;
    _liveSub = _repo.liveStream(widget.code, teamId: teamId).listen(
          (l) => setState(() => _live = l),
          onError: (_) {},
        );
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _liveSub?.cancel();
    _clock?.cancel();
    _engine.removeListener(_onEngine);
    _engine.dispose();
    super.dispose();
  }

  Future<void> _reportCatch() async {
    final g = _game;
    if (g == null) return;
    final hunted = _players.where((p) {
      final t = g.team(p.teamId);
      return t != null && !t.isHunter && !p.isCaught;
    }).toList();
    final chosen = await showModalBottomSheet<Player>(
      context: context,
      backgroundColor: PH.surface,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Wen hast du gefangen?',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            for (final p in hunted)
              ListTile(
                leading: Dot(Color(g.team(p.teamId)!.color)),
                title: Text(p.name),
                subtitle: Text(g.team(p.teamId)!.name),
                onTap: () => Navigator.pop(c, p),
              ),
            if (hunted.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Keine freien Gejagten.'),
              ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    await _repo.addEvent(
      widget.code,
      'Fang gemeldet: ${chosen.name} durch ${_me?.name ?? 'Jäger'} – Spielleitung bitte bestätigen',
      PH.hunterColor,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fang gemeldet. Die Spielleitung bestätigt ihn.')),
      );
    }
  }

  List<Marker> _markers(Game g, Player? me, DateTime now) {
    final markers = <Marker>[];
    final myTeam = g.team(me?.teamId);

    if (myTeam != null && myTeam.isHunter) {
      final (_, pingMarkers) = pingHistory(
          game: g, pings: _pings, count: _history, teamFilter: _teamFilter, now: now);
      markers.addAll(pingMarkers);
      for (final p in _players) {
        final t = g.team(p.teamId);
        if (t == null || t.isHunter || p.exposed == null || !p.isLive(now)) continue;
        markers.add(labelMarker(
          point: p.exposed!,
          color: Color(t.color),
          label: '${p.name} · LIVE ${countdown(p.liveUntil!.difference(now))}',
          size: 18,
          live: true,
        ));
      }
    }

    for (final l in _live) {
      if (l.uid == _repo.uid) continue;
      final t = g.team(l.teamId);
      markers.add(labelMarker(
        point: l.pos,
        color: Color(t?.color ?? 0xFF9AA4B2),
        label: l.name,
        size: 13,
      ));
    }

    final pos = _engine.latLng;
    if (pos != null) {
      markers.add(labelMarker(
        point: pos,
        color: Color(myTeam?.color ?? 0xFFEEF1F5),
        label: 'Du',
        size: 20,
        ring: true,
        live: me?.isLive(now) ?? false,
      ));
    }
    return markers;
  }

  @override
  Widget build(BuildContext context) {
    final g = _game;
    final now = DateTime.now();

    if (!_gameLoaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (g == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Dieses Spiel gibt es nicht mehr.')),
      );
    }
    final me = _me;
    final myTeam = g.team(me?.teamId);
    final isHunter = myTeam?.isHunter ?? false;

    final polylines = isHunter
        ? pingHistory(game: g, pings: _pings, count: _history, teamFilter: _teamFilter, now: now).$1
        : <Polyline>[];

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        final leave = await confirm(context, 'Spiel verlassen?',
            'Dein Standort wird dann nicht mehr übertragen und Pings fallen aus.');
        if (leave && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: GameMap(
                controller: _map,
                area: g.area,
                markers: _markers(g, me, now),
                polylines: polylines,
                initialCenter: _engine.latLng,
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(g, now),
                    const SizedBox(height: 8),
                    _chips(g, me, myTeam),
                    const SizedBox(height: 8),
                    _statusCard(g, me, myTeam, now),
                  ],
                ),
              ),
            ),
            Positioned(
              right: 12,
              bottom: isHunter ? 196 : 120,
              child: FloatingActionButton.small(
                heroTag: 'center',
                backgroundColor: PH.surface,
                foregroundColor: PH.text,
                tooltip: 'Auf mich zentrieren',
                onPressed: _engine.latLng == null ? null : () => _map.move(_engine.latLng!, 16),
                child: const Icon(Icons.my_location),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: _bottomPanel(g, me, myTeam),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(Game g, DateTime now) {
    final left = g.endsAt?.difference(now);
    return Row(
      children: [
        const Text('PINGHUNT', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 3)),
        const Spacer(),
        if (g.isRunning && left != null)
          Pill(
            dot: PH.good,
            child: Text('${countdown(left)} übrig', style: mono(12)),
          ),
      ],
    );
  }

  Widget _chips(Game g, Player? me, Team? myTeam) {
    final chips = <Widget>[];
    if (myTeam == null) {
      chips.add(const Pill(child: Text('Noch keinem Team zugeteilt')));
    } else {
      chips.add(Pill(
        filled: Color(myTeam.color),
        child: Text(
          '${myTeam.isHunter ? 'JÄGER' : 'GEJAGT'} · ${myTeam.name.toUpperCase()}',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: PH.bg),
        ),
      ));
    }
    if (me?.isCaught ?? false) {
      chips.add(const Pill(dot: PH.danger, child: Text('Gefangen')));
    }
    if (g.area.length >= 3 && _engine.inside != null) {
      final d = _engine.distToEdge;
      chips.add(Pill(
        dot: _engine.inside! ? PH.good : PH.danger,
        child: Text(_engine.inside!
            ? 'Im Spielfeld · ${d == null ? '-' : d.round()} m zum Rand'
            : 'AUSSERHALB des Spielfelds'),
      ));
    }
    return Wrap(spacing: 6, runSpacing: 6, children: chips);
  }

  Widget _statusCard(Game g, Player? me, Team? myTeam, DateTime now) {
    final live = me?.isLive(now) ?? false;
    final children = <Widget>[];
    if (_engine.error != null) {
      children.add(Text(_engine.error!, style: const TextStyle(color: PH.danger)));
    }
    if (g.isLobby) {
      children.add(const Text('Warte auf den Spielstart …',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)));
      children.add(const SizedBox(height: 4));
      children.add(Text(
        myTeam == null
            ? 'Die Spielleitung teilt dich gleich einem Team zu.'
            : 'Du bist in ${myTeam.name}.',
        style: const TextStyle(color: PH.muted),
      ));
    } else if (g.isEnded) {
      children.add(const Text('Spiel beendet', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)));
    } else {
      final next = g.nextPing(now);
      final headStart = g.pingAnchor != null && now.isBefore(g.pingAnchor!);
      children.add(Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(headStart ? 'VORSPRUNG · ERSTER PING' : 'NÄCHSTER PING', style: label()),
              Text(next == null ? '--:--' : countdown(next.difference(now)),
                  style: mono(40, color: PH.accent)),
            ],
          ),
          const Spacer(),
          Text(
            'Intervall ${g.intervalMin} min\n${(myTeam?.isHunter ?? false) ? 'Dann siehst du die Gejagten' : 'Dann sehen dich die Jäger'}',
            textAlign: TextAlign.right,
            style: const TextStyle(color: PH.muted, fontSize: 12, height: 1.4),
          ),
        ],
      ));
    }
    if (live) {
      children.add(const SizedBox(height: 10));
      children.add(Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: PH.danger, borderRadius: BorderRadius.circular(12)),
        child: Text(
          'Du bist LIVE sichtbar – noch ${countdown(me!.liveUntil!.difference(now))}',
          style: const TextStyle(color: PH.bg, fontWeight: FontWeight.w800),
        ),
      ));
    }
    return Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children));
  }

  Widget _bottomPanel(Game g, Player? me, Team? myTeam) {
    final isHunter = myTeam?.isHunter ?? false;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: const BoxDecoration(
        color: PH.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: PH.line)),
      ),
      child: SafeArea(
        top: false,
        child: isHunter
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text('Ping-Verlauf', style: label()),
                      const Spacer(),
                      SegmentedButton<int>(
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
                    ],
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final t in g.teamList.where((t) => !t.isHunter))
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: FilterChip(
                              avatar: Dot(Color(t.color)),
                              label: Text(t.name),
                              selected: _teamFilter.contains(t.id),
                              onSelected: (v) => setState(() {
                                v ? _teamFilter.add(t.id) : _teamFilter.remove(t.id);
                              }),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: g.isRunning ? _reportCatch : null,
                    icon: const Icon(Icons.back_hand),
                    label: const Text('Fang melden'),
                  ),
                ],
              )
            : Text(
                myTeam == null
                    ? 'Sobald du in einem Team bist, siehst du hier deine Mitspieler.'
                    : 'Dein Team sieht dich live. Die Jäger sehen dich nur beim Ping – '
                        'oder ${g.liveMin} Minuten lang, wenn du das Spielfeld verlässt.',
                style: const TextStyle(color: PH.muted, height: 1.4),
              ),
      ),
    );
  }
}

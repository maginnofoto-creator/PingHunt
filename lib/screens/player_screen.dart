import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../chat.dart';
import '../models.dart';
import '../notify.dart';
import '../player_engine.dart';
import '../repo.dart';
import '../theme.dart';
import '../tracker.dart';
import '../widgets/game_map.dart';
import '../widgets/ui.dart';
import 'chat_screen.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.code, this.observer = false});

  final String code;

  /// Zentrale: Team-Ansicht im Browser, ohne eigenen Standort.
  final bool observer;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final _repo = Repo.i;
  final _map = MapController();
  late final PlayerEngine _engine;
  late final ChatWatcher _chat;
  String _chatKey = '';
  LatLng? _sharedPin;
  DateTime? _sharedPinAt;

  Game? _game;
  List<Player> _players = [];
  List<Ping> _pings = [];
  List<LivePos> _live = [];
  List<GameEvent> _events = [];
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
    // Die App-Ansicht rechnet nur für die Anzeige; Pings & Co. sendet der Hintergrunddienst.
    _engine = PlayerEngine(widget.code, passive: true)..addListener(_onEngine);
    _chat = ChatWatcher(widget.code, notify: widget.observer)..addListener(_onEngine);
    if (!widget.observer) Tracker.start(widget.code);
    Notify.init();
    _updateChat(null);
    if (!widget.observer) _engine.start();
    if (widget.observer) {
      _subs.add(_repo.eventsStream(widget.code).listen((e) => setState(() => _events = e)));
    }
    _subs.add(_repo.gameStream(widget.code).listen((g) {
      setState(() {
        _game = g;
        _gameLoaded = true;
      });
      _engine.update(g, _me);
      _updateChat(_me);
    }));
    _subs.add(_repo.playersStream(widget.code).listen((ps) {
      setState(() => _players = ps);
      final me = _me;
      _engine.update(_game, me);
      if (me?.teamId != _liveTeam) _subscribeLive(me?.teamId);
      _updateChat(me);
    }));
    _subs.add(_repo.pingsStream(widget.code).listen((ps) => setState(() => _pings = ps)));
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _updateChat(Player? me) {
    final team = _game?.team(me?.teamId);
    final key = '${team?.id}|${team?.name}';
    if (key == _chatKey) return;
    _chatKey = key;
    _chat.watch({
      'all': 'Durchsage',
      'dm:${_repo.uid}': 'Spielleitung',
      if (team != null) 'team:${team.id}': team.name,
    });
  }

  Future<void> _openChat(Game g, Player? me) async {
    final pos = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerChatScreen(
          watcher: _chat,
          myName: me?.name ?? 'Spieler',
          team: g.team(me?.teamId),
          myPos: widget.observer ? null : () => _engine.latLng,
          spectatorNote: me?.teamId != null && g.spec.chatVisible(me!.teamId!)
              ? (g.spec.teamChats == 'delay'
                  ? '👀 Zuschauer lesen diesen Chat mit (${g.spectatorDelayMin} min verzögert)'
                  : '👀 Zuschauer lesen diesen Chat live mit')
              : null,
        ),
      ),
    );
    if (pos != null && mounted) {
      setState(() {
        _sharedPin = pos;
        _sharedPinAt = DateTime.now();
      });
      _map.move(pos, 17);
    }
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
    _chat.removeListener(_onEngine);
    _chat.dispose();
    _engine.dispose();
    super.dispose();
  }

  Future<void> _reportCatch() async {
    final g = _game;
    if (g == null) return;
    final hunted = _players.where((p) {
      final t = g.team(p.teamId);
      return t != null && !t.isHunter && !p.isCaught && !p.observer;
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

    if (_sharedPin != null &&
        _sharedPinAt != null &&
        now.difference(_sharedPinAt!).inMinutes < 10) {
      markers.add(labelMarker(
        point: _sharedPin!,
        color: PH.accent,
        label: '📍 geteilt',
        size: 16,
        ring: true,
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
        final leave = widget.observer ||
            await confirm(context, 'Spiel verlassen?',
                'Dein Standort wird dann nicht mehr übertragen und Pings fallen aus. '
                'Tipp: Mit der Home-Taste kannst du die App einfach verlassen – das Spiel läuft weiter.');
        if (!leave) return;
        if (!widget.observer) await Tracker.stop();
        if (context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        body: _wideWrap(Stack(
          children: [
            Positioned.fill(
              child: GameMap(
                controller: _map,
                area: g.area,
                markers: _markers(g, me, now),
                polylines: polylines,
                initialCenter: _engine.latLng,
                zones: [for (final z in g.zones) if (z.visibleTo(_repo.uid, me?.teamId)) z],
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: _limitWidth(Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(g, now),
                    const SizedBox(height: 8),
                    _chips(g, me, myTeam),
                    const SizedBox(height: 8),
                    _statusCard(g, me, myTeam, now),
                    ..._liveBanners(g, myTeam, now),
                  ],
                )),
              ),
            ),
            Positioned(
              right: 12,
              bottom: (isHunter ? 196 : 120) + 52,
              child: UnreadBadge(
                count: _chat.totalUnread,
                child: FloatingActionButton.small(
                  heroTag: 'chat',
                  backgroundColor: PH.accent,
                  foregroundColor: PH.bg,
                  tooltip: 'Nachrichten',
                  onPressed: () => _openChat(g, me),
                  child: const Icon(Icons.chat_bubble),
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
              alignment: widget.observer ? Alignment.bottomLeft : Alignment.bottomCenter,
              child: widget.observer
                  ? ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: _bottomPanel(g, me, myTeam),
                    )
                  : _bottomPanel(g, me, myTeam),
            ),
          ],
        )),
      ),
    );
  }

  /// Im Browser (breiter Bildschirm): Karte links, Ereignisse rechts.
  Widget _wideWrap(Widget main) {
    if (!widget.observer) return main;
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < 1000) return main;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: main),
          Container(
            width: 340,
            color: PH.surface,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('EREIGNISSE', style: label()),
                const SizedBox(height: 10),
                if (_events.isEmpty)
                  const Text('Noch nichts passiert.', style: TextStyle(color: PH.muted)),
                for (final e in _events)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 44, child: Text(hhmm(e.t), style: mono(12, color: PH.muted))),
                        Padding(
                          padding: const EdgeInsets.only(top: 4, right: 8),
                          child: Dot(Color(e.color), size: 8),
                        ),
                        Expanded(child: Text(e.text, style: const TextStyle(fontSize: 13, height: 1.35))),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    });
  }

  /// Jäger: roter Balken je Gejagtem, der gerade live sichtbar ist.
  List<Widget> _liveBanners(Game g, Team? myTeam, DateTime now) {
    if (myTeam == null || !myTeam.isHunter) return const [];
    final live = _players.where((p) {
      final t = g.team(p.teamId);
      return t != null && !t.isHunter && !p.observer && p.exposed != null && p.isLive(now);
    }).toList();
    return [
      for (final p in live)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Material(
            color: PH.danger,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _map.move(p.exposed!, 17),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.radar, color: PH.bg, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'LIVE: ${p.name} (${g.team(p.teamId)!.name}) · noch ${countdown(p.liveUntil!.difference(now))}',
                        style: const TextStyle(color: PH.bg, fontWeight: FontWeight.w800),
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: PH.bg),
                  ],
                ),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _limitWidth(Widget child) => widget.observer
      ? Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: child),
        )
      : child;

  Widget _header(Game g, DateTime now) {
    final left = g.endsAt?.difference(now);
    return Row(
      children: [
        const Text('PINGHUNT', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 3)),
        if (widget.observer) ...[
          const SizedBox(width: 10),
          const Pill(dot: PH.accent, child: Text('ZENTRALE · ohne GPS')),
        ],
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
    if (_engine.inBlocked != null) {
      chips.add(Pill(
        filled: PH.danger,
        child: Text('IM SPERRGEBIET: ${_engine.inBlocked!.name}',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: PH.bg)),
      ));
    } else if ((_engine.distToBlocked ?? double.infinity) < 50) {
      chips.add(Pill(dot: PH.danger, child: Text('Sperrgebiet in ${_engine.distToBlocked!.round()} m')));
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
            ? (widget.observer
                ? 'Die Spielleitung muss dich als Zentrale einem Team zuteilen.'
                : 'Die Spielleitung teilt dich gleich einem Team zu.')
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
                widget.observer
                    ? (myTeam == null
                        ? 'Die Spielleitung muss dich noch einem Team zuteilen. Danach siehst du hier, was dein Team sieht.'
                        : 'Zentrale von ${myTeam.name}: Du siehst dein Team live. Dein eigener Standort wird nicht gesendet.')
                    : myTeam == null
                    ? 'Sobald du in einem Team bist, siehst du hier deine Mitspieler.'
                    : 'Dein Team sieht dich live. Die Jäger sehen dich nur beim Ping – '
                        'oder ${g.liveMin} Minuten lang, wenn du das Spielfeld verlässt.',
                style: const TextStyle(color: PH.muted, height: 1.4),
              ),
      ),
    );
  }
}

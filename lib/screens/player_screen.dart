import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../chat.dart';
import '../jokers.dart';
import '../models.dart';
import '../notify.dart';
import '../player_engine.dart';
import '../repo.dart';
import '../setup_check.dart';
import '../theme.dart';
import '../tracker.dart';
import '../widgets/game_map.dart';
import '../widgets/ui.dart';
import 'chat_screen.dart';
import 'joker_screen.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.code, this.observer = false});

  final String code;

  /// Zentrale: Team-Ansicht im Browser, ohne eigenen Standort.
  final bool observer;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WidgetsBindingObserver {
  SetupStatus _setup = const SetupStatus();
  bool _setupShown = false;
  bool? _setupReported;

  Future<void> _checkSetup({bool openIfMissing = false}) async {
    if (widget.observer) return;
    final st = await SetupCheck.check();
    if (!mounted) return;
    setState(() => _setup = st);
    if (_setupReported != st.ok && _me != null) {
      _setupReported = st.ok;
      try {
        await _repo.updateMe(widget.code, {'setupOk': st.ok});
      } catch (_) {}
    }
    if (openIfMissing && !st.ok && !_setupShown) {
      _setupShown = true;
      _openSetup();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkSetup();
  }

  Widget _setupBanner() {
    if (widget.observer || _setup.ok) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: PH.danger,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _openSetup,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.warning_amber, color: PH.bg, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${_setup.missing} Einstellung${_setup.missing == 1 ? '' : 'en'} fehlt – sonst kommen keine Pings an',
                    style: const TextStyle(color: PH.bg, fontWeight: FontWeight.w800, fontSize: 12),
                  ),
                ),
                const Icon(Icons.chevron_right, color: PH.bg),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openSetup() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: PH.surface,
      builder: (c) => StatefulBuilder(builder: (c, setLocal) {
        Future<void> run(Future<void> Function() f) async {
          await f();
          final st = await SetupCheck.check();
          if (mounted) setState(() => _setup = st);
          setLocal(() {});
        }

        Widget row(bool ok, String title, String text, Future<void> Function() fix) => ListTile(
              leading: Icon(ok ? Icons.check_circle : Icons.cancel, color: ok ? PH.good : PH.danger),
              title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(text, style: const TextStyle(fontSize: 12)),
              trailing: ok ? null : FilledButton(onPressed: () => run(fix), child: const Text('Einstellen')),
            );

        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 16),
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('Damit PingHunt im Hintergrund läuft',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 8),
              row(_setup.locationAlways, 'Standort: „Immer zulassen“',
                  'Sonst bekommt der Hintergrunddienst kein GPS und es gehen keine Pings raus.', SetupCheck.fixLocation),
              row(_setup.precise, 'Genauer Standort',
                  'Ohne „Genauen Standort verwenden“ ist die Position bis zu mehrere Kilometer ungenau.',
                  SetupCheck.openSettings),
              row(_setup.batteryOk, 'Akku: „Keine Einschränkungen“',
                  'Sonst beendet Android die App im Hintergrund. Tippe auf „Zulassen“.', SetupCheck.fixBattery),
              row(_setup.notifications, 'Benachrichtigungen',
                  'Für Chat, Warnungen und „Du bist LIVE“. Empfohlen.', SetupCheck.fixNotifications),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'Xiaomi, Huawei & Co.: zusätzlich in der App-Info „Autostart“ einschalten und PingHunt in der '
                  'Übersicht der letzten Apps mit dem Schloss sperren.',
                  style: TextStyle(color: PH.muted, fontSize: 12),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    OutlinedButton(onPressed: SetupCheck.openSettings, child: const Text('App-Info öffnen')),
                    const Spacer(),
                    FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Fertig')),
                  ],
                ),
              ),
            ],
          ),
        );
      }),
    );
    await _checkSetup();
  }

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
  List<Effect> _effects = [];
  List<MapMark> _marks = [];
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
    WidgetsBinding.instance.addObserver(this);
    _engine = PlayerEngine(widget.code, passive: true)..addListener(_onEngine);
    Future.delayed(const Duration(seconds: 2), () => _checkSetup(openIfMissing: true));
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
      _liveTeam = me?.teamId;
      _updateChat(me);
    }));
    _subs.add(_repo.pingsStream(widget.code).listen((ps) => setState(() => _pings = ps)));
    _subs.add(_repo.marksStream(widget.code).listen((m) => setState(() => _marks = m), onError: (_) {}));
    _subs.add(_repo.effectsStream(widget.code).listen((e) {
      setState(() => _effects = e);
      _engine.setEffects(e);
    }, onError: (_) {}));
    // Alle Positionen (eigenes Team wird angezeigt; andere nur über Joker)
    _liveSub = _repo.liveStream(widget.code).listen((l) => setState(() => _live = l), onError: (_) {});
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

  /// Jäger: lange auf die Karte drücken → Markierung mit Text setzen (15 min sichtbar).
  Future<void> _addMark(LatLng p) async {
    final me = _me;
    final g = _game;
    if (me == null || g == null || !(g.team(me.teamId)?.isHunter ?? false)) return;
    final text = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Markierung setzen'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: text,
              autofocus: true,
              maxLength: 24,
              decoration: const InputDecoration(labelText: 'Text, z. B. Treffpunkt'),
            ),
            Wrap(
              spacing: 6,
              children: [
                for (final q in ['Treffpunkt', 'Hier vermutet', 'Gesehen!', 'Absperren', 'Achtung'])
                  ActionChip(label: Text(q), onPressed: () => text.text = q),
              ],
            ),
            const SizedBox(height: 6),
            const Text('Nur für Jäger sichtbar, verschwindet nach 15 Minuten.',
                style: TextStyle(fontSize: 12, color: PH.muted)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Setzen')),
        ],
      ),
    );
    if (ok != true || text.text.trim().isEmpty) return;
    final now = DateTime.now();
    try {
      await _repo.addMark(widget.code, {
        'byName': me.name,
        'teamId': me.teamId,
        'text': text.text.trim(),
        'lat': p.latitude,
        'lng': p.longitude,
        't': Timestamp.fromDate(now),
        'end': Timestamp.fromDate(now.add(const Duration(minutes: 15))),
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Fehler: $e')));
    }
  }

  Future<void> _markOptions(MapMark m) async {
    final del = await confirm(context, m.text, 'Gesetzt von ${m.byName}. Markierung entfernen?');
    if (del) {
      try {
        await _repo.deleteMark(widget.code, m.id);
      } catch (_) {}
    }
  }

  /// Teams, deren Ping-Verlauf gerade verwischt ist.
  Set<String> _wipedTeams(DateTime now) => {
        for (final e in _effects)
          if (e.type == 'wipe' && e.isActive(now) && e.targetId != null) e.targetId!,
      };

  Future<void> _openJokers(Game g, Player me) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: PH.surface,
        builder: (_) => JokerSheet(
          game: g,
          me: me,
          players: _players,
          effects: _effects,
          live: _live,
          pings: _pings,
          myPos: _engine.latLng,
        ),
      );

  /// Laufende Joker, die mich betreffen oder von meinem Team stammen.
  List<Widget> _effectBanners(Game g, Player? me, DateTime now) {
    if (me == null) return const [];
    final out = <Widget>[];
    for (final e in _effects) {
      if (!e.isActive(now)) continue;
      final d = jokerDef(e.type);
      if (d == null) continue;
      final mine = e.byTeam != null && e.byTeam == me.teamId;
      final hitsMe = e.targets(me.uid, me.teamId);
      final myTeam = g.team(me.teamId);
      if (!mine && !hitsMe) continue;
      // Zielgerichtete Slot-Joker (Fake etc.) nur dem eigenen Team zeigen
      if (!mine && ['fake', 'skip', 'timeshift', 'wipe', 'shield', 'freepass', 'pause', 'proximity', 'hunterview']
          .contains(e.type)) {
        continue;
      }
      if (e.type == 'freeze' && (myTeam?.isHunter ?? false) == false && me.isPaused(now)) continue;
      final isThreat = !mine && hitsMe;
      final left = (e.slot != null && now.isBefore(e.slot!)) ? 'beim nächsten Ping' : 'noch ${countdown(e.end.difference(now))}';
      out.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isThreat ? PH.danger : PH.surface2,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isThreat ? PH.danger : PH.accent),
          ),
          child: Row(
            children: [
              Icon(d.icon, size: 18, color: isThreat ? PH.bg : PH.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  e.type == 'freeze' && isThreat ? '❄ FREEZE – nicht bewegen! $left' : '${d.name} · $left',
                  style: TextStyle(fontWeight: FontWeight.w700, color: isThreat ? PH.bg : PH.text),
                ),
              ),
            ],
          ),
        ),
      ));
    }
    return out;
  }

  /// Kompass-Pfeil zum nächsten Gejagten (Jäger-Joker).
  Widget? _compass(Game g, Player? me, DateTime now) {
    if (me == null) return null;
    final active = _effects.any((e) => e.type == 'compass' && e.by == _repo.uid && e.isActive(now));
    final here = _engine.latLng;
    if (!active || here == null) return null;
    LivePos? best;
    double? bestD;
    for (final l in _live) {
      final t = g.team(l.teamId);
      if (t == null || t.isHunter) continue;
      Player? p;
      for (final x in _players) {
        if (x.uid == l.uid) p = x;
      }
      if (p == null || p.isCaught || p.isPaused(now) || p.observer) continue;
      final d = metersBetween(here, l.pos);
      if (bestD == null || d < bestD) {
        bestD = d;
        best = l;
      }
    }
    if (best == null) return null;
    final angle = bearingTo(here, best.pos) * 3.14159265 / 180;
    return IgnorePointer(
      child: Center(
        child: Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            color: PH.surface.withOpacity(0.85),
            shape: BoxShape.circle,
            border: Border.all(color: PH.accent, width: 3),
          ),
          child: Transform.rotate(
            angle: angle,
            child: const Icon(Icons.navigation, size: 72, color: PH.accent),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _liveSub?.cancel();
    _clock?.cancel();
    WidgetsBinding.instance.removeObserver(this);
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
      final now = DateTime.now();
      final shielded = activeFor(_effects, 'shield', p.uid, p.teamId, now).isNotEmpty;
      return t != null && !t.isHunter && !p.isCaught && !p.observer && !shielded && !p.isPaused(now);
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
    final me = _me;
    if (me == null) return;
    await _repo.reportCatch(widget.code, me, chosen);
    await _repo.addEvent(
      widget.code,
      'Fang gemeldet: ${chosen.name} durch ${me.name} – Spielleitung bitte bestätigen',
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
          game: g, pings: _pings, count: _history, teamFilter: _teamFilter, now: now,
          latestOnlyTeams: _wipedTeams(now));
      markers.addAll(pingMarkers);
      for (final p in _players) {
        final t = g.team(p.teamId);
        if (t == null || t.isHunter || p.exposed == null || !p.isLive(now) || p.isPaused(now)) continue;
        markers.add(labelMarker(
          point: p.exposed!,
          color: Color(t.color),
          label: '${p.name} · LIVE ${countdown(p.liveUntil!.difference(now))}',
          size: 18,
          live: true,
        ));
      }
    }

    // Jäger-Blick: Gejagte sehen kurz alle Jäger
    final hunterView = myTeam != null &&
        !myTeam.isHunter &&
        activeFor(_effects, 'hunterview', _repo.uid, me?.teamId, now).isNotEmpty;
    for (final l in _live) {
      if (l.uid == _repo.uid) continue;
      final lt = g.team(l.teamId);
      final ownTeam = l.teamId != null && l.teamId == me?.teamId;
      final showHunter = hunterView && (lt?.isHunter ?? false);
      if (!ownTeam && !showHunter) continue;
      final t = lt;
      markers.add(labelMarker(
        point: l.pos,
        color: Color(t?.color ?? 0xFF9AA4B2),
        label: l.name,
        size: 13,
      ));
    }

    // Markierungen des eigenen (Jäger-)Teams
    for (final m in _marks) {
      if (m.teamId == null || m.teamId != me?.teamId || !now.isBefore(m.end)) continue;
      markers.add(markMarker(m, now, onTap: () => _markOptions(m)));
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
        ? pingHistory(
                game: g, pings: _pings, count: _history, teamFilter: _teamFilter, now: now,
                latestOnlyTeams: _wipedTeams(now))
            .$1
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
                onLongPress: isHunter ? _addMark : null,
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: _limitWidth(Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _setupBanner(),
                    _statusCard(g, me, myTeam, now),
                    const SizedBox(height: 4),
                    _chips(g, me, myTeam),
                    ..._liveBanners(g, myTeam, now),
                    ..._effectBanners(g, me, now),
                  ],
                )),
              ),
            ),
            if (_compass(g, me, now) != null) Positioned.fill(child: _compass(g, me, now)!),
            if (me != null && myTeam != null)
              Positioned(
                right: 12,
                bottom: _bottomHeight(myTeam) + 104,
                child: FloatingActionButton.small(
                  heroTag: 'joker',
                  backgroundColor: PH.surface,
                  foregroundColor: PH.accent,
                  tooltip: 'Joker',
                  onPressed: () => _openJokers(g, me),
                  child: const Icon(Icons.style),
                ),
              ),
            Positioned(
              right: 12,
              bottom: _bottomHeight(myTeam) + 52,
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
              bottom: _bottomHeight(myTeam),
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

  Widget _header(Game g, DateTime now) => const SizedBox.shrink();

  Widget _chips(Game g, Player? me, Team? myTeam) {
    final chips = <Widget>[];
    if (widget.observer) chips.add(const Pill(dot: PH.accent, child: Text('ZENTRALE · ohne GPS')));
    if (myTeam == null) {
      chips.add(const Pill(child: Text('Noch keinem Team zugeteilt')));
    } else {
      chips.add(Pill(
        filled: Color(myTeam.color),
        child: Text(
          '${myTeam.isHunter ? 'JÄGER' : 'GEJAGT'} · ${myTeam.name}',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11, color: PH.bg),
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
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11, color: PH.bg)),
      ));
    } else if ((_engine.distToBlocked ?? double.infinity) < 50) {
      chips.add(Pill(dot: PH.danger, child: Text('Sperrgebiet ${_engine.distToBlocked!.round()} m')));
    }
    if (g.area.length >= 3 && _engine.inside != null) {
      final d = _engine.distToEdge;
      chips.add(Pill(
        dot: _engine.inside! ? PH.good : PH.danger,
        child: Text(_engine.inside! ? 'Rand ${d == null ? '-' : d.round()} m' : 'AUSSERHALB'),
      ));
    }
    return Wrap(spacing: 4, runSpacing: 4, children: chips);
  }

  /// Schmale Statusleiste: nächster Ping, Restzeit, LIVE-Hinweis.
  Widget _statusCard(Game g, Player? me, Team? myTeam, DateTime now) {
    final live = me?.isLive(now) ?? false;
    final rows = <Widget>[];
    if (_engine.error != null) {
      rows.add(Text(_engine.error!, style: const TextStyle(color: PH.danger, fontSize: 12)));
    }
    if (g.isLobby) {
      rows.add(Text(
        myTeam == null
            ? (widget.observer ? 'Warte auf Team-Zuteilung (Zentrale)' : 'Warte auf Team-Zuteilung …')
            : 'Warte auf den Spielstart · ${myTeam.name}',
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
      ));
    } else if (g.isEnded) {
      rows.add(const Text('Spiel beendet', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)));
    } else {
      final next = g.nextPing(now);
      final headStart = g.pingAnchor != null && now.isBefore(g.pingAnchor!);
      final left = g.endsAt?.difference(now);
      rows.add(Row(
        children: [
          Text(headStart ? 'VORSPRUNG ' : 'PING ', style: label()),
          Text(next == null ? '--:--' : countdown(next.difference(now)), style: mono(18, color: PH.accent)),
          const SizedBox(width: 8),
          Text('· alle ${g.intervalMin} min', style: const TextStyle(color: PH.muted, fontSize: 11)),
          const Spacer(),
          if (left != null) Text('${countdown(left)} übrig', style: mono(11, color: PH.muted)),
        ],
      ));
    }
    if (live && me?.liveUntil != null) {
      rows.add(const SizedBox(height: 6));
      rows.add(Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: PH.danger, borderRadius: BorderRadius.circular(10)),
        child: Text(
          'Du bist LIVE sichtbar – noch ${countdown(me!.liveUntil!.difference(now))}',
          style: const TextStyle(color: PH.bg, fontWeight: FontWeight.w800, fontSize: 12),
        ),
      ));
    }
    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
    );
  }

  /// Höhe des unteren Bereichs (für die Position der runden Knöpfe).
  double _bottomHeight(Team? myTeam) =>
      (myTeam?.isHunter ?? false) ? 112 : (widget.observer ? 60 : 16);

  Widget _bottomPanel(Game g, Player? me, Team? myTeam) {
    final isHunter = myTeam?.isHunter ?? false;
    if (!isHunter && !widget.observer) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: const BoxDecoration(
        color: PH.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
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
                      Expanded(
                        child: SegmentedButton<int>(
                          showSelectedIcon: false,
                          style: const ButtonStyle(visualDensity: VisualDensity.compact),
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
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                        onPressed: g.isRunning ? _reportCatch : null,
                        icon: const Icon(Icons.back_hand, size: 18),
                        label: const Text('Fang'),
                      ),
                    ],
                  ),
                  SizedBox(
                    height: 40,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final t in g.teamList.where((t) => !t.isHunter))
                          Padding(
                            padding: const EdgeInsets.only(right: 6, top: 4),
                            child: FilterChip(
                              visualDensity: VisualDensity.compact,
                              avatar: Dot(Color(t.color), size: 10),
                              label: Text(t.name, style: const TextStyle(fontSize: 12)),
                              selected: _teamFilter.contains(t.id),
                              onSelected: (v) => setState(() {
                                v ? _teamFilter.add(t.id) : _teamFilter.remove(t.id);
                              }),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              )
            : Text(
                myTeam == null
                    ? 'Die Spielleitung muss dich noch einem Team zuteilen.'
                    : 'Zentrale von ${myTeam.name} – ohne eigenen Standort.',
                style: const TextStyle(color: PH.muted, fontSize: 12),
              ),
      ),
    );
  }
}

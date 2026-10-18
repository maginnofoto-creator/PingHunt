import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models.dart';
import '../repo.dart';
import '../theme.dart';
import '../widgets/game_map.dart';
import '../widgets/ui.dart';
import 'area_editor.dart';

/// Spielleitung – auf dem Handy als Tabs, im Browser als großes Dashboard.
class LeaderScreen extends StatefulWidget {
  const LeaderScreen({super.key, required this.code});

  final String code;

  @override
  State<LeaderScreen> createState() => _LeaderScreenState();
}

class _LeaderScreenState extends State<LeaderScreen> {
  final _repo = Repo.i;
  final _map = MapController();

  Game? _game;
  bool _loaded = false;
  List<Player> _players = [];
  List<Ping> _pings = [];
  List<LivePos> _live = [];
  List<GameEvent> _events = [];
  String? _pin;
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
    _subs.add(_repo.liveStream(c).listen((l) => setState(() => _live = l), onError: (_) {}));
    _subs.add(_repo.eventsStream(c).listen((e) => setState(() => _events = e)));
    _subs.add(_repo.pinStream(c).listen((p) => setState(() => _pin = p), onError: (_) {}));
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

  void _msg(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _do(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      _msg('Fehler: $e');
    }
  }

  // ---------------- Karte ----------------

  Widget _mapView(Game g, DateTime now) {
    final (lines, pingMarkers) =
        pingHistory(game: g, pings: _pings, count: _history, now: now);
    final markers = <Marker>[...pingMarkers];
    final byUid = {for (final p in _players) p.uid: p};
    for (final l in _live) {
      final p = byUid[l.uid];
      final t = g.team(p?.teamId ?? l.teamId);
      final stale = l.t != null && now.difference(l.t!).inMinutes >= 5;
      markers.add(labelMarker(
        point: l.pos,
        color: (p?.isCaught ?? false) ? PH.muted : Color(t?.color ?? 0xFF9AA4B2),
        label: '${p?.name ?? l.name}${stale ? ' · ${ago(l.t!, now)}' : ''}',
        size: 14,
        ring: true,
        live: p?.isLive(now) ?? false,
        opacity: stale ? 0.5 : 1,
      ));
    }
    return Stack(
      children: [
        Positioned.fill(
          child: GameMap(controller: _map, area: g.area, markers: markers, polylines: lines),
        ),
        Positioned(
          left: 12,
          top: 12,
          right: 12,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final t in g.teamList)
                Pill(dot: Color(t.color), child: Text(t.name)),
              Container(
                decoration: BoxDecoration(
                  color: PH.surface,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 1, label: Text('Letzter Ping')),
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
        Positioned(
          right: 12,
          bottom: 28,
          child: Panel(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: _pingCountdown(g, now, big: true),
          ),
        ),
      ],
    );
  }

  Widget _pingCountdown(Game g, DateTime now, {bool big = false}) {
    final next = g.nextPing(now);
    final head = g.pingAnchor != null && now.isBefore(g.pingAnchor!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          g.isRunning ? (head ? 'VORSPRUNG · ERSTER PING' : 'NÄCHSTER PING') : g.isLobby ? 'NOCH NICHT GESTARTET' : 'BEENDET',
          style: label(),
        ),
        Text(next == null ? '--:--' : countdown(next.difference(now)),
            style: mono(big ? 44 : 28, color: PH.accent)),
      ],
    );
  }

  // ---------------- Spiel & Einstellungen ----------------

  Widget _gamePanel(Game g, DateTime now) {
    final left = g.endsAt?.difference(now);
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                child: QrImageView(data: g.code, size: 96, padding: EdgeInsets.zero),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('SPIELCODE', style: label()),
                    SelectableText(g.code, style: mono(30).copyWith(letterSpacing: 5)),
                    const SizedBox(height: 6),
                    Text('LEITUNGS-PIN', style: label()),
                    Row(
                      children: [
                        Text(_pin ?? '······', style: mono(16)),
                        IconButton(
                          tooltip: 'PIN kopieren',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.copy, size: 16),
                          onPressed: _pin == null
                              ? null
                              : () {
                                  Clipboard.setData(ClipboardData(text: _pin!));
                                  _msg('PIN kopiert');
                                },
                        ),
                      ],
                    ),
                    const Text('Mit Code + PIN kann ein zweites Gerät (z. B. der Browser) mitleiten.',
                        style: TextStyle(fontSize: 11.5, color: PH.muted)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Pill(
                dot: g.isRunning ? PH.good : g.isLobby ? PH.accent : PH.muted,
                child: Text(g.isRunning
                    ? 'LÄUFT${left != null ? ' · ${countdown(left)} übrig' : ''}'
                    : g.isLobby
                        ? 'Lobby · ${_players.length} Spieler'
                        : 'Beendet'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (g.isLobby)
            FilledButton.icon(
              onPressed: () async {
                if (g.area.length < 3) {
                  final ok = await confirm(context, 'Ohne Spielfeld starten?',
                      'Es wurde noch kein Spielfeld gezeichnet. Die Zonen-Regel ist dann aus.');
                  if (!ok) return;
                }
                if (_players.any((p) => p.teamId == null)) {
                  if (!mounted) return;
                  final ok = await confirm(context, 'Nicht alle zugeteilt',
                      'Einige Spieler sind noch in keinem Team. Trotzdem starten?');
                  if (!ok) return;
                }
                await _do(() => _repo.startGame(g));
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('Spiel starten'),
            ),
          if (g.isRunning) ...[
            FilledButton.icon(
              onPressed: () => _do(() => _repo.requestPing(g)),
              icon: const Icon(Icons.bolt),
              label: const Text('Ping jetzt auslösen'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () async {
                if (await confirm(context, 'Spiel beenden?', 'Pings und Ortung werden gestoppt.')) {
                  await _do(() => _repo.endGame(g));
                }
              },
              icon: const Icon(Icons.stop),
              label: const Text('Spiel beenden'),
            ),
          ],
          if (g.isEnded)
            OutlinedButton.icon(
              onPressed: () => _do(() => _repo.updateGame(g.code, {'status': 'lobby'})),
              icon: const Icon(Icons.replay),
              label: const Text('Zurück in die Lobby'),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => AreaEditor(code: g.code, initial: g.area)),
            ),
            icon: const Icon(Icons.draw),
            label: Text(g.area.length >= 3 ? 'Spielfeld bearbeiten' : 'Spielfeld zeichnen'),
          ),
          const SizedBox(height: 12),
          const Divider(color: PH.line),
          StepperRow(
            title: 'Ping-Intervall',
            subtitle: 'in 10-Minuten-Schritten',
            value: '${g.intervalMin} min',
            onMinus: g.intervalMin <= 10 ? null : () => _do(() => _repo.changeInterval(g, g.intervalMin - 10)),
            onPlus: g.intervalMin >= 180 ? null : () => _do(() => _repo.changeInterval(g, g.intervalMin + 10)),
          ),
          StepperRow(
            title: 'Vorsprung',
            subtitle: 'bis zum ersten Ping',
            value: '${g.headStartMin} min',
            onMinus: !g.isLobby || g.headStartMin <= 0
                ? null
                : () => _do(() => _repo.updateGame(g.code, {'headStartMin': g.headStartMin - 5})),
            onPlus: !g.isLobby || g.headStartMin >= 120
                ? null
                : () => _do(() => _repo.updateGame(g.code, {'headStartMin': g.headStartMin + 5})),
          ),
          StepperRow(
            title: 'Zone verlassen',
            subtitle: 'so lange live für Jäger sichtbar',
            value: '${g.liveMin} min',
            onMinus: g.liveMin <= 1 ? null : () => _do(() => _repo.updateGame(g.code, {'liveMin': g.liveMin - 1})),
            onPlus: g.liveMin >= 60 ? null : () => _do(() => _repo.updateGame(g.code, {'liveMin': g.liveMin + 1})),
          ),
          StepperRow(
            title: 'Kulanz',
            subtitle: 'gegen GPS-Sprünge',
            value: '${g.graceSec} s',
            onMinus: g.graceSec <= 0 ? null : () => _do(() => _repo.updateGame(g.code, {'graceSec': g.graceSec - 5})),
            onPlus: g.graceSec >= 60 ? null : () => _do(() => _repo.updateGame(g.code, {'graceSec': g.graceSec + 5})),
          ),
          StepperRow(
            title: 'Spieldauer',
            value: '${g.durationH} h',
            onMinus: g.durationH <= 1 ? null : () => _changeDuration(g, -1),
            onPlus: g.durationH >= 72 ? null : () => _changeDuration(g, 1),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Zuschauer-Verzögerung', style: TextStyle(fontWeight: FontWeight.w600)),
                      Text('was Zuschauer sehen', style: TextStyle(fontSize: 12, color: PH.muted)),
                    ],
                  ),
                ),
                DropdownButton<int>(
                  value: const [0, 10, 20, 30, 60].contains(g.spectatorDelayMin) ? g.spectatorDelayMin : 20,
                  dropdownColor: PH.surface2,
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('Keine')),
                    DropdownMenuItem(value: 10, child: Text('10 min')),
                    DropdownMenuItem(value: 20, child: Text('20 min')),
                    DropdownMenuItem(value: 30, child: Text('30 min')),
                    DropdownMenuItem(value: 60, child: Text('60 min')),
                  ],
                  onChanged: (v) =>
                      v == null ? null : _do(() => _repo.updateGame(g.code, {'spectatorDelayMin': v})),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _changeDuration(Game g, int delta) => _do(() {
        final data = <String, dynamic>{'durationH': g.durationH + delta};
        if (g.isRunning && g.endsAt != null) {
          data['endsAt'] = Timestamp.fromDate(g.endsAt!.add(Duration(hours: delta)));
        }
        return _repo.updateGame(g.code, data);
      });

  // ---------------- Teams ----------------

  Widget _teamsPanel(Game g, DateTime now) {
    final unassigned = _players.where((p) => g.team(p.teamId) == null).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('TEILNEHMER · ${_players.length}', style: label()),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _editTeam(g, null),
              icon: const Icon(Icons.add),
              label: const Text('Team'),
            ),
          ],
        ),
        for (final t in g.teamList) ...[
          _teamCard(g, t, _players.where((p) => p.teamId == t.id).toList(), now),
          const SizedBox(height: 10),
        ],
        Panel(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Nicht zugeteilt · ${unassigned.length}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              if (unassigned.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('Alle Spieler sind in einem Team.', style: TextStyle(color: PH.muted, fontSize: 13)),
                ),
              for (final p in unassigned) _playerRow(g, p, now),
            ],
          ),
        ),
      ],
    );
  }

  Widget _teamCard(Game g, Team t, List<Player> members, DateTime now) {
    final caught = members.where((p) => p.isCaught && !p.observer).length;
    final active = members.where((p) => !p.observer).length;
    final centrals = members.length - active;
    return Panel(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Dot(Color(t.color), size: 14),
              const SizedBox(width: 10),
              Expanded(child: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
              Text(
                (t.isHunter
                        ? '$active Jäger'
                        : '${active - caught} frei${caught > 0 ? ' · $caught gefangen' : ''}') +
                    (centrals > 0 ? ' · $centrals Zentrale' : ''),
                style: const TextStyle(color: PH.muted, fontSize: 12),
              ),
              PopupMenuButton<String>(
                tooltip: 'Team bearbeiten',
                onSelected: (v) async {
                  if (v == 'edit') _editTeam(g, t);
                  if (v == 'delete' &&
                      await confirm(context, '${t.name} löschen?', 'Die Spieler werden „Nicht zugeteilt“.')) {
                    await _do(() => _repo.deleteTeam(g.code, t.id, members));
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
                  PopupMenuItem(value: 'delete', child: Text('Löschen')),
                ],
              ),
            ],
          ),
          if (members.isEmpty)
            const Text('Noch niemand im Team.', style: TextStyle(color: PH.muted, fontSize: 13)),
          for (final p in members) _playerRow(g, p, now),
        ],
      ),
    );
  }

  Widget _playerRow(Game g, Player p, DateTime now) {
    LivePos? live;
    for (final l in _live) {
      if (l.uid == p.uid) live = l;
    }
    final seen = live?.t ?? p.lastSeen;
    final offline = !p.observer && (seen == null || now.difference(seen).inMinutes >= 5);
    final batteryLow = (p.battery ?? 100) < 20;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          const SizedBox(width: 24),
          Expanded(
            child: Text(
              p.name,
              style: TextStyle(
                decoration: p.isCaught ? TextDecoration.lineThrough : null,
                color: p.isCaught ? PH.muted : PH.text,
              ),
            ),
          ),
          if (p.observer)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Tooltip(
                message: 'Zentrale im Browser – sendet keinen Standort',
                child: Icon(Icons.desktop_windows_outlined, size: 15, color: PH.muted),
              ),
            ),
          if (p.isLive(now))
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Text('LIVE', style: TextStyle(color: PH.danger, fontWeight: FontWeight.w800, fontSize: 11)),
            ),
          if (offline)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Tooltip(message: 'Seit über 5 min kein Standort', child: Icon(Icons.wifi_off, size: 15, color: PH.muted)),
            ),
          if (p.battery != null)
            Text('${p.battery} %', style: mono(11, color: batteryLow ? PH.danger : PH.muted)),
          PopupMenuButton<String>(
            tooltip: 'Spieler',
            icon: const Icon(Icons.more_vert, size: 18),
            onSelected: (v) {
              if (v == 'caught') _do(() => _repo.setPlayerStatus(g.code, p.uid, 'caught'));
              if (v == 'free') _do(() => _repo.setPlayerStatus(g.code, p.uid, 'free'));
              if (v == 'none') _do(() => _repo.setPlayerTeam(g.code, p.uid, null));
              if (v == 'remove') _do(() => _repo.removePlayer(g.code, p.uid));
              if (v.startsWith('team:')) _do(() => _repo.setPlayerTeam(g.code, p.uid, v.substring(5)));
            },
            itemBuilder: (_) => [
              for (final t in g.teamList)
                if (t.id != p.teamId)
                  PopupMenuItem(value: 'team:${t.id}', child: Text('→ ${t.name}')),
              if (p.teamId != null) const PopupMenuItem(value: 'none', child: Text('→ Nicht zugeteilt')),
              const PopupMenuDivider(),
              if (!p.isCaught) const PopupMenuItem(value: 'caught', child: Text('Als gefangen markieren')),
              if (p.isCaught) const PopupMenuItem(value: 'free', child: Text('Wieder freilassen')),
              const PopupMenuItem(value: 'remove', child: Text('Aus dem Spiel entfernen')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _editTeam(Game g, Team? existing) async {
    final name = TextEditingController(text: existing?.name ?? '');
    var hunter = existing?.isHunter ?? false;
    final used = g.teams.values.map((t) => t.color).toSet();
    var color = existing?.color ??
        PH.teamColors.firstWhere((c) => !used.contains(c), orElse: () => PH.teamColors.first);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: Text(existing == null ? 'Neues Team' : 'Team bearbeiten'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Gejagte')),
                  ButtonSegment(value: true, label: Text('Jäger')),
                ],
                selected: {hunter},
                onSelectionChanged: (s) => setLocal(() => hunter = s.first),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final col in [PH.hunterColor, ...PH.teamColors])
                    InkWell(
                      onTap: () => setLocal(() => color = col),
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: Color(col),
                          shape: BoxShape.circle,
                          border: Border.all(color: col == color ? Colors.white : Colors.transparent, width: 3),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Speichern')),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    final id = existing?.id ?? 't${DateTime.now().millisecondsSinceEpoch}';
    await _do(() => _repo.setTeam(g.code, Team(id, name.text.trim(), color, hunter ? 'hunter' : 'hunted')));
  }

  // ---------------- Ereignisse ----------------

  Widget _eventsPanel(DateTime now) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
    );
  }

  // ---------------- Aufbau ----------------

  @override
  Widget build(BuildContext context) {
    final g = _game;
    final now = DateTime.now();
    if (!_loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (g == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Spiel nicht gefunden.')));
    }

    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth >= 1000) {
        return Scaffold(
          appBar: AppBar(
            title: Text('PINGHUNT · Spiel ${g.code} · Spielleitung',
                style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.5)),
          ),
          body: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 380,
                  child: ListView(
                    children: [_gamePanel(g, now), const SizedBox(height: 16), _teamsPanel(g, now)],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: _mapView(g, now),
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(width: 320, child: ListView(children: [_eventsPanel(now)])),
              ],
            ),
          ),
        );
      }
      return DefaultTabController(
        length: 4,
        child: Scaffold(
          appBar: AppBar(
            title: Text('Spielleitung · ${g.code}', style: const TextStyle(fontWeight: FontWeight.w800)),
            bottom: const TabBar(
              tabs: [
                Tab(text: 'Karte'),
                Tab(text: 'Teams'),
                Tab(text: 'Spiel'),
                Tab(text: 'Ereignisse'),
              ],
            ),
          ),
          body: TabBarView(
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _mapView(g, now),
              ListView(padding: const EdgeInsets.all(12), children: [_teamsPanel(g, now)]),
              ListView(padding: const EdgeInsets.all(12), children: [_gamePanel(g, now)]),
              ListView(padding: const EdgeInsets.all(12), children: [_eventsPanel(now)]),
            ],
          ),
        ),
      );
    });
  }
}

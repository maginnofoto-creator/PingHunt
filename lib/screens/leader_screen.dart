import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../chat.dart';
import '../models.dart';
import '../notify.dart';
import '../repo.dart';
import '../theme.dart';
import '../widgets/game_map.dart';
import '../widgets/ui.dart';
import 'area_editor.dart';
import 'chat_screen.dart';

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
  late final ChatWatcher _chat;
  String _chatKey = '';

  void _updateChat() {
    final g = _game;
    final channels = <String, String>{
      'all': 'Durchsage',
      if (g != null)
        for (final t in g.teamList) 'team:${t.id}': t.name,
      for (final p in _players) 'dm:${p.uid}': p.name,
    };
    final key = (channels.keys.toList()..sort()).join(',');
    if (key == _chatKey) return;
    _chatKey = key;
    _chat.watch(channels);
  }

  void _openChatList(Game g) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Nachrichten')),
          body: LeaderChatList(watcher: _chat, game: g, players: _players),
        ),
      ),
    );
  }

  Widget _chatAction(Game g) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: UnreadBadge(
          count: _chat.totalUnread,
          child: IconButton(
            tooltip: 'Nachrichten',
            onPressed: () => _openChatList(g),
            icon: const Icon(Icons.chat_bubble_outline),
          ),
        ),
      );

  @override
  void initState() {
    super.initState();
    final c = widget.code;
    _chat = ChatWatcher(c)..addListener(() {
        if (mounted) setState(() {});
      });
    Notify.init();
    _subs.add(_repo.gameStream(c).listen((g) {
      setState(() {
        _game = g;
        _loaded = true;
      });
      _updateChat();
    }));
    _subs.add(_repo.playersStream(c).listen((p) {
      setState(() => _players = p);
      _updateChat();
    }));
    _subs.add(_repo.pingsStream(c).listen((p) => setState(() => _pings = p)));
    _subs.add(_repo.liveStream(c).listen((l) => setState(() => _live = l), onError: (_) {}));
    _subs.add(_repo.eventsStream(c).listen((e) => setState(() => _events = e)));
    _subs.add(_repo.pinStream(c).listen((p) => setState(() => _pin = p), onError: (_) {}));
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _watchdog = Timer.periodic(const Duration(seconds: 30), (_) => _checkOffline());
  }

  Timer? _watchdog;
  final Set<String> _offlineReported = {};
  DateTime? _lastSlotChecked;

  /// Offline-Spieler melden und für verpasste Pings die letzte bekannte Position senden.
  Future<void> _checkOffline() async {
    final g = _game;
    if (g == null || !g.isRunning) return;
    final now = DateTime.now();
    final liveBy = {for (final l in _live) l.uid: l};

    DateTime? lastSign(Player p) {
      final a = p.lastSeen, b = liveBy[p.uid]?.t;
      if (a == null) return b;
      if (b == null) return a;
      return a.isAfter(b) ? a : b;
    }

    final active = _players.where((p) => !p.observer && g.team(p.teamId) != null).toList();

    for (final p in active) {
      final seen = lastSign(p);
      final offline = seen == null || now.difference(seen).inMinutes >= 5;
      if (offline && !_offlineReported.contains(p.uid)) {
        _offlineReported.add(p.uid);
        final mins = seen == null ? null : now.difference(seen).inMinutes;
        final text = '${p.name} (${g.team(p.teamId)?.name ?? ''}) ist offline'
            '${mins == null ? '' : ' – seit $mins min kein Signal'}';
        await _repo.addEventOnce(
            g.code, 'off_${p.uid}_${seen?.millisecondsSinceEpoch ?? 0}', text, 0xFF9AA4B2);
        Notify.message('Spieler offline', text, important: true);
      } else if (!offline) {
        _offlineReported.remove(p.uid);
      }
    }

    // Verpasster Ping → letzte bekannte Position
    final slot = g.currentSlot(now);
    if (slot == null || now.difference(slot).inMinutes < 2 || slot == _lastSlotChecked) return;
    _lastSlotChecked = slot;
    for (final p in active) {
      final t = g.team(p.teamId)!;
      if (t.isHunter || p.isCaught) continue;
      final has = _pings.any((x) => x.uid == p.uid && x.t.isAtSameMomentAs(slot));
      if (has) continue;
      final last = liveBy[p.uid];
      var pos = last?.pos;
      DateTime? posAt = last?.t;
      if (pos == null) {
        for (final x in _pings) {
          if (x.uid == p.uid) {
            pos = x.pos;
            posAt = x.t;
          }
        }
      }
      if (pos == null) continue;
      try {
        await _repo.writePingIfMissing(g.code, '${p.uid}_${slot.millisecondsSinceEpoch}', {
          'uid': p.uid,
          'name': p.name,
          'teamId': p.teamId,
          'lat': pos.latitude,
          'lng': pos.longitude,
          't': Timestamp.fromDate(slot),
          'manual': false,
          'offline': true,
        });
        await _repo.addEventOnce(
            g.code,
            'miss_${p.uid}_${slot.millisecondsSinceEpoch}',
            'Ping von ${p.name} fehlte – letzte bekannte Position von ${posAt == null ? '?' : hhmm(posAt)} gesendet',
            t.color);
      } catch (e) {
        debugPrint('Ersatz-Ping: $e');
      }
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _clock?.cancel();
    _watchdog?.cancel();
    _chat.dispose();
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
          child: GameMap(controller: _map, area: g.area, markers: markers, polylines: lines, zones: g.zones),
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
          const SizedBox(height: 14),
          _zonesSection(g),
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
            subtitle: _headStartEditable(g, now) ? 'bis zum ersten Ping' : 'schon abgelaufen',
            value: '${g.headStartMin} min',
            onMinus: !_headStartEditable(g, now) || g.headStartMin <= 0
                ? null
                : () => _do(() => _repo.changeHeadStart(g, g.headStartMin - 5)),
            onPlus: !_headStartEditable(g, now) || g.headStartMin >= 120
                ? null
                : () => _do(() => _repo.changeHeadStart(g, g.headStartMin + 5)),
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
            title: 'Offline-Strafe',
            subtitle: g.offlinePenaltyMin == 0
                ? 'aus'
                : 'nach >5 min offline so lange live sichtbar',
            value: g.offlinePenaltyMin == 0 ? 'aus' : '${g.offlinePenaltyMin} min',
            onMinus: g.offlinePenaltyMin <= 0
                ? null
                : () => _do(() => _repo.updateGame(g.code, {'offlinePenaltyMin': g.offlinePenaltyMin - 5})),
            onPlus: g.offlinePenaltyMin >= 30
                ? null
                : () => _do(() => _repo.updateGame(g.code, {'offlinePenaltyMin': g.offlinePenaltyMin + 5})),
          ),
          StepperRow(
            title: 'Spieldauer',
            value: '${g.durationH} h',
            onMinus: g.durationH <= 1 ? null : () => _changeDuration(g, -1),
            onPlus: g.durationH >= 72 ? null : () => _changeDuration(g, 1),
          ),
          const SizedBox(height: 8),
          const Divider(color: PH.line),
          _spectatorSection(g),
        ],
      ),
    );
  }

  // ---------------- Zuschauer ----------------

  Future<void> _setSpec(Game g, SpecSettings spec) =>
      _do(() => _repo.updateGame(g.code, {'spec': spec.toMap()}));

  Widget _modeRow(String title, String value, ValueChanged<String> onChanged,
      {List<(String, String)> options = const [('live', 'Live'), ('delay', 'Verzögert'), ('off', 'Aus')]}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [for (final o in options) ButtonSegment(value: o.$1, label: Text(o.$2))],
            selected: {value},
            onSelectionChanged: (v) => onChanged(v.first),
          ),
        ],
      ),
    );
  }

  Widget _spectatorSection(Game g) {
    final sp = g.spec;
    final hunted = g.teamList.where((t) => !t.isHunter).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('ZUSCHAUER', style: label()),
        const SizedBox(height: 4),
        const Text('Was Zuschauer sehen – die Spieler bekommen davon nichts mit, '
            'außer bei sichtbaren Team-Chats.', style: TextStyle(fontSize: 12, color: PH.muted)),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              const Expanded(child: Text('Verzögerung', style: TextStyle(fontWeight: FontWeight.w600))),
              DropdownButton<int>(
                value: const [0, 5, 10, 20, 30, 60].contains(g.spectatorDelayMin) ? g.spectatorDelayMin : 20,
                dropdownColor: PH.surface2,
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Keine')),
                  DropdownMenuItem(value: 5, child: Text('5 min')),
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
        _modeRow('Jäger auf der Karte', sp.hunters, (v) => _setSpec(g, sp.copyWith(hunters: v))),
        _modeRow('Gejagte live verfolgen', sp.hunted, (v) => _setSpec(g, sp.copyWith(hunted: v))),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Letzte Pings verblasst zeigen'),
          subtitle: const Text('Wo die Jäger gerade hinlaufen', style: TextStyle(fontSize: 12)),
          value: sp.lastPings,
          onChanged: (v) => _setSpec(g, sp.copyWith(lastPings: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Durchsagen zeigen'),
          value: sp.announcements,
          onChanged: (v) => _setSpec(g, sp.copyWith(announcements: v)),
        ),
        _modeRow('Team-Chats', sp.teamChats, (v) => _setSpec(g, sp.copyWith(teamChats: v))),
        if (sp.teamChats != 'off')
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in g.teamList)
                FilterChip(
                  avatar: Dot(Color(t.color)),
                  label: Text(t.name),
                  selected: sp.chatTeams.contains(t.id),
                  onSelected: (on) => _setSpec(
                    g,
                    sp.copyWith(chatTeams: [
                      for (final id in sp.chatTeams)
                        if (id != t.id) id,
                      if (on) t.id,
                    ]),
                  ),
                ),
            ],
          ),
        if (sp.teamChats != 'off')
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Ausgewählte Teams sehen in ihrem Chat den Hinweis „Zuschauer lesen mit“. '
                'Private Chats mit der Spielleitung sind nie sichtbar.',
                style: TextStyle(fontSize: 12, color: PH.muted)),
          ),
        if (hunted.isEmpty) const SizedBox.shrink(),
      ],
    );
  }

  /// Vorsprung: in Lobby/nach dem Spiel frei, im Spiel nur solange er noch läuft.
  bool _headStartEditable(Game g, DateTime now) =>
      !g.isRunning || (g.pingAnchor != null && now.isBefore(g.pingAnchor!));

  Future<void> _changeDuration(Game g, int delta) => _do(() {
        final data = <String, dynamic>{'durationH': g.durationH + delta};
        if (g.isRunning && g.endsAt != null) {
          data['endsAt'] = Timestamp.fromDate(g.endsAt!.add(Duration(hours: delta)));
        }
        return _repo.updateGame(g.code, data);
      });

  // ---------------- Zonen ----------------

  String _scopeLabel(Game g, Zone z) {
    if (z.scope == 'team') return 'nur ${g.team(z.target)?.name ?? 'Team'}';
    if (z.scope == 'player') {
      for (final p in _players) {
        if (p.uid == z.target) return 'nur ${p.name}';
      }
      return 'nur ein Spieler';
    }
    return 'für alle';
  }

  Widget _zonesSection(Game g) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('ZONEN · ${g.zones.length}', style: label()),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _editZone(g, null),
              icon: const Icon(Icons.add),
              label: const Text('Zone'),
            ),
          ],
        ),
        if (g.zones.isEmpty)
          const Text('Farbige Markierungen (z. B. Startpunkt) für alle, ein Team oder einen Spieler – '
              'oder Sperrgebiete, die wie das Verlassen des Spielfelds zählen.',
              style: TextStyle(color: PH.muted, fontSize: 12.5)),
        for (final z in g.zones)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Dot(Color(z.color), size: 14),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(z.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(z.isBlocked ? 'Sperrgebiet · für alle' : _scopeLabel(g, z),
                          style: TextStyle(fontSize: 12, color: z.isBlocked ? PH.danger : PH.muted)),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Zone bearbeiten',
                  onSelected: (v) async {
                    if (v == 'edit') _editZone(g, z);
                    if (v == 'delete' && await confirm(context, '${z.name} löschen?', 'Die Zone verschwindet von allen Karten.')) {
                      await _do(() => _repo.saveZones(g.code, [for (final o in g.zones) if (o.id != z.id) o]));
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
                    PopupMenuItem(value: 'delete', child: Text('Löschen')),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _editZone(Game g, Zone? existing) async {
    final name = TextEditingController(text: existing?.name ?? '');
    var color = existing?.color ?? PH.teamColors[g.zones.length % PH.teamColors.length];
    var scope = existing?.scope ?? 'all';
    String? target = existing?.target;
    var kind = existing?.kind ?? 'mark';
    final players = _players.where((p) => !p.observer).toList()..sort((a, b) => a.name.compareTo(b.name));

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: Text(existing == null ? 'Neue Zone' : 'Zone bearbeiten'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: name,
                  autofocus: existing == null,
                  decoration: const InputDecoration(labelText: 'Name, z. B. „Start Team Fuchs“'),
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'mark', icon: Icon(Icons.flag_outlined), label: Text('Markierung')),
                    ButtonSegment(value: 'blocked', icon: Icon(Icons.block), label: Text('Sperrgebiet')),
                  ],
                  selected: {kind},
                  onSelectionChanged: (v) => setLocal(() {
                    kind = v.first;
                    if (kind == 'blocked') {
                      color = PH.hunterColor;
                      scope = 'all';
                      target = null;
                    }
                  }),
                ),
                if (kind == 'blocked')
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Für alle sichtbar. Gejagte, die es betreten, gelten wie beim Verlassen des Spielfelds '
                      'als live sichtbar. Jäger bekommen eine Warnung, die Spielleitung eine Meldung.',
                      style: TextStyle(fontSize: 12, color: PH.muted),
                    ),
                  ),
                if (kind == 'mark') ...[
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
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: Color(col),
                            shape: BoxShape.circle,
                            border: Border.all(color: col == color ? Colors.white : Colors.transparent, width: 3),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                const Text('Wer sieht die Zone?', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'all', label: Text('Alle')),
                    ButtonSegment(value: 'team', label: Text('Ein Team')),
                    ButtonSegment(value: 'player', label: Text('Ein Spieler')),
                  ],
                  selected: {scope},
                  onSelectionChanged: (v) => setLocal(() {
                    scope = v.first;
                    target = null;
                  }),
                ),
                if (scope == 'team')
                  DropdownButton<String>(
                    isExpanded: true,
                    hint: const Text('Team wählen'),
                    value: g.teams.containsKey(target) ? target : null,
                    dropdownColor: PH.surface2,
                    items: [
                      for (final t in g.teamList) DropdownMenuItem(value: t.id, child: Text(t.name)),
                    ],
                    onChanged: (v) => setLocal(() => target = v),
                  ),
                if (scope == 'player')
                  DropdownButton<String>(
                    isExpanded: true,
                    hint: const Text('Spieler wählen'),
                    value: players.any((p) => p.uid == target) ? target : null,
                    dropdownColor: PH.surface2,
                    items: [
                      for (final p in players) DropdownMenuItem(value: p.uid, child: Text(p.name)),
                    ],
                    onChanged: (v) => setLocal(() => target = v),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(existing == null ? 'Weiter zum Zeichnen' : 'Speichern & neu zeichnen'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    if (name.text.trim().isEmpty) {
      _msg('Bitte einen Namen für die Zone eingeben.');
      return;
    }
    if (scope != 'all' && target == null) {
      _msg('Bitte ein Team bzw. einen Spieler auswählen.');
      return;
    }
    final id = existing?.id ?? 'z${DateTime.now().millisecondsSinceEpoch}';
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AreaEditor(
          code: g.code,
          initial: existing?.points ?? const [],
          title: 'Zone: ${name.text.trim()}',
          color: Color(color),
          reference: g.area,
          onSave: (pts) async {
            final zone = Zone(id, name.text.trim(), color, pts, scope, scope == 'all' ? null : target,
                kind: kind);
            final latest = _game ?? g;
            final list = [for (final o in latest.zones) if (o.id != id) o, zone];
            await _repo.saveZones(g.code, list);
          },
        ),
      ),
    );
  }

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
              if (v == 'msg') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: Text(p.name)),
                      body: ChatThread(
                        watcher: _chat,
                        channel: 'dm:${p.uid}',
                        myName: 'Spielleitung',
                        fromLeader: true,
                        emptyText: 'Privater Chat mit ${p.name}.',
                      ),
                    ),
                  ),
                );
              }
              if (v.startsWith('team:')) _do(() => _repo.setPlayerTeam(g.code, p.uid, v.substring(5)));
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'msg', child: Text('Nachricht schreiben')),
              const PopupMenuDivider(),
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
            actions: [_chatAction(g)],
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
                SizedBox(
                  width: 340,
                  child: DefaultTabController(
                    length: 2,
                    child: Column(
                      children: [
                        TabBar(
                          tabs: [
                            const Tab(text: 'Ereignisse'),
                            Tab(
                              child: UnreadBadge(count: _chat.totalUnread, child: const Text('Nachrichten')),
                            ),
                          ],
                        ),
                        Expanded(
                          child: TabBarView(
                            children: [
                              ListView(children: [_eventsPanel(now)]),
                              LeaderChatList(watcher: _chat, game: g, players: _players),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return DefaultTabController(
        length: 5,
        child: Scaffold(
          appBar: AppBar(
            title: Text('Spielleitung · ${g.code}', style: const TextStyle(fontWeight: FontWeight.w800)),
            bottom: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                const Tab(text: 'Karte'),
                const Tab(text: 'Teams'),
                const Tab(text: 'Spiel'),
                Tab(child: UnreadBadge(count: _chat.totalUnread, child: const Text('Chat'))),
                const Tab(text: 'Ereignisse'),
              ],
            ),
          ),
          body: TabBarView(
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _mapView(g, now),
              ListView(padding: const EdgeInsets.all(12), children: [_teamsPanel(g, now)]),
              ListView(padding: const EdgeInsets.all(12), children: [_gamePanel(g, now)]),
              LeaderChatList(watcher: _chat, game: g, players: _players),
              ListView(padding: const EdgeInsets.all(12), children: [_eventsPanel(now)]),
            ],
          ),
        ),
      );
    });
  }
}

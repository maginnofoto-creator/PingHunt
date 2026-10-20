import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../jokers.dart';
import '../models.dart';
import '../repo.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// Joker-Auswahl für Spieler (Gejagte oder Jäger).
class JokerSheet extends StatelessWidget {
  const JokerSheet({
    super.key,
    required this.game,
    required this.me,
    required this.players,
    required this.effects,
    required this.live,
    required this.pings,
    required this.myPos,
  });

  final Game game;
  final Player me;
  final List<Player> players;
  final List<Effect> effects;
  final List<LivePos> live;
  final List<Ping> pings;
  final LatLng? myPos;

  @override
  Widget build(BuildContext context) {
    final g = game;
    final team = g.team(me.teamId);
    if (team == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('Du bist noch keinem Team zugeteilt.'),
      );
    }
    final now = DateTime.now();
    final jammed = activeFor(effects, 'jammer', me.uid, me.teamId, now).isNotEmpty;
    final defs = allJokers.where((d) => d.forHunters == team.isHunter && jokerCfg(g, d).enabled).toList();

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Text(team.isHunter ? 'Jäger-Joker' : 'Joker', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            if (!g.isRunning)
              const Text('Joker gibt es erst, wenn das Spiel läuft.', style: TextStyle(color: PH.muted)),
            if (jammed)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('📡 Störsender aktiv – dein Team kann gerade keine Joker einsetzen.',
                    style: TextStyle(color: PH.danger, fontWeight: FontWeight.w700)),
              ),
            if (defs.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('Die Spielleitung hat für diese Runde keine Joker freigegeben.',
                    style: TextStyle(color: PH.muted)),
              ),
            for (final d in defs) _tile(context, d, jokerCfg(g, d), jammed),
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, JokerDef d, JokerCfg c, bool jammed) {
    final used = jokerUsed(effects, d, c, me.uid, me.teamId);
    final left = c.count - used;
    final enabled = game.isRunning && left > 0 && !jammed;
    return Card(
      margin: const EdgeInsets.only(top: 10),
      child: ListTile(
        enabled: enabled,
        leading: Icon(d.icon, color: enabled ? PH.accent : PH.muted, size: 30),
        title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('${d.describe(c.p1, c.p2)}\nNoch $left von ${c.count}${c.perTeam ? ' (fürs Team)' : ''}'),
        ),
        isThreeLine: true,
        onTap: enabled ? () => _use(context, d, c) : null,
      ),
    );
  }

  List<Player> _hunted({bool includePaused = true}) {
    final now = DateTime.now();
    return players.where((p) {
      final t = game.team(p.teamId);
      return t != null && !t.isHunter && !p.observer && !p.isCaught && (includePaused || !p.isPaused(now));
    }).toList();
  }

  LivePos? _livePos(String uid) {
    for (final l in live) {
      if (l.uid == uid) return l;
    }
    return null;
  }

  Future<(String, String?)?> _pickTarget(BuildContext context, {required bool allowPlayer}) {
    final teams = game.teamList.where((t) => !t.isHunter).toList();
    final hunted = _hunted();
    return showModalBottomSheet<(String, String?)>(
      context: context,
      backgroundColor: PH.surface,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Ziel auswählen', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            for (final t in teams)
              ListTile(
                leading: CircleAvatar(backgroundColor: Color(t.color), child: const Icon(Icons.groups, color: PH.bg)),
                title: Text('Ganzes Team: ${t.name}'),
                onTap: () => Navigator.pop(c, ('team', t.id)),
              ),
            if (allowPlayer)
              for (final p in hunted)
                ListTile(
                  leading: Dot(Color(game.team(p.teamId)!.color)),
                  title: Text(p.name),
                  subtitle: Text(game.team(p.teamId)!.name),
                  onTap: () => Navigator.pop(c, ('player', p.uid)),
                ),
          ],
        ),
      ),
    );
  }

  String _targetName(String kind, String? id) {
    if (kind == 'all') return 'alle Gejagten';
    if (kind == 'team') return game.team(id)?.name ?? 'Team';
    for (final p in players) {
      if (p.uid == id) return p.name;
    }
    return 'Spieler';
  }

  void _msg(BuildContext context, String t) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _use(BuildContext context, JokerDef d, JokerCfg c) async {
    final g = game;
    final repo = Repo.i;
    final now = DateTime.now();
    final myTeam = g.team(me.teamId)!;
    var kind = 'team';
    String? target = me.teamId;
    DateTime end = now.add(const Duration(minutes: 1));
    DateTime? slot;
    String? resultText;

    switch (d.id) {
      case 'fake':
      case 'skip':
      case 'timeshift':
        slot = g.nextPing(now);
        if (slot == null) {
          _msg(context, 'Gerade ist kein Ping geplant.');
          return;
        }
        if (slot.difference(now).inSeconds < 20) {
          _msg(context, 'Der nächste Ping kommt gleich – zu spät für diesen Joker.');
          return;
        }
        end = slot.add(const Duration(minutes: 5));
      case 'pause':
        end = now.add(Duration(hours: c.p1));
      case 'hunterview':
      case 'compass':
        end = now.add(Duration(seconds: c.p1));
        if (d.id == 'compass') {
          kind = 'player';
          target = me.uid;
        }
      case 'proximity':
      case 'shield':
      case 'freepass':
      case 'wipe':
      case 'live':
      case 'jammer':
        end = now.add(Duration(minutes: c.p1));
      case 'turbo':
        kind = 'all';
        target = null;
        end = now.add(Duration(minutes: c.p1));
      case 'freeze':
        kind = 'all';
        target = null;
        end = now.add(Duration(minutes: c.p1));
        // Alle Jäger müssen weit genug von allen Gejagten entfernt sein
        final hunters = players.where((p) => !p.observer && (g.team(p.teamId)?.isHunter ?? false));
        double? minDist;
        for (final h in hunters) {
          final hp = _livePos(h.uid);
          if (hp == null) continue;
          for (final v in _hunted(includePaused: false)) {
            final vp = _livePos(v.uid);
            if (vp == null) continue;
            final dist = metersBetween(hp.pos, vp.pos);
            if (minDist == null || dist < minDist) minDist = dist;
          }
        }
        if (minDist != null && minDist < c.p2) {
          _msg(context, 'Freeze geht nicht: Ein Jäger ist nur ${minDist.round()} m von einem Gejagten entfernt '
              '(nötig: ${c.p2} m).');
          return;
        }
      case 'speedhunt':
        end = now.add(const Duration(minutes: 2));
      case 'radar':
        kind = 'player';
        target = me.uid;
        final here = myPos;
        if (here == null) {
          _msg(context, 'Noch kein GPS-Signal.');
          return;
        }
        var n = 0;
        for (final v in _hunted(includePaused: false)) {
          final vp = _livePos(v.uid);
          if (vp != null && metersBetween(here, vp.pos) <= c.p1) n++;
        }
        resultText = n == 0
            ? 'Im Umkreis von ${c.p1} m ist kein Gejagter.'
            : '$n Gejagte${n == 1 ? 'r ist' : ' sind'} im Umkreis von ${c.p1} m!';
      case 'fakedetect':
        break;
    }

    if (d.target == JokerTarget.playerOrTeam || d.target == JokerTarget.huntedTeam) {
      final t = await _pickTarget(context, allowPlayer: d.target == JokerTarget.playerOrTeam);
      if (t == null) return;
      kind = t.$1;
      target = t.$2;
      if (d.id == 'fakedetect') {
        final members = players.where((p) => p.teamId == target).map((p) => p.uid).toSet();
        final lines = <String>[];
        for (final uid in members) {
          Ping? last;
          for (final p in pings) {
            if (p.uid == uid && !p.manual) last = p;
          }
          if (last != null) lines.add('${last.name}: ${last.fake ? 'FAKE ❌' : 'echt ✅'} (${hhmm(last.t)})');
        }
        resultText = lines.isEmpty ? 'Von diesem Team gibt es noch keine Pings.' : lines.join('\n');
      }
    }

    if (!context.mounted) return;
    final targetText = (d.target == JokerTarget.none && kind == 'team') ? '' : ' → ${_targetName(kind, target)}';
    final ok = await confirm(context, '${d.name} einsetzen?', '${d.describe(c.p1, c.p2)}$targetText');
    if (!ok) return;

    try {
      await repo.createEffect(g.code, {
        'type': d.id,
        'byName': me.name,
        'byTeam': me.teamId,
        'targetKind': kind,
        'targetId': target,
        'start': Timestamp.fromDate(now),
        'end': Timestamp.fromDate(end),
        if (slot != null) 'slot': Timestamp.fromDate(slot),
        'p1': c.p1,
        'p2': c.p2,
      });
      final who = myTeam.isHunter ? '${me.name} (Jäger)' : '${me.name} (${myTeam.name})';
      await repo.addEvent(g.code, '🃏 $who setzt „${d.name}“ ein$targetText', myTeam.color);
    } catch (e) {
      if (context.mounted) _msg(context, 'Joker konnte nicht eingesetzt werden: $e');
      return;
    }
    if (!context.mounted) return;
    if (resultText != null) {
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(d.name),
          content: Text(resultText!, style: const TextStyle(fontSize: 17)),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      );
    } else {
      _msg(context, '„${d.name}“ eingesetzt.');
    }
    if (context.mounted) Navigator.pop(context);
  }
}

/// Einstellungen der Joker für die Spielleitung.
class JokerConfigScreen extends StatefulWidget {
  const JokerConfigScreen({super.key, required this.code});

  final String code;

  @override
  State<JokerConfigScreen> createState() => _JokerConfigScreenState();
}

class _JokerConfigScreenState extends State<JokerConfigScreen> {
  Game? _game;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = Repo.i.gameStream(widget.code).listen((g) => setState(() => _game = g));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _save(JokerDef d, JokerCfg c) async {
    try {
      await Repo.i.updateGame(widget.code, {'jokers.${d.id}': c.toMap()});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Fehler: $e')));
    }
  }

  Widget _param(JokerParam p, int value, ValueChanged<int> onChanged) => StepperRow(
        title: p.label,
        value: '$value ${p.unit}',
        onMinus: value - p.step < p.min ? null : () => onChanged(value - p.step),
        onPlus: value + p.step > p.max ? null : () => onChanged(value + p.step),
      );

  Widget _card(Game g, JokerDef d) {
    final c = jokerCfg(g, d);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: Icon(d.icon, color: c.enabled ? PH.accent : PH.muted),
              title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(d.describe(c.p1, c.p2), style: const TextStyle(fontSize: 12)),
              value: c.enabled,
              onChanged: (v) => _save(d, c.copyWith(enabled: v)),
            ),
            if (c.enabled) ...[
              StepperRow(
                title: 'Anzahl',
                subtitle: c.perTeam ? 'pro Team' : 'pro Person',
                value: '${c.count}×',
                onMinus: c.count <= 1 ? null : () => _save(d, c.copyWith(count: c.count - 1)),
                onPlus: c.count >= 20 ? null : () => _save(d, c.copyWith(count: c.count + 1)),
              ),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('pro Person')),
                  ButtonSegment(value: true, label: Text('pro Team')),
                ],
                selected: {c.perTeam},
                onSelectionChanged: (v) => _save(d, c.copyWith(perTeam: v.first)),
              ),
              if (d.p1 != null) _param(d.p1!, c.p1, (v) => _save(d, c.copyWith(p1: v))),
              if (d.p2 != null) _param(d.p2!, c.p2, (v) => _save(d, c.copyWith(p2: v))),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = _game;
    return Scaffold(
      appBar: AppBar(title: const Text('Joker einstellen')),
      body: g == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    SwitchListTile(
                      title: const Text('Gegner erfahren, welcher Joker'),
                      subtitle: const Text('Aus: nur „hat einen Joker eingesetzt“. '
                          'Die Spielleitung und Zuschauer sehen es immer im Ticker.'),
                      value: g.jokerReveal,
                      onChanged: (v) => Repo.i.updateGame(g.code, {'jokerReveal': v}),
                    ),
                    const SizedBox(height: 8),
                    Text('JOKER FÜR GEJAGTE', style: label()),
                    const SizedBox(height: 8),
                    for (final d in allJokers.where((d) => !d.forHunters)) _card(g, d),
                    const SizedBox(height: 16),
                    Text('JOKER FÜR JÄGER', style: label()),
                    const SizedBox(height: 8),
                    for (final d in allJokers.where((d) => d.forHunters)) _card(g, d),
                  ],
                ),
              ),
            ),
    );
  }
}

import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'models.dart';

/// Wen ein Joker trifft, den der Spieler beim Auslösen auswählt.
enum JokerTarget { none, team, playerOrTeam, huntedTeam }

/// Einstellbarer Wert eines Jokers (z. B. Dauer, Radius).
class JokerParam {
  final String label;
  final String unit;
  final int min, max, step, def;
  const JokerParam(this.label, this.unit, this.min, this.max, this.step, this.def);
}

class JokerDef {
  final String id;
  final bool forHunters;
  final String name;
  final IconData icon;
  final String Function(int p1, int p2) describe;
  final JokerTarget target;
  final JokerParam? p1;
  final JokerParam? p2;

  const JokerDef(this.id, this.forHunters, this.name, this.icon, this.describe,
      {this.target = JokerTarget.none, this.p1, this.p2});
}

/// Alle Joker. Die Spielleitung schaltet pro Runde frei, welche es gibt.
final List<JokerDef> allJokers = [
  // ---------- Gejagte ----------
  JokerDef('fake', false, 'Fake-Ping', Icons.wrong_location,
      (a, b) => 'Der nächste Ping deines Teams erscheint ca. $a m neben der echten Position.',
      p1: const JokerParam('Abstand', 'm', 100, 500, 50, 200)),
  JokerDef('pause', false, 'Pause', Icons.pause_circle,
      (a, b) => 'Dein Team pausiert $a Stunde${a == 1 ? '' : 'n'}: keine Pings, nicht live sichtbar, nicht fangbar. '
          'Wer sich mehr als $b m entfernt, beendet die Pause für sich.',
      p1: const JokerParam('Dauer', 'h', 1, 5, 1, 1),
      p2: const JokerParam('Bewegungsradius', 'm', 0, 500, 50, 300)),
  JokerDef('skip', false, 'Ping überspringen', Icons.skip_next,
      (a, b) => 'Der nächste Ping deines Teams fällt aus.'),
  JokerDef('timeshift', false, 'Zeitverschiebung', Icons.history,
      (a, b) => 'Der nächste Ping zeigt, wo dein Team vor $a Minuten war.',
      p1: const JokerParam('Zeit zurück', 'min', 5, 30, 5, 10)),
  JokerDef('hunterview', false, 'Jäger-Blick', Icons.visibility,
      (a, b) => 'Dein Team sieht $a Sekunden lang, wo alle Jäger gerade sind.',
      p1: const JokerParam('Dauer', 's', 15, 120, 15, 60)),
  JokerDef('proximity', false, 'Annäherungsalarm', Icons.sensors,
      (a, b) => '$a Minuten lang vibriert es, sobald ein Jäger näher als $b m kommt.',
      p1: const JokerParam('Dauer', 'min', 10, 60, 10, 30),
      p2: const JokerParam('Radius', 'm', 100, 1000, 100, 300)),
  JokerDef('shield', false, 'Schutzschild', Icons.shield,
      (a, b) => 'Dein Team kann $a Minuten lang nicht gefangen werden.',
      p1: const JokerParam('Dauer', 'min', 5, 30, 5, 10)),
  JokerDef('freepass', false, 'Freigang', Icons.directions_walk,
      (a, b) => 'Dein Team darf $a Minuten lang das Spielfeld und Sperrgebiete verlassen, ohne live sichtbar zu werden.',
      p1: const JokerParam('Dauer', 'min', 5, 30, 5, 15)),
  JokerDef('wipe', false, 'Spuren verwischen', Icons.blur_on,
      (a, b) => 'Die Jäger sehen $a Minuten lang keinen Ping-Verlauf deines Teams, nur den letzten Ping.',
      p1: const JokerParam('Dauer', 'min', 15, 120, 15, 60)),

  // ---------- Jäger ----------
  JokerDef('live', true, 'Live-Ortung', Icons.radar,
      (a, b) => 'Eine Person oder ein ganzes Team ist $a Minuten lang live sichtbar.',
      target: JokerTarget.playerOrTeam,
      p1: const JokerParam('Dauer', 'min', 5, 20, 5, 10)),
  JokerDef('freeze', true, 'Freeze', Icons.ac_unit,
      (a, b) => 'Kein Gejagter darf sich $a Minuten bewegen (30 m Toleranz), sonst ist er live sichtbar. '
          'Nur auslösbar, wenn alle Jäger mindestens $b m von allen Gejagten entfernt sind.',
      p1: const JokerParam('Dauer', 'min', 1, 10, 1, 5),
      p2: const JokerParam('Mindestabstand', 'm', 100, 1000, 100, 500)),
  JokerDef('speedhunt', true, 'Speedhunt', Icons.bolt,
      (a, b) => 'Sofortiger Ping einer Person oder eines Teams.', target: JokerTarget.playerOrTeam),
  JokerDef('radar', true, 'Radar', Icons.track_changes,
      (a, b) => 'Zeigt, wie viele Gejagte gerade im Umkreis von $a m um dich sind.',
      p1: const JokerParam('Radius', 'm', 200, 2000, 100, 500)),
  JokerDef('compass', true, 'Kompass', Icons.explore,
      (a, b) => '$a Sekunden lang zeigt ein Pfeil in Richtung des nächsten Gejagten.',
      p1: const JokerParam('Dauer', 's', 10, 120, 10, 30)),
  JokerDef('turbo', true, 'Turbo-Intervall', Icons.speed,
      (a, b) => '$a Minuten lang kommen zusätzlich alle 10 Minuten Pings.',
      p1: const JokerParam('Dauer', 'min', 30, 180, 30, 60)),
  JokerDef('fakedetect', true, 'Fake-Detektor', Icons.fact_check,
      (a, b) => 'Zeigt, ob der letzte Ping eines Teams ein Fake war.', target: JokerTarget.huntedTeam),
  JokerDef('jammer', true, 'Störsender', Icons.portable_wifi_off,
      (a, b) => 'Ein Team kann $a Minuten lang keine Joker einsetzen.',
      target: JokerTarget.huntedTeam,
      p1: const JokerParam('Dauer', 'min', 10, 60, 10, 30)),
];

JokerDef? jokerDef(String id) {
  for (final d in allJokers) {
    if (d.id == id) return d;
  }
  return null;
}

/// Einstellung eines Jokers durch die Spielleitung.
class JokerCfg {
  final bool enabled;
  final int count;
  final bool perTeam;
  final int p1, p2;

  const JokerCfg({this.enabled = false, this.count = 1, this.perTeam = false, this.p1 = 0, this.p2 = 0});

  static JokerCfg defaults(JokerDef d) => JokerCfg(p1: d.p1?.def ?? 0, p2: d.p2?.def ?? 0);

  static JokerCfg fromMap(JokerDef d, dynamic m) {
    if (m is! Map) return defaults(d);
    int n(dynamic v, int f) => v is num ? v.toInt() : f;
    return JokerCfg(
      enabled: m['enabled'] == true,
      count: math.max(1, math.min(20, n(m['count'], 1))),
      perTeam: m['perTeam'] == true,
      p1: n(m['p1'], d.p1?.def ?? 0),
      p2: n(m['p2'], d.p2?.def ?? 0),
    );
  }

  Map<String, dynamic> toMap() =>
      {'enabled': enabled, 'count': count, 'perTeam': perTeam, 'p1': p1, 'p2': p2};

  JokerCfg copyWith({bool? enabled, int? count, bool? perTeam, int? p1, int? p2}) => JokerCfg(
        enabled: enabled ?? this.enabled,
        count: count ?? this.count,
        perTeam: perTeam ?? this.perTeam,
        p1: p1 ?? this.p1,
        p2: p2 ?? this.p2,
      );
}

JokerCfg jokerCfg(Game g, JokerDef d) => JokerCfg.fromMap(d, g.jokers[d.id]);

/// Ein eingesetzter Joker.
class Effect {
  final String id;
  final String type;
  final String by;
  final String byName;
  final String? byTeam;
  final String targetKind; // team, player, all
  final String? targetId;
  final DateTime start;
  final DateTime end;
  final DateTime? slot; // betroffener Ping-Zeitpunkt (fake, skip, timeshift)
  final int p1, p2;

  Effect(this.id, this.type, this.by, this.byName, this.byTeam, this.targetKind, this.targetId, this.start,
      this.end, this.slot, this.p1, this.p2);

  bool isActive(DateTime now) => !now.isBefore(start) && now.isBefore(end);

  bool targets(String uid, String? teamId) {
    if (targetKind == 'all') return true;
    if (targetKind == 'player') return targetId == uid;
    return targetId != null && targetId == teamId;
  }

  static Effect? fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data();
    if (m == null) return null;
    DateTime? ts(dynamic v) => v is Timestamp ? v.toDate() : null;
    int n(dynamic v) => v is num ? v.toInt() : 0;
    final start = ts(m['start']), end = ts(m['end']);
    if (start == null || end == null) return null;
    return Effect(
      d.id,
      (m['type'] as String?) ?? '',
      (m['by'] as String?) ?? '',
      (m['byName'] as String?) ?? '',
      m['byTeam'] as String?,
      (m['targetKind'] as String?) ?? 'team',
      m['targetId'] as String?,
      start,
      end,
      ts(m['slot']),
      n(m['p1']),
      n(m['p2']),
    );
  }
}

/// Wie oft ein Joker schon benutzt wurde (pro Person bzw. pro Team).
int jokerUsed(List<Effect> effects, JokerDef d, JokerCfg c, String uid, String? teamId) => effects
    .where((e) => e.type == d.id && (c.perTeam ? e.byTeam != null && e.byTeam == teamId : e.by == uid))
    .length;

/// Aktive Effekte eines Typs, die diesen Spieler betreffen.
List<Effect> activeFor(List<Effect> effects, String type, String uid, String? teamId, DateTime now) =>
    effects.where((e) => e.type == type && e.isActive(now) && e.targets(uid, teamId)).toList();

/// Punkt in [meters] Entfernung und zufälliger Richtung (für Fake-Pings).
LatLng offsetRandom(LatLng p, double meters, math.Random rnd) {
  final bearing = rnd.nextDouble() * 360;
  return const Distance().offset(p, meters, bearing);
}

/// Richtung von a nach b in Grad (0 = Norden).
double bearingTo(LatLng a, LatLng b) => const Distance().bearing(a, b);

double metersBetween(LatLng a, LatLng b) => const Distance().as(LengthUnit.Meter, a, b);

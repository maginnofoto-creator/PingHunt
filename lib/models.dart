import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:latlong2/latlong.dart';

DateTime? _ts(dynamic v) => v is Timestamp ? v.toDate() : null;
int _int(dynamic v, int fallback) => v is num ? v.toInt() : fallback;
double? _dbl(dynamic v) => v is num ? v.toDouble() : null;

class Team {
  final String id;
  final String name;
  final int color;
  final String role; // 'hunter' oder 'hunted'

  const Team(this.id, this.name, this.color, this.role);

  bool get isHunter => role == 'hunter';

  Map<String, dynamic> toMap() => {'name': name, 'color': color, 'role': role};

  static Team fromMap(String id, Map<String, dynamic> m) => Team(
        id,
        (m['name'] as String?) ?? 'Team',
        _int(m['color'], 0xFF9AA4B2),
        (m['role'] as String?) ?? 'hunted',
      );
}

/// Farbige Zone auf der Karte, sichtbar für alle, ein Team oder einen Spieler.
class Zone {
  final String id;
  final String name;
  final int color;
  final List<LatLng> points;
  final String scope; // all, team, player
  final String? target; // teamId oder uid
  final String kind; // mark = Markierung, blocked = Sperrgebiet

  const Zone(this.id, this.name, this.color, this.points, this.scope, this.target,
      {this.kind = 'mark'});

  bool get isBlocked => kind == 'blocked';

  bool visibleTo(String? uid, String? teamId) {
    if (isBlocked) return true;
    if (scope == 'team') return target != null && target == teamId;
    if (scope == 'player') return target != null && target == uid;
    return true;
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'color': color,
        'scope': scope,
        'target': target,
        'kind': kind,
        'points': [for (final p in points) {'lat': p.latitude, 'lng': p.longitude}],
      };

  static Zone? fromMap(Map<String, dynamic> m) {
    final raw = (m['points'] as List?) ?? const [];
    final pts = [
      for (final p in raw)
        if (p is Map && p['lat'] is num && p['lng'] is num)
          LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()),
    ];
    if (pts.length < 3) return null;
    return Zone(
      (m['id'] as String?) ?? 'z',
      (m['name'] as String?) ?? 'Zone',
      _int(m['color'], 0xFF4DA3FF),
      pts,
      (m['scope'] as String?) ?? 'all',
      m['target'] as String?,
      kind: (m['kind'] as String?) == 'blocked' ? 'blocked' : 'mark',
    );
  }
}

/// Was Zuschauer sehen dürfen (legt die Spielleitung fest).
class SpecSettings {
  final String hunters; // live, delay, off
  final String hunted; // live, delay, off
  final bool lastPings; // letzte Pings verblasst anzeigen
  final bool announcements; // Durchsagen
  final String teamChats; // off, live, delay
  final List<String> chatTeams; // Teams, deren Chat sichtbar ist

  const SpecSettings({
    this.hunters = 'live',
    this.hunted = 'delay',
    this.lastPings = true,
    this.announcements = true,
    this.teamChats = 'off',
    this.chatTeams = const [],
  });

  bool chatVisible(String teamId) => teamChats != 'off' && chatTeams.contains(teamId);

  Map<String, dynamic> toMap() => {
        'hunters': hunters,
        'hunted': hunted,
        'lastPings': lastPings,
        'announcements': announcements,
        'teamChats': teamChats,
        'chatTeams': chatTeams,
      };

  SpecSettings copyWith({
    String? hunters,
    String? hunted,
    bool? lastPings,
    bool? announcements,
    String? teamChats,
    List<String>? chatTeams,
  }) =>
      SpecSettings(
        hunters: hunters ?? this.hunters,
        hunted: hunted ?? this.hunted,
        lastPings: lastPings ?? this.lastPings,
        announcements: announcements ?? this.announcements,
        teamChats: teamChats ?? this.teamChats,
        chatTeams: chatTeams ?? this.chatTeams,
      );

  static String _mode(dynamic v, String fallback, List<String> allowed) =>
      v is String && allowed.contains(v) ? v : fallback;

  static SpecSettings fromMap(dynamic raw) {
    if (raw is! Map) return const SpecSettings();
    return SpecSettings(
      hunters: _mode(raw['hunters'], 'live', ['live', 'delay', 'off']),
      hunted: _mode(raw['hunted'], 'delay', ['live', 'delay', 'off']),
      lastPings: raw['lastPings'] != false,
      announcements: raw['announcements'] != false,
      teamChats: _mode(raw['teamChats'], 'off', ['live', 'delay', 'off']),
      chatTeams: [for (final t in (raw['chatTeams'] as List?) ?? const []) '$t'],
    );
  }
}

class Game {
  final String code;
  final String leaderUid;
  final String name;
  final String status; // lobby, running, ended
  final List<LatLng> area;
  final Map<String, Team> teams;
  final int intervalMin;
  final int headStartMin;
  final int liveMin;
  final int graceSec;
  final int durationH;
  final int spectatorDelayMin;
  final int offlinePenaltyMin;
  final SpecSettings spec;
  final Map<String, dynamic> jokers; // Joker-Einstellungen (siehe jokers.dart)
  final bool jokerReveal; // Gegner erfahren, welcher Joker eingesetzt wurde
  final SpeedRule speedRule;
  final DateTime? startedAt;
  final DateTime? endsAt;
  final DateTime? pingAnchor;
  final DateTime? pingRequestAt;
  final List<Zone> zones;

  Game({
    required this.code,
    required this.leaderUid,
    required this.name,
    required this.status,
    required this.area,
    required this.teams,
    required this.intervalMin,
    required this.headStartMin,
    required this.liveMin,
    required this.graceSec,
    required this.durationH,
    required this.spectatorDelayMin,
    this.offlinePenaltyMin = 5,
    this.spec = const SpecSettings(),
    this.jokers = const {},
    this.jokerReveal = false,
    this.speedRule = const SpeedRule(),
    this.startedAt,
    this.endsAt,
    this.pingAnchor,
    this.pingRequestAt,
    this.zones = const [],
  });

  List<Zone> get blockedZones => [for (final z in zones) if (z.isBlocked) z];

  bool get isRunning => status == 'running';
  bool get isLobby => status == 'lobby';
  bool get isEnded => status == 'ended';

  List<Team> get teamList {
    final l = teams.values.toList();
    l.sort((a, b) {
      if (a.isHunter != b.isHunter) return a.isHunter ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return l;
  }

  Team? team(String? id) => id == null ? null : teams[id];

  /// Der zuletzt fällige Ping-Zeitpunkt (oder null, solange noch kein Ping fällig war).
  DateTime? currentSlot(DateTime now) {
    final a = pingAnchor;
    if (!isRunning || a == null || now.isBefore(a)) return null;
    final k = now.difference(a).inSeconds ~/ (intervalMin * 60);
    return a.add(Duration(minutes: intervalMin * k));
  }

  /// Der nächste geplante Ping.
  DateTime? nextPing(DateTime now) {
    final a = pingAnchor;
    if (!isRunning || a == null) return null;
    if (now.isBefore(a)) return a;
    final k = now.difference(a).inSeconds ~/ (intervalMin * 60) + 1;
    return a.add(Duration(minutes: intervalMin * k));
  }

  static Game fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? {};
    final rawArea = (m['area'] as List?) ?? const [];
    final rawTeams = (m['teams'] as Map?) ?? const {};
    return Game(
      code: doc.id,
      leaderUid: (m['leaderUid'] as String?) ?? '',
      name: (m['name'] as String?) ?? 'PingHunt',
      status: (m['status'] as String?) ?? 'lobby',
      area: [
        for (final p in rawArea)
          if (p is Map && p['lat'] is num && p['lng'] is num)
            LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()),
      ],
      teams: {
        for (final e in rawTeams.entries)
          if (e.value is Map)
            '${e.key}': Team.fromMap('${e.key}', Map<String, dynamic>.from(e.value as Map)),
      },
      intervalMin: _int(m['intervalMin'], 30) < 10 ? 10 : _int(m['intervalMin'], 30),
      headStartMin: _int(m['headStartMin'], 20),
      liveMin: _int(m['liveMin'], 10),
      graceSec: _int(m['graceSec'], 15),
      durationH: _int(m['durationH'], 24),
      spectatorDelayMin: _int(m['spectatorDelayMin'], 20),
      offlinePenaltyMin: _int(m['offlinePenaltyMin'], 5),
      spec: SpecSettings.fromMap(m['spec']),
      jokers: m['jokers'] is Map ? Map<String, dynamic>.from(m['jokers'] as Map) : const {},
      jokerReveal: m['jokerReveal'] == true,
      speedRule: SpeedRule.fromMap(m['speedRule']),
      startedAt: _ts(m['startedAt']),
      endsAt: _ts(m['endsAt']),
      pingAnchor: _ts(m['pingAnchor']),
      pingRequestAt: _ts(m['pingRequestAt']),
      zones: [
        for (final z in (m['zones'] as List?) ?? const [])
          if (z is Map) Zone.fromMap(Map<String, dynamic>.from(z)),
      ].whereType<Zone>().toList(),
    );
  }
}

class Player {
  final String uid;
  final String name;
  final String? teamId;
  final String status; // free, caught
  final int? battery;
  final DateTime? lastSeen;
  final DateTime? liveUntil;
  final LatLng? exposed;
  final DateTime? exposedAt;
  final bool observer; // Zentrale im Browser: sieht mit, sendet keinen Standort
  final DateTime? pausedUntil; // Pause-Joker aktiv
  final bool? setupOk; // Standort/Akku-Einstellungen in Ordnung
  final double? distM; // gelaufene Strecke in Metern

  Player({
    required this.uid,
    required this.name,
    this.teamId,
    this.status = 'free',
    this.battery,
    this.lastSeen,
    this.liveUntil,
    this.exposed,
    this.exposedAt,
    this.observer = false,
    this.pausedUntil,
    this.setupOk,
    this.distM,
  });

  bool isPaused(DateTime now) => pausedUntil != null && now.isBefore(pausedUntil!);

  bool get isCaught => status == 'caught';
  bool isLive(DateTime now) => liveUntil != null && now.isBefore(liveUntil!);

  static Player fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? {};
    final ex = m['exposed'];
    LatLng? exposed;
    DateTime? exposedAt;
    if (ex is Map && ex['lat'] is num && ex['lng'] is num) {
      exposed = LatLng((ex['lat'] as num).toDouble(), (ex['lng'] as num).toDouble());
      exposedAt = _ts(ex['t']);
    }
    return Player(
      uid: doc.id,
      name: (m['name'] as String?) ?? 'Spieler',
      teamId: m['teamId'] as String?,
      status: (m['status'] as String?) ?? 'free',
      battery: m['battery'] is num ? (m['battery'] as num).toInt() : null,
      lastSeen: _ts(m['lastSeen']),
      liveUntil: _ts(m['liveUntil']),
      exposed: exposed,
      exposedAt: exposedAt,
      observer: m['observer'] == true,
      pausedUntil: _ts(m['pausedUntil']),
      setupOk: m['setupOk'] is bool ? m['setupOk'] as bool : null,
      distM: _dbl(m['distM']),
    );
  }
}

class Ping {
  final String id;
  final String uid;
  final String name;
  final String? teamId;
  final LatLng pos;
  final DateTime t;
  final bool manual;
  final bool offline; // Ersatz-Ping mit letzter bekannter Position
  final bool fake; // Fake-Ping-Joker

  Ping(this.id, this.uid, this.name, this.teamId, this.pos, this.t, this.manual,
      {this.offline = false, this.fake = false});

  static Ping? fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data();
    if (m == null) return null;
    final lat = _dbl(m['lat']);
    final lng = _dbl(m['lng']);
    final t = _ts(m['t']);
    if (lat == null || lng == null || t == null) return null;
    return Ping(doc.id, (m['uid'] as String?) ?? '', (m['name'] as String?) ?? '',
        m['teamId'] as String?, LatLng(lat, lng), t, m['manual'] == true,
        offline: m['offline'] == true, fake: m['fake'] == true);
  }
}

class LivePos {
  final String uid;
  final String name;
  final String? teamId;
  final LatLng pos;
  final DateTime? t;
  final double? acc; // GPS-Genauigkeit in Metern

  LivePos(this.uid, this.name, this.teamId, this.pos, this.t, {this.acc});

  static LivePos? fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data();
    if (m == null) return null;
    final lat = _dbl(m['lat']);
    final lng = _dbl(m['lng']);
    if (lat == null || lng == null) return null;
    return LivePos(doc.id, (m['name'] as String?) ?? '', m['teamId'] as String?,
        LatLng(lat, lng), _ts(m['t']), acc: _dbl(m['acc']));
  }
}

class GameEvent {
  final String id;
  final String text;
  final int color;
  final DateTime t;

  GameEvent(this.id, this.text, this.color, this.t);

  static GameEvent fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? {};
    return GameEvent(
      doc.id,
      (m['text'] as String?) ?? '',
      _int(m['color'], 0xFF9AA4B2),
      _ts(m['t']) ?? DateTime.now(),
    );
  }
}

/// Verzögerte Jäger-Spur für Zuschauer.
class TrailPos {
  final String uid;
  final String name;
  final String? teamId;
  final LatLng pos;
  final DateTime t;

  TrailPos(this.uid, this.name, this.teamId, this.pos, this.t);

  static TrailPos? fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data();
    if (m == null) return null;
    final lat = _dbl(m['lat']);
    final lng = _dbl(m['lng']);
    final t = _ts(m['t']);
    if (lat == null || lng == null || t == null) return null;
    return TrailPos((m['uid'] as String?) ?? '', (m['name'] as String?) ?? '',
        m['teamId'] as String?, LatLng(lat, lng), t);
  }
}

/// Chat-Nachricht. Kanäle: 'all' (Durchsage), 'dm:<uid>' (Spieler ↔ Spielleitung),
/// 'team:<teamId>' (Team-Chat, Spielleitung liest mit).
class ChatMsg {
  final String id;
  final String channel;
  final String from;
  final String fromName;
  final bool fromLeader;
  final String text;
  final String kind; // text, quick, loc
  final LatLng? pos;
  final DateTime t;

  ChatMsg(this.id, this.channel, this.from, this.fromName, this.fromLeader, this.text, this.kind,
      this.pos, this.t);

  static ChatMsg? fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data();
    if (m == null) return null;
    final t = _ts(m['t']);
    if (t == null) return null;
    final lat = _dbl(m['lat']);
    final lng = _dbl(m['lng']);
    return ChatMsg(
      doc.id,
      (m['channel'] as String?) ?? '',
      (m['from'] as String?) ?? '',
      (m['fromName'] as String?) ?? '',
      m['fromLeader'] == true,
      (m['text'] as String?) ?? '',
      (m['kind'] as String?) ?? 'text',
      lat != null && lng != null ? LatLng(lat, lng) : null,
      t,
    );
  }
}

/// Gemeldeter Fang (wird von der Spielleitung bestätigt oder abgelehnt).
class CatchReport {
  final String id;
  final String by;
  final String byName;
  final String target;
  final String targetName;
  final String? teamId;
  final DateTime t;
  final String status; // pending, confirmed, rejected
  final DateTime? decidedAt;

  CatchReport(this.id, this.by, this.byName, this.target, this.targetName, this.teamId, this.t, this.status,
      this.decidedAt);

  static CatchReport? fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data();
    if (m == null) return null;
    final t = _ts(m['t']);
    if (t == null) return null;
    return CatchReport(
      d.id,
      (m['by'] as String?) ?? '',
      (m['byName'] as String?) ?? '',
      (m['target'] as String?) ?? '',
      (m['targetName'] as String?) ?? '',
      m['teamId'] as String?,
      t,
      (m['status'] as String?) ?? 'pending',
      _ts(m['decidedAt']),
    );
  }
}

/// Markierung der Jäger auf der Karte (verschwindet nach Ablauf).
class MapMark {
  final String id;
  final String by;
  final String byName;
  final String? teamId;
  final String text;
  final LatLng pos;
  final DateTime end;

  MapMark(this.id, this.by, this.byName, this.teamId, this.text, this.pos, this.end);

  static MapMark? fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data();
    if (m == null) return null;
    final lat = _dbl(m['lat']), lng = _dbl(m['lng']), end = _ts(m['end']);
    if (lat == null || lng == null || end == null) return null;
    return MapMark(d.id, (m['by'] as String?) ?? '', (m['byName'] as String?) ?? '', m['teamId'] as String?,
        (m['text'] as String?) ?? '', LatLng(lat, lng), end);
  }
}

/// Fahrzeug-Regel: Wer schneller als [kmh] ist, wird live sichtbar.
class SpeedRule {
  final bool enabled;
  final int kmh;
  final int afterMin;
  const SpeedRule({this.enabled = false, this.kmh = 10, this.afterMin = 3});

  static SpeedRule fromMap(dynamic m) {
    if (m is! Map) return const SpeedRule();
    int n(dynamic v, int f) => v is num ? v.toInt() : f;
    return SpeedRule(enabled: m['enabled'] == true, kmh: n(m['kmh'], 10), afterMin: n(m['afterMin'], 3));
  }

  Map<String, dynamic> toMap() => {'enabled': enabled, 'kmh': kmh, 'afterMin': afterMin};
}

/// Alle aufgezeichneten Daten eines Spiels für die Wiederholung.
class ReplayData {
  final List<TrailPos> trail;
  final List<Ping> pings;
  final List<GameEvent> events;
  ReplayData(this.trail, this.pings, this.events);
}

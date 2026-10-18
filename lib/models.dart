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
  final DateTime? startedAt;
  final DateTime? endsAt;
  final DateTime? pingAnchor;
  final DateTime? pingRequestAt;

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
    this.startedAt,
    this.endsAt,
    this.pingAnchor,
    this.pingRequestAt,
  });

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
      startedAt: _ts(m['startedAt']),
      endsAt: _ts(m['endsAt']),
      pingAnchor: _ts(m['pingAnchor']),
      pingRequestAt: _ts(m['pingRequestAt']),
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
  });

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

  Ping(this.id, this.uid, this.name, this.teamId, this.pos, this.t, this.manual);

  static Ping? fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data();
    if (m == null) return null;
    final lat = _dbl(m['lat']);
    final lng = _dbl(m['lng']);
    final t = _ts(m['t']);
    if (lat == null || lng == null || t == null) return null;
    return Ping(doc.id, (m['uid'] as String?) ?? '', (m['name'] as String?) ?? '',
        m['teamId'] as String?, LatLng(lat, lng), t, m['manual'] == true);
  }
}

class LivePos {
  final String uid;
  final String name;
  final String? teamId;
  final LatLng pos;
  final DateTime? t;

  LivePos(this.uid, this.name, this.teamId, this.pos, this.t);

  static LivePos? fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data();
    if (m == null) return null;
    final lat = _dbl(m['lat']);
    final lng = _dbl(m['lng']);
    if (lat == null || lng == null) return null;
    return LivePos(doc.id, (m['name'] as String?) ?? '', m['teamId'] as String?,
        LatLng(lat, lng), _ts(m['t']));
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

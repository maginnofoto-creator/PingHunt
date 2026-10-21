import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:latlong2/latlong.dart';

import 'jokers.dart';
import 'models.dart';
import 'theme.dart';

/// Alle Zugriffe auf Firebase an einer Stelle.
class Repo {
  Repo._();
  static final Repo i = Repo._();

  final _db = FirebaseFirestore.instance;
  final _rnd = Random.secure();

  String get uid => FirebaseAuth.instance.currentUser!.uid;

  DocumentReference<Map<String, dynamic>> gameRef(String code) =>
      _db.collection('games').doc(code);
  CollectionReference<Map<String, dynamic>> _players(String code) =>
      gameRef(code).collection('players');
  CollectionReference<Map<String, dynamic>> _pings(String code) =>
      gameRef(code).collection('pings');
  CollectionReference<Map<String, dynamic>> _live(String code) =>
      gameRef(code).collection('live');
  CollectionReference<Map<String, dynamic>> _events(String code) =>
      gameRef(code).collection('events');
  CollectionReference<Map<String, dynamic>> _trail(String code) =>
      gameRef(code).collection('trail');

  Future<void> writeTrail(String code, Map<String, dynamic> data) => _trail(code).add(data);

  /// Jäger-Spur der letzten Stunden (für Zuschauer).
  Stream<List<TrailPos>> trailStream(String code, DateTime since) => _trail(code)
      .where('t', isGreaterThan: Timestamp.fromDate(since))
      .orderBy('t')
      .snapshots()
      .map((q) => q.docs.map(TrailPos.fromDoc).whereType<TrailPos>().toList());

  Future<void> saveZones(String code, List<Zone> zones) =>
      gameRef(code).update({'zones': [for (final z in zones) z.toMap()]});

  /// Vorsprung ändern – in der Lobby oder solange der Vorsprung noch läuft.
  Future<void> changeHeadStart(Game g, int minutes) async {
    final data = <String, dynamic>{'headStartMin': minutes};
    if (g.isRunning && g.startedAt != null) {
      data['pingAnchor'] = Timestamp.fromDate(g.startedAt!.add(Duration(minutes: minutes)));
    }
    await updateGame(g.code, data);
  }

  // ---------- Spiel anlegen / beitreten ----------

  Future<String> createGame() async {
    String code;
    var tries = 0;
    while (true) {
      code = (10000 + _rnd.nextInt(90000)).toString();
      final snap = await gameRef(code).get();
      if (!snap.exists) break;
      if (++tries > 20) throw Exception('Kein freier Spielcode gefunden');
    }
    await gameRef(code).set({
      'leaderUid': uid,
      'name': 'PingHunt $code',
      'status': 'lobby',
      'createdAt': FieldValue.serverTimestamp(),
      'area': <Map<String, double>>[],
      'teams': {
        'hunters': const Team('hunters', 'Jäger', PH.hunterColor, 'hunter').toMap(),
        't1': Team('t1', 'Team Fuchs', PH.teamColors[0], 'hunted').toMap(),
        't2': Team('t2', 'Team Wolf', PH.teamColors[1], 'hunted').toMap(),
      },
      'intervalMin': 30,
      'headStartMin': 20,
      'liveMin': 10,
      'graceSec': 15,
      'durationH': 24,
      'spectatorDelayMin': 20,
    });
    final pin = (100000 + _rnd.nextInt(900000)).toString();
    await gameRef(code).collection('secret').doc('main').set({'pin': pin});
    return code;
  }

  Future<Game?> getGame(String code) async {
    final snap = await gameRef(code).get();
    if (!snap.exists) return null;
    return Game.fromDoc(snap);
  }

  Future<void> joinAsPlayer(String code, String name, {bool observer = false}) async {
    final ref = _players(code).doc(uid);
    final snap = await ref.get();
    if (snap.exists) {
      await ref.update({
        'name': name,
        'observer': observer,
        'lastSeen': FieldValue.serverTimestamp(),
      });
    } else {
      await ref.set({
        'name': name,
        'status': 'free',
        'observer': observer,
        'lastSeen': FieldValue.serverTimestamp(),
      });
      await addEvent(
          code,
          observer ? '$name ist als Zentrale beigetreten' : '$name ist dem Spiel beigetreten',
          0xFF9AA4B2);
    }
  }

  /// Spielleitung auf einem weiteren Gerät übernehmen (mit Leitungs-PIN).
  Future<bool> claimLeader(String code, String pin) async {
    try {
      await gameRef(code).collection('leaders').doc(uid).set({'pin': pin});
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isLeader(Game g) async {
    if (g.leaderUid == uid) return true;
    try {
      final s = await gameRef(g.code).collection('leaders').doc(uid).get();
      return s.exists;
    } catch (_) {
      return false;
    }
  }

  Stream<String?> pinStream(String code) => gameRef(code)
      .collection('secret')
      .doc('main')
      .snapshots()
      .map((s) => s.data()?['pin'] as String?);

  // ---------- Streams ----------

  Stream<Game?> gameStream(String code) =>
      gameRef(code).snapshots().map((s) => s.exists ? Game.fromDoc(s) : null);

  Stream<List<Player>> playersStream(String code) =>
      _players(code).snapshots().map((q) => q.docs.map(Player.fromDoc).toList());

  Stream<List<Ping>> pingsStream(String code) => _pings(code)
      .orderBy('t')
      .snapshots()
      .map((q) => q.docs.map(Ping.fromDoc).whereType<Ping>().toList());

  /// Live-Positionen: Spielleitung sieht alle, Spieler nur das eigene Team.
  Stream<List<LivePos>> liveStream(String code, {String? teamId}) {
    Query<Map<String, dynamic>> q = _live(code);
    if (teamId != null) q = q.where('teamId', isEqualTo: teamId);
    return q.snapshots().map((s) => s.docs.map(LivePos.fromDoc).whereType<LivePos>().toList());
  }

  // ---------- Nachrichten ----------

  CollectionReference<Map<String, dynamic>> _msgs(String code) =>
      gameRef(code).collection('messages');

  /// Nachrichten eines Kanals (ohne orderBy, damit kein Index nötig ist; sortiert wird in der App).
  Stream<List<ChatMsg>> messagesStream(String code, String channel) => _msgs(code)
      .where('channel', isEqualTo: channel)
      .snapshots()
      .map((q) => q.docs.map(ChatMsg.fromDoc).whereType<ChatMsg>().toList()
        ..sort((a, b) => a.t.compareTo(b.t)));

  Future<void> sendMessage(
    String code, {
    required String channel,
    required String fromName,
    required bool fromLeader,
    required String text,
    String kind = 'text',
    LatLng? pos,
  }) =>
      _msgs(code).add({
        'channel': channel,
        'from': uid,
        'fromName': fromName,
        'fromLeader': fromLeader,
        'text': text,
        'kind': kind,
        if (pos != null) 'lat': pos.latitude,
        if (pos != null) 'lng': pos.longitude,
        't': Timestamp.fromDate(DateTime.now()),
      });

  Stream<List<GameEvent>> eventsStream(String code) => _events(code)
      .orderBy('t', descending: true)
      .limit(200)
      .snapshots()
      .map((q) => q.docs.map(GameEvent.fromDoc).toList());

  // ---------- Schreiben ----------

  Future<void> updateGame(String code, Map<String, dynamic> data) =>
      gameRef(code).update(data);

  Future<void> saveArea(String code, List<LatLng> area) => gameRef(code).update({
        'area': [for (final p in area) {'lat': p.latitude, 'lng': p.longitude}],
      });

  Future<void> setTeam(String code, Team t) =>
      gameRef(code).update({'teams.${t.id}': t.toMap()});

  Future<void> deleteTeam(String code, String teamId, List<Player> members) async {
    final batch = _db.batch();
    batch.update(gameRef(code), {'teams.$teamId': FieldValue.delete()});
    for (final p in members) {
      batch.update(_players(code).doc(p.uid), {'teamId': null});
    }
    await batch.commit();
  }

  Future<void> setPlayerTeam(String code, String playerUid, String? teamId) =>
      _players(code).doc(playerUid).update({'teamId': teamId});

  Future<void> setPlayerStatus(String code, String playerUid, String status) =>
      _players(code).doc(playerUid).update({'status': status});

  Future<void> removePlayer(String code, String playerUid) =>
      _players(code).doc(playerUid).delete();

  Future<void> updateMe(String code, Map<String, dynamic> data) =>
      _players(code).doc(uid).update(data);

  Future<void> writeLive(String code, Map<String, dynamic> data) =>
      _live(code).doc(uid).set(data);

  Future<void> writePing(String code, String id, Map<String, dynamic> data) =>
      _pings(code).doc(id).set(data);

  /// Ereignis mit fester ID – wird nur einmal angelegt (auch bei mehreren Leitungs-Geräten).
  Future<void> addEventOnce(String code, String id, String text, int color) async {
    try {
      await _events(code).doc(id).set({
        'text': text,
        'color': color,
        't': Timestamp.fromDate(DateTime.now()),
      });
    } catch (_) {
      // existiert schon
    }
  }

  /// Ersatz-Ping (Spielleitung) – nur, wenn der Spieler selbst keinen geschickt hat.
  Future<void> writePingIfMissing(String code, String id, Map<String, dynamic> data) async {
    final ref = _pings(code).doc(id);
    final snap = await ref.get();
    if (snap.exists) return;
    await ref.set(data);
  }

  /// Spiel mit allen Daten löschen (nur Spielleitung).
  Future<void> deleteGame(String code) async {
    for (final sub in ['pings', 'trail', 'live', 'messages', 'events', 'effects', 'catches', 'marks', 'players', 'secret']) {
      while (true) {
        final q = await gameRef(code).collection(sub).limit(300).get();
        if (q.docs.isEmpty) break;
        final batch = _db.batch();
        for (final d in q.docs) {
          batch.delete(d.reference);
        }
        await batch.commit();
      }
    }
    final leaders = await gameRef(code).collection('leaders').get();
    for (final d in leaders.docs) {
      if (d.id != uid) await d.reference.delete();
    }
    await gameRef(code).delete();
    try {
      await gameRef(code).collection('leaders').doc(uid).delete();
    } catch (_) {}
  }

  // ---------- Fänge ----------

  Stream<List<CatchReport>> catchesStream(String code) => gameRef(code)
      .collection('catches')
      .snapshots()
      .map((q) => q.docs.map(CatchReport.fromDoc).whereType<CatchReport>().toList()
        ..sort((a, b) => a.t.compareTo(b.t)));

  Future<void> reportCatch(String code, Player hunter, Player target) =>
      gameRef(code).collection('catches').add({
        'by': uid,
        'byName': hunter.name,
        'target': target.uid,
        'targetName': target.name,
        'teamId': target.teamId,
        't': Timestamp.fromDate(DateTime.now()),
        'status': 'pending',
      });

  Future<void> decideCatch(String code, CatchReport c, bool confirmed) async {
    await gameRef(code).collection('catches').doc(c.id).update({
      'status': confirmed ? 'confirmed' : 'rejected',
      'decidedAt': Timestamp.fromDate(DateTime.now()),
    });
    if (confirmed) await setPlayerStatus(code, c.target, 'caught');
  }

  // ---------- Markierungen ----------

  Stream<List<MapMark>> marksStream(String code) => gameRef(code)
      .collection('marks')
      .snapshots()
      .map((q) => q.docs.map(MapMark.fromDoc).whereType<MapMark>().toList());

  Future<void> addMark(String code, Map<String, dynamic> data) =>
      gameRef(code).collection('marks').add({...data, 'by': uid});

  Future<void> deleteMark(String code, String id) => gameRef(code).collection('marks').doc(id).delete();

  // ---------- Joker ----------

  Stream<List<Effect>> effectsStream(String code) => gameRef(code)
      .collection('effects')
      .snapshots()
      .map((q) => q.docs.map(Effect.fromDoc).whereType<Effect>().toList()
        ..sort((a, b) => a.start.compareTo(b.start)));

  Future<void> createEffect(String code, Map<String, dynamic> data) =>
      gameRef(code).collection('effects').add({...data, 'by': uid});

  Future<Player?> getMyPlayer(String code) async {
    final s = await _players(code).doc(uid).get();
    return s.exists ? Player.fromDoc(s) : null;
  }

  Future<void> addEvent(String code, String text, int color) => _events(code).add({
        'text': text,
        'color': color,
        't': Timestamp.fromDate(DateTime.now()),
      });

  // ---------- Spielablauf (Spielleitung) ----------

  Future<void> startGame(Game g) async {
    final now = DateTime.now();
    await updateGame(g.code, {
      'status': 'running',
      'startedAt': Timestamp.fromDate(now),
      'endsAt': Timestamp.fromDate(now.add(Duration(hours: g.durationH))),
      'pingAnchor': Timestamp.fromDate(now.add(Duration(minutes: g.headStartMin))),
    });
    await addEvent(g.code,
        'Spiel gestartet – erster Ping in ${g.headStartMin} min', 0xFFFF6B2C);
  }

  Future<void> endGame(Game g) async {
    await updateGame(g.code, {'status': 'ended'});
    await addEvent(g.code, 'Spiel beendet', 0xFFFF6B2C);
  }

  Future<void> changeInterval(Game g, int minutes) async {
    final data = <String, dynamic>{'intervalMin': minutes};
    if (g.isRunning) {
      // Nächster Ping kommt nach dem neuen Intervall.
      data['pingAnchor'] =
          Timestamp.fromDate(DateTime.now().add(Duration(minutes: minutes)));
    }
    await updateGame(g.code, data);
    if (g.isRunning) {
      await addEvent(g.code, 'Ping-Intervall jetzt $minutes min', 0xFFFF6B2C);
    }
  }

  Future<void> requestPing(Game g) async {
    await updateGame(g.code, {'pingRequestAt': Timestamp.fromDate(DateTime.now())});
    await addEvent(g.code, 'Spielleitung hat einen Ping ausgelöst', 0xFFFF6B2C);
  }
}

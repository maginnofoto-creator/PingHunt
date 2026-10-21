import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'dart:math' as math;

import 'geo.dart';
import 'jokers.dart';
import 'models.dart';
import 'notify.dart';
import 'repo.dart';
import 'theme.dart';

/// Läuft auf dem Handy eines Spielers: GPS, Pings, Zonen-Regel.
///
/// Aktiv (im Hintergrunddienst): sendet Pings, Positionen und Ereignisse.
/// Passiv (in der App-Ansicht): berechnet nur Anzeige-Werte, schreibt nichts.
class PlayerEngine extends ChangeNotifier {
  PlayerEngine(this.code, {this.passive = false});

  final String code;
  final bool passive;
  final _repo = Repo.i;

  StreamSubscription<Position>? _posSub;
  Timer? _tick;

  Game? game;
  Player? me;

  Position? position;
  bool? inside;
  double? distToEdge;

  /// Sperrgebiet, in dem der Spieler gerade steht (oder null).
  Zone? inBlocked;

  /// Abstand zum nächsten Sperrgebiet in Metern (wenn eines existiert).
  double? distToBlocked;
  String? _hunterWarnedZone;
  DateTime? liveUntil;
  String? error;
  bool tracking = false;

  DateTime? _lastSlotSent;
  DateTime? _lastManualHandled;
  bool _initialisedSlots = false;
  DateTime? _outsideSince;
  bool _exitTriggered = false;
  bool _edgeWarned = false;
  DateTime? _lastLiveWrite;
  LatLng? _lastLivePos;
  DateTime? _lastExposedWrite;
  DateTime? _lastTrail;
  DateTime? _lastBattery;
  int? _battery;
  bool _pinging = false;
  bool _offlineChecked = false;

  // ---------- Joker ----------
  List<Effect> effects = [];
  List<LivePos> others = [];
  final List<(DateTime, LatLng)> _hist = [];
  final Map<String, LatLng> _anchors = {};
  final Set<String> _done = {};
  final _rnd = math.Random();
  DateTime? _lastProximity;
  DateTime? _fastSince;
  bool _speedLive = false;
  DateTime? _lastSpeedWrite;
  DateTime? _lastTurbo;

  void setEffects(List<Effect> list) {
    effects = list;
    notifyListeners();
  }

  void setOthers(List<LivePos> list) => others = list;

  String? get _teamId => me?.teamId;

  Effect? _active(String type) {
    final l = activeFor(effects, type, _repo.uid, _teamId, DateTime.now());
    return l.isEmpty ? null : l.last;
  }

  /// Pause-Joker aktiv (und Radius nicht verlassen)?
  bool get isPaused {
    final e = _active('pause');
    return e != null && !_done.contains('pausebroken_${e.id}');
  }

  bool get _freepass => _active('freepass') != null;

  LatLng? _histAt(DateTime t) {
    LatLng? best;
    for (final (time, pos) in _hist) {
      if (time.isAfter(t)) break;
      best = pos;
    }
    return best ?? (_hist.isEmpty ? null : _hist.first.$2);
  }

  /// Kurzer Hinweis per Vibration (+ Benachrichtigung im Hintergrunddienst).
  void _buzz(String title, String body) {
    if (passive) return;
    Notify.message(title, body, important: true);
  }

  LatLng? get latLng =>
      position == null ? null : LatLng(position!.latitude, position!.longitude);

  Team? get myTeam => game?.team(me?.teamId);
  bool get isHunted => myTeam != null && !myTeam!.isHunter;
  bool get isHunter => myTeam?.isHunter ?? false;

  Future<void> start() async {
    if (kIsWeb) {
      error = 'Als Spieler bitte die Android-App verwenden.';
      notifyListeners();
      return;
    }
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        error = 'Standort ist ausgeschaltet. Bitte GPS einschalten.';
        notifyListeners();
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied && passive) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        error = 'Ohne Standort-Erlaubnis kann PingHunt nicht funktionieren. '
            'Bitte in den Einstellungen erlauben.';
        notifyListeners();
        return;
      }
      // Der Hintergrunddienst ist selbst ein Vordergrund-Dienst mit Benachrichtigung.
      final settings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
        intervalDuration: const Duration(seconds: 10),
      );
      _posSub = Geolocator.getPositionStream(locationSettings: settings).listen(
        _onPosition,
        onError: (Object e) {
          error = 'GPS-Fehler: $e';
          notifyListeners();
        },
      );
      tracking = true;
      error = null;
    } catch (e) {
      error = 'Standort konnte nicht gestartet werden: $e';
    }
    _tick = Timer.periodic(const Duration(seconds: 5), (_) => _onTick());
    notifyListeners();
  }

  void update(Game? g, Player? p) {
    game = g;
    me = p;
    if (p?.liveUntil != null) liveUntil = p!.liveUntil;
    if (g != null && !_initialisedSlots && g.isRunning) {
      final now = DateTime.now();
      final slot = g.currentSlot(now);
      // Einen Ping, der vor mehr als 2 Minuten fällig war, nicht nachholen.
      if (slot != null && now.difference(slot).inMinutes >= 2) _lastSlotSent = slot;
      _lastManualHandled = g.pingRequestAt;
      _initialisedSlots = true;
    }
    if (g != null && g.isLobby) _initialisedSlots = false;
    _checkOfflinePenalty();
    notifyListeners();
  }

  /// Wer lange offline war, ist beim Wiedereinstieg kurz live sichtbar.
  Future<void> _checkOfflinePenalty() async {
    final g = game, p = me;
    if (passive || _offlineChecked || g == null || p == null) return;
    _offlineChecked = true;
    if (!_activeHunted || g.offlinePenaltyMin <= 0) return;
    final seen = p.lastSeen;
    final now = DateTime.now();
    if (seen == null || now.difference(seen).inMinutes < 5) return;
    final until = now.add(Duration(minutes: g.offlinePenaltyMin));
    if (liveUntil != null && liveUntil!.isAfter(until)) return;
    liveUntil = until;
    await _safe(() => _repo.updateMe(code, {'liveUntil': Timestamp.fromDate(until)}));
    await _safe(() => _repo.addEvent(
        code,
        '${p.name} war ${now.difference(seen).inMinutes} min offline – ${g.offlinePenaltyMin} min live sichtbar',
        myTeam?.color ?? 0xFFFF4D4D));
    _buzz('Du warst offline', 'Du bist jetzt ${g.offlinePenaltyMin} Minuten live für die Jäger sichtbar.');
  }

  bool get _activeHunted =>
      game != null &&
      game!.isRunning &&
      isHunted &&
      me != null &&
      !me!.isCaught &&
      !me!.observer;

  Future<void> _onPosition(Position pos) async {
    position = pos;
    final now = DateTime.now();
    final here = LatLng(pos.latitude, pos.longitude);
    final g = game;

    // Spielfeld und Sperrgebiete
    if (g != null && g.area.length >= 3) {
      inside = pointInPolygon(here, g.area);
      distToEdge = distanceToEdge(here, g.area);
    } else {
      inside = null;
      distToEdge = null;
    }
    inBlocked = null;
    distToBlocked = null;
    if (g != null) {
      for (final z in g.blockedZones) {
        if (pointInPolygon(here, z.points)) {
          inBlocked = z;
        } else {
          final d = distanceToEdge(here, z.points);
          if (distToBlocked == null || d < distToBlocked!) distToBlocked = d;
        }
      }
    }

    if (passive) {
      notifyListeners();
      return;
    }

    // Geschwindigkeit (für die Fahrzeug-Regel)
    double kmh = pos.speed > 0 ? pos.speed * 3.6 : 0;
    if (_hist.isNotEmpty) {
      final (t0, p0) = _hist.last;
      final dt = now.difference(t0).inMilliseconds / 1000;
      if (dt >= 5 && dt <= 120) {
        final derived = metersBetween(p0, here) / dt * 3.6;
        if (pos.speed <= 0) kmh = derived;
      }
    }
    _hist.add((now, here));
    while (_hist.isNotEmpty && now.difference(_hist.first.$1).inMinutes > 45) {
      _hist.removeAt(0);
    }
    if (g != null && _activeHunted) await _jokerPosition(g, here, now);
    if (g != null && _activeHunted && !isPaused) await _speedCheck(g, here, now, kmh);

    if (g != null && _activeHunted && !isPaused && !_freepass) {
      final violating = inside == false || inBlocked != null;
      if (violating) {
        _outsideSince ??= now;
        if (!_exitTriggered && now.difference(_outsideSince!).inSeconds >= g.graceSec) {
          _exitTriggered = true;
          liveUntil = now.add(Duration(minutes: g.liveMin));
          _buzz('Du bist LIVE sichtbar',
              'Die Jäger sehen dich jetzt ${g.liveMin} Minuten lang live.');
          await _safe(() => _repo.updateMe(code, {
                'liveUntil': Timestamp.fromDate(liveUntil!),
                'exposed': {'lat': here.latitude, 'lng': here.longitude, 't': Timestamp.fromDate(now)},
              }));
          _lastExposedWrite = now;
          final what = inBlocked != null
              ? 'hat das Sperrgebiet „${inBlocked!.name}“ betreten'
              : 'hat das Spielfeld verlassen';
          await _safe(() => _repo.addEvent(
              code,
              '${me?.name ?? 'Spieler'} (${myTeam?.name ?? ''}) $what – ${g.liveMin} min live sichtbar',
              myTeam?.color ?? 0xFFFF4D4D));
        }
      } else {
        _outsideSince = null;
        _exitTriggered = false;
        final d = [distToEdge ?? double.infinity, distToBlocked ?? double.infinity]
            .reduce((a, b) => a < b ? a : b);
        if (d < 50 && !_edgeWarned) {
          _edgeWarned = true;
          _buzz('Achtung: Grenze in ${d.round()} m',
              inBlocked == null && (distToBlocked ?? double.infinity) < 50
                  ? 'Gleich beginnt ein Sperrgebiet.'
                  : 'Gleich verlässt du das Spielfeld.');
        } else if (d > 80) {
          _edgeWarned = false;
        }
      }
    }

    // Jäger: Sperrgebiet nur Warnung + Meldung an die Spielleitung
    if (g != null && g.isRunning && isHunter && !(me?.observer ?? false)) {
      final z = inBlocked;
      if (z != null && _hunterWarnedZone != z.id) {
        _hunterWarnedZone = z.id;
        _buzz('Sperrgebiet', 'Du bist im Sperrgebiet „${z.name}“.');
        await _safe(() => _repo.addEvent(
            code, '${me?.name ?? 'Jäger'} (Jäger) ist im Sperrgebiet „${z.name}“', PH.hunterColor));
      } else if (z == null) {
        _hunterWarnedZone = null;
        final d = distToBlocked ?? double.infinity;
        if (d < 50 && !_edgeWarned) {
          _edgeWarned = true;
          _buzz('Achtung', 'Sperrgebiet in ${d.round()} m.');
        } else if (d > 80) {
          _edgeWarned = false;
        }
      }
    }

    // Live-Sichtbarkeit nach Verlassen der Zone
    if (_activeHunted && !isPaused && liveUntil != null && now.isBefore(liveUntil!)) {
      if (_lastExposedWrite == null || now.difference(_lastExposedWrite!).inSeconds >= 10) {
        _lastExposedWrite = now;
        await _safe(() => _repo.updateMe(code, {
              'exposed': {'lat': here.latitude, 'lng': here.longitude, 't': Timestamp.fromDate(now)},
            }));
      }
    }

    // Position für das eigene Team und die Spielleitung
    final moved = _lastLivePos == null
        ? double.infinity
        : const Distance().as(LengthUnit.Meter, _lastLivePos!, here);
    if (_lastLiveWrite == null ||
        now.difference(_lastLiveWrite!).inSeconds >= 60 ||
        (moved > 40 && now.difference(_lastLiveWrite!).inSeconds >= 20)) {
      _lastLiveWrite = now;
      _lastLivePos = here;
      await _safe(() => _repo.writeLive(code, {
            'name': me?.name ?? '',
            'teamId': me?.teamId,
            'lat': here.latitude,
            'lng': here.longitude,
            'acc': pos.accuracy,
            't': Timestamp.fromDate(now),
          }));
    }
    // Spur für Zuschauer (nur wenn die Spielleitung sie für diese Rolle freigibt)
    final showToSpectators =
        g != null && (isHunter ? g.spec.hunters != 'off' : (isHunted && g.spec.hunted != 'off'));
    if (g != null &&
        g.isRunning &&
        showToSpectators &&
        !isPaused &&
        !(me?.observer ?? false) &&
        !(me?.isCaught ?? false) &&
        (_lastTrail == null ||
            now.difference(_lastTrail!).inSeconds >= 60 ||
            (moved > 40 && now.difference(_lastTrail!).inSeconds >= 20))) {
      _lastTrail = now;
      await _safe(() => _repo.writeTrail(code, {
            'uid': _repo.uid,
            'name': me?.name ?? '',
            'teamId': me?.teamId,
            'lat': here.latitude,
            'lng': here.longitude,
            't': Timestamp.fromDate(now),
          }));
    }
    notifyListeners();
  }

  Future<void> _onTick() async {
    if (passive) {
      notifyListeners();
      return;
    }
    final g = game;
    final now = DateTime.now();

    // Lebenszeichen alle 2 Minuten (für die Offline-Erkennung der Spielleitung)
    if (_lastBattery == null || now.difference(_lastBattery!).inMinutes >= 2) {
      _lastBattery = now;
      try {
        _battery = await Battery().batteryLevel;
      } catch (_) {}
      await _safe(() => _repo.updateMe(code, {
            'lastSeen': FieldValue.serverTimestamp(),
            if (_battery != null) 'battery': _battery,
          }));
    }

    if (g == null || !_activeHunted || _pinging) {
      notifyListeners();
      return;
    }

    await _jokerTick(g, now);

    final slot = g.currentSlot(now);
    if (slot != null && (_lastSlotSent == null || slot.isAfter(_lastSlotSent!))) {
      _lastSlotSent = slot;
      final id = '${_repo.uid}_${slot.millisecondsSinceEpoch}';
      Effect? forSlot(String type) {
        for (final e in effects) {
          if (e.type == type && e.slot != null && e.slot!.isAtSameMomentAs(slot) && e.targets(_repo.uid, _teamId)) {
            return e;
          }
        }
        return null;
      }

      if (isPaused || forSlot('skip') != null) {
        // Platzhalter, damit die Spielleitung keinen Ersatz-Ping schickt
        await _safe(() => _repo.writePing(code, id, {
              'uid': _repo.uid,
              'name': me?.name ?? '',
              'teamId': _teamId,
              't': Timestamp.fromDate(slot),
              'skipped': true,
            }));
      } else {
        final fake = forSlot('fake');
        final shift = forSlot('timeshift');
        await _sendPing(id, slot, false,
            fakeMeters: fake?.p1, shiftMinutes: shift?.p1);
      }
    }

    final req = g.pingRequestAt;
    if (req != null &&
        (_lastManualHandled == null || req.isAfter(_lastManualHandled!))) {
      _lastManualHandled = req;
      if (now.difference(req).inMinutes < 2 && !isPaused) {
        await _sendPing('${_repo.uid}_m${req.millisecondsSinceEpoch}', now, true);
      }
    }
    notifyListeners();
  }

  Future<void> _sendPing(String id, DateTime t, bool manual, {int? fakeMeters, int? shiftMinutes}) async {
    _pinging = true;
    try {
      if (shiftMinutes != null) {
        final old = _histAt(DateTime.now().subtract(Duration(minutes: shiftMinutes)));
        if (old != null) {
          await _safe(() => _repo.writePing(code, id, {
                'uid': _repo.uid,
                'name': me?.name ?? '',
                'teamId': me?.teamId,
                'lat': old.latitude,
                'lng': old.longitude,
                't': Timestamp.fromDate(t),
                'manual': manual,
              }));
          return;
        }
      }
      Position? p = position;
      if (p == null || DateTime.now().difference(p.timestamp).inSeconds > 30) {
        try {
          p = await Geolocator.getCurrentPosition(
            locationSettings: AndroidSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: const Duration(seconds: 20),
            ),
          );
        } catch (_) {
          // Letzte bekannte Position verwenden
        }
      }
      if (p == null) return;
      var fix = LatLng(p.latitude, p.longitude);
      if (fakeMeters != null) fix = offsetRandom(fix, fakeMeters.toDouble(), _rnd);
      final pos = fix;
      await _safe(() => _repo.writePing(code, id, {
            'uid': _repo.uid,
            'name': me?.name ?? '',
            'teamId': me?.teamId,
            'lat': pos.latitude,
            'lng': pos.longitude,
            't': Timestamp.fromDate(t),
            'manual': manual,
            if (fakeMeters != null) 'fake': true,
          }));
    } finally {
      _pinging = false;
    }
  }

  /// Joker, die von der eigenen Position abhängen (Pause-Radius, Freeze, Annäherungsalarm).
  Future<void> _jokerPosition(Game g, LatLng here, DateTime now) async {
    // Pause
    final pause = _active('pause');
    if (pause != null && !_done.contains('pausebroken_${pause.id}')) {
      final anchor = _anchors.putIfAbsent('pause_${pause.id}', () => here);
      final radius = math.max(pause.p2, 25); // 25 m GPS-Toleranz
      if (_done.add('pausestart_${pause.id}')) {
        await _safe(() => _repo.updateMe(code, {'pausedUntil': Timestamp.fromDate(pause.end)}));
        _buzz('⏸ Pause bis ${_hhmm(pause.end)}', 'Bleib im Umkreis von ${pause.p2} m, sonst endet deine Pause.');
      } else if (metersBetween(anchor, here) > radius) {
        _done.add('pausebroken_${pause.id}');
        await _safe(() => _repo.updateMe(code, {'pausedUntil': null}));
        await _safe(() => _repo.addEvent(
            code, '${me?.name ?? 'Spieler'} hat den Pausen-Radius verlassen – Pause beendet', myTeam?.color ?? 0xFF9AA4B2));
        _buzz('Pause beendet', 'Du hast den Radius von ${pause.p2} m verlassen.');
      }
    }
    // Freeze
    final freeze = _active('freeze');
    if (freeze != null && !isPaused && !_done.contains('freezebroken_${freeze.id}')) {
      final anchor = _anchors.putIfAbsent('freeze_${freeze.id}', () => here);
      if (_done.add('freezestart_${freeze.id}')) {
        _buzz('❄ FREEZE!', 'Nicht bewegen bis ${_hhmm(freeze.end)} – sonst bist du live sichtbar.');
      } else if (metersBetween(anchor, here) > 30) {
        _done.add('freezebroken_${freeze.id}');
        final until = now.add(Duration(minutes: g.liveMin));
        liveUntil = until;
        await _safe(() => _repo.updateMe(code, {
              'liveUntil': Timestamp.fromDate(until),
              'exposed': {'lat': here.latitude, 'lng': here.longitude, 't': Timestamp.fromDate(now)},
            }));
        await _safe(() => _repo.addEvent(code,
            '${me?.name ?? 'Spieler'} hat sich beim Freeze bewegt – ${g.liveMin} min live sichtbar', myTeam?.color ?? 0xFFFF4D4D));
        _buzz('Bewegt beim Freeze!', 'Du bist jetzt ${g.liveMin} Minuten live sichtbar.');
      }
    }

    // Annäherungsalarm
    final prox = _active('proximity');
    if (prox != null && (_lastProximity == null || now.difference(_lastProximity!).inMinutes >= 2)) {
      double? nearest;
      for (final o in others) {
        final t = g.team(o.teamId);
        if (t == null || !t.isHunter) continue;
        if (o.t != null && now.difference(o.t!).inMinutes > 5) continue;
        final d = metersBetween(here, o.pos);
        if (nearest == null || d < nearest) nearest = d;
      }
      if (nearest != null && nearest < prox.p2) {
        _lastProximity = now;
        _buzz('⚠ Jäger in der Nähe!', 'Ein Jäger ist ca. ${nearest.round()} m entfernt.');
      }
    }
  }

  /// Fahrzeug-Regel: mehr als X km/h für 30 Sekunden → live sichtbar (plus Nachlaufzeit).
  Future<void> _speedCheck(Game g, LatLng here, DateTime now, double kmh) async {
    final rule = g.speedRule;
    if (!rule.enabled) return;
    if (kmh <= rule.kmh) {
      _fastSince = null;
      _speedLive = false;
      return;
    }
    _fastSince ??= now;
    if (now.difference(_fastSince!).inSeconds < 30) return;
    final until = now.add(Duration(minutes: rule.afterMin));
    if (!_speedLive) {
      _speedLive = true;
      await _safe(() => _repo.addEvent(
          code,
          '${me?.name ?? 'Spieler'} (${myTeam?.name ?? ''}) ist schnell unterwegs (ca. ${kmh.round()} km/h) – live sichtbar',
          myTeam?.color ?? 0xFFFF4D4D));
      _buzz('🚗 Zu schnell!', 'Über ${rule.kmh} km/h – du bist jetzt live sichtbar.');
    }
    if (_lastSpeedWrite == null || now.difference(_lastSpeedWrite!).inSeconds >= 30) {
      _lastSpeedWrite = now;
      if (liveUntil == null || liveUntil!.isBefore(until)) {
        liveUntil = until;
        await _safe(() => _repo.updateMe(code, {
              'liveUntil': Timestamp.fromDate(until),
              'exposed': {'lat': here.latitude, 'lng': here.longitude, 't': Timestamp.fromDate(now)},
            }));
      }
    }
  }

  /// Joker, die zeitgesteuert wirken (Live-Ortung, Speedhunt, Turbo).
  Future<void> _jokerTick(Game g, DateTime now) async {
    final paused = isPaused;
    // Live-Ortung durch Jäger
    final live = _active('live');
    if (live != null && !paused && _done.add('live_${live.id}')) {
      if (liveUntil == null || liveUntil!.isBefore(live.end)) {
        liveUntil = live.end;
        final here = latLng;
        await _safe(() => _repo.updateMe(code, {
              'liveUntil': Timestamp.fromDate(live.end),
              if (here != null)
                'exposed': {'lat': here.latitude, 'lng': here.longitude, 't': Timestamp.fromDate(now)},
            }));
      }
      _buzz('🔴 Du bist LIVE!', 'Die Jäger orten dich bis ${_hhmm(live.end)} (Joker „Live-Ortung“).');
    }
    // Speedhunt
    for (final e in effects) {
      if (e.type != 'speedhunt' || !e.isActive(now) || !e.targets(_repo.uid, _teamId)) continue;
      if (!_done.add('speed_${e.id}')) continue;
      if (paused) continue;
      _buzz('⚡ Speedhunt!', 'Die Jäger haben dich gerade geortet.');
      await _sendPing('${_repo.uid}_s${e.id}', now, true);
    }
    // Turbo-Intervall: zusätzliche Pings alle 10 Minuten
    final turbo = _active('turbo');
    if (turbo != null && !paused) {
      final k = now.difference(turbo.start).inMinutes ~/ 10;
      if (k >= 1) {
        final slotT = turbo.start.add(Duration(minutes: 10 * k));
        if (_lastTurbo == null || slotT.isAfter(_lastTurbo!)) {
          _lastTurbo = slotT;
          await _sendPing('${_repo.uid}_t${slotT.millisecondsSinceEpoch}', slotT, false);
        }
      }
    }
  }

  String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _safe(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      debugPrint('PingHunt write failed: $e');
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _tick?.cancel();
    super.dispose();
  }
}

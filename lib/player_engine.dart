import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'geo.dart';
import 'models.dart';
import 'repo.dart';

/// Läuft auf dem Handy eines Spielers: GPS, Pings, Zonen-Regel.
class PlayerEngine extends ChangeNotifier {
  PlayerEngine(this.code);

  final String code;
  final _repo = Repo.i;

  StreamSubscription<Position>? _posSub;
  Timer? _tick;

  Game? game;
  Player? me;

  Position? position;
  bool? inside;
  double? distToEdge;
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
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        error = 'Ohne Standort-Erlaubnis kann PingHunt nicht funktionieren. '
            'Bitte in den Einstellungen erlauben.';
        notifyListeners();
        return;
      }
      final settings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
        intervalDuration: const Duration(seconds: 10),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'PingHunt läuft',
          notificationText: 'Dein Standort wird für das laufende Spiel verwendet.',
          enableWakeLock: true,
        ),
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
    notifyListeners();
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

    // Zonen-Regel
    if (g != null && g.area.length >= 3) {
      inside = pointInPolygon(here, g.area);
      distToEdge = distanceToEdge(here, g.area);
      if (_activeHunted) {
        if (inside == false) {
          _outsideSince ??= now;
          if (!_exitTriggered &&
              now.difference(_outsideSince!).inSeconds >= g.graceSec) {
            _exitTriggered = true;
            liveUntil = now.add(Duration(minutes: g.liveMin));
            HapticFeedback.vibrate();
            await _safe(() => _repo.updateMe(code, {
                  'liveUntil': Timestamp.fromDate(liveUntil!),
                  'exposed': {'lat': here.latitude, 'lng': here.longitude, 't': Timestamp.fromDate(now)},
                }));
            _lastExposedWrite = now;
            await _safe(() => _repo.addEvent(
                code,
                '${me?.name ?? 'Spieler'} (${myTeam?.name ?? ''}) hat die Zone verlassen – ${g.liveMin} min live sichtbar',
                myTeam?.color ?? 0xFFFF4D4D));
          }
        } else {
          _outsideSince = null;
          _exitTriggered = false;
          final d = distToEdge ?? double.infinity;
          if (d < 50 && !_edgeWarned) {
            _edgeWarned = true;
            HapticFeedback.heavyImpact();
          } else if (d > 80) {
            _edgeWarned = false;
          }
        }
      }
    } else {
      inside = null;
      distToEdge = null;
    }

    // Live-Sichtbarkeit nach Verlassen der Zone
    if (_activeHunted && liveUntil != null && now.isBefore(liveUntil!)) {
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
    // Jäger-Spur für Zuschauer (einmal pro Minute)
    if (g != null &&
        g.isRunning &&
        isHunter &&
        !(me?.observer ?? false) &&
        (_lastTrail == null || now.difference(_lastTrail!).inSeconds >= 60)) {
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
    final g = game;
    final now = DateTime.now();

    if (_lastBattery == null || now.difference(_lastBattery!).inMinutes >= 5) {
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

    final slot = g.currentSlot(now);
    if (slot != null && (_lastSlotSent == null || slot.isAfter(_lastSlotSent!))) {
      _lastSlotSent = slot;
      await _sendPing('${_repo.uid}_${slot.millisecondsSinceEpoch}', slot, false);
    }

    final req = g.pingRequestAt;
    if (req != null &&
        (_lastManualHandled == null || req.isAfter(_lastManualHandled!))) {
      _lastManualHandled = req;
      if (now.difference(req).inMinutes < 2) {
        await _sendPing('${_repo.uid}_m${req.millisecondsSinceEpoch}', now, true);
      }
    }
    notifyListeners();
  }

  Future<void> _sendPing(String id, DateTime t, bool manual) async {
    _pinging = true;
    try {
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
      final fix = p;
      await _safe(() => _repo.writePing(code, id, {
            'uid': _repo.uid,
            'name': me?.name ?? '',
            'teamId': me?.teamId,
            'lat': fix.latitude,
            'lng': fix.longitude,
            't': Timestamp.fromDate(t),
            'manual': manual,
          }));
    } finally {
      _pinging = false;
    }
  }

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

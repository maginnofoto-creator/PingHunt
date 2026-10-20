import 'dart:async';
import 'dart:ui';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat.dart';
import 'config.dart';
import 'models.dart';
import 'notify.dart';
import 'player_engine.dart';
import 'repo.dart';
import 'theme.dart';

/// Hintergrunddienst: hält Ortung, Pings und Chat-Benachrichtigungen am Laufen,
/// auch wenn die App aus der Übersicht weggewischt wird.
class Tracker {
  Tracker._();

  static const _key = 'activeGame';

  static Future<void> configure() async {
    if (kIsWeb) return;
    try {
      await FlutterBackgroundService().configure(
        androidConfiguration: AndroidConfiguration(
          onStart: trackerMain,
          autoStart: false,
          autoStartOnBoot: false,
          isForegroundMode: true,
          initialNotificationTitle: 'PingHunt läuft',
          initialNotificationContent: 'Dein Spiel läuft im Hintergrund weiter.',
          foregroundServiceNotificationId: 888,
          foregroundServiceTypes: [AndroidForegroundType.location],
        ),
        iosConfiguration: IosConfiguration(autoStart: false, onForeground: trackerMain),
      );
    } catch (e) {
      debugPrint('Hintergrunddienst nicht verfügbar: $e');
    }
  }

  /// Spiel, in dem dieser Spieler zuletzt aktiv war (für den automatischen Wiedereinstieg).
  static Future<String?> activeGame() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getString(_key);
    } catch (_) {
      return null;
    }
  }

  static Future<void> start(String code) async {
    if (kIsWeb) return;
    try {
      final p = await SharedPreferences.getInstance();
      final running = await FlutterBackgroundService().isRunning();
      final old = p.getString(_key);
      await p.setString(_key, code);
      if (running && old == code) return;
      if (running) {
        FlutterBackgroundService().invoke('stop');
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      await FlutterBackgroundService().startService();
    } catch (e) {
      debugPrint('Hintergrunddienst konnte nicht starten: $e');
    }
  }

  static Future<void> stop() async {
    if (kIsWeb) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_key);
      FlutterBackgroundService().invoke('stop');
    } catch (_) {}
  }

  /// Dem Dienst mitteilen, welcher Chat gerade offen ist (dafür keine Benachrichtigung).
  static void chatOpen(String? channel) {
    if (kIsWeb) return;
    try {
      FlutterBackgroundService().invoke('chatOpen', {'channel': channel});
    } catch (_) {}
  }
}

final Set<String> _liveNotified = {};

/// Jäger: Benachrichtigung, sobald ein Gejagter live sichtbar wird.
void _notifyLive(Game? g, Player me, List<Player> all) {
  if (g == null || !g.isRunning || me.observer) return;
  if (!(g.team(me.teamId)?.isHunter ?? false)) return;
  final now = DateTime.now();
  for (final p in all) {
    final t = g.team(p.teamId);
    if (t == null || t.isHunter || p.observer || !p.isLive(now)) continue;
    final key = '${p.uid}_${p.liveUntil!.millisecondsSinceEpoch}';
    if (!_liveNotified.add(key)) continue;
    final mins = (p.liveUntil!.difference(now).inSeconds / 60).ceil();
    Notify.message('🔴 ${p.name} ist LIVE!', '${p.name} (${t.name}) ist $mins Minuten live sichtbar.',
        important: true);
  }
}

@pragma('vm:entry-point')
Future<void> trackerMain(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final subs = <StreamSubscription>[];
  PlayerEngine? engine;
  ChatWatcher? chat;
  Timer? status;

  Future<void> shutdown() async {
    for (final s in subs) {
      await s.cancel();
    }
    status?.cancel();
    engine?.dispose();
    chat?.dispose();
    await service.stopSelf();
  }

  service.on('stop').listen((_) => shutdown());
  service.on('chatOpen').listen((d) => chat?.openChannel = d?['channel'] as String?);

  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final code = prefs.getString(Tracker._key);
    if (code == null) {
      await shutdown();
      return;
    }

    await Firebase.initializeApp(options: AppConfig.firebaseOptions);
    final user = FirebaseAuth.instance.currentUser ??
        await FirebaseAuth.instance
            .authStateChanges()
            .firstWhere((u) => u != null)
            .timeout(const Duration(seconds: 20));
    if (user == null) {
      await shutdown();
      return;
    }

    await Notify.init(askPermission: false);
    final repo = Repo.i;
    final eng = PlayerEngine(code);
    engine = eng;
    final watcher = ChatWatcher(code);
    chat = watcher;

    Game? game;
    Player? me;
    String chatKey = '';

    void refreshChat() {
      final team = game?.team(me?.teamId);
      final key = '${team?.id}|${team?.name}';
      if (key == chatKey) return;
      chatKey = key;
      watcher.watch({
        'all': 'Durchsage',
        'dm:${repo.uid}': 'Spielleitung',
        if (team != null) 'team:${team.id}': team.name,
      });
    }

    subs.add(repo.gameStream(code).listen((g) async {
      game = g;
      if (g == null || g.isEnded) {
        await prefs.remove(Tracker._key);
        await shutdown();
        return;
      }
      eng.update(g, me);
      refreshChat();
    }));
    subs.add(repo.playersStream(code).listen((ps) async {
      Player? mine;
      for (final p in ps) {
        if (p.uid == repo.uid) mine = p;
      }
      if (mine == null) {
        // Aus dem Spiel entfernt
        await prefs.remove(Tracker._key);
        await shutdown();
        return;
      }
      me = mine;
      eng.update(game, mine);
      refreshChat();
      _notifyLive(game, mine, ps);
    }));

    // Jäger: Benachrichtigung bei neuen Pings (gebündelt)
    final startedAt = DateTime.now();
    final seenPings = <String>{};
    final pendingPings = <String>{};
    Timer? pingDebounce;
    subs.add(repo.pingsStream(code).listen((pings) {
      final g = game, m = me;
      final hunter = g != null && m != null && !m.observer && (g.team(m.teamId)?.isHunter ?? false);
      for (final p in pings) {
        if (!seenPings.add(p.id)) continue;
        if (!hunter || p.t.isBefore(startedAt.subtract(const Duration(minutes: 1)))) continue;
        pendingPings.add(p.uid);
      }
      if (pendingPings.isEmpty) return;
      pingDebounce?.cancel();
      pingDebounce = Timer(const Duration(seconds: 15), () {
        final n = pendingPings.length;
        pendingPings.clear();
        Notify.message('📍 Neue Pings', n == 1 ? '1 Gejagter wurde geortet.' : '$n Gejagte wurden geortet.',
            important: true);
      });
    }, onError: (_) {}));

    await eng.start();

    // Benachrichtigung des Dienstes aktuell halten
    status = Timer.periodic(const Duration(seconds: 30), (_) {
      if (service is! AndroidServiceInstance) return;
      final g = game;
      final now = DateTime.now();
      String text;
      if (g == null || g.isLobby) {
        text = 'Warte auf den Spielstart …';
      } else {
        final next = g.nextPing(now);
        final team = g.team(me?.teamId);
        final live = me?.isLive(now) ?? false;
        text = [
          if (team != null) team.name,
          if (live) 'LIVE sichtbar',
          if (next != null) 'nächster Ping ${hhmm(next)}',
        ].join(' · ');
      }
      service.setForegroundNotificationInfo(title: 'PingHunt läuft', content: text);
    });
  } catch (e) {
    debugPrint('PingHunt-Dienst: $e');
    await shutdown();
  }
}

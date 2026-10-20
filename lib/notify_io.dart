import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Benachrichtigungen für neue Nachrichten (nur Android; im Browser nichts).
class Notify {
  Notify._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static int _id = 100;

  static Future<void> init({bool askPermission = true}) async {
    if (kIsWeb || _ready) return;
    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      _ready = true;
    } catch (e) {
      debugPrint('Benachrichtigungen nicht verfügbar: $e');
      return;
    }
    if (!askPermission) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('Benachrichtigungs-Erlaubnis: $e');
    }
  }

  static Future<void> message(String title, String body, {bool important = false}) async {
    try {
      await HapticFeedback.vibrate();
    } catch (_) {}
    if (kIsWeb || !_ready) return;
    try {
      await _plugin.show(
        _id++,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            important ? 'pinghunt_important' : 'pinghunt_chat',
            important ? 'Durchsagen & Spielleitung' : 'Team-Chat',
            channelDescription: 'Nachrichten im laufenden PingHunt-Spiel',
            importance: important ? Importance.high : Importance.defaultImportance,
            priority: important ? Priority.high : Priority.defaultPriority,
            playSound: false,
            enableVibration: true,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Benachrichtigung fehlgeschlagen: $e');
    }
  }
}

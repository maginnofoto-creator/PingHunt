import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

/// Prüft die Android-Einstellungen, die PingHunt im Hintergrund braucht.
class SetupStatus {
  final bool locationAlways;
  final bool precise;
  final bool batteryOk;
  final bool notifications;

  const SetupStatus({
    this.locationAlways = true,
    this.precise = true,
    this.batteryOk = true,
    this.notifications = true,
  });

  bool get ok => locationAlways && precise && batteryOk;
  int get missing => [locationAlways, precise, batteryOk].where((v) => !v).length;
}

class SetupCheck {
  static Future<SetupStatus> check() async {
    if (kIsWeb) return const SetupStatus();
    try {
      final loc = await Geolocator.checkPermission();
      var precise = true;
      try {
        precise = await Geolocator.getLocationAccuracy() == LocationAccuracyStatus.precise;
      } catch (_) {}
      final bat = await Permission.ignoreBatteryOptimizations.status;
      final notif = await Permission.notification.status;
      return SetupStatus(
        locationAlways: loc == LocationPermission.always,
        precise: precise,
        batteryOk: bat.isGranted,
        notifications: notif.isGranted,
      );
    } catch (_) {
      return const SetupStatus();
    }
  }

  /// Standort „Immer zulassen“ anfordern (öffnet ggf. die Einstellungen).
  static Future<void> fixLocation() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.whileInUse) {
        final r = await Permission.locationAlways.request();
        if (!r.isGranted) await openAppSettings();
      } else if (perm == LocationPermission.deniedForever) {
        await openAppSettings();
      }
    } catch (_) {
      await openAppSettings();
    }
  }

  /// Akku-Optimierung ausschalten (Android fragt direkt nach).
  static Future<void> fixBattery() async {
    try {
      final r = await Permission.ignoreBatteryOptimizations.request();
      if (!r.isGranted) await openAppSettings();
    } catch (_) {
      await openAppSettings();
    }
  }

  static Future<void> fixNotifications() async {
    try {
      final r = await Permission.notification.request();
      if (!r.isGranted) await openAppSettings();
    } catch (_) {}
  }

  static Future<void> openSettings() => openAppSettings();
}

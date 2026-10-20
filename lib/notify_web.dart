/// Browser: keine System-Benachrichtigungen.
class Notify {
  Notify._();

  static Future<void> init({bool askPermission = true}) async {}

  static Future<void> message(String title, String body, {bool important = false}) async {}
}

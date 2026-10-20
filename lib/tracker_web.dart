/// Browser: kein Hintergrunddienst.
class Tracker {
  Tracker._();

  static Future<void> configure() async {}

  static Future<String?> activeGame() async => null;

  static Future<void> start(String code) async {}

  static Future<void> stop() async {}

  static void chatOpen(String? channel) {}
}

// Auf Android echte Benachrichtigungen, im Browser nur ein Platzhalter.
export 'notify_web.dart' if (dart.library.io) 'notify_io.dart';

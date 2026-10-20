import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Firebase-Zugangsdaten. Sie werden beim Bauen auf GitHub aus dem
/// Secret FIREBASE_CONFIG eingesetzt (siehe README.md).
class AppConfig {
  /// Versionsnummer, wird beim Bauen auf GitHub gesetzt (z. B. 1.0.18).
  static const version = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

  static const apiKey = String.fromEnvironment('apiKey');
  static const projectId = String.fromEnvironment('projectId');
  static const messagingSenderId = String.fromEnvironment('messagingSenderId');
  static const androidAppId = String.fromEnvironment('androidAppId');
  static const webAppId = String.fromEnvironment('webAppId');
  static const authDomain = String.fromEnvironment('authDomain');

  static bool get isConfigured => apiKey.isNotEmpty && projectId.isNotEmpty;

  static FirebaseOptions get firebaseOptions {
    if (kIsWeb) {
      return FirebaseOptions(
        apiKey: apiKey,
        appId: webAppId,
        messagingSenderId: messagingSenderId,
        projectId: projectId,
        authDomain: authDomain.isEmpty ? '$projectId.firebaseapp.com' : authDomain,
        storageBucket: '$projectId.appspot.com',
      );
    }
    return FirebaseOptions(
      apiKey: apiKey,
      appId: androidAppId,
      messagingSenderId: messagingSenderId,
      projectId: projectId,
      storageBucket: '$projectId.appspot.com',
    );
  }
}

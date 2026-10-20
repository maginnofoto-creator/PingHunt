import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'config.dart';
import 'screens/home_screen.dart';
import 'theme.dart';
import 'tracker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? startError;
  if (!AppConfig.isConfigured) {
    startError = 'Firebase ist nicht eingerichtet. Das Secret FIREBASE_CONFIG fehlt beim Bauen.';
  } else {
    try {
      await Firebase.initializeApp(options: AppConfig.firebaseOptions);
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuth.instance.signInAnonymously();
      }
      await Tracker.configure();
    } catch (e) {
      startError = 'Verbindung zu Firebase fehlgeschlagen:\n$e';
    }
  }
  runApp(PingHuntApp(startError: startError));
}

class PingHuntApp extends StatelessWidget {
  const PingHuntApp({super.key, this.startError});

  final String? startError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PingHunt',
      debugShowCheckedModeBanner: false,
      theme: PH.theme(),
      home: startError == null
          ? const HomeScreen()
          : Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(startError!, textAlign: TextAlign.center),
                ),
              ),
            ),
    );
  }
}

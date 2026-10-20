/// Rechtliche Texte von PingHunt (werden auch als Webseite datenschutz.html veröffentlicht).
class Legal {
  static const developer = 'Marcel Maginno';
  static const email = 'Marcelmaginno@gmail.com';
  static const privacyUrl = 'https://maginnofoto-creator.github.io/PingHunt/datenschutz.html';
  static const consentVersion = 1;

  static const consentText =
      'PingHunt teilt während eines laufenden Spiels deinen Standort mit deinem Team, '
      'der Spielleitung und – je nach Rolle und Einstellung – mit den Jägern bzw. Zuschauern. '
      'Die Ortung läuft auch im Hintergrund, solange du im Spiel bist. '
      'Dein Name, Chat-Nachrichten und dein Akkustand werden ebenfalls gespeichert.';

  /// Abschnitte der Datenschutzerklärung: (Überschrift, Text).
  static const privacy = <(String, String)>[
    (
      'Verantwortlich',
      'Marcel Maginno\nE-Mail: Marcelmaginno@gmail.com\n\n'
          'PingHunt ist ein privates Hobbyprojekt für GPS-Fangspiele (Jäger und Gejagte) '
          'unter Freunden. Die App wird nicht kommerziell betrieben.'
    ),
    (
      'Welche Daten verarbeitet werden',
      '• Ein frei gewählter Spielername\n'
          '• Dein Standort (GPS), auch im Hintergrund, solange du an einem laufenden Spiel teilnimmst\n'
          '• Akkustand und der Zeitpunkt deines letzten Lebenszeichens\n'
          '• Chat-Nachrichten und geteilte Standorte im Chat\n'
          '• Spielereignisse (z. B. „hat das Spielfeld verlassen“, „wurde gefangen“)\n'
          '• Eine zufällige, anonyme Nutzerkennung (anonyme Anmeldung, kein Konto, keine E-Mail, kein Passwort)\n\n'
          'Es werden keine Kontakte, Fotos oder andere Inhalte deines Geräts ausgelesen. '
          'Die Kamera wird nur zum Scannen des QR-Codes eines Spiels verwendet; Bilder werden nicht gespeichert.'
    ),
    (
      'Zweck',
      'Die Daten werden ausschließlich verwendet, um das Spiel durchzuführen: Pings an die Jäger, '
      'Live-Ansicht für das eigene Team, Spielfeld- und Sperrgebiets-Regeln, Chat sowie die Übersicht '
      'für die Spielleitung und – falls freigegeben – für Zuschauer. '
      'Es findet keine Werbung, kein Tracking zu Werbezwecken und keine Weitergabe an Dritte zu eigenen Zwecken statt.'
    ),
    (
      'Wer welche Daten sieht',
      '• Dein Team: deinen Standort live\n'
          '• Die Jäger (wenn du gejagt wirst): deinen Standort nur beim Ping sowie live, '
          'wenn du das Spielfeld verlässt, ein Sperrgebiet betrittst oder offline warst\n'
          '• Die Spielleitung: alle Standorte, Akkustände, Ereignisse und Chats\n'
          '• Zuschauer: nur das, was die Spielleitung freigibt – ggf. mit Verzögerung. '
          'Wird der Chat deines Teams für Zuschauer freigegeben, siehst du einen Hinweis im Chat. '
          'Private Chats mit der Spielleitung sind für Zuschauer nie sichtbar.'
    ),
    (
      'Rechtsgrundlage',
      'Die Verarbeitung erfolgt auf Grundlage deiner Einwilligung (Art. 6 Abs. 1 lit. a DSGVO), '
      'die du beim ersten Beitritt zu einem Spiel gibst. Du kannst sie jederzeit widerrufen, '
      'indem du das Spiel verlässt und die App deinstallierst; ab dann werden keine neuen Daten mehr erhoben.'
    ),
    (
      'Speicherort und Dienstleister',
      '• Google Firebase (Google Ireland Limited, Gordon House, Barrow Street, Dublin 4, Irland): '
      'Speicherung der Spieldaten (Firestore-Datenbank in einem Rechenzentrum in Europa) und anonyme Anmeldung. '
      'Google kann dabei technische Daten wie die IP-Adresse verarbeiten; eine Übermittlung in die USA ist '
      'nicht ausgeschlossen und erfolgt auf Grundlage des EU-US Data Privacy Framework bzw. der EU-Standardvertragsklauseln.\n'
          '• Kartendienste: OpenStreetMap (OpenStreetMap Foundation) sowie für die Satellitenansicht Esri. '
          'Beim Laden der Karte wird deine IP-Adresse technisch bedingt an diese Anbieter übertragen.\n'
          '• GitHub (GitHub Inc.): Bereitstellung der Browser-Version und der App-Datei. '
          'Beim Aufruf können Zugriffsdaten (z. B. IP-Adresse) protokolliert werden.'
    ),
    (
      'Speicherdauer',
      'Die Daten eines Spiels bleiben gespeichert, bis die Spielleitung das Spiel löscht '
      '(Funktion „Spiel löschen“ nach Spielende). Dabei werden alle Standorte, Pings, Nachrichten '
      'und Ereignisse des Spiels entfernt. Spiele, die nicht gelöscht wurden, werden auf Anfrage gelöscht. '
      'Auf deinem Gerät speichert die App nur deinen zuletzt verwendeten Namen, Spielcode und Einstellungen.'
    ),
    (
      'Deine Rechte',
      'Du hast das Recht auf Auskunft, Berichtigung, Löschung, Einschränkung der Verarbeitung, '
      'Datenübertragbarkeit und Widerruf deiner Einwilligung. Schreib dazu einfach eine E-Mail an '
      'Marcelmaginno@gmail.com und nenne den Spielcode und deinen Spielernamen. '
      'Außerdem kannst du dich bei einer Datenschutz-Aufsichtsbehörde beschweren.'
    ),
    (
      'Berechtigungen der App',
      '• Standort (auch im Hintergrund): für Pings und Spielregeln während eines Spiels\n'
          '• Benachrichtigungen: für Chat, Warnungen und den Hinweis „PingHunt läuft“\n'
          '• Kamera: nur zum Scannen eines QR-Codes\n'
          '• Internet: zur Verbindung mit dem Spiel'
    ),
    (
      'Stand',
      'Oktober 2026. Diese Datenschutzerklärung kann bei Änderungen der App angepasst werden.'
    ),
  ];
}

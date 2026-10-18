# PingHunt

GPS-Spiel für Jäger und Gejagte: Spielfeld zeichnen, Teams einteilen, automatische Pings,
Ping-Verlauf, Zone-verlassen-Regel, Spielleitung in der App und im Browser, Zuschauermodus.

- **Android-App:** für Spieler und Spielleitung
- **Browser-Version:** für Spielleitung und Zuschauer (unter `https://DEIN-NAME.github.io/pinghunt/`)

---

## Einrichtung (einmalig, ca. 20 Minuten, am besten am PC)

### 1. Firebase-Projekt anlegen

Firebase ist der kostenlose Google-Dienst, über den die Handys ihre Positionen austauschen.

1. <https://console.firebase.google.com> öffnen und mit deinem Google-Konto anmelden.
2. **Projekt erstellen**, Name z. B. `pinghunt`. Google Analytics kannst du ausschalten.
3. Links **Build → Authentication → Jetzt starten**. Unter **Anmeldemethode** den Anbieter
   **Anonym** aktivieren und speichern.
4. Links **Build → Firestore Database → Datenbank erstellen**.
   - Standort: einen in Europa wählen (z. B. `eur3` oder `europe-west3`).
   - Modus: **Produktionsmodus**.
   - Danach Reiter **Regeln** öffnen, alles löschen, den kompletten Inhalt der Datei
     `firestore.rules` aus diesem Projekt einfügen und **Veröffentlichen**.
5. Zur **Projektübersicht** (Zahnrad → Projekteinstellungen) und unten **App hinzufügen**:
   - **Android:** Paketname `de.pinghunt.pinghunt`, Name `PingHunt`, registrieren.
     Die restlichen Schritte (google-services.json, SDK) einfach überspringen.
   - **Web** (Symbol `</>`): Name `PingHunt Web`, registrieren. Es erscheint ein Codeblock
     `firebaseConfig` – den brauchst du gleich.
6. In den **Projekteinstellungen** stehen jetzt beide Apps mit ihrer **App-ID**.

### 2. Zugangsdaten zusammenstellen

Trage die Werte in diese Vorlage ein (alles in einer Zeile oder wie hier, Hauptsache gültiges JSON):

```json
{
  "apiKey": "AIza...",
  "projectId": "pinghunt-xxxxx",
  "messagingSenderId": "123456789012",
  "authDomain": "pinghunt-xxxxx.firebaseapp.com",
  "webAppId": "1:123456789012:web:abc123...",
  "androidAppId": "1:123456789012:android:def456..."
}
```

- `apiKey`, `projectId`, `messagingSenderId`, `authDomain` und `webAppId` (= `appId`) stehen im
  `firebaseConfig` der Web-App.
- `androidAppId` ist die App-ID der Android-App (enthält `:android:`).

### 3. GitHub einrichten

1. Kostenloses Konto auf <https://github.com> anlegen.
2. Neues Repository `pinghunt` anlegen (**Public**, sonst gibt es keine kostenlose Browser-Version).
3. Diese Projektdateien hochladen (oder von Claude hochladen lassen).
4. Im Repository **Settings → Secrets and variables → Actions → New repository secret**:
   - Name: `FIREBASE_CONFIG`
   - Wert: das JSON aus Schritt 2
5. **Settings → Pages → Build and deployment → Source: GitHub Actions** auswählen.
6. Reiter **Actions → PingHunt bauen → Run workflow**. Der Bau dauert ca. 10 Minuten.

### 4. App installieren

- Nach dem Bau findest du unter **Releases** (rechte Seite im Repository) die Datei
  **PingHunt.apk**. Dauerhafter Link:
  `https://github.com/DEIN-NAME/pinghunt/releases/latest/download/PingHunt.apk`
- Auf dem Handy öffnen und die Installation „aus unbekannten Quellen“ erlauben.
- Die Browser-Version läuft unter `https://DEIN-NAME.github.io/pinghunt/`.

### 5. Wichtig für Xiaomi und andere Handys mit aggressivem Akku-Sparen

Ohne diese Einstellungen beendet das Handy die App im Hintergrund und Pings fallen aus:

- **Standort:** App-Info → Berechtigungen → Standort → **Immer zulassen**
- **Autostart:** App-Info → **Autostart** einschalten
- **Akku:** App-Info → Akkusparmodus → **Keine Einschränkungen**
- In der Übersicht der zuletzt genutzten Apps PingHunt **sperren** (Schloss-Symbol)

---

## So wird gespielt

1. **Spielleitung:** „Neues Spiel erstellen“. Es gibt einen 5-stelligen **Spielcode**, einen QR-Code
   und eine **Leitungs-PIN**.
2. **Spieler:** Namen eingeben, Code eintippen oder QR scannen, „Spiel beitreten“.
3. Spielleitung teilt alle in Teams ein (Teams → ⋮ bei einem Spieler), zeichnet das Spielfeld und
   stellt Intervall, Vorsprung usw. ein.
4. **Spiel starten.** Nach dem Vorsprung kommt der erste Ping, dann im eingestellten Intervall.
5. **Browser:** Code eingeben, „Spielleitung mit PIN übernehmen“ → großes Dashboard.
   Zuschauer geben nur den Code ein und klicken „Zuschauen“.
6. **Zentrale:** Im Browser (oder einer zweiten App) Code + Namen eingeben und
   „Als Zentrale beitreten (ohne GPS)“ wählen. Die Spielleitung teilt die Zentrale einem Team zu.
   Die Zentrale sieht dann alles, was dieses Team sieht – ohne Verzögerung, aber ohne eigenen Standort.

### Regeln, die die App umsetzt

- Pings: eingefrorene Position aller freien Gejagten, im Intervall (10-Minuten-Schritte) oder per
  „Ping jetzt“.
- Jäger sehen Pings mit Verlauf (letzter, 3, 6, alle) und können nach Teams filtern.
- Gejagte sehen ihr eigenes Team live, Jäger sehen die anderen Jäger live.
- Zone verlassen: nach der Kulanzzeit (Standard 15 s) ist der Gejagte für die eingestellte Zeit
  (Standard 10 min) live für alle Jäger sichtbar. Erneutes Verlassen startet die Zeit neu.
  Jäger dürfen die Zone frei verlassen.
- Warnung per Vibration ca. 50 m vor dem Rand.
- Fänge melden die Jäger in der App, die Spielleitung bestätigt sie.
- Zuschauer sehen alles mit der eingestellten Verzögerung (auch „Keine“ möglich).

## Noch nicht enthalten (nächste Schritte)

Joker, Sprechfunk, Text-Chat, Wiederholung im Zeitraffer, iPhone-Version.

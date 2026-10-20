import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../legal.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// Info über die App und den Entwickler.
class InfoScreen extends StatelessWidget {
  const InfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Über PingHunt')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text('PINGHUNT',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 6)),
              const SizedBox(height: 4),
              const Text('Jäger und Gejagte – per GPS', style: TextStyle(color: PH.muted)),
              const SizedBox(height: 24),
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ENTWICKELT VON', style: label()),
                    const SizedBox(height: 4),
                    const Text(Legal.developer, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    Text('KONTAKT', style: label()),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Expanded(child: SelectableText(Legal.email)),
                        IconButton(
                          tooltip: 'E-Mail-Adresse kopieren',
                          icon: const Icon(Icons.copy, size: 18),
                          onPressed: () {
                            Clipboard.setData(const ClipboardData(text: Legal.email));
                            ScaffoldMessenger.of(context)
                                .showSnackBar(const SnackBar(content: Text('E-Mail-Adresse kopiert')));
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.privacy_tip_outlined, color: PH.accent),
                title: const Text('Datenschutzerklärung'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivacyScreen())),
              ),
              const SizedBox(height: 8),
              const Text('Auch online abrufbar unter:', style: TextStyle(color: PH.muted, fontSize: 12)),
              const SelectableText(Legal.privacyUrl, style: TextStyle(fontSize: 12)),
              const SizedBox(height: 24),
              const Text('PingHunt ist ein privates Hobbyprojekt. Kartendaten © OpenStreetMap-Mitwirkende; '
                  'Satellitenbilder: Esri, Maxar, Earthstar Geographics.',
                  style: TextStyle(color: PH.muted, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Datenschutzerklärung in der App.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Datenschutzerklärung')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              for (final (title, text) in Legal.privacy) ...[
                Text(title,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: PH.accent)),
                const SizedBox(height: 6),
                SelectableText(text, style: const TextStyle(height: 1.45)),
                const SizedBox(height: 20),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Einwilligung vor dem ersten Beitritt. Gibt true zurück, wenn zugestimmt wurde.
Future<bool> askConsent(BuildContext context) async {
  var checked = false;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (c) => StatefulBuilder(
      builder: (c, setLocal) => AlertDialog(
        title: const Text('Bevor es losgeht'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(Legal.consentText),
              const SizedBox(height: 8),
              TextButton(
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                onPressed: () =>
                    Navigator.push(c, MaterialPageRoute(builder: (_) => const PrivacyScreen())),
                child: const Text('Datenschutzerklärung lesen'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: checked,
                onChanged: (v) => setLocal(() => checked = v ?? false),
                title: const Text('Ich bin einverstanden, dass mein Standort und meine Spieldaten '
                    'während des Spiels so geteilt werden.'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
          FilledButton(
            onPressed: checked ? () => Navigator.pop(c, true) : null,
            child: const Text('Zustimmen'),
          ),
        ],
      ),
    ),
  );
  return ok ?? false;
}

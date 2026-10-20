import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../repo.dart';
import '../theme.dart';
import '../legal.dart';
import '../tracker.dart';
import 'info_screen.dart';
import 'leader_screen.dart';
import 'player_screen.dart';
import 'scan_screen.dart';
import 'spectator_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _name = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  String? _lastCode;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      setState(() {
        _name.text = p.getString('name') ?? '';
        _lastCode = p.getString('lastCode');
        if (_lastCode != null) _code.text = _lastCode!;
      });
    });
    _resume();
  }

  /// Automatisch zurück ins laufende Spiel (z. B. nach versehentlichem Schließen).
  Future<void> _resume() async {
    final code = await Tracker.activeGame();
    if (code == null) return;
    try {
      final game = await Repo.i.getGame(code);
      final me = await Repo.i.getMyPlayer(code);
      if (game == null || game.isEnded || me == null) {
        await Tracker.stop();
        return;
      }
      if (!mounted) return;
      _code.text = code;
      _open(PlayerScreen(code: code));
    } catch (_) {}
  }

  Future<void> _remember(String code) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('name', _name.text.trim());
    await p.setString('lastCode', code);
  }

  void _msg(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  String? _validCode() {
    final c = _code.text.trim();
    if (!RegExp(r'^\d{5}$').hasMatch(c)) {
      _msg('Bitte den 5-stelligen Spielcode eingeben.');
      return null;
    }
    return c;
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      _msg('Fehler: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Einwilligung einmal pro Gerät (bzw. bei neuer Version der Datenschutzerklärung).
  Future<bool> _ensureConsent() async {
    final p = await SharedPreferences.getInstance();
    if ((p.getInt('consent') ?? 0) >= Legal.consentVersion) return true;
    if (!mounted) return false;
    final ok = await askConsent(context);
    if (ok) await p.setInt('consent', Legal.consentVersion);
    return ok;
  }

  Future<void> _join() => _run(() async {
        final code = _validCode();
        if (code == null) return;
        final name = _name.text.trim();
        if (name.isEmpty) {
          _msg('Bitte zuerst deinen Namen eingeben.');
          return;
        }
        final game = await Repo.i.getGame(code);
        if (game == null) {
          _msg('Kein Spiel mit dem Code $code gefunden.');
          return;
        }
        await _remember(code);
        if (!mounted) return;
        if (!await Repo.i.isLeader(game) && !kIsWeb && !await _ensureConsent()) return;
        if (!mounted) return;
        if (await Repo.i.isLeader(game)) {
          _open(LeaderScreen(code: code));
          return;
        }
        if (kIsWeb) {
          _msg('Mitspielen geht nur in der Android-App. Hier kannst du zuschauen.');
          _open(SpectatorScreen(code: code));
          return;
        }
        await Repo.i.joinAsPlayer(code, name);
        _open(PlayerScreen(code: code));
      });

  Future<void> _joinCentral() => _run(() async {
        final code = _validCode();
        if (code == null) return;
        final name = _name.text.trim();
        if (name.isEmpty) {
          _msg('Bitte zuerst einen Namen eingeben, z. B. „Jäger-Zentrale“.');
          return;
        }
        final game = await Repo.i.getGame(code);
        if (game == null) {
          _msg('Kein Spiel mit dem Code $code gefunden.');
          return;
        }
        await _remember(code);
        if (!await _ensureConsent()) return;
        await Repo.i.joinAsPlayer(code, name, observer: true);
        _msg('Beigetreten. Die Spielleitung teilt dich jetzt einem Team zu.');
        _open(PlayerScreen(code: code, observer: true));
      });

  Future<void> _create() => _run(() async {
        final code = await Repo.i.createGame();
        _code.text = code;
        await _remember(code);
        _open(LeaderScreen(code: code));
      });

  Future<void> _spectate() => _run(() async {
        final code = _validCode();
        if (code == null) return;
        final game = await Repo.i.getGame(code);
        if (game == null) {
          _msg('Kein Spiel mit dem Code $code gefunden.');
          return;
        }
        _open(SpectatorScreen(code: code));
      });

  Future<void> _claimLeader() async {
    final code = _validCode();
    if (code == null) return;
    final pin = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Spielleitung übernehmen'),
        content: TextField(
          controller: pin,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
          decoration: const InputDecoration(labelText: 'Leitungs-PIN (6 Ziffern)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Übernehmen')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      final success = await Repo.i.claimLeader(code, pin.text.trim());
      if (!success) {
        _msg('PIN falsch oder Spiel nicht gefunden.');
        return;
      }
      await _remember(code);
      _open(LeaderScreen(code: code));
    });
  }

  Future<void> _scan() async {
    final code = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ScanScreen()),
    );
    if (code != null) setState(() => _code.text = code);
  }

  void _open(Widget screen) {
    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    tooltip: 'Über PingHunt & Datenschutz',
                    icon: const Icon(Icons.info_outline),
                    onPressed: () => _open(const InfoScreen()),
                  ),
                ),
                const Text('PINGHUNT',
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 6)),
                const SizedBox(height: 6),
                const Text('Jäger und Gejagte – per GPS',
                    style: TextStyle(color: PH.muted, fontSize: 15)),
                const SizedBox(height: 32),
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Dein Name'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _code,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(5),
                        ],
                        style: const TextStyle(fontSize: 22, letterSpacing: 6, fontWeight: FontWeight.w700),
                        decoration: const InputDecoration(labelText: 'Spielcode (5 Ziffern)'),
                      ),
                    ),
                    if (!kIsWeb) ...[
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 60,
                        width: 60,
                        child: IconButton.filledTonal(
                          tooltip: 'QR-Code scannen',
                          onPressed: _busy ? null : _scan,
                          icon: const Icon(Icons.qr_code_scanner),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _join,
                  child: Text(kIsWeb ? 'Spiel öffnen' : 'Spiel beitreten'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _joinCentral,
                  icon: const Icon(Icons.desktop_windows_outlined),
                  label: const Text('Als Zentrale beitreten (ohne GPS)'),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: _busy ? null : _spectate,
                  child: const Text('Zuschauen'),
                ),
                const SizedBox(height: 32),
                const Divider(color: PH.line),
                const SizedBox(height: 16),
                const Text('Spielleitung',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _create,
                  icon: const Icon(Icons.add),
                  label: const Text('Neues Spiel erstellen'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _claimLeader,
                  icon: const Icon(Icons.key),
                  label: const Text('Spielleitung mit PIN übernehmen'),
                ),
                if (_busy) ...[
                  const SizedBox(height: 20),
                  const Center(child: CircularProgressIndicator()),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

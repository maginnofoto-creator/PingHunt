import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'notify.dart';
import 'repo.dart';

/// Beobachtet mehrere Chat-Kanäle: Nachrichten, Ungelesen-Zähler, Benachrichtigungen.
class ChatWatcher extends ChangeNotifier {
  ChatWatcher(this.code, {this.notify = true});

  final String code;
  final bool notify;
  final _repo = Repo.i;

  final Map<String, List<ChatMsg>> messages = {};
  final Map<String, DateTime> _lastRead = {};
  final Map<String, StreamSubscription> _subs = {};
  final Map<String, String> _titles = {};
  final DateTime _startedAt = DateTime.now();
  final Set<String> _notified = {};
  String? openChannel;

  /// Setzt die beobachteten Kanäle (Kanal → Titel für Benachrichtigungen).
  void watch(Map<String, String> channels) {
    _titles
      ..clear()
      ..addAll(channels);
    for (final ch in _subs.keys.toList()) {
      if (!channels.containsKey(ch)) {
        _subs.remove(ch)?.cancel();
        messages.remove(ch);
      }
    }
    for (final ch in channels.keys) {
      if (_subs.containsKey(ch)) continue;
      _loadRead(ch);
      _subs[ch] = _repo.messagesStream(code, ch).listen((list) {
        messages[ch] = list;
        _maybeNotify(ch, list);
        notifyListeners();
      }, onError: (Object e) => debugPrint('Chat $ch: $e'));
    }
    notifyListeners();
  }

  void _maybeNotify(String ch, List<ChatMsg> list) {
    for (final m in list) {
      if (_notified.contains(m.id)) continue;
      _notified.add(m.id);
      if (!notify || m.from == _repo.uid || m.t.isBefore(_startedAt) || ch == openChannel) continue;
      final title = m.fromLeader ? 'Spielleitung · ${_titles[ch] ?? ''}' : '${m.fromName} · ${_titles[ch] ?? ''}';
      Notify.message(title, m.kind == 'loc' ? '📍 hat einen Standort geteilt' : m.text,
          important: m.fromLeader || ch.startsWith('dm:') || ch == 'all');
    }
  }

  int unread(String ch) {
    final last = _lastRead[ch];
    return (messages[ch] ?? const [])
        .where((m) => m.from != _repo.uid && (last == null || m.t.isAfter(last)))
        .length;
  }

  int get totalUnread => _titles.keys.fold(0, (s, ch) => s + unread(ch));

  DateTime? lastMessageAt(String ch) {
    final l = messages[ch];
    return l == null || l.isEmpty ? null : l.last.t;
  }

  Future<void> markRead(String ch) async {
    final now = DateTime.now();
    _lastRead[ch] = now;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('read:$code:$ch', now.millisecondsSinceEpoch);
    } catch (_) {}
  }

  Future<void> _loadRead(String ch) async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getInt('read:$code:$ch');
      if (v != null) {
        _lastRead[ch] = DateTime.fromMillisecondsSinceEpoch(v);
        notifyListeners();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final s in _subs.values) {
      s.cancel();
    }
    super.dispose();
  }
}

import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../theme.dart';

class ToastItem {
  final IconData icon;
  final String title;
  final String text;
  final Color color;
  const ToastItem(this.icon, this.title, this.text, {this.color = PH.accent});
}

/// Warteschlange für große Einblendungen (je ca. 5 Sekunden).
class ToastQueue extends ChangeNotifier {
  final _queue = Queue<ToastItem>();
  ToastItem? current;
  Timer? _timer;

  void show(ToastItem item) {
    _queue.add(item);
    if (current == null) _next();
  }

  void _next() {
    current = _queue.isEmpty ? null : _queue.removeFirst();
    notifyListeners();
    _timer?.cancel();
    if (current != null) _timer = Timer(const Duration(seconds: 5), _next);
  }

  void skip() => _next();

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Zeigt die aktuelle Einblendung groß in der Bildschirmmitte.
class BigToastView extends StatelessWidget {
  const BigToastView({super.key, required this.queue});

  final ToastQueue queue;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: queue,
      builder: (context, _) {
        final t = queue.current;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: t == null
              ? const SizedBox.shrink()
              : Material(
                  key: ValueKey(t),
                  type: MaterialType.transparency,
                  child: Center(
                  child: GestureDetector(
                    onTap: queue.skip,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 560),
                      margin: const EdgeInsets.all(24),
                      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
                      decoration: BoxDecoration(
                        color: PH.surface.withOpacity(0.96),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: t.color, width: 3),
                        boxShadow: [BoxShadow(color: t.color.withOpacity(0.35), blurRadius: 40, spreadRadius: 4)],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(t.icon, color: t.color, size: 56),
                          const SizedBox(height: 10),
                          Text(t.title,
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: t.color)),
                          const SizedBox(height: 6),
                          Text(t.text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
                        ],
                      ),
                    ),
                  ),
                  ),
                ),
        );
      },
    );
  }
}

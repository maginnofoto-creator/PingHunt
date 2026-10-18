import 'package:flutter/material.dart';

import '../theme.dart';

TextStyle mono(double size, {Color color = PH.text}) => TextStyle(
      fontFamily: 'monospace',
      fontSize: size,
      fontWeight: FontWeight.w700,
      color: color,
      height: 1.1,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

TextStyle label() => const TextStyle(
      fontSize: 11,
      letterSpacing: 1.4,
      fontWeight: FontWeight.w700,
      color: PH.muted,
    );

class Dot extends StatelessWidget {
  const Dot(this.color, {super.key, this.size = 12});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

class Pill extends StatelessWidget {
  const Pill({super.key, required this.child, this.dot, this.filled});

  final Widget child;
  final Color? dot;
  final Color? filled;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: filled ?? PH.surface,
          borderRadius: BorderRadius.circular(999),
          border: filled == null ? Border.all(color: PH.line) : null,
        ),
        child: DefaultTextStyle.merge(
          style: const TextStyle(fontSize: 12, color: PH.text),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (dot != null) ...[Dot(dot!, size: 8), const SizedBox(width: 8)],
              child,
            ],
          ),
        ),
      );
}

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(16)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: PH.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: PH.line),
        ),
        child: child,
      );
}

Future<bool> confirm(BuildContext context, String title, String text) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(text),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Ja')),
      ],
    ),
  );
  return r ?? false;
}

/// Zeile mit Minus/Plus-Knöpfen für Einstellungen.
class StepperRow extends StatelessWidget {
  const StepperRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onMinus,
    required this.onPlus,
  });

  final String title;
  final String? subtitle;
  final String value;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (subtitle != null)
                    Text(subtitle!, style: const TextStyle(fontSize: 12, color: PH.muted)),
                ],
              ),
            ),
            IconButton.outlined(
              onPressed: onMinus,
              icon: const Icon(Icons.remove),
              tooltip: 'Weniger',
            ),
            SizedBox(
              width: 78,
              child: Text(value, textAlign: TextAlign.center, style: mono(16, color: PH.accent)),
            ),
            IconButton.outlined(
              onPressed: onPlus,
              icon: const Icon(Icons.add),
              tooltip: 'Mehr',
            ),
          ],
        ),
      );
}

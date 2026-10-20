import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../chat.dart';
import '../models.dart';
import '../repo.dart';
import '../theme.dart';
import '../tracker.dart';
import '../widgets/ui.dart';

const quickTexts = ['Jäger in der Nähe!', 'Bin sicher', 'Treffpunkt?', 'Brauche Hilfe', 'Bewege mich', 'Bleibe hier'];

/// Ein einzelner Chat-Verlauf mit Eingabe.
class ChatThread extends StatefulWidget {
  const ChatThread({
    super.key,
    required this.watcher,
    required this.channel,
    required this.myName,
    required this.fromLeader,
    this.canWrite = true,
    this.quick = false,
    this.myPos,
    this.onLocation,
    this.emptyText = 'Noch keine Nachrichten.',
  });

  final ChatWatcher watcher;
  final String channel;
  final String myName;
  final bool fromLeader;
  final bool canWrite;
  final bool quick;
  final LatLng? Function()? myPos;
  final void Function(LatLng)? onLocation;
  final String emptyText;

  @override
  State<ChatThread> createState() => _ChatThreadState();
}

class _ChatThreadState extends State<ChatThread> {
  final _text = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    widget.watcher.openChannel = widget.channel;
    Tracker.chatOpen(widget.channel);
    widget.watcher.markRead(widget.channel);
    widget.watcher.addListener(_changed);
  }

  @override
  void didUpdateWidget(ChatThread old) {
    super.didUpdateWidget(old);
    if (old.channel != widget.channel) {
      widget.watcher.openChannel = widget.channel;
      widget.watcher.markRead(widget.channel);
    }
  }

  void _changed() {
    if (!mounted) return;
    if (widget.watcher.unread(widget.channel) > 0) widget.watcher.markRead(widget.channel);
    setState(() {});
  }

  @override
  void dispose() {
    widget.watcher.removeListener(_changed);
    if (widget.watcher.openChannel == widget.channel) widget.watcher.openChannel = null;
    Tracker.chatOpen(null);
    super.dispose();
  }

  Future<void> _send(String text, {String kind = 'text', LatLng? pos}) async {
    if (text.trim().isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await Repo.i.sendMessage(
        widget.watcher.code,
        channel: widget.channel,
        fromName: widget.fromLeader ? 'Spielleitung' : widget.myName,
        fromLeader: widget.fromLeader,
        text: text.trim(),
        kind: kind,
        pos: pos,
      );
      if (kind == 'text') _text.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Senden fehlgeschlagen: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final msgs = (widget.watcher.messages[widget.channel] ?? const <ChatMsg>[]).reversed.toList();
    final me = Repo.i.uid;
    return Column(
      children: [
        if (widget.watcher.error != null)
          Container(
            width: double.infinity,
            color: PH.danger.withOpacity(0.2),
            padding: const EdgeInsets.all(10),
            child: Text(widget.watcher.error!, style: const TextStyle(fontSize: 12)),
          ),
        Expanded(
          child: msgs.isEmpty
              ? Center(child: Text(widget.emptyText, style: const TextStyle(color: PH.muted)))
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(12),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) => _bubble(msgs[i], msgs[i].from == me),
                ),
        ),
        if (widget.canWrite) ...[
          if (widget.quick)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final q in quickTexts)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(label: Text(q), onPressed: () => _send(q, kind: 'quick')),
                    ),
                ],
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Row(
                children: [
                  if (widget.myPos != null)
                    IconButton(
                      tooltip: 'Meinen Standort teilen',
                      icon: const Icon(Icons.my_location, color: PH.accent),
                      onPressed: () {
                        final p = widget.myPos!();
                        if (p == null) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(const SnackBar(content: Text('Noch kein GPS-Signal.')));
                          return;
                        }
                        _send('📍 Mein Standort', kind: 'loc', pos: p);
                      },
                    ),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Nachricht …',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                      onSubmitted: (v) => _send(v),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    tooltip: 'Senden',
                    onPressed: _sending ? null : () => _send(_text.text),
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ] else
          const SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text('Nur die Spielleitung schreibt hier.', style: TextStyle(color: PH.muted)),
            ),
          ),
      ],
    );
  }

  Widget _bubble(ChatMsg m, bool mine) {
    final color = m.fromLeader ? PH.accent.withOpacity(0.18) : (mine ? PH.surface2 : PH.surface);
    final isLoc = m.kind == 'loc' && m.pos != null;
    final body = Container(
      constraints: const BoxConstraints(maxWidth: 320),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: m.kind == 'quick' ? PH.accent.withOpacity(0.28) : color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: m.fromLeader ? PH.accent : PH.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${mine ? 'Du' : m.fromName} · ${hhmm(m.t)}',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: m.fromLeader ? PH.accent : PH.muted,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            isLoc ? '📍 Standort geteilt – antippen für Karte' : m.text,
            style: TextStyle(
              fontSize: 15,
              fontWeight: m.kind == 'quick' ? FontWeight.w800 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: isLoc && widget.onLocation != null
          ? InkWell(onTap: () => widget.onLocation!(m.pos!), child: body)
          : body,
    );
  }
}

/// Badge mit Ungelesen-Zahl.
class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.count, required this.child});

  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) => Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        backgroundColor: PH.danger,
        child: child,
      );
}

/// Chat-Übersicht für Spieler: Team, Spielleitung, Durchsagen.
class PlayerChatScreen extends StatelessWidget {
  const PlayerChatScreen({
    super.key,
    required this.watcher,
    required this.myName,
    required this.team,
    this.myPos,
  });

  final ChatWatcher watcher;
  final String myName;
  final Team? team;
  final LatLng? Function()? myPos;

  @override
  Widget build(BuildContext context) {
    final uid = Repo.i.uid;
    final tabs = <(String, String, Widget)>[
      if (team != null)
        (
          team!.name,
          'team:${team!.id}',
          ChatThread(
            watcher: watcher,
            channel: 'team:${team!.id}',
            myName: myName,
            fromLeader: false,
            quick: true,
            myPos: myPos,
            onLocation: (p) => Navigator.pop(context, p),
            emptyText: 'Team-Chat – nur dein Team und die Spielleitung lesen mit.',
          ),
        ),
      (
        'Spielleitung',
        'dm:$uid',
        ChatThread(
          watcher: watcher,
          channel: 'dm:$uid',
          myName: myName,
          fromLeader: false,
          myPos: myPos,
          emptyText: 'Privater Chat mit der Spielleitung.',
        ),
      ),
      (
        'Durchsagen',
        'all',
        ChatThread(
          watcher: watcher,
          channel: 'all',
          myName: myName,
          fromLeader: false,
          canWrite: false,
          emptyText: 'Durchsagen der Spielleitung an alle erscheinen hier.',
        ),
      ),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Nachrichten'),
          bottom: TabBar(
            tabs: [
              for (final t in tabs)
                Tab(
                  child: AnimatedBuilder(
                    animation: watcher,
                    builder: (_, __) => UnreadBadge(count: watcher.unread(t.$2), child: Text(t.$1)),
                  ),
                ),
            ],
          ),
        ),
        body: TabBarView(children: [for (final t in tabs) t.$3]),
      ),
    );
  }
}

/// Chat-Übersicht für die Spielleitung: Durchsage, Teams, einzelne Spieler.
class LeaderChatList extends StatelessWidget {
  const LeaderChatList({super.key, required this.watcher, required this.game, required this.players});

  final ChatWatcher watcher;
  final Game game;
  final List<Player> players;

  void _open(BuildContext context, String channel, String title, {bool quick = false}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: ChatThread(
            watcher: watcher,
            channel: channel,
            myName: 'Spielleitung',
            fromLeader: true,
            emptyText: channel == 'all'
                ? 'Durchsage an alle Spieler.'
                : channel.startsWith('team:')
                    ? 'Team-Chat – du schreibst als Spielleitung mit.'
                    : 'Privater Chat.',
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, {
    required Widget leading,
    required String title,
    required String subtitle,
    required String channel,
  }) {
    final n = watcher.unread(channel);
    final last = watcher.lastMessageAt(channel);
    return ListTile(
      leading: leading,
      title: Text(title, style: TextStyle(fontWeight: n > 0 ? FontWeight.w800 : FontWeight.w500)),
      subtitle: Text(subtitle, style: const TextStyle(color: PH.muted, fontSize: 12)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (last != null) Text(hhmm(last), style: mono(11, color: PH.muted)),
          if (n > 0) ...[
            const SizedBox(width: 8),
            UnreadBadge(count: n, child: const SizedBox(width: 6, height: 6)),
          ],
        ],
      ),
      onTap: () => _open(context, channel, title),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: watcher,
      builder: (context, _) {
        final sorted = [...players]
          ..sort((a, b) {
            final ua = watcher.unread('dm:${a.uid}'), ub = watcher.unread('dm:${b.uid}');
            if (ua != ub) return ub.compareTo(ua);
            final la = watcher.lastMessageAt('dm:${a.uid}'), lb = watcher.lastMessageAt('dm:${b.uid}');
            if (la != null || lb != null) {
              if (la == null) return 1;
              if (lb == null) return -1;
              return lb.compareTo(la);
            }
            return a.name.compareTo(b.name);
          });
        return ListView(
          children: [
            _row(
              context,
              leading: const CircleAvatar(backgroundColor: PH.accent, child: Icon(Icons.campaign, color: PH.bg)),
              title: 'Durchsage an alle',
              subtitle: 'Alle Spieler bekommen die Nachricht',
              channel: 'all',
            ),
            Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('TEAMS', style: label())),
            for (final t in game.teamList)
              _row(
                context,
                leading: CircleAvatar(backgroundColor: Color(t.color), child: const Icon(Icons.groups, color: PH.bg)),
                title: t.name,
                subtitle: 'Team-Chat',
                channel: 'team:${t.id}',
              ),
            Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('EINZELNE SPIELER', style: label())),
            for (final p in sorted)
              _row(
                context,
                leading: CircleAvatar(
                  backgroundColor: Color(game.team(p.teamId)?.color ?? 0xFF9AA4B2),
                  child: Text(p.name.isEmpty ? '?' : p.name.substring(0, 1).toUpperCase(),
                      style: const TextStyle(color: PH.bg, fontWeight: FontWeight.w800)),
                ),
                title: p.name,
                subtitle: '${game.team(p.teamId)?.name ?? 'Nicht zugeteilt'}${p.observer ? ' · Zentrale' : ''}',
                channel: 'dm:${p.uid}',
              ),
          ],
        );
      },
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sing_box/sing_box.dart';

const orange = Color(0xFFFF6B00);
const bg = Color(0xFF0D0E12);
const panel = Color(0xFF17181E);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SingBox.instance.initialize(const SingBoxOptions(
    android: SingBoxAndroidOptions(
      notificationTitle: 'Nima ORANGE VPN',
      showTrafficInNotification: true,
      stopActionTitle: 'قطع اتصال',
    ),
  ));
  runApp(const NimaOrangeApp());
}

class NimaOrangeApp extends StatelessWidget {
  const NimaOrangeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Nima ORANGE VPN',
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.fromSeed(seedColor: orange, brightness: Brightness.dark),
      useMaterial3: true,
      fontFamily: 'Roboto',
    ),
    home: const HomePage(),
  );
}

class SavedNode {
  final String id;
  final String name;
  final String link;
  const SavedNode({required this.id, required this.name, required this.link});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'link': link};
  factory SavedNode.fromJson(Map<String, dynamic> j) => SavedNode(
    id: j['id'] as String, name: j['name'] as String, link: j['link'] as String);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final core = SingBox.instance;
  final List<SavedNode> nodes = [];
  static const secureStore = FlutterSecureStorage();
  StreamSubscription<SingBoxConnectionStatus>? statusSub;
  StreamSubscription<SingBoxConnectionStats>? statsSub;
  SingBoxConnectionStatus status = SingBoxConnectionStatus.disconnected;
  String? activeId;
  String errorText = '';
  double down = 0, up = 0;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _load();
    status = core.status;
    statusSub = core.watchConnectionStatus().listen((s) {
      if (mounted) setState(() => status = s);
    });
    statsSub = core.watchConnectionStats().listen((s) {
      if (mounted) setState(() {
        down = s.downloadSpeed / 1024 / 1024;
        up = s.uploadSpeed / 1024 / 1024;
      });
    });
  }

  Future<void> _load() async {
    final raw = await secureStore.read(key: 'nima_nodes_v1');
    final active = await secureStore.read(key: 'nima_active_v1');
    final loaded = <SavedNode>[];
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        for (final item in decoded) {
          loaded.add(SavedNode.fromJson(Map<String, dynamic>.from(item as Map)));
        }
      } catch (_) {
        // Corrupt entries are ignored instead of crashing startup.
      }
    }
    if (!mounted) return;
    setState(() {
      nodes.addAll(loaded);
      activeId = active;
      if (activeId == null && nodes.isNotEmpty) activeId = nodes.first.id;
    });
  }

  Future<void> _persist() async {
    await secureStore.write(
      key: 'nima_nodes_v1',
      value: jsonEncode(nodes.map((n) => n.toJson()).toList()),
    );
    if (activeId != null) {
      await secureStore.write(key: 'nima_active_v1', value: activeId!);
    } else {
      await secureStore.delete(key: 'nima_active_v1');
    }
  }

  String _nameFor(String link) {
    try {
      if (link.startsWith('vmess://')) {
        final payload = link.substring(8).split('#').first;
        final decoded = Uri.decodeComponent(payload);
        final normalized = decoded.replaceAll('-', '+').replaceAll('_', '/');
        final padded = normalized.padRight((normalized.length + 3) ~/ 4 * 4, '=');
        final obj = Uri.splitQueryString('x=${Uri.encodeQueryComponent(padded)}');
        final raw = Uri.decodeComponent(obj['x']!);
        final name = Uri.decodeComponent(link.split('#').length > 1 ? link.split('#').last : '');
        return name.isNotEmpty ? name : 'VMess';
      }
      final uri = Uri.parse(link);
      final fragment = Uri.decodeComponent(uri.fragment);
      if (fragment.isNotEmpty) return fragment;
      return '${uri.scheme.toUpperCase()} • ${uri.host}';
    } catch (_) {
      return 'کانفیگ جدید';
    }
  }

  Future<void> _importText(String raw) async {
    final links = raw.trim().split(RegExp(r'[\r\n]+'))
      .map((e) => e.trim()).where((e) => e.contains('://')).toList();
    if (links.isEmpty) {
      _message('لینک معتبری پیدا نشد. لینک کانفیگ را بررسی کنید.');
      return;
    }
    int added = 0;
    for (final link in links) {
      final supported = RegExp(r'^(vless|vmess|trojan|ss|hysteria2|hy2|hysteria|tuic|anytls|wireguard|wg|socks5?)://', caseSensitive: false).hasMatch(link);
      if (!supported) continue;
      if (nodes.any((n) => n.link == link)) continue;
      final id = DateTime.now().microsecondsSinceEpoch.toString() + added.toString();
      nodes.add(SavedNode(id: id, name: _nameFor(link), link: link));
      added++;
    }
    if (added == 0) {
      _message('کانفیگ جدیدی برای افزودن پیدا نشد.');
    } else {
      activeId ??= nodes.last.id;
      await _persist();
      if (mounted) setState(() {});
      _message('$added کانفیگ اضافه شد.');
    }
  }

  Future<void> _pasteImport() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if ((data?.text ?? '').trim().isNotEmpty) {
      await _importText(data!.text!);
    } else {
      _showPasteDialog();
    }
  }

  Future<void> _showPasteDialog() async {
    final controller = TextEditingController();
    await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: panel,
      title: const Text('افزودن کانفیگ'),
      content: TextField(controller: controller, maxLines: 6,
        decoration: const InputDecoration(hintText: 'لینک یا چند لینک کانفیگ را وارد کنید')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
        FilledButton(onPressed: () { Navigator.pop(ctx); _importText(controller.text); },
          child: const Text('افزودن')),
      ],
    ));
    controller.dispose();
  }

  Future<void> _scanQr() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => QRPage(onFound: (value) {
      Navigator.pop(context);
      _importText(value);
    })));
  }

  SavedNode? get activeNode {
    for (final n in nodes) { if (n.id == activeId) return n; }
    return nodes.isEmpty ? null : nodes.first;
  }

  Future<void> _toggle() async {
    if (busy) return;
    setState(() { busy = true; errorText = ''; });
    try {
      if (status == SingBoxConnectionStatus.connected ||
          status == SingBoxConnectionStatus.connecting) {
        await core.disconnect();
        down = 0; up = 0;
      } else {
        final node = activeNode;
        if (node == null) { _message('برای اتصال، ابتدا کانفیگ خارجی وارد کنید.'); return; }
        await core.requestNotificationPermission();
        await core.connect(node.link);
      }
    } on SingBoxException catch (e) {
      if (mounted) setState(() => errorText = e.message);
    } catch (e) {
      if (mounted) setState(() => errorText = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _delete(SavedNode n) async {
    final wasActive = activeId == n.id;
    nodes.removeWhere((x) => x.id == n.id);
    if (wasActive) {
      if (status == SingBoxConnectionStatus.connected) await core.disconnect();
      activeId = nodes.isEmpty ? null : nodes.first.id;
    }
    await _persist();
    if (mounted) setState(() {});
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  String _speed(double v) => v < 0.01 ? '0.00' : v.toStringAsFixed(2);
  bool get connected => status == SingBoxConnectionStatus.connected;
  bool get connecting => status == SingBoxConnectionStatus.connecting ||
      status == SingBoxConnectionStatus.disconnecting;

  @override
  void dispose() {
    statusSub?.cancel();
    statsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final node = activeNode;
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(
        backgroundColor: bg,
        title: Row(children: [
          Container(width: 42, height: 42, decoration: BoxDecoration(
            color: orange.withOpacity(.13), border: Border.all(color: orange.withOpacity(.5)),
            borderRadius: BorderRadius.circular(13)),
            child: const Center(child: Text('Ω', style: TextStyle(color: orange, fontSize: 25, fontWeight: FontWeight.w900)))),
          const SizedBox(width: 10),
          const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Nima ORANGE', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            Text('SECURE VPN CLIENT', style: TextStyle(color: Colors.white54, fontSize: 9, letterSpacing: 1.3)),
          ]),
        ]),
        actions: [
          IconButton(tooltip: 'افزودن از کلیپ‌بورد', onPressed: _pasteImport,
            icon: const Icon(Icons.content_paste, color: orange)),
          IconButton(tooltip: 'اسکن QR', onPressed: _scanQr,
            icon: const Icon(Icons.qr_code_scanner, color: orange)),
        ],
      ),
      body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [
        _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('کانفیگ خارجی انتخاب‌شده', style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.dns_outlined, color: orange),
            const SizedBox(width: 10),
            Expanded(child: Text(node?.name ?? 'هنوز کانفیگ خارجی وارد نشده',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
            if (node != null) IconButton(onPressed: () => _showNodeActions(node),
              icon: const Icon(Icons.more_vert, color: Colors.white54)),
          ]),
        ])),
        const SizedBox(height: 28),
        Center(child: GestureDetector(
          onTap: _toggle,
          child: AnimatedContainer(duration: const Duration(milliseconds: 250),
            width: 190, height: 190,
            decoration: BoxDecoration(shape: BoxShape.circle,
              gradient: LinearGradient(colors: connected
                ? [const Color(0xFF164B38), const Color(0xFF101A17)]
                : [const Color(0xFF24252D), const Color(0xFF101115)],
                begin: Alignment.topLeft, end: Alignment.bottomRight),
              border: Border.all(color: connected ? Colors.greenAccent : orange.withOpacity(.7), width: 2),
              boxShadow: [BoxShadow(color: (connected ? Colors.green : orange).withOpacity(.18), blurRadius: 30, spreadRadius: 4)]),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(connected ? Icons.shield : Icons.power_settings_new,
                size: 52, color: connected ? Colors.greenAccent : orange),
              const SizedBox(height: 10),
              Text(busy || connecting ? 'لطفاً صبر کنید' : connected ? 'CONNECTED' : 'CONNECT',
                style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.4)),
            ]),
          ),
        )),
        const SizedBox(height: 18),
        Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: connected ? Colors.green.withOpacity(.12) : panel,
            borderRadius: BorderRadius.circular(30), border: Border.all(color: connected ? Colors.green : Colors.white12)),
          child: Text(connected ? 'اتصال برقرار است' : connecting || busy ? 'در حال اتصال...' : 'قطع ارتباط',
            style: TextStyle(color: connected ? Colors.greenAccent : Colors.white60, fontSize: 12)))),
        if (errorText.isNotEmpty) ...[
          const SizedBox(height: 12),
          _panel(child: Text(errorText, style: const TextStyle(color: Colors.redAccent, fontSize: 12))),
        ],
        const SizedBox(height: 22),
        Row(children: [
          Expanded(child: _stat('دانلود', _speed(down), Icons.arrow_downward, Colors.greenAccent)),
          const SizedBox(width: 12),
          Expanded(child: _stat('آپلود', _speed(up), Icons.arrow_upward, orange)),
        ]),
        const SizedBox(height: 26),
        Row(children: [
          const Expanded(child: Text('کانفیگ‌های خارجی', style: TextStyle(fontWeight: FontWeight.bold))),
          Text('${nodes.length} مورد', style: const TextStyle(color: Colors.white54, fontSize: 12)),
          IconButton(onPressed: _showPasteDialog, icon: const Icon(Icons.add_circle, color: orange)),
        ]),
        if (nodes.isEmpty)
          _panel(child: const Padding(padding: EdgeInsets.symmetric(vertical: 20),
            child: Column(children: [
              Icon(Icons.inbox_outlined, size: 34, color: Colors.white30),
              SizedBox(height: 8),
              Text('هنوز کانفیگ خارجی وارد نشده', style: TextStyle(color: Colors.white70)),
              SizedBox(height: 4),
              Text('فقط کانفیگ خارجی را از کلیپ‌بورد، متن یا QR وارد کنید.',
                style: TextStyle(color: Colors.white38, fontSize: 11)),
            ])))
        else
          ...nodes.map((n) => _nodeTile(n)),
        const SizedBox(height: 22),
        const Text('موتور اتصال: sing-box 1.14 • آمار ترافیک از تونل واقعی',
          textAlign: TextAlign.center, style: TextStyle(color: Colors.white30, fontSize: 10)),
      ])),
    ));
  }

  Widget _panel({required Widget child}) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(18),
      border: Border.all(color: Colors.white.withOpacity(.07))),
    child: child);

  Widget _stat(String label, String value, IconData icon, Color color) => _panel(child: Row(children: [
    Icon(icon, color: color, size: 25), const SizedBox(width: 10),
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
      Text('$value MB/s', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
    ])),
  ]));

  Widget _nodeTile(SavedNode n) {
    final selected = n.id == activeId;
    return Container(margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(15),
        border: Border.all(color: selected ? orange.withOpacity(.7) : Colors.white10)),
      child: ListTile(
        onTap: () async {
          if (connected) await core.disconnect();
          setState(() => activeId = n.id);
          await _persist();
        },
        leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
          color: selected ? orange : Colors.white38),
        title: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        subtitle: Text(n.link.split('://').first.toUpperCase(),
          style: const TextStyle(color: Colors.white38, fontSize: 10)),
        trailing: IconButton(onPressed: () => _delete(n),
          icon: const Icon(Icons.delete_outline, color: Colors.white38)),
      ));
  }

  Future<void> _showNodeActions(SavedNode n) async {
    await showModalBottomSheet<void>(context: context, backgroundColor: panel, builder: (ctx) =>
      SafeArea(child: Wrap(children: [
        ListTile(leading: const Icon(Icons.copy, color: orange), title: const Text('کپی لینک'),
          onTap: () { Clipboard.setData(ClipboardData(text: n.link)); Navigator.pop(ctx); _message('کپی شد'); }),
        ListTile(leading: const Icon(Icons.delete_outline, color: Colors.redAccent), title: const Text('حذف کانفیگ'),
          onTap: () { Navigator.pop(ctx); _delete(n); }),
      ])));
  }
}

class QRPage extends StatelessWidget {
  final ValueChanged<String> onFound;
  const QRPage({super.key, required this.onFound});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: bg,
    appBar: AppBar(title: const Text('اسکن QR کانفیگ')),
    body: MobileScanner(onDetect: (capture) {
      final value = capture.barcodes.firstOrNull?.rawValue;
      if (value != null && value.isNotEmpty) onFound(value);
    }),
  );
}

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ───────────────────────── palette ─────────────────────────
class C {
  static const bg = Color(0xFF0D0C0B);
  static const surface = Color(0xFF161513);
  static const line = Color(0xFF2A2724);
  static const text = Color(0xFFF2EEE7);
  static const muted = Color(0xFF8E877C);
  static const red = Color(0xFFFF4A2E);
  static const amber = Color(0xFFFFB020);
  static const lime = Color(0xFFC6F24E);
  static const tickOff = Color(0xFF2B2825);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: C.bg,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const YtSkipsApp());
}

class YtSkipsApp extends StatelessWidget {
  const YtSkipsApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ytskips',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: C.bg,
          colorScheme: const ColorScheme.dark(primary: C.red, surface: C.surface),
        ),
        home: const HomePage(),
      );
}

// ───────────────────────── native bridge ─────────────────────────
enum AdStatus { idle, detected, skipped, unskippable }

AdStatus parseStatus(String? s) => switch (s) {
      'ad_detected' => AdStatus.detected,
      'skipped' => AdStatus.skipped,
      'ad_unskippable' => AdStatus.unskippable,
      _ => AdStatus.idle,
    };

class Native {
  static const _m = MethodChannel('ytskips/methods');
  static const _e = EventChannel('ytskips/events');

  static Stream<Map<String, dynamic>> get events =>
      _e.receiveBroadcastStream().map((e) => Map<String, dynamic>.from(e as Map));

  static Future<Map<String, dynamic>> config() async {
    final r = await _m.invokeMethod('getConfig');
    return Map<String, dynamic>.from(r as Map);
  }

  static Future<void> setFlag(String key, bool value) async {
    await _m.invokeMethod('setFlag', {'key': key, 'value': value});
  }

  static Future<void> resetStats() async => _m.invokeMethod('resetStats');
  static Future<void> openAccessibility() async => _m.invokeMethod('openAccessibility');
  static Future<void> openAppInfo() async => _m.invokeMethod('openAppInfo');
}

class LogEntry {
  final DateTime time;
  final String label;
  final Color color;
  LogEntry(this.time, this.label, this.color);
}

// ───────────────────────── home ─────────────────────────
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver, TickerProviderStateMixin {
  late final AnimationController _sweep =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
  late final AnimationController _flash =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));

  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _revert;

  bool _serviceOn = false;
  bool _enabled = true;
  bool _mute = true;
  int _skipped = 0;
  int _unskippable = 0;
  AdStatus _status = AdStatus.idle;
  final List<LogEntry> _log = [];

  bool get _live => _serviceOn && _enabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sweep.repeat();
    _flash.value = 1;
    _refresh();
    _sub = Native.events.listen(_onEvent, onError: (_) {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _revert?.cancel();
    _sweep.dispose();
    _flash.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final c = await Native.config();
      if (!mounted) return;
      setState(() {
        _serviceOn = c['serviceOn'] == true;
        _enabled = c['enabled'] != false;
        _mute = c['mute'] != false;
        _skipped = (c['skipped'] as num?)?.toInt() ?? 0;
        _unskippable = (c['unskippable'] as num?)?.toInt() ?? 0;
      });
    } catch (_) {}
  }

  void _onEvent(Map<String, dynamic> m) {
    if (!mounted) return;
    final st = parseStatus(m['status'] as String?);
    setState(() {
      _status = st;
      _skipped = (m['skipped'] as num?)?.toInt() ?? _skipped;
      _unskippable = (m['unskippable'] as num?)?.toInt() ?? _unskippable;
      switch (st) {
        case AdStatus.detected:
          _addLog('Iklan terdeteksi', C.amber);
        case AdStatus.skipped:
          _addLog('Dilewati otomatis', C.lime);
        case AdStatus.unskippable:
          _addLog('Tak bisa dilewati', C.red);
        case AdStatus.idle:
          break;
      }
    });
    _revert?.cancel();
    if (st == AdStatus.skipped) {
      _flash.forward(from: 0);
      HapticFeedback.mediumImpact();
      _revert = Timer(const Duration(milliseconds: 2600), () {
        if (mounted && _status == AdStatus.skipped) setState(() => _status = AdStatus.idle);
      });
    }
  }

  void _addLog(String label, Color color) {
    _log.insert(0, LogEntry(DateTime.now(), label, color));
    if (_log.length > 6) _log.removeLast();
  }

  Future<void> _toggleEnabled() async {
    HapticFeedback.selectionClick();
    final next = !_enabled;
    setState(() {
      _enabled = next;
      if (!next) _status = AdStatus.idle;
    });
    await Native.setFlag('enabled', next);
  }

  Future<void> _toggleMute(bool v) async {
    setState(() => _mute = v);
    await Native.setFlag('mute', v);
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: C.line)),
        title: const Text('Reset statistik?', style: TextStyle(fontWeight: FontWeight.w800)),
        content: const Text('Penghitung iklan akan kembali ke nol.', style: TextStyle(color: C.muted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal', style: TextStyle(color: C.muted))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset', style: TextStyle(color: C.red, fontWeight: FontWeight.w800))),
        ],
      ),
    );
    if (ok == true) {
      await Native.resetStats();
      if (!mounted) return;
      setState(() {
        _skipped = 0;
        _unskippable = 0;
        _log.clear();
      });
    }
  }

  Color get _accent {
    if (!_live) return C.muted;
    return switch (_status) {
      AdStatus.detected => C.amber,
      AdStatus.skipped => C.lime,
      AdStatus.unskippable => C.red,
      AdStatus.idle => C.red,
    };
  }

  (String, String) get _copy {
    if (!_serviceOn) return ('Belum terhubung', 'Aktifkan layanan aksesibilitas untuk memulai.');
    if (!_enabled) return ('Dijeda', 'Ketuk lingkaran untuk melanjutkan.');
    return switch (_status) {
      AdStatus.detected => ('Iklan terdeteksi', 'Menunggu tombol Lewati muncul…'),
      AdStatus.skipped => ('Terlewati', 'Iklan dilewati otomatis.'),
      AdStatus.unskippable =>
        ('Tak bisa dilewati', _mute ? 'Suara dimatikan sampai iklan selesai.' : 'Menunggu iklan selesai.'),
      AdStatus.idle => ('Siaga', 'Buka YouTube. Sisanya biar ytskips.'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final dial = math.min(w - 64, 320.0);
    final (head, sub) = _copy;
    final total = _skipped + _unskippable;
    final ratio = total == 0 ? '–' : '${(_skipped * 100 / total).round()}%';

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
          children: [
            _header(),
            const SizedBox(height: 28),
            Center(
              child: GestureDetector(
                onTap: _serviceOn ? _toggleEnabled : null,
                child: SizedBox(
                  width: dial,
                  height: dial,
                  child: Stack(alignment: Alignment.center, children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: DialPainter(
                          sweep: _sweep,
                          flash: _flash,
                          live: _live,
                          status: _status,
                          accent: _accent,
                        ),
                      ),
                    ),
                    Align(
                      alignment: const Alignment(0, 0.58),
                      child: Text(
                        !_serviceOn ? 'OFFLINE' : (_enabled ? 'AKTIF' : 'JEDA'),
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 3,
                          fontWeight: FontWeight.w800,
                          color: _live ? _accent : C.muted,
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 24),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Column(
                key: ValueKey(head),
                children: [
                  Text(head,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -1, height: 1.1, color: C.text)),
                  const SizedBox(height: 6),
                  Text(sub, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: C.muted)),
                ],
              ),
            ),
            const SizedBox(height: 28),
            _statsRow(ratio),
            if (!_serviceOn) ...[const SizedBox(height: 20), _setupCard()],
            const SizedBox(height: 20),
            _sectionLabel('PENGATURAN'),
            _tile(
              'Mute iklan non-skippable',
              'Matikan suara selama iklan yang tak bisa dilewati.',
              Switch(
                value: _mute,
                onChanged: _toggleMute,
                activeColor: C.bg,
                activeTrackColor: C.lime,
                inactiveThumbColor: C.muted,
                inactiveTrackColor: C.tickOff,
              ),
            ),
            _tile(
              'Reset statistik',
              'Kembalikan penghitung ke nol.',
              const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: C.muted),
              onTap: _confirmReset,
            ),
            const SizedBox(height: 20),
            _sectionLabel('AKTIVITAS'),
            _logView(),
          ],
        ),
      ),
    );
  }

  Widget _header() => Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.asset('assets/logo.png', width: 38, height: 38),
        ),
        const SizedBox(width: 12),
        const Text('ytskips', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: -1.2, color: C.text)),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(border: Border.all(color: C.line), borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(shape: BoxShape.circle, color: _live ? C.lime : C.muted),
            ),
            const SizedBox(width: 7),
            Text(_live ? 'live' : 'off', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: C.muted)),
          ]),
        ),
      ]);

  Widget _statsRow(String ratio) {
    Widget stat(String label, String value, Color color) => Expanded(
          child: Column(children: [
            Text(value,
                style: TextStyle(
                  fontSize: 42,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -2,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                )),
            const SizedBox(height: 2),
            Text(label.toUpperCase(),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, letterSpacing: 1.6, fontWeight: FontWeight.w700, color: C.muted)),
          ]),
        );
    Widget bar() => Container(width: 1, height: 52, color: C.line);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        border: Border.symmetric(horizontal: BorderSide(color: C.line)),
      ),
      child: Row(children: [
        stat('Dilewati', '$_skipped', C.lime),
        bar(),
        stat('Tak bisa\ndilewati', '$_unskippable', C.red),
        bar(),
        stat('Rasio skip', ratio, C.text),
      ]),
    );
  }

  Widget _setupCard() {
    Widget step(String n, String t) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: C.red, letterSpacing: 1)),
            const SizedBox(width: 12),
            Expanded(child: Text(t, style: const TextStyle(fontSize: 14, color: C.text, height: 1.3))),
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: C.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Aktifkan dalam 3 langkah', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: C.text)),
        const SizedBox(height: 14),
        step('01', 'Ketuk tombol di bawah untuk membuka Aksesibilitas.'),
        step('02', 'Pilih ytskips (di "Aplikasi terinstal" / "Layanan terunduh").'),
        step('03', 'Nyalakan saklar lalu izinkan.'),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: Native.openAccessibility,
            style: FilledButton.styleFrom(
              backgroundColor: C.red,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: const Text('Buka Aksesibilitas', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Pilihan abu-abu / terkunci (Android 13+)? Buka Info Aplikasi → ⋮ → "Izinkan setelan terbatas", lalu ulangi.',
          style: TextStyle(fontSize: 12, color: C.muted, height: 1.4),
        ),
        TextButton(
          onPressed: Native.openAppInfo,
          style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 36), alignment: Alignment.centerLeft),
          child: const Text('Buka Info Aplikasi', style: TextStyle(color: C.text, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }

  Widget _sectionLabel(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(t, style: const TextStyle(fontSize: 11, letterSpacing: 2.4, fontWeight: FontWeight.w800, color: C.muted)),
      );

  Widget _tile(String title, String sub, Widget trailing, {VoidCallback? onTap}) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.line)),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: C.text)),
                    const SizedBox(height: 2),
                    Text(sub, style: const TextStyle(fontSize: 12, color: C.muted)),
                  ]),
                ),
                trailing,
              ]),
            ),
          ),
        ),
      );

  Widget _logView() {
    if (_log.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(border: Border.all(color: C.line), borderRadius: BorderRadius.circular(16)),
        child: const Text('Belum ada aktivitas. Putar video di YouTube.', style: TextStyle(color: C.muted, fontSize: 13)),
      );
    }
    String two(int v) => v.toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(border: Border.all(color: C.line), borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          for (final e in _log)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Text('${two(e.time.hour)}:${two(e.time.minute)}:${two(e.time.second)}',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: C.muted)),
                const SizedBox(width: 14),
                Container(width: 6, height: 6, decoration: BoxDecoration(color: e.color, shape: BoxShape.circle)),
                const SizedBox(width: 10),
                Text(e.label, style: const TextStyle(fontSize: 13, color: C.text, fontWeight: FontWeight.w600)),
              ]),
            ),
        ],
      ),
    );
  }
}

// ───────────────────────── dial painter ─────────────────────────
class DialPainter extends CustomPainter {
  final Animation<double> sweep;
  final Animation<double> flash;
  final bool live;
  final AdStatus status;
  final Color accent;

  DialPainter({
    required this.sweep,
    required this.flash,
    required this.live,
    required this.status,
    required this.accent,
  }) : super(repaint: Listenable.merge([sweep, flash]));

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    const n = 90;

    // ticks
    for (int i = 0; i < n; i++) {
      final a = -math.pi / 2 + i * 2 * math.pi / n;
      final major = i % 5 == 0;
      final len = major ? r * 0.09 : r * 0.055;
      final outer = r * 0.98;
      final inner = outer - len;
      double lit = 0;
      if (live) {
        if (status == AdStatus.detected || status == AdStatus.unskippable) {
          final d = (sweep.value - i / n) % 1.0;
          lit = (1 - d * 3).clamp(0.12, 1.0);
        } else if (status == AdStatus.skipped) {
          lit = (1 - flash.value).clamp(0.0, 1.0) * 0.9 + 0.12;
        } else {
          lit = 0.2;
        }
      }
      final p = Paint()
        ..color = Color.lerp(C.tickOff, accent, lit)!
        ..strokeWidth = major ? 2.6 : 1.7
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        c + Offset(math.cos(a), math.sin(a)) * inner,
        c + Offset(math.cos(a), math.sin(a)) * outer,
        p,
      );
    }

    // glow
    if (live) {
      canvas.drawCircle(
        c,
        r * 0.78,
        Paint()
          ..color = accent.withOpacity(0.16)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 28),
      );
    }

    // button body
    final br = r * 0.7;
    canvas.drawCircle(
      c + Offset(0, r * 0.05),
      br,
      Paint()
        ..color = Colors.black.withOpacity(0.7)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
    final body = Paint()
      ..shader = const RadialGradient(
        center: Alignment(-0.4, -0.5),
        radius: 1.1,
        colors: [Color(0xFF2B2926), Color(0xFF151413), Color(0xFF0C0B0A)],
        stops: [0.0, 0.6, 1.0],
      ).createShader(Rect.fromCircle(center: c, radius: br));
    canvas.drawCircle(c, br, body);
    canvas.drawCircle(
      c,
      br - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withOpacity(0.22), Colors.white.withOpacity(0.02), Colors.black.withOpacity(0.5)],
        ).createShader(Rect.fromCircle(center: c, radius: br)),
    );

    // glyph (skip icon)
    final pulse = status == AdStatus.skipped && live ? 1 + 0.14 * math.sin(flash.value * math.pi) : 1.0;
    final g = r * 0.2 * pulse;
    final color = live ? accent : C.muted;
    final gc = c + Offset(0, -r * 0.06);
    Path glyph(Offset o) {
      final tri = Path()
        ..moveTo(o.dx - g * 1.05, o.dy - g)
        ..lineTo(o.dx - g * 1.05, o.dy + g)
        ..lineTo(o.dx + g * 0.75, o.dy)
        ..close();
      final bar = Path()
        ..addRRect(RRect.fromRectAndRadius(
          Rect.fromLTWH(o.dx + g * 1.0, o.dy - g, g * 0.4, g * 2),
          Radius.circular(g * 0.2),
        ));
      return Path.combine(PathOperation.union, tri, bar);
    }

    final stroke = g * 0.28;
    // depth
    for (int i = 5; i >= 1; i--) {
      canvas.drawPath(
        glyph(gc + Offset(i * 0.5, i * 1.1)),
        Paint()
          ..color = Color.lerp(color, Colors.black, 0.7)!
          ..style = PaintingStyle.fill,
      );
    }
    final face = Paint()..color = color;
    canvas.drawPath(glyph(gc), face);
    canvas.drawPath(
      glyph(gc),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant DialPainter old) =>
      old.live != live || old.status != status || old.accent != accent;
}

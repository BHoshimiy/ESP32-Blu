import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const Esp32AlarmApp());

class Esp32AlarmApp extends StatelessWidget {
  const Esp32AlarmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 Alarm',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const deviceName = 'ESP32-Alarm';

  BluetoothConnection? _connection;
  bool _connecting = false;
  String _status = 'Ulanmagan';
  String _deviceTime = '--:--:--.---';
  String _rxBuf = '';

  // ESP32'dan oxirgi kelgan vaqt (kun boshidan mikrosekundlarda) va
  // shu paytdan beri o'tgan lokal vaqtni o'lchash uchun Stopwatch.
  // ESP32 har 1 daqiqada CT yuboradi; oraliqda ilova o'zi hisoblaydi.
  int? _baseUs;
  final Stopwatch _sw = Stopwatch();
  Timer? _ticker;
  TimeOfDay _alarmTime = TimeOfDay.now();

  final _ssidCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _secCtrl = TextEditingController(text: '0');
  final _msCtrl = TextEditingController(text: '0');
  final _delayCtrl = TextEditingController(text: '0');

  bool get _connected => _connection?.isConnected ?? false;

  // ---------- Bluetooth ----------

  Future<void> _connect() async {
    final statuses = await [
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();

    if (statuses[Permission.bluetoothConnect]?.isDenied ?? false) {
      _setStatus('Bluetooth ruxsati berilmadi');
      return;
    }

    setState(() {
      _connecting = true;
      _status = 'Ulanmoqda...';
    });

    try {
      final bonded =
          await FlutterBluetoothSerial.instance.getBondedDevices();
      final device = bonded.where((d) => d.name == deviceName).firstOrNull;

      if (device == null) {
        _setStatus(
            '$deviceName topilmadi. Avval telefon sozlamalarida pair qiling!');
        setState(() => _connecting = false);
        return;
      }

      final conn = await BluetoothConnection.toAddress(device.address);
      _connection = conn;
      _rxBuf = '';

      conn.input?.listen(_onData, onDone: () {
        _connection = null;
        _stopTicker();
        if (mounted) {
          setState(() {
            _status = 'Uzildi';
            _deviceTime = '--:--:--.---';
          });
        }
      });

      _setStatus('Ulandi ✓');
    } catch (e) {
      _setStatus('Ulanib bo\'lmadi: $e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _onData(Uint8List data) {
    _rxBuf += utf8.decode(data, allowMalformed: true);
    while (true) {
      final i = _rxBuf.indexOf('\n');
      if (i < 0) break;
      final line = _rxBuf.substring(0, i).trim();
      _rxBuf = _rxBuf.substring(i + 1);
      if (line.isNotEmpty) _handleLine(line);
    }
  }

  void _handleLine(String line) {
    if (!mounted) return;
    if (line.startsWith('CT ')) {
      final us = _parseCt(line.substring(3));
      if (us == null) {
        // Sinxronlanmagan placeholder keldi
        _stopTicker();
        setState(() => _deviceTime = '--:--:--.---');
      } else {
        // Yangi anchor: shu paytdan boshlab lokal hisoblaymiz
        _baseUs = us;
        _sw
          ..reset()
          ..start();
        _startTicker();
        setState(() => _deviceTime = _fmtUs(us));
      }
    } else {
      setState(() => _status = line);
    }
  }

  // "HH:MM:SS.mmm" -> mikrosekund (kun boshidan), xato bo'lsa null
  int? _parseCt(String s) {
    final m = RegExp(r'^(\d{2}):(\d{2}):(\d{2})\.(\d{3})$')
        .firstMatch(s.trim());
    if (m == null) return null;
    final h = int.parse(m.group(1)!);
    final min = int.parse(m.group(2)!);
    final sec = int.parse(m.group(3)!);
    final ms = int.parse(m.group(4)!);
    return ((h * 3600 + min * 60 + sec) * 1000 + ms) * 1000;
  }

  String _fmtUs(int us) {
    final total = us % 86400000000;
    final secs = total ~/ 1000000;
    final ms = (total % 1000000) ~/ 1000;
    return '${_two(secs ~/ 3600)}:${_two((secs % 3600) ~/ 60)}:${_two(secs % 60)}.${ms.toString().padLeft(3, '0')}';
  }

  void _startTicker() {
    _ticker ??= Timer.periodic(const Duration(milliseconds: 33), (_) {
      final base = _baseUs;
      if (base == null || !mounted) return;
      final now = base + _sw.elapsedMicroseconds;
      setState(() => _deviceTime = _fmtUs(now));
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
    _sw.stop();
    _baseUs = null;
  }

  void _disconnect() {
    _connection?.dispose();
    _connection = null;
    _stopTicker();
    setState(() {
      _status = 'Uzildi';
      _deviceTime = '--:--:--.---';
    });
  }

  void _sendRaw(String cmd) {
    final conn = _connection;
    if (conn == null || !conn.isConnected) {
      _setStatus('Avval ulaning');
      return;
    }
    conn.output.add(Uint8List.fromList(utf8.encode('$cmd\n')));
  }

  void _sendAlarm() {
    final sec = int.tryParse(_secCtrl.text.trim()) ?? -1;
    final ms =
        int.tryParse(_msCtrl.text.trim().isEmpty ? '0' : _msCtrl.text.trim()) ??
            -1;

    if (sec < 0 || sec > 59) {
      _setStatus('Sekund 0-59 oralig\'ida bo\'lishi kerak');
      return;
    }
    if (ms < 0 || ms > 999) {
      _setStatus('Millisekund 0-999 oralig\'ida bo\'lishi kerak');
      return;
    }

    final timeStr =
        '${_two(_alarmTime.hour)}:${_two(_alarmTime.minute)}:${_two(sec)}.${ms.toString().padLeft(3, '0')}';
    _sendRaw('A $timeStr');
    _setStatus('Alarm yuborildi: $timeStr');
  }

  void _sendStop() {
    _sendRaw('STOP');
    _setStatus('STOP yuborildi');
  }

  void _sendDelay() {
    final txt = _delayCtrl.text.trim();
    final ms = int.tryParse(txt.isEmpty ? '0' : txt) ?? -1;
    if (ms < 0 || ms > 999) {
      _setStatus('Delay 0-999 ms oralig\'ida bo\'lishi kerak');
      return;
    }
    _sendRaw('D $ms');
    _setStatus('Delay yuborildi: $ms ms');
  }

  // ---------- WiFi sahifasi ----------

  void _openWifiPage() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WifiPage(
          ssidCtrl: _ssidCtrl,
          passCtrl: _passCtrl,
          connected: _connected,
          onSaveAndSync: (ssid, pass) {
            _sendRaw('W $ssid;$pass');
            _setStatus(
                'WiFi yuborildi. ESP32 qayta ishga tushib vaqtni sinxronlaydi — 10 soniyadan keyin qayta ulaning.');
          },
          onSyncOnly: () {
            _sendRaw('SYNC');
            _setStatus(
                'Sinxronlash boshlandi. ESP32 qayta ishga tushadi — 10 soniyadan keyin qayta ulaning.');
          },
        ),
      ),
    );
  }

  // ---------- Yordamchi ----------

  String _two(int n) => n.toString().padLeft(2, '0');

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _alarmTime,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _alarmTime = picked);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _connection?.dispose();
    _ssidCtrl.dispose();
    _passCtrl.dispose();
    _secCtrl.dispose();
    _msCtrl.dispose();
    _delayCtrl.dispose();
    super.dispose();
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ESP32 Alarm'),
        actions: [
          IconButton(
            icon: const Icon(Icons.wifi),
            tooltip: 'WiFi sozlamalari',
            onPressed: _openWifiPage,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ESP32 joriy vaqti (real-time)
            Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text('ESP32 joriy vaqti',
                        style: Theme.of(context).textTheme.labelMedium),
                    const SizedBox(height: 4),
                    Text(
                      _deviceTime,
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Holat
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      _connected
                          ? Icons.bluetooth_connected
                          : Icons.bluetooth_disabled,
                      color: _connected ? Colors.blue : Colors.grey,
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(_status)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Ulanish / Uzish
            FilledButton.icon(
              onPressed: _connecting
                  ? null
                  : (_connected ? _disconnect : _connect),
              icon: Icon(_connected ? Icons.link_off : Icons.link),
              label: Text(_connecting
                  ? 'Ulanmoqda...'
                  : (_connected ? 'Uzish' : 'Ulanish')),
            ),
            const SizedBox(height: 32),

            // Alarm vaqti
            Text('Alarm vaqti:',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _pickTime,
              icon: const Icon(Icons.access_time),
              label: Text(
                '${_two(_alarmTime.hour)}:${_two(_alarmTime.minute)}',
                style: const TextStyle(fontSize: 24),
              ),
            ),
            const SizedBox(height: 12),

            // Sekund va millisekund
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _secCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Sekund (0-59)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _msCtrl,
                    keyboardType: TextInputType.number,
                    maxLength: 3,
                    decoration: const InputDecoration(
                      labelText: 'Millisekund (0-999)',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Masalan: 500 = yarim sekund',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),

            FilledButton.icon(
              onPressed: _connected ? _sendAlarm : null,
              icon: const Icon(Icons.alarm_add),
              label: const Text('Alarm yuborish'),
            ),
            const SizedBox(height: 12),

            OutlinedButton.icon(
              onPressed: _connected ? _sendStop : null,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('STOP (alarmni o\'chirish)'),
            ),
            const SizedBox(height: 24),

            // Delay kompensatsiya
            Text('Delay (kompensatsiya):',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
                    controller: _delayCtrl,
                    keyboardType: TextInputType.number,
                    maxLength: 3,
                    decoration: const InputDecoration(
                      labelText: 'Delay (0-999 ms)',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonalIcon(
                  onPressed: _connected ? _sendDelay : null,
                  icon: const Icon(Icons.speed),
                  label: const Text('Yuborish'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Alarm shuncha millisekund OLDIN ishlaydi. '
              'Masalan: 350 -> 21:29:59.890 + 0.350 >= 21:30:00.001 da signal.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

// ================= WiFi sahifasi =================

class WifiPage extends StatelessWidget {
  final TextEditingController ssidCtrl;
  final TextEditingController passCtrl;
  final bool connected;
  final void Function(String ssid, String pass) onSaveAndSync;
  final VoidCallback onSyncOnly;

  const WifiPage({
    super.key,
    required this.ssidCtrl,
    required this.passCtrl,
    required this.connected,
    required this.onSaveAndSync,
    required this.onSyncOnly,
  });

  void _save(BuildContext context) {
    final ssid = ssidCtrl.text.trim();
    final pass = passCtrl.text.trim();
    if (ssid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('WiFi nomini kiriting')));
      return;
    }
    if (ssid.contains(';')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('WiFi nomida ";" belgisi bo\'lmasligi kerak')));
      return;
    }
    onSaveAndSync(ssid, pass);
    Navigator.of(context).pop();
  }

  void _sync(BuildContext context) {
    onSyncOnly();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WiFi sozlamalari')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!connected)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                      'Bluetooth ulanmagan! Avval asosiy sahifada ESP32 ga ulaning.'),
                ),
              ),
            if (!connected) const SizedBox(height: 16),

            Text('WiFi orqali vaqt sinxronlash',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'ESP32 shu WiFi orqali time.uzex.uz serveridan aniq vaqtni olib, '
              'xotirasiga saqlaydi va shu vaqtdan hisoblashda foydalanadi. '
              'WiFi ma\'lumotlari ESP32 xotirasida saqlanadi — keyingi safar '
              'faqat "Qayta sinxronlash" ni bossangiz kifoya.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),

            TextField(
              controller: ssidCtrl,
              decoration: const InputDecoration(
                labelText: 'WiFi nomi (SSID)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.wifi),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'WiFi paroli',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
            const SizedBox(height: 16),

            FilledButton.icon(
              onPressed: connected ? () => _save(context) : null,
              icon: const Icon(Icons.sync),
              label: const Text('Saqlash va vaqtni sinxronlash'),
            ),
            const SizedBox(height: 12),

            OutlinedButton.icon(
              onPressed: connected ? () => _sync(context) : null,
              icon: const Icon(Icons.refresh),
              label: const Text('Qayta sinxronlash (saqlangan WiFi bilan)'),
            ),
            const SizedBox(height: 16),

            Text(
              'Eslatma: sinxronlashda ESP32 qayta ishga tushadi va Bluetooth '
              'aloqasi uziladi. ~10 soniyadan keyin asosiy sahifadan qayta ulaning.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

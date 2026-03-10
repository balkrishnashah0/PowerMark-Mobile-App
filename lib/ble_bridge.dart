import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// BLE UUIDs — must match ESP32 firmware
// ─────────────────────────────────────────────────────────────────────────────
const _svcUuid   = '00001234-0000-1000-8000-00805f9b34fb';
const _pinUuid   = '0000abcd-0000-1000-8000-00805f9b34fb';
const _wifiUuid  = '0000ef01-0000-1000-8000-00805f9b34fb';
const _scanUuid  = '0000ef02-0000-1000-8000-00805f9b34fb';
const _ssidsUuid = '0000ef03-0000-1000-8000-00805f9b34fb';
const _respUuid  = '0000ef05-0000-1000-8000-00805f9b34fb';

// ─────────────────────────────────────────────────────────────────────────────
// BleBridge
//
// Wire-up in your State.initState():
//   _bleBridge = BleBridge(controller: _controller);
//
// Add the JS channel when building WebViewController:
//   ..addJavaScriptChannel('BleChannel',
//       onMessageReceived: (msg) => _bleBridge.handleMessage(msg.message))
//
// Dispose in State.dispose():
//   _bleBridge.dispose();
// ─────────────────────────────────────────────────────────────────────────────
class BleBridge {
  final WebViewController controller;

  BluetoothDevice?          _device;
  BluetoothCharacteristic?  _pinChar;
  BluetoothCharacteristic?  _wifiChar;
  BluetoothCharacteristic?  _scanChar;
  BluetoothCharacteristic?  _ssidsChar;
  BluetoothCharacteristic?  _respChar;

  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>?                _ssidSub;
  StreamSubscription<List<int>>?                _respSub;

  BleBridge({required this.controller});

  // ── Entry point called by the BleChannel JS channel ───────────────────────
  void handleMessage(String jsonStr) {
    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      switch (data['cmd'] as String? ?? '') {
        case 'CHECK_BT':  _checkBluetooth();                              break;
        case 'CONNECT':   _connect();                                     break;
        case 'WRITE_PIN': _writePin(data['pin'] as String? ?? '');        break;
        case 'SCAN_WIFI': _scanWifi();                                    break;
        case 'SEND_WIFI':
          _sendWifi(data['ssid'] as String? ?? '', data['pass'] as String? ?? '');
          break;
      }
    } catch (e) {
      debugPrint('[BleBridge] handleMessage error: $e');
    }
  }

  // ── Post an event back to JavaScript ──────────────────────────────────────
  Future<void> _jsEvent(String event, [Map<String, dynamic>? extra]) async {
    final payload = <String, dynamic>{'event': event, ...?extra};
    // Double-encode: Flutter passes a String to JS, JS does JSON.parse on it.
    final js =
        'if(window._ble&&window._ble.onEvent)window._ble.onEvent(${jsonEncode(jsonEncode(payload))})';
    try {
      await controller.runJavaScript(js);
    } catch (e) {
      debugPrint('[BleBridge] runJavaScript error: $e');
    }
  }

  // ── CHECK_BT ──────────────────────────────────────────────────────────────
  // Android: requests permissions first (avoids Android 12 crash), then calls
  //          FlutterBluePlus.turnOn() which shows the OS "Turn on Bluetooth?"
  //          system dialog.
  // iOS:     cannot turn BT on programmatically — instructs user to use
  //          Control Centre.
  Future<void> _checkBluetooth() async {
    if (Platform.isAndroid) {
      // MUST request BLUETOOTH_CONNECT before calling turnOn() — otherwise
      // Android 12 crashes with a SecurityException.
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();

      if (statuses.values.any((s) => s == PermissionStatus.permanentlyDenied)) {
        await _jsEvent('BT_UNAVAILABLE', {
          'reason':
              'Bluetooth permission permanently denied. '
              'Go to Android Settings → Apps → [this app] → Permissions and enable Bluetooth.',
        });
        return;
      }
      if (statuses.values.any((s) => s == PermissionStatus.denied)) {
        await _jsEvent('BT_UNAVAILABLE', {
          'reason': 'Bluetooth permission denied. Please allow it and try again.',
        });
        return;
      }
    }

    final state = await FlutterBluePlus.adapterState.first;

    if (state == BluetoothAdapterState.on) {
      await _jsEvent('BT_AVAILABLE');
      return;
    }

    // Adapter is off — try to turn it on.
    if (Platform.isAndroid) {
      try {
        // Shows Android system dialog: "Allow app to turn on Bluetooth?"
        await FlutterBluePlus.turnOn();

        // Wait (up to 10 s) for adapter to finish turning on.
        final next = await FlutterBluePlus.adapterState
            .where((s) => s != BluetoothAdapterState.turningOn)
            .first
            .timeout(const Duration(seconds: 10));

        if (next == BluetoothAdapterState.on) {
          await _jsEvent('BT_AVAILABLE');
        } else {
          await _jsEvent('BT_UNAVAILABLE', {
            'reason': 'Bluetooth was not enabled. Please turn it on and try again.',
          });
        }
      } catch (e) {
        await _jsEvent('BT_UNAVAILABLE', {'reason': e.toString()});
      }
    } else {
      // iOS — no API to enable BT programmatically.
      await _jsEvent('BT_UNAVAILABLE', {
        'reason': 'Bluetooth is off. Please enable it in Control Centre and try again.',
      });
    }
  }

  // ── CONNECT ───────────────────────────────────────────────────────────────
  // NOTE: Android has NO native BLE device-picker dialog (unlike Web Bluetooth
  // or iOS). We scan silently and connect directly by device name. For a single
  // provisioning target ('ESP32_Config') this is the correct approach.
  Future<void> _connect() async {
    await _jsEvent('CONNECTING');

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      await _jsEvent('CONNECT_FAILED',
          {'reason': 'Bluetooth is off. Please enable it first.'});
      return;
    }

    try {
      final completer = Completer<BluetoothDevice?>();

      final scanSub = FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
          // advName is the reliable field in flutter_blue_plus 1.x+
          final name = r.advertisementData.advName.isNotEmpty
              ? r.advertisementData.advName
              : r.device.platformName;
          if (name == 'ESP32_Config' && !completer.isCompleted) {
            completer.complete(r.device);
          }
        }
      });

      await FlutterBluePlus.startScan(
        withNames: ['ESP32_Config'],
        timeout: const Duration(seconds: 10),
      );

      BluetoothDevice? found;
      try {
        found = await completer.future.timeout(const Duration(seconds: 11));
      } on TimeoutException {
        found = null;
      }

      await scanSub.cancel();
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();

      if (found == null) {
        await _jsEvent('CONNECT_FAILED', {
          'reason':
              'ESP32_Config not found nearby. '
              'Make sure the ESP32 is powered and in BLE provisioning mode.',
        });
        return;
      }

      _device = found;
      await _device!.connect(autoConnect: false);

      _connSub = _device!.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          _cleanupSubscriptions();
          _jsEvent('DISCONNECTED');
        }
      });

      final services = await _device!.discoverServices();
      final svc = services.firstWhere(
        (s) => s.uuid.toString().toLowerCase() == _svcUuid,
        orElse: () => throw Exception(
            'BLE service $_svcUuid not found. Check ESP32 firmware UUIDs.'),
      );

      _pinChar   = _findChar(svc, _pinUuid);
      _wifiChar  = _findChar(svc, _wifiUuid);
      _scanChar  = _findChar(svc, _scanUuid);
      _ssidsChar = _findChar(svc, _ssidsUuid);

      if (_ssidsChar != null) {
        await _ssidsChar!.setNotifyValue(true);
        _ssidSub = _ssidsChar!.onValueReceived.listen(_onSsidList);
      }

      try {
        _respChar = _findChar(svc, _respUuid);
        if (_respChar != null) {
          await _respChar!.setNotifyValue(true);
          _respSub = _respChar!.onValueReceived.listen(_onResponse);
        }
      } catch (_) {
        _respChar = null;
      }

      await _jsEvent('CONNECTED');
    } catch (e) {
      await _jsEvent('CONNECT_FAILED', {'reason': e.toString()});
    }
  }

  // ── WRITE_PIN ─────────────────────────────────────────────────────────────
  Future<void> _writePin(String pin) async {
    if (_pinChar == null) {
      await _jsEvent('PIN_ERROR', {'reason': 'Not connected'});
      return;
    }
    try {
      await _pinChar!.write(pin.codeUnits, withoutResponse: false);
      if (_respChar == null) {
        // Older firmware with no response char — optimistic proceed
        await _jsEvent('PIN_SENT');
      }
      // else PIN_OK / PIN_FAIL arrives via _onResponse
    } catch (e) {
      await _jsEvent('PIN_ERROR', {'reason': e.toString()});
    }
  }

  // ── SCAN_WIFI ─────────────────────────────────────────────────────────────
  Future<void> _scanWifi() async {
    if (_scanChar == null) {
      await _jsEvent('SCAN_ERROR', {'reason': 'Not connected'});
      return;
    }
    try {
      await _scanChar!.write('scan'.codeUnits, withoutResponse: false);
      await _jsEvent('SCAN_STARTED');
    } catch (e) {
      await _jsEvent('SCAN_ERROR', {'reason': e.toString()});
    }
  }

  // ── SEND_WIFI ─────────────────────────────────────────────────────────────
  Future<void> _sendWifi(String ssid, String pass) async {
    if (_wifiChar == null) {
      await _jsEvent('WIFI_ERROR', {'reason': 'Not connected'});
      return;
    }
    try {
      await _wifiChar!.write('$ssid|$pass'.codeUnits, withoutResponse: false);
      if (_respChar == null) {
        await _jsEvent('WIFI_SAVED');
      }
      // else WIFI_SAVED / WIFI_FAIL arrives via _onResponse
    } catch (e) {
      await _jsEvent('WIFI_ERROR', {'reason': e.toString()});
    }
  }

  // ── BLE notification handlers ─────────────────────────────────────────────
  void _onResponse(List<int> value) {
    switch (String.fromCharCodes(value).trim()) {
      case 'PIN_OK':     _jsEvent('PIN_OK');     break;
      case 'PIN_FAIL':   _jsEvent('PIN_FAIL');   break;
      case 'WIFI_SAVED': _jsEvent('WIFI_SAVED'); break;
      case 'WIFI_FAIL':  _jsEvent('WIFI_FAIL');  break;
    }
  }

  void _onSsidList(List<int> value) {
    final ssids = String.fromCharCodes(value)
        .split('|')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    _jsEvent('SSID_LIST', {'ssids': ssids});
  }

  // ── Internal helpers ──────────────────────────────────────────────────────
  BluetoothCharacteristic? _findChar(BluetoothService svc, String uuid) {
    try {
      return svc.characteristics
          .firstWhere((c) => c.uuid.toString().toLowerCase() == uuid);
    } catch (_) {
      return null;
    }
  }

  void _cleanupSubscriptions() {
    _ssidSub?.cancel(); _ssidSub = null;
    _respSub?.cancel(); _respSub = null;
    _connSub?.cancel(); _connSub = null;
    _pinChar = _wifiChar = _scanChar = _ssidsChar = _respChar = null;
  }

  Future<void> dispose() async {
    _cleanupSubscriptions();
    try { await _device?.disconnect(); } catch (_) {}
    _device = null;
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// BLE UUIDs — same values as ESP32 firmware.
//
// IMPORTANT: Android shortens UUIDs that follow the Bluetooth base-UUID pattern
//   (0000xxxx-0000-1000-8000-00805f9b34fb) to just the 4-hex "xxxx" short form.
//   flutter_blue_plus exposes them that way too, so DO NOT compare full 128-bit
//   strings.  Use Guid() for comparison — it normalises both forms correctly.
// ─────────────────────────────────────────────────────────────────────────────
final _svcGuid   = Guid('00001234-0000-1000-8000-00805f9b34fb');
final _pinGuid   = Guid('0000abcd-0000-1000-8000-00805f9b34fb');
final _wifiGuid  = Guid('0000ef01-0000-1000-8000-00805f9b34fb');
final _scanGuid  = Guid('0000ef02-0000-1000-8000-00805f9b34fb');
final _ssidsGuid = Guid('0000ef03-0000-1000-8000-00805f9b34fb');
final _respGuid  = Guid('0000ef05-0000-1000-8000-00805f9b34fb');

// ─────────────────────────────────────────────────────────────────────────────
// BleBridge
//
// 1. In State.initState(), after building WebViewController:
//      _bleBridge = BleBridge(controller: _controller);
//
// 2. Add JS channel to WebViewController:
//      ..addJavaScriptChannel('BleChannel',
//          onMessageReceived: (msg) => _bleBridge.handleMessage(msg.message))
//
// 3. In State.dispose():
//      _bleBridge.dispose();
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

  // ── Entry point from JS channel ───────────────────────────────────────────
  void handleMessage(String jsonStr) {
    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      switch (data['cmd'] as String? ?? '') {
        case 'CHECK_BT':  _checkBluetooth();                                    break;
        case 'CONNECT':   _connect();                                           break;
        case 'WRITE_PIN': _writePin(data['pin']  as String? ?? '');             break;
        case 'SCAN_WIFI': _scanWifi();                                          break;
        case 'SEND_WIFI': _sendWifi(data['ssid'] as String? ?? '',
                                    data['pass'] as String? ?? '');             break;
      }
    } catch (e) {
      debugPrint('[BleBridge] handleMessage error: $e');
    }
  }

  // ── Post an event back to JS ───────────────────────────────────────────────
  Future<void> _jsEvent(String event, [Map<String, dynamic>? extra]) async {
    final payload = <String, dynamic>{'event': event, ...?extra};
    final js =
        'if(window._ble&&window._ble.onEvent)window._ble.onEvent(${jsonEncode(jsonEncode(payload))})';
    try {
      await controller.runJavaScript(js);
    } catch (e) {
      debugPrint('[BleBridge] runJavaScript error: $e');
    }
  }

  // ── CHECK_BT ──────────────────────────────────────────────────────────────
  Future<void> _checkBluetooth() async {
    if (Platform.isAndroid) {
      final granted = await _requestAndroidPermissions();
      if (!granted) return;
    }

    final state = await FlutterBluePlus.adapterState.first;
    if (state == BluetoothAdapterState.on) {
      await _jsEvent('BT_AVAILABLE');
      return;
    }

    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
        final next = await FlutterBluePlus.adapterState
            .where((s) => s != BluetoothAdapterState.turningOn)
            .first
            .timeout(const Duration(seconds: 10));
        await _jsEvent(
          next == BluetoothAdapterState.on ? 'BT_AVAILABLE' : 'BT_UNAVAILABLE',
          next != BluetoothAdapterState.on
              ? {'reason': 'Bluetooth was not enabled. Please turn it on and try again.'}
              : null,
        );
      } catch (e) {
        await _jsEvent('BT_UNAVAILABLE', {'reason': e.toString()});
      }
    } else {
      await _jsEvent('BT_UNAVAILABLE', {
        'reason': 'Bluetooth is off. Please enable it in Control Centre and try again.',
      });
    }
  }

  // ── Android version-aware permission request ──────────────────────────────
  Future<bool> _requestAndroidPermissions() async {
    int sdk = 31;
    try {
      sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
    } catch (_) {}

    final Map<Permission, PermissionStatus> statuses;
    if (sdk >= 31) {
      // Android 12+ — BLUETOOTH_SCAN + BLUETOOTH_CONNECT (no location needed)
      statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();
    } else {
      // Android 11 and below — legacy BLUETOOTH + location
      statuses = await [
        Permission.bluetooth,
        Permission.locationWhenInUse,
      ].request();
    }

    if (statuses.values.any((s) => s == PermissionStatus.permanentlyDenied)) {
      await _jsEvent('BT_UNAVAILABLE', {
        'reason':
            'Bluetooth permission permanently denied. '
            'Go to Settings → Apps → [this app] → Permissions and enable it.',
      });
      return false;
    }
    if (statuses.values.any((s) => s == PermissionStatus.denied)) {
      await _jsEvent('BT_UNAVAILABLE', {
        'reason': 'Bluetooth permission denied. Please allow it and try again.',
      });
      return false;
    }
    return true;
  }

  // ── CONNECT ───────────────────────────────────────────────────────────────
  Future<void> _connect() async {
    await _jsEvent('CONNECTING');

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      await _jsEvent('CONNECT_FAILED',
          {'reason': 'Bluetooth is off. Please enable it first.'});
      return;
    }

    try {
      // ── Scan for ESP32_Config ──────────────────────────────────────────────
      final completer = Completer<BluetoothDevice?>();

      final scanSub = FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
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
              'Make sure the ESP32 is powered and in provisioning mode.',
        });
        return;
      }

      _device = found;

      // ── Connect ───────────────────────────────────────────────────────────
      await _device!.connect(autoConnect: false);

      _connSub = _device!.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          _cleanupSubscriptions();
          _jsEvent('DISCONNECTED');
        }
      });

    
      final services = await _device!.discoverServices();

      // Debug: log every discovered service UUID so you can verify in console
      debugPrint('[BleBridge] Discovered ${services.length} services:');
      for (final s in services) {
        debugPrint('  SVC: ${s.uuid}');
        for (final c in s.characteristics) {
          debugPrint('    CHAR: ${c.uuid}');
        }
      }

      BluetoothService? svc;
      for (final s in services) {
        if (s.uuid == _svcGuid) { svc = s; break; }
      }

      if (svc == null) {
        // Fallback: try matching by short UUID string "1234"
        for (final s in services) {
          if (s.uuid.toString().toLowerCase() == '1234') { svc = s; break; }
        }
      }

      if (svc == null) {
        await _device!.disconnect();
        await _jsEvent('CONNECT_FAILED', {
          'reason':
              'BLE service not found on ESP32. '
              'Check the ESP32 is in provisioning mode (hold BOOT 3s). '
              'Expected service: 0x1234',
        });
        return;
      }

      _pinChar   = _findChar(svc, _pinGuid);
      _wifiChar  = _findChar(svc, _wifiGuid);
      _scanChar  = _findChar(svc, _scanGuid);
      _ssidsChar = _findChar(svc, _ssidsGuid);

      if (_ssidsChar != null) {
        await _ssidsChar!.setNotifyValue(true);
        _ssidSub = _ssidsChar!.onValueReceived.listen(_onSsidList);
      }

      try {
        _respChar = _findChar(svc, _respGuid);
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
      if (_respChar == null) await _jsEvent('PIN_SENT');
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
      if (_respChar == null) await _jsEvent('WIFI_SAVED');
      // else WIFI_SAVED / WIFI_FAIL comes via _onResponse
    } catch (e) {
      await _jsEvent('WIFI_ERROR', {'reason': e.toString()});
    }
  }

  // ── BLE notification callbacks ────────────────────────────────────────────
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



  // Use Guid == comparison, never string matching
  BluetoothCharacteristic? _findChar(BluetoothService svc, Guid guid) {
    for (final c in svc.characteristics) {
      if (c.uuid == guid) return c;
    }
    return null;
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

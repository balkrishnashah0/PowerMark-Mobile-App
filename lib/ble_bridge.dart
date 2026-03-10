import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
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
// BleBridge — delegates BLE ops from WebView JS to native flutter_blue_plus
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
      if (!granted) return; // _requestAndroidPermissions already fired jsEvent
    }

    final state = await FlutterBluePlus.adapterState.first;
    if (state == BluetoothAdapterState.on) {
      await _jsEvent('BT_AVAILABLE');
      return;
    }

    if (Platform.isAndroid) {
      // Shows native Android "Allow app to turn on Bluetooth?" dialog
      try {
        await FlutterBluePlus.turnOn();
        final next = await FlutterBluePlus.adapterState
            .where((s) => s != BluetoothAdapterState.turningOn)
            .first
            .timeout(const Duration(seconds: 10));
        if (next == BluetoothAdapterState.on) {
          await _jsEvent('BT_AVAILABLE');
        } else {
          await _jsEvent('BT_UNAVAILABLE',
              {'reason': 'Bluetooth was not enabled. Please turn it on and try again.'});
        }
      } catch (e) {
        await _jsEvent('BT_UNAVAILABLE', {'reason': e.toString()});
      }
    } else {
      await _jsEvent('BT_UNAVAILABLE', {
        'reason': 'Bluetooth is off. Please enable it in Control Centre and try again.',
      });
    }
  }

  // ── Android permission request — version-aware ────────────────────────────
  // Android 12+ (API 31+) uses BLUETOOTH_SCAN + BLUETOOTH_CONNECT.
  // Android 11 and below uses the legacy BLUETOOTH permission + location.
  // permission_handler returns "denied" for permissions that don't exist on
  // the running OS — so we must branch by SDK version, not just request all.
  Future<bool> _requestAndroidPermissions() async {
    final sdkInt = await _androidSdkVersion();

    late Map<Permission, PermissionStatus> statuses;

    if (sdkInt >= 31) {
      // Android 12+ — new granular BT permissions (no location needed for BLE)
      statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();
    } else {
      // Android 11 and below — legacy BT permission + location required for scan
      statuses = await [
        Permission.bluetooth,
        Permission.locationWhenInUse,
      ].request();
    }

    final permanentlyDenied =
        statuses.values.any((s) => s == PermissionStatus.permanentlyDenied);
    final denied =
        statuses.values.any((s) => s == PermissionStatus.denied);

    if (permanentlyDenied) {
      await _jsEvent('BT_UNAVAILABLE', {
        'reason':
            'Bluetooth permission permanently denied. '
            'Go to Settings → Apps → [this app] → Permissions and enable it.',
      });
      return false;
    }
    if (denied) {
      await _jsEvent('BT_UNAVAILABLE', {
        'reason': 'Bluetooth permission denied. Please allow it and try again.',
      });
      return false;
    }
    return true;
  }

  Future<int> _androidSdkVersion() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.version.sdkInt;
    } catch (_) {
      return 31; // safe default — assume modern if lookup fails
    }
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
            'BLE service $_svcUuid not found. Check ESP32 firmware.'),
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
      if (_respChar == null) await _jsEvent('PIN_SENT');
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

  // ── Helpers ───────────────────────────────────────────────────────────────
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

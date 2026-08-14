import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

final printerServiceProvider = Provider((ref) => PrinterService());

/// Thrown by [PrinterService] when Bluetooth permission is missing.
/// [permanentlyDenied] means Android will never show the system prompt again
/// for this app — the only way forward is [PrinterService.openSettings].
class BluetoothPermissionDeniedException implements Exception {
  final String message;
  final bool permanentlyDenied;
  const BluetoothPermissionDeniedException(this.message, {this.permanentlyDenied = false});
  @override
  String toString() => message;
}

/// Classic Bluetooth (SPP) thermal printer transport.
///
/// Most cheap ESC/POS receipt/thermal printers only speak classic Bluetooth
/// Serial Port Profile, not BLE — a BLE GATT connect attempt to them fails
/// immediately with CONNECTION_FAILED_ESTABLISHMENT. This talks RFCOMM
/// instead, which is what these printers actually expect.
class PrinterService {
  /// Already-paired printers (Settings > Bluetooth). Classic SPP devices
  /// aren't discovered via an active scan here — Android just lists devices
  /// already bonded to the system, which is all we need since printers must
  /// be paired via system Bluetooth settings first anyway.
  Future<List<BluetoothInfo>> pairedDevices() async {
    await _ensurePermission();
    return PrintBluetoothThermal.pairedBluetooths;
  }

  Future<bool> isConnected() => PrintBluetoothThermal.connectionStatus;

  Future<bool> connect(String macAddress) async {
    await _ensurePermission();
    return PrintBluetoothThermal.connect(macPrinterAddress: macAddress);
  }

  /// Dio's byte responses are typically `Uint8List`, which Flutter's platform
  /// channel codec encodes as a native `byte[]` — but the plugin's Android
  /// side expects `call.arguments as List<Int>` (an ArrayList) and throws a
  /// ClassCastException otherwise. Converting to a plain growable List<int>
  /// here forces the codec to encode it the way the plugin expects.
  Future<bool> printBytes(List<int> bytes) =>
      PrintBluetoothThermal.writeBytes(List<int>.from(bytes));

  Future<void> disconnect() => PrintBluetoothThermal.disconnect;

  /// Opens the app's system settings page so the user can grant a
  /// permanently-denied permission manually — Android won't show its own
  /// request dialog again once a permission has been denied that way.
  Future<void> openSettings() => openAppSettings();

  static const _needed = [Permission.bluetoothConnect, Permission.bluetoothScan];

  /// Android 12+ requires both "Nearby devices" runtime permissions:
  /// - BLUETOOTH_CONNECT for connecting/writing to a bonded device
  /// - BLUETOOTH_SCAN for BluetoothAdapter.cancelDiscovery(), which the
  ///   plugin's connect() calls internally as a safety step before opening
  ///   the RFCOMM socket, even though we never actively scan ourselves
  /// Without these, print_bluetooth_thermal's native side doesn't throw —
  /// it silently returns without resolving the platform call — so this must
  /// succeed before any other call on this class.
  ///
  /// If a permission was already permanently denied (e.g. the user denied it
  /// on an earlier attempt), Android will never show the request dialog
  /// again — `.request()` just silently resolves as denied with no UI. We
  /// detect that case up front and point the caller at Settings instead of
  /// requesting again.
  Future<void> _ensurePermission() async {
    final alreadyPermanentlyDenied = <Permission>[];
    final toRequest = <Permission>[];
    for (final p in _needed) {
      if (await p.isPermanentlyDenied) {
        alreadyPermanentlyDenied.add(p);
      } else if (!await p.isGranted) {
        toRequest.add(p);
      }
    }

    if (toRequest.isNotEmpty) {
      await toRequest.request();
    }

    final stillMissing = <Permission>[];
    var permanentlyDenied = alreadyPermanentlyDenied.isNotEmpty;
    for (final p in _needed) {
      if (!await p.isGranted) {
        stillMissing.add(p);
        if (await p.isPermanentlyDenied) permanentlyDenied = true;
      }
    }

    if (stillMissing.isNotEmpty) {
      if (permanentlyDenied) {
        throw const BluetoothPermissionDeniedException(
          'Bluetooth permission was permanently denied, so Android won\'t '
          'show the request prompt again. Tap below to open Settings and '
          'enable "Nearby devices" for this app manually.',
          permanentlyDenied: true,
        );
      }
      throw const BluetoothPermissionDeniedException(
        'Bluetooth permission denied. Enable "Nearby devices" for this app '
        'to use the printer.',
      );
    }
  }
}

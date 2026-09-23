import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import '../network/api_client.dart';
import 'printer_service.dart';

/// Bottom sheet listing paired Bluetooth printers, shared by every thermal
/// print flow (order/return/damage — both post-submit and reprint).
class PrinterPickerSheet extends StatelessWidget {
  final List<BluetoothInfo> devices;
  const PrinterPickerSheet({super.key, required this.devices});

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Select Printer',
                  style: Theme.of(context).textTheme.titleMedium)),
          if (devices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                  'No paired printers found — pair one in system Bluetooth settings first'),
            )
          else
            ...devices.map((d) => ListTile(
                  leading: const Icon(Icons.print_outlined),
                  title: Text(d.name.isEmpty ? 'Unknown device' : d.name),
                  subtitle: Text(d.macAdress, style: const TextStyle(fontSize: 11)),
                  onTap: () => Navigator.pop(context, d),
                )),
          const SizedBox(height: 16),
        ],
      );
}

/// Fetches the thermal ESC/POS bytes for [path] and sends them to a paired
/// Bluetooth printer, prompting for one via [PrinterPickerSheet] when
/// [printer] is null. Returns the connected printer (or null on failure/
/// cancellation) so callers can reuse it for a following print without
/// re-prompting.
Future<BluetoothInfo?> printThermalReceipt({
  required BuildContext context,
  required WidgetRef ref,
  required String path,
  BluetoothInfo? printer,
}) async {
  try {
    final dio = ref.read(dioProvider);
    final resp = await dio.get(path,
        options: Options(responseType: ResponseType.bytes));
    final bytes = resp.data as List<int>;

    final printerSvc = ref.read(printerServiceProvider);
    var selected = printer;
    if (selected == null) {
      final devices = await printerSvc.pairedDevices();
      if (!context.mounted) return null;
      selected = await showModalBottomSheet<BluetoothInfo>(
        context: context,
        builder: (_) => PrinterPickerSheet(devices: devices),
      );
    }
    if (selected == null) return null;

    try {
      await printerSvc.disconnect();
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 400));

    final connected = await printerSvc.connect(selected.macAdress);
    if (!connected) throw Exception('Could not connect to ${selected.name}');
    await Future.delayed(const Duration(milliseconds: 500));

    final sent = await printerSvc.printBytes(bytes);
    if (!sent) throw Exception('Printer did not accept the print job');
    return selected;
  } catch (e) {
    if (context.mounted) {
      if (e is BluetoothPermissionDeniedException) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.message),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 8),
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Print failed: $e'), backgroundColor: Colors.red));
      }
    }
    return null;
  }
}

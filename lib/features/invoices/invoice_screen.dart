import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import '../../app/colors.dart';
import '../../core/bluetooth/printer_service.dart';
import '../../core/network/api_client.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/status_badge.dart';
import '../../utils/formatters.dart';
import 'invoice_print_preview_screen.dart';

final _invoiceProvider = FutureProvider.family<Map<String, dynamic>, String>((ref, id) async {
  final dio = ref.read(dioProvider);
  final resp = await dio.get('/invoices/$id');
  return resp.data as Map<String, dynamic>;
});

class InvoiceScreen extends ConsumerStatefulWidget {
  final String id;
  const InvoiceScreen({super.key, required this.id});
  @override
  ConsumerState<InvoiceScreen> createState() => _InvoiceScreenState();
}

class _InvoiceScreenState extends ConsumerState<InvoiceScreen> {
  bool _printing = false;
  BluetoothInfo? _printer;

  Future<void> _selectAndPrint(Map<String, dynamic> invoice) async {
    setState(() => _printing = true);
    try {
      final dio = ref.read(dioProvider);
      final thermalResp = await dio.get('/invoices/${widget.id}/thermal',
          options: Options(responseType: ResponseType.bytes));
      final bytes = thermalResp.data as List<int>;

      final printerSvc = ref.read(printerServiceProvider);
      if (_printer == null) {
        final devices = await printerSvc.pairedDevices();
        if (!mounted) return;
        _printer = await showModalBottomSheet<BluetoothInfo>(
          context: context,
          builder: (_) => _PrinterPicker(devices: devices),
        );
      }
      if (_printer == null) return;

      // This device's Bluetooth stack refuses a fresh connect() outright
      // (returns false) if a prior socket wasn't explicitly released first,
      // so disconnect() is required — but calling connect() immediately
      // after raced the OS's own socket teardown and left the link dead
      // right after reporting "connected". Give the disconnect a moment to
      // actually settle before reconnecting.
      try { await printerSvc.disconnect(); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 400));

      final connected = await printerSvc.connect(_printer!.macAdress);
      if (!connected) throw Exception('Could not connect to ${_printer!.name}');
      await Future.delayed(const Duration(milliseconds: 500));

      final sent = await printerSvc.printBytes(bytes);
      if (!sent) throw Exception('Printer did not accept the print job');

      if (mounted) await _showPrintedDialog(invoice);
    } catch (e) {
      _printer = null; // stale/unreachable — re-show the picker next attempt
      if (mounted) {
        if (e is BluetoothPermissionDeniedException && e.permanentlyDenied) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.message),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 8),
            action: SnackBarAction(
              label: 'Open Settings',
              textColor: Colors.white,
              onPressed: () => ref.read(printerServiceProvider).openSettings(),
            ),
          ));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Print failed: $e'), backgroundColor: Colors.red));
        }
      }
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  // A dialog (rather than a snackbar) so "Print Again" doesn't disappear
  // before the user has a chance to tap it.
  Future<void> _showPrintedDialog(Map<String, dynamic> invoice) => showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.check_circle_rounded, color: Colors.green.shade500, size: 48),
          title: const Text('Printed Successfully', textAlign: TextAlign.center),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _selectAndPrint(invoice);
              },
              icon: const Icon(Icons.print_outlined, size: 18),
              label: const Text('Print Again'),
            ),
          ],
        ),
      );

  void _openPreview(Map<String, dynamic> invoice) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => InvoicePrintPreviewScreen(invoice: invoice),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_invoiceProvider(widget.id));
    return Scaffold(
      appBar: AppBar(title: const Text('Invoice')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error:   (e, _) => Center(child: Text('Error: $e')),
        data:    (inv) => _Body(invoice: inv),
      ),
      bottomNavigationBar: async.valueOrNull != null ? Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _openPreview(async.value!),
              icon: const Icon(Icons.preview_outlined),
              label: const Text('Preview PDF'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _printing ? null : () => _selectAndPrint(async.value!),
              icon: _printing
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.print_outlined),
              label: Text(_printing ? 'Printing...' : 'Print (Bluetooth)'),
            ),
          ),
        ]),
      ) : null,
    );
  }
}

class _Body extends StatelessWidget {
  final Map<String, dynamic> invoice;
  const _Body({required this.invoice});
  @override
  Widget build(BuildContext context) {
    final items = ((invoice['order'] as Map?)?['items'] as List?) ?? const [];
    final taxedItem = items.cast<Map<String, dynamic>>().where(
        (i) => ((i['taxPct'] as num?) ?? 0) > 0).firstOrNull;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(invoice['invoiceNumber'] as String? ?? '',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
            StatusBadge(label: invoice['status'] as String? ?? '', tone: _statusTone(invoice['status'] as String?)),
          ]),
          const SizedBox(height: 16),
          _InfoRow('Customer',  (invoice['customer'] as Map?)?['name'] as String? ?? ''),
          if ((invoice['customer'] as Map?)?['creditDays'] != null)
            _InfoRow('Credit Days',
                '${(invoice['customer'] as Map)['creditDays']} days'),
          if (((invoice['order'] as Map?)?['poNumber'] as String?)?.isNotEmpty == true)
            _InfoRow('PO Number', (invoice['order'] as Map)['poNumber'] as String),
          ..._buildDeliveryAddress(invoice),
          _InfoRow('Date',      invoice['issuedDate'] as String? ?? ''),
          _InfoRow('Due',       invoice['dueDate'] as String? ?? ''),
          const Divider(height: 20),
          _InfoRow('Subtotal',  'LKR ${formatAmount((invoice['subtotal'] as num?) ?? 0)}'),
          if (((invoice['discountTotal'] as num?) ?? 0) > 0) ...[
            _InfoRow('Discount', 'LKR ${formatAmount(-(((invoice['discountTotal'] as num?) ?? 0)))}'),
            // Amount tax is actually calculated on — makes it explicit that tax
            // applies after the discount, not on the pre-discount subtotal.
            _InfoRow('Net Amount',
                'LKR ${formatAmount(((invoice['subtotal'] as num?) ?? 0) - ((invoice['discountTotal'] as num?) ?? 0))}'),
          ],
          _InfoRow(
              taxedItem != null
                  ? 'Tax (${((taxedItem['taxPct'] as num).toDouble()).toStringAsFixed(0)}%)'
                  : 'Tax',
              'LKR ${formatAmount((invoice['taxTotal'] as num?) ?? 0)}'),
          const SizedBox(height: 4),
          _InfoRow('Total',     'LKR ${formatAmount((invoice['total'] as num?) ?? 0)}', bold: true),
          ..._buildSignatures(invoice),
        ])),
      ],
    );
  }

  static AppTone _statusTone(String? status) => switch (status) {
    'PAID'      => AppTone.mint,
    'CANCELLED' => AppTone.pink,
    _           => AppTone.sky,
  };

  List<Widget> _buildDeliveryAddress(Map<String, dynamic> invoice) {
    final order = invoice['order'] as Map?;
    final label = order?['deliveryAddressLabel'] as String?;
    final line  = order?['deliveryAddressLine']  as String?;
    if (line == null || line.isEmpty) return [];
    final display = (label != null && label.isNotEmpty) ? '$label: $line' : line;
    return [_InfoRow('Delivery', display)];
  }

  List<Widget> _buildSignatures(Map<String, dynamic> invoice) {
    final order          = invoice['order'] as Map?;
    final customerSig    = order?['customerSignature']    as String?;
    final salespersonSig = order?['salespersonSignature'] as String?;
    if (customerSig == null && salespersonSig == null) return [];

    return [
      const Divider(height: 24),
      const Padding(
        padding: EdgeInsets.only(bottom: 10),
        child: Text('Signatures',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      ),
      if (customerSig != null) ...[
        const Text('Customer',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Container(
            height: 100,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Image.memory(
              base64Decode(customerSig),
              fit: BoxFit.contain,
              width: double.infinity,
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
      if (salespersonSig != null) ...[
        const Text('Sales Person',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Container(
            height: 100,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Image.memory(
              base64Decode(salespersonSig),
              fit: BoxFit.contain,
              width: double.infinity,
            ),
          ),
        ),
      ],
    ];
  }
}

class _InfoRow extends StatelessWidget {
  final String label, value;
  final bool bold;
  const _InfoRow(this.label, this.value, {this.bold = false});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(children: [
      SizedBox(width: 90, child: Text(label,
          style: const TextStyle(color: Colors.grey, fontSize: 13))),
      Expanded(child: Text(value, style: TextStyle(
          fontWeight: bold ? FontWeight.bold : FontWeight.w500,
          fontSize: bold ? 16 : 14))),
    ]),
  );
}

class _PrinterPicker extends StatelessWidget {
  final List<BluetoothInfo> devices;
  const _PrinterPicker({required this.devices});
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(padding: const EdgeInsets.all(16),
        child: Text('Select Printer', style: Theme.of(context).textTheme.titleMedium)),
      if (devices.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('No paired printers found — pair one in system Bluetooth settings first'),
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

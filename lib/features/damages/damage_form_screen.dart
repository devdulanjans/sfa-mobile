import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import '../../app/colors.dart';
import '../../app/radii.dart';
import '../../core/bluetooth/printer_service.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/local_db.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/empty_state.dart';

const _damageReasons = [
  'Damaged in Transit',
  'Damaged in Storage / Warehouse',
  'Expired',
  'Broken Packaging',
  'Water / Moisture Damage',
  'Mishandling',
  'Other',
];

/// One product + quantity line within a damage record being built.
class _DamageLine {
  Map product;
  final TextEditingController qtyCtrl;
  _DamageLine(this.product, {String qty = '1'})
      : qtyCtrl = TextEditingController(text: qty);

  void dispose() => qtyCtrl.dispose();
}

class DamageFormScreen extends ConsumerStatefulWidget {
  final String? preselectedCustomerId;
  final String? preselectedCustomerName;
  const DamageFormScreen({
    super.key,
    this.preselectedCustomerId,
    this.preselectedCustomerName,
  });
  @override
  ConsumerState<DamageFormScreen> createState() => _DamageFormScreenState();
}

class _DamageFormScreenState extends ConsumerState<DamageFormScreen> {
  final _formKey    = GlobalKey<FormState>();
  Map?  _customer;
  final List<_DamageLine> _items = [];
  String? _reasonOption;
  final _descCtrl   = TextEditingController(); // only used when _reasonOption == 'Other'
  bool  _submitting = false;
  BluetoothInfo? _printer;

  @override
  void initState() {
    super.initState();
    if (widget.preselectedCustomerId != null) {
      _customer = LocalDb.customers.firstWhere(
        (c) => c['id'] == widget.preselectedCustomerId,
        orElse: () => {'id': widget.preselectedCustomerId, 'name': widget.preselectedCustomerName ?? ''},
      );
    }
  }

  @override
  void dispose() {
    for (final line in _items) line.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  // Same restriction rule as order creation: assignment itself is the signal
  // (not a visibility-rule flag) — a customer with no assigned products sees
  // the full catalog, any assignment narrows it to just those products.
  // effectiveAssignedProductIds includes both direct assignments and every
  // customer group the customer belongs to.
  List<Map> get _availableProducts {
    var all = LocalDb.products.where((p) => p['status'] == 'ACTIVE').toList();
    if (_customer != null) {
      final assigned = List<String>.from(
          (_customer!['effectiveAssignedProductIds'] as List?)?.map((e) => e.toString()) ?? []);
      if (assigned.isNotEmpty) {
        all = all.where((p) => assigned.contains(p['id'] as String? ?? '')).toList();
      }
    }
    return all;
  }

  void _addProductLine(Map product) {
    setState(() => _items.add(_DamageLine(product)));
  }

  void _removeLine(int index) {
    setState(() => _items.removeAt(index).dispose());
  }

  String get _finalReason =>
      _reasonOption == 'Other' ? _descCtrl.text.trim() : (_reasonOption ?? '');

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_customer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a customer')));
      return;
    }
    if (_items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one product')));
      return;
    }

    setState(() => _submitting = true);
    final payload = {
      'customerId': _customer!['id'],
      'items': _items.map((line) => {
        'productId': line.product['id'],
        'quantity': double.parse(line.qtyCtrl.text.trim()),
      }).toList(),
      'description': _finalReason,
    };
    try {
      final dio  = ref.read(dioProvider);
      final resp = await dio.post('/damages', data: payload);
      final created = resp.data as Map<String, dynamic>;
      if (mounted) {
        final wantPrint = await _showSuccessDialog(
            created['damageNumber'] as String? ?? '', 'Damage');
        if (!mounted) return;
        if (wantPrint) await _printNote(created['id'] as String);
        if (mounted) context.pop();
      }
    } catch (_) {
      await LocalDb.enqueue('POST', '/damages', payload);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved offline — will sync'), backgroundColor: Colors.orange));
        context.pop();
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ── Post-submit print flow ─────────────────────────────────────────────────

  Future<bool> _showSuccessDialog(String number, String docLabel) async =>
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.check_circle_rounded, color: Colors.green.shade500, size: 48),
          title: Text('$docLabel Recorded', textAlign: TextAlign.center),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(number, textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 10),
            const Text('Do you need to print the damage note?',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 13)),
          ]),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No, Thanks')),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.print_outlined, size: 18),
              label: const Text('Print Damage Note'),
            ),
          ],
        ),
      ) ?? false;

  Future<void> _printNote(String id) async {
    try {
      final dio = ref.read(dioProvider);
      final resp = await dio.get('/damages/$id/thermal',
          options: Options(responseType: ResponseType.bytes));
      final bytes = resp.data as List<int>;

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

      try { await printerSvc.disconnect(); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 400));

      final connected = await printerSvc.connect(_printer!.macAdress);
      if (!connected) throw Exception('Could not connect to ${_printer!.name}');
      await Future.delayed(const Duration(milliseconds: 500));

      final sent = await printerSvc.printBytes(bytes);
      if (!sent) throw Exception('Printer did not accept the print job');
    } catch (e) {
      _printer = null;
      if (mounted) {
        if (e is BluetoothPermissionDeniedException) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.message), backgroundColor: Colors.red,
            duration: const Duration(seconds: 8),
          ));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Print failed: $e'), backgroundColor: Colors.red));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final customerLocked = widget.preselectedCustomerId != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Record Damage'),
        backgroundColor: AppColors.pinkBg,
        foregroundColor: AppColors.pinkFg,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SectionLabel('Customer *'),
            const SizedBox(height: 6),
            _Picker(
              label: 'Select Customer',
              value: _customer?['name'] as String?,
              enabled: !customerLocked,
              onTap: () async {
                final picked = await showModalBottomSheet<Map>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => _PickerSheet(title: 'Customer', items: LocalDb.customers),
                );
                if (picked != null) setState(() => _customer = picked);
              },
            ),
            const SizedBox(height: 18),

            // ── Products ─────────────────────────────────────────────────────
            Row(children: [
              Expanded(child: _SectionLabel('Damaged Products *')),
              TextButton.icon(
                onPressed: () async {
                  final picked = await showModalBottomSheet<Map>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => _PickerSheet(title: 'Product', items: _availableProducts),
                  );
                  if (picked != null) _addProductLine(picked);
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Product'),
              ),
            ]),
            if (_items.isEmpty)
              const EmptyState(
                message: 'No products added yet. Tap "Add Product" to start.',
                icon: Icons.inventory_2_outlined,
              )
            else
              ..._items.asMap().entries.map((entry) {
                final i    = entry.key;
                final line = entry.value;
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: AppCard(
                  padding: const EdgeInsets.all(10),
                  child: Row(children: [
                    Expanded(
                      child: Text(line.product['name'] as String? ?? '',
                          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 70,
                      child: TextFormField(
                        controller: line.qtyCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        textAlign: TextAlign.center,
                        decoration: _inputDec('Qty'),
                        validator: (v) {
                          if (v == null || v.isEmpty) return 'Req.';
                          if ((double.tryParse(v) ?? 0) <= 0) return '>0';
                          return null;
                        },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18, color: Colors.red),
                      onPressed: () => _removeLine(i),
                    ),
                  ]),
                  ),
                );
              }),
            const SizedBox(height: 14),

            _SectionLabel('Reason for damage *'),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: _reasonOption,
              decoration: _inputDec('Select a reason'),
              items: _damageReasons
                  .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                  .toList(),
              onChanged: (v) => setState(() => _reasonOption = v),
              validator: (v) => v == null ? 'Please select a reason' : null,
            ),
            if (_reasonOption == 'Other') ...[
              const SizedBox(height: 10),
              TextFormField(
                controller: _descCtrl,
                maxLines: 3,
                decoration: _inputDec('Describe the damage — how it occurred, extent, etc.'),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Please describe the damage'
                    : null,
              ),
            ],
            const SizedBox(height: 28),

            SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _submitting ? null : _submit,
                icon: _submitting
                    ? const SizedBox(height: 18, width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.report_outlined),
                label: Text(_submitting ? 'Submitting…' : 'Record Damage'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.pinkFg,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.pill)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Bluetooth printer picker sheet ───────────────────────────────────────────
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

// ─── Helpers ──────────────────────────────────────────────────────────────────

class _Picker extends StatelessWidget {
  final String label;
  final String? value;
  final VoidCallback onTap;
  final bool enabled;
  const _Picker({
    required this.label,
    this.value,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: enabled ? onTap : null,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: enabled ? Colors.white : Colors.grey.shade100,
        border: Border.all(color: const Color(0xFFCBD5E1)),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(children: [
        Expanded(child: Text(value ?? 'Select $label',
            style: TextStyle(color: value != null ? Colors.black87 : Colors.grey.shade500))),
        const Icon(Icons.arrow_drop_down, color: Colors.grey),
      ]),
    ),
  );
}

class _PickerSheet extends StatefulWidget {
  final String title;
  final List<Map> items;
  const _PickerSheet({required this.title, required this.items});
  @override
  State<_PickerSheet> createState() => _PickerSheetState();
}

class _PickerSheetState extends State<_PickerSheet> {
  String _q = '';
  List<Map> get _filtered => widget.items
      .where((i) => _q.isEmpty ||
          (i['name'] as String? ?? '').toLowerCase().contains(_q.toLowerCase()))
      .toList();

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    initialChildSize: 0.75,
    minChildSize: 0.5,
    maxChildSize: 0.95,
    expand: false,
    builder: (_, ctrl) => Column(children: [
      Padding(padding: const EdgeInsets.symmetric(vertical: 10),
        child: Container(width: 40, height: 4,
            decoration: BoxDecoration(color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2)))),
      Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: TextField(
          decoration: InputDecoration(
            hintText: 'Search ${widget.title}…',
            prefixIcon: const Icon(Icons.search, size: 18),
            isDense: true,
          ),
          onChanged: (v) => setState(() => _q = v),
        )),
      Expanded(child: ListView.builder(
        controller: ctrl,
        itemCount: _filtered.length,
        itemBuilder: (_, i) {
          final item = _filtered[i];
          return ListTile(
            dense: true,
            title: Text(item['name'] as String? ?? ''),
            subtitle: (item['code'] ?? item['productCode']) != null
                ? Text((item['code'] ?? item['productCode']) as String,
                    style: const TextStyle(fontSize: 11))
                : null,
            onTap: () => Navigator.pop(context, item),
          );
        },
      )),
    ]),
  );
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black54));
}


InputDecoration _inputDec(String hint) => InputDecoration(
  hintText: hint,
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  isDense: true,
);

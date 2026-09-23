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
import '../../shared/widgets/status_badge.dart';
import '../../utils/formatters.dart';
import '../orders/price_tiers_sheet.dart';
import 'return_print_preview_screen.dart';

/// One product + quantity line within a return being built.
class _ReturnLine {
  Map product;
  final TextEditingController qtyCtrl;
  // Defaults to the product's flat list price; replaced with a batch/customer
  // tier price when the rep picks one via the batch-price sheet.
  double unitPrice;
  String? batchPriceId;
  _ReturnLine(this.product, {String qty = '1'})
      : qtyCtrl = TextEditingController(text: qty),
        unitPrice = (product['defaultPrice'] as num?)?.toDouble() ?? 0.0;

  void dispose() => qtyCtrl.dispose();
}

class ReturnFormScreen extends ConsumerStatefulWidget {
  final String? preselectedCustomerId;
  final String? preselectedCustomerName;
  const ReturnFormScreen({
    super.key,
    this.preselectedCustomerId,
    this.preselectedCustomerName,
  });

  @override
  ConsumerState<ReturnFormScreen> createState() => _ReturnFormScreenState();
}

class _ReturnFormScreenState extends ConsumerState<ReturnFormScreen> {
  final _formKey    = GlobalKey<FormState>();
  Map?  _customer;
  Map?  _order;
  final List<_ReturnLine> _items = [];
  String? _reasonOption;
  final _reasonCtrl = TextEditingController(); // only used when the selected reason allows free text
  bool  _submitting  = false;
  BluetoothInfo? _printer;

  bool  _loadingOrders = false;
  List<Map> _customerOrders = [];

  @override
  void initState() {
    super.initState();
    if (widget.preselectedCustomerId != null) {
      _customer = LocalDb.customers.firstWhere(
        (c) => c['id'] == widget.preselectedCustomerId,
        orElse: () => {'id': widget.preselectedCustomerId, 'name': widget.preselectedCustomerName ?? ''},
      );
      _loadOrdersForCustomer(widget.preselectedCustomerId!);
    }
  }

  @override
  void dispose() {
    for (final line in _items) line.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadOrdersForCustomer(String customerId) async {
    setState(() => _loadingOrders = true);
    try {
      final dio  = ref.read(dioProvider);
      final resp = await dio.get('/customers/$customerId/orders', queryParameters: {
        'page': 0,
        'size': 50,
        'sort': 'orderDate,desc',
      });
      final content = (resp.data['content'] as List? ?? []).cast<Map>();
      if (mounted) setState(() => _customerOrders = content);
    } catch (_) {
      if (mounted) setState(() => _customerOrders = []);
    } finally {
      if (mounted) setState(() => _loadingOrders = false);
    }
  }

  void _selectCustomer(Map customer) {
    setState(() {
      _customer = customer;
      _order = null; // any previously selected order belonged to the old customer
      _customerOrders = [];
    });
    _loadOrdersForCustomer(customer['id'] as String);
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

  // Admin-managed via Settings → General ('return_damage_price_qty_enabled').
  // Lets a business hide per-line pricing from return/damage forms (e.g. reps
  // who shouldn't see product values) without changing what's actually
  // submitted — quantity is still required either way.
  bool get _showPriceQty => LocalDb.getSystemSettingBool(
      'return_damage_price_qty_enabled', defaultValue: true);

  void _addProductLine(Map product) {
    setState(() => _items.add(_ReturnLine(product)));
  }

  void _removeLine(int index) {
    setState(() => _items.removeAt(index).dispose());
  }

  // Lets the rep apply a batch/customer-tier price to a return line, same
  // sheet used when building an order — see order_review_screen's _changeTier.
  Future<void> _pickBatchPrice(_ReturnLine line) async {
    try {
      final resp = await ref.read(dioProvider).get('/pricing/tiers', queryParameters: {
        'productId': line.product['id'],
        if (_customer != null) 'customerId': _customer!['id'],
      });
      final tiers = List<Map<String, dynamic>>.from(resp.data as List? ?? []);
      if (!mounted) return;
      if (tiers.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No batch price tiers for this product')));
        return;
      }
      final unit = (line.product['unit'] as Map?)?['name'] as String? ?? '';
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl))),
        builder: (_) => PriceTiersSheet(
          productName: line.product['name'] as String? ?? '',
          unit: unit,
          tiers: tiers,
          initialQty: double.tryParse(line.qtyCtrl.text) ?? 1,
          initialPrice: line.unitPrice,
          confirmLabel: 'Apply',
          onConfirm: (price, qty, source, batchPriceId) async {
            setState(() {
              line.unitPrice = price;
              line.batchPriceId = batchPriceId;
              line.qtyCtrl.text = qty % 1 == 0 ? qty.toInt().toString() : qty.toString();
            });
          },
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load price tiers')));
    }
  }

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
      if (_order != null) 'orderId': _order!['id'],
      'customerId': _customer!['id'],
      'items': _items.map((line) => {
        'productId': line.product['id'],
        'quantity': double.parse(line.qtyCtrl.text.trim()),
        if (line.batchPriceId != null) 'batchPriceId': line.batchPriceId,
      }).toList(),
      'reason': _finalReason,
    };
    try {
      final dio  = ref.read(dioProvider);
      final resp = await dio.post('/returns', data: payload);
      final created = resp.data as Map<String, dynamic>;
      if (mounted) {
        final returnNumber = created['returnNumber'] as String? ?? '';
        final wantPrint = await _showSuccessDialog(returnNumber, 'Return');
        if (!mounted) return;
        if (wantPrint) {
          await _printOrPreview(created['id'] as String, returnNumber);
        }
        if (mounted) context.pop();
      }
    } catch (_) {
      await LocalDb.enqueue('POST', '/returns', payload);
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
          title: Text('$docLabel Submitted', textAlign: TextAlign.center),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(number, textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 10),
            const Text('Do you need to print the return note?',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 13)),
          ]),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No, Thanks')),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.print_outlined, size: 18),
              label: const Text('Print Return Note'),
            ),
          ],
        ),
      ) ?? false;

  // TEMPORARY (debug-only): the thermal print preview is gated behind the
  // 'invoice_print_preview_enabled' system setting (default OFF, shared with the
  // invoice/damage preview flows), so normal use prints directly. The whole
  // preview feature is still slated for removal before production.
  Future<void> _printOrPreview(String id, String returnNumber) {
    final previewEnabled = LocalDb.getSystemSettingBool(
        'invoice_print_preview_enabled', defaultValue: false);
    return previewEnabled ? _openPrintPreview(id, returnNumber) : _printNote(id);
  }

  Future<void> _openPrintPreview(String id, String returnNumber) {
    return Navigator.push(context, MaterialPageRoute(
      builder: (_) => ReturnPrintPreviewScreen(
        returnId: id,
        returnNumber: returnNumber,
        // Awaited (not fired-and-forgotten) so the preview route — and this
        // screen's own post-print pop() — doesn't proceed until the actual
        // Bluetooth print (with its own picker/progress/result dialogs) is done.
        onPrint: () async {
          await _printNote(id);
          if (mounted) Navigator.pop(context);
        },
      ),
    ));
  }

  Future<void> _printNote(String id) async {
    try {
      final dio = ref.read(dioProvider);
      final resp = await dio.get('/returns/$id/thermal',
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

  // Admin-managed via Settings → Return & Damage Reasons; kept in sync locally
  // (see LocalDb.replaceReasons / sync_service.dart) so this list reflects
  // whatever the admin last added/removed without an app update.
  List<Map> get _returnReasons => LocalDb.reasonsFor('RETURN');

  bool get _selectedAllowsFreeText {
    final match = _returnReasons.firstWhere(
      (r) => r['label'] == _reasonOption,
      orElse: () => const {},
    );
    return match['allowFreeText'] == true;
  }

  String get _finalReason =>
      _selectedAllowsFreeText ? _reasonCtrl.text.trim() : (_reasonOption ?? '');

  String _orderLabel(Map order) {
    final num = order['orderNumber'] as String? ?? '—';
    final total = order['total'] ?? order['grandTotal'];
    return total != null ? '$num  •  LKR $total' : num;
  }

  @override
  Widget build(BuildContext context) {
    final customerLocked = widget.preselectedCustomerId != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('New Return'),
        backgroundColor: AppColors.orangeBg,
        foregroundColor: AppColors.orangeFg,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── Customer picker ─────────────────────────────────────────────
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
                  builder: (_) => _SearchPickerSheet(
                      title: 'Customer', items: LocalDb.customers),
                );
                if (picked != null) _selectCustomer(picked);
              },
            ),
            const SizedBox(height: 14),

            // ── Order picker (optional) ─────────────────────────────────────
            _SectionLabel('Order (optional)'),
            const SizedBox(height: 6),
            _Picker(
              label: _customer == null
                  ? 'Select a customer first'
                  : _loadingOrders
                      ? 'Loading orders…'
                      : 'Select Order (optional)',
              value: _order != null ? _orderLabel(_order!) : null,
              enabled: _customer != null && !_loadingOrders,
              trailing: _order != null
                  ? IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() => _order = null),
                    )
                  : null,
              onTap: () async {
                if (_customerOrders.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('No orders found for this customer')));
                  return;
                }
                final picked = await showModalBottomSheet<Map>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => _OrderPickerSheet(orders: _customerOrders, labelFn: _orderLabel),
                );
                if (picked != null) setState(() => _order = picked);
              },
            ),
            const SizedBox(height: 18),

            // ── Products ─────────────────────────────────────────────────────
            Row(children: [
              Expanded(child: _SectionLabel('Products *')),
              TextButton.icon(
                onPressed: () async {
                  final picked = await showModalBottomSheet<Map>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => _SearchPickerSheet(
                        title: 'Product', items: _availableProducts),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
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
                      if (_showPriceQty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: ValueListenableBuilder<TextEditingValue>(
                            valueListenable: line.qtyCtrl,
                            builder: (_, value, __) {
                              final qty = double.tryParse(value.text) ?? 0;
                              return Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  InkWell(
                                    onTap: () => _pickBatchPrice(line),
                                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                                      Text('LKR ${formatAmount(line.unitPrice)} / unit',
                                          style: TextStyle(
                                              fontSize: 11, color: Colors.grey.shade600)),
                                      const SizedBox(width: 3),
                                      const Icon(Icons.sell_outlined,
                                          size: 13, color: AppColors.orangeFg),
                                    ]),
                                  ),
                                  Text('LKR ${formatAmount(line.unitPrice * qty)}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600, fontSize: 12)),
                                ],
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                  ),
                );
              }),
            if (_showPriceQty && _items.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 4),
                child: AnimatedBuilder(
                  animation: Listenable.merge(_items.map((l) => l.qtyCtrl).toList()),
                  builder: (_, __) {
                    final total = _items.fold<double>(0, (s, l) {
                      final qty = double.tryParse(l.qtyCtrl.text) ?? 0;
                      return s + l.unitPrice * qty;
                    });
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        const Text('Total Value:  ',
                            style: TextStyle(fontSize: 12, color: Colors.black54)),
                        Text('LKR ${formatAmount(total)}',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      ],
                    );
                  },
                ),
              ),
            const SizedBox(height: 14),

            // ── Reason ──────────────────────────────────────────────────────
            _SectionLabel('Reason for return *'),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: _reasonOption,
              decoration: _inputDec('Select a reason'),
              items: _returnReasons
                  .map((r) => DropdownMenuItem(
                      value: r['label'] as String, child: Text(r['label'] as String)))
                  .toList(),
              onChanged: (v) => setState(() => _reasonOption = v),
              validator: (v) => v == null ? 'Please select a reason' : null,
            ),
            if (_selectedAllowsFreeText) ...[
              const SizedBox(height: 10),
              TextFormField(
                controller: _reasonCtrl,
                maxLines: 3,
                decoration: _inputDec('Describe why these items are being returned…'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
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
                    : const Icon(Icons.undo_rounded),
                label: Text(_submitting ? 'Submitting…' : 'Place Return'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.orangeFg,
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

// ─── Order picker sheet ────────────────────────────────────────────────────────
class _OrderPickerSheet extends StatefulWidget {
  final List<Map> orders;
  final String Function(Map) labelFn;
  const _OrderPickerSheet({required this.orders, required this.labelFn});
  @override
  State<_OrderPickerSheet> createState() => _OrderPickerSheetState();
}

class _OrderPickerSheetState extends State<_OrderPickerSheet> {
  String _q = '';
  static const _statusTones = {
    'DRAFT': AppTone.neutral, 'SUBMITTED': AppTone.orange,
    'APPROVED': AppTone.mint, 'INVOICED': AppTone.violet, 'CANCELLED': AppTone.pink,
  };

  List<Map> get _filtered => widget.orders.where((o) {
    final label = widget.labelFn(o).toLowerCase();
    return _q.isEmpty || label.contains(_q.toLowerCase());
  }).toList();

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, ctrl) => Column(
        children: [
          const _SheetHandle(),
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search by order #…',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _q = v),
            )),
          Expanded(child: ListView.builder(
            controller: ctrl,
            itemCount: _filtered.length,
            itemBuilder: (_, i) {
              final o      = _filtered[i];
              final status = o['status'] as String? ?? '';
              final total  = o['total'] ?? o['grandTotal'];
              return ListTile(
                dense: true,
                title: Text(o['orderNumber'] as String? ?? '—',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    StatusBadge(label: status, tone: _statusTones[status] ?? AppTone.neutral),
                    if (total != null)
                      Text('LKR $total', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
                onTap: () => Navigator.pop(context, o),
              );
            },
          )),
        ],
      ),
    );
  }
}

// ─── Generic search picker sheet ──────────────────────────────────────────────
class _SearchPickerSheet extends StatefulWidget {
  final String title;
  final List<Map> items;
  const _SearchPickerSheet({required this.title, required this.items});
  @override
  State<_SearchPickerSheet> createState() => _SearchPickerSheetState();
}

class _SearchPickerSheetState extends State<_SearchPickerSheet> {
  String _q = '';
  List<Map> get _filtered => widget.items.where((i) {
    if (_q.isEmpty) return true;
    final q = _q.toLowerCase();
    final name = (i['name'] as String? ?? '').toLowerCase();
    final code = (i['code'] ?? i['productCode'] ?? '').toString().toLowerCase();
    return name.contains(q) || code.contains(q);
  }).toList();

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, ctrl) => Column(
        children: [
          const _SheetHandle(),
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
        ],
      ),
    );
  }
}

// ─── Shared helpers ───────────────────────────────────────────────────────────
class _Picker extends StatelessWidget {
  final String label;
  final String? value;
  final VoidCallback onTap;
  final bool enabled;
  final Widget? trailing;
  const _Picker({
    required this.label,
    this.value,
    required this.onTap,
    this.enabled = true,
    this.trailing,
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
        Expanded(child: Text(value ?? label,
            style: TextStyle(color: value != null ? Colors.black87 : Colors.grey.shade500))),
        trailing ?? const Icon(Icons.arrow_drop_down, color: Colors.grey),
      ]),
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black54));
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Container(
      width: 40, height: 4,
      decoration: BoxDecoration(
          color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
    ),
  );
}

InputDecoration _inputDec(String hint) => InputDecoration(
  hintText: hint,
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  isDense: true,
);

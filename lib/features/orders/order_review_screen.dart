import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:signature/signature.dart';

import '../../app/colors.dart';
import '../../app/radii.dart';
import '../../core/bluetooth/printer_service.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/local_db.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/section_header.dart';
import '../../shared/widgets/status_badge.dart';
import '../../utils/formatters.dart';
import '../invoices/invoice_print_preview_screen.dart';
import 'order_provider.dart';
import 'price_tiers_sheet.dart';

class OrderReviewScreen extends ConsumerStatefulWidget {
  const OrderReviewScreen({super.key});
  @override
  ConsumerState<OrderReviewScreen> createState() => _OrderReviewScreenState();
}

class _OrderReviewScreenState extends ConsumerState<OrderReviewScreen> {
  bool _submitting = false;

  // Remembered across "Print Again" taps so a second copy doesn't re-show
  // the printer picker when the same printer is still reachable.
  BluetoothInfo? _lastPrinter;

  // Needed to title the print preview screen — set once in _submit().
  String? _lastOrderNumber;

  // Delivery address selection
  String? _deliveryAddressLabel;
  String? _deliveryAddressLine;

  // Optional PO number, entered by the rep — printed on the invoice when present.
  final _poNumberCtrl = TextEditingController();

  // Signature controllers
  late final SignatureController _customerSigCtrl;
  late final SignatureController _salespersonSigCtrl;

  // Track whether controllers have strokes (for button state)
  bool _customerSigned    = false;
  bool _salespersonSigned = false;

  @override
  void initState() {
    super.initState();
    _customerSigCtrl = SignatureController(
      penStrokeWidth: 3,
      penColor: Colors.black,
      exportBackgroundColor: Colors.white,
    )..addListener(() {
        setState(() => _customerSigned = _customerSigCtrl.isNotEmpty);
      });

    _salespersonSigCtrl = SignatureController(
      penStrokeWidth: 3,
      penColor: Colors.black,
      exportBackgroundColor: Colors.white,
    )..addListener(() {
        setState(() => _salespersonSigned = _salespersonSigCtrl.isNotEmpty);
      });
  }

  @override
  void dispose() {
    _poNumberCtrl.dispose();
    _customerSigCtrl.dispose();
    _salespersonSigCtrl.dispose();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<void> _editQty(OrderLineItem item) async {
    final controller = TextEditingController(
        text: item.qty % 1 == 0 ? item.qty.toInt().toString() : item.qty.toString());
    final newQty = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Quantity'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Quantity'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(controller.text)),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    if (newQty == null) return;
    // updateLineQty() already removes the line when newQty <= 0.
    ref.read(orderCreationProvider.notifier)
        .updateLineQty(item.productId, newQty);
  }

  Future<void> _changeTier(OrderLineItem item, int index) async {
    final draft = ref.read(orderCreationProvider);
    if (draft == null) return;
    try {
      final resp = await ref.read(dioProvider).get('/pricing/tiers', queryParameters: {
        'productId': item.productId,
        'customerId': draft.customerId,
      });
      final tiers = List<Map<String, dynamic>>.from(resp.data as List? ?? []);
      if (!mounted) return;
      if (tiers.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No batch price tiers for this product')));
        return;
      }
      final product = LocalDb.products.firstWhere(
          (p) => p['id'] == item.productId, orElse: () => <String, dynamic>{});
      final unit = (product['unit'] as Map?)?['name'] as String? ?? '';
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl))),
        builder: (_) => PriceTiersSheet(
          productName: item.productName,
          unit: unit,
          tiers: tiers,
          initialQty: item.qty,
          initialPrice: item.unitPrice,
          confirmLabel: 'Update',
          onConfirm: (price, qty, source) async {
            ref.read(orderCreationProvider.notifier)
                .replaceLine(index, price, qty, source);
          },
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load price tiers')));
    }
  }

  List<Map> _customerAddresses(String customerId) {
    final cached = LocalDb.customers
        .where((c) => c['id'] == customerId)
        .firstOrNull;
    if (cached == null) return [];
    return List<Map>.from((cached['addresses'] as List?) ?? []);
  }

  bool _addressOk(List<Map> addresses) =>
      addresses.isEmpty || _deliveryAddressLine != null;

  bool _canSubmit(List<Map> addresses) =>
      _addressOk(addresses) && _customerSigned && _salespersonSigned;

  // ── Submit ────────────────────────────────────────────────────────────────

  Future<void> _submit(List<Map> addresses) async {
    if (addresses.isNotEmpty && _deliveryAddressLine == null) {
      _snack('Please select a delivery address', AppColors.orangeFg);
      return;
    }
    if (!_customerSigned) {
      _snack('Customer signature is required', AppColors.orangeFg);
      return;
    }
    if (!_salespersonSigned) {
      _snack('Sales person signature is required', AppColors.orangeFg);
      return;
    }

    setState(() => _submitting = true);

    final customerBytes     = await _customerSigCtrl.toPngBytes();
    final salespersonBytes  = await _salespersonSigCtrl.toPngBytes();
    final customerSig       = customerBytes    != null ? base64Encode(customerBytes)    : null;
    final salespersonSig    = salespersonBytes != null ? base64Encode(salespersonBytes) : null;

    try {
      final result = await ref.read(orderCreationProvider.notifier).submitOrder(
        deliveryAddressLabel: _deliveryAddressLabel,
        deliveryAddressLine:  _deliveryAddressLine,
        customerSignature:    customerSig,
        salespersonSignature: salespersonSig,
        poNumber: _poNumberCtrl.text.trim().isEmpty ? null : _poNumberCtrl.text.trim(),
      );
      if (!mounted) return;

      if (result == null) {
        _snack('Order saved offline — will sync when connected', AppColors.orangeFg);
        context.go('/dashboard');
        return;
      }

      final orderId     = result['id']          as String;
      final orderNumber = result['orderNumber'] as String? ?? '';
      _lastOrderNumber  = orderNumber;

      String? invoiceId;
      try {
        final resp = await ref.read(dioProvider).get('/invoices/by-order/$orderId');
        invoiceId = resp.data['id'] as String;
      } catch (_) {}

      if (!mounted) return;
      final wantPrint = await _showSuccessDialog(orderNumber, invoiceId != null);
      if (!mounted) return;

      if (wantPrint && invoiceId != null) {
        await _printOrPreview(invoiceId);
        if (!mounted) return;
      }

      // Clear the draft only now — doing it inside submitOrder() itself
      // triggered this screen's own "no draft" redirect to /dashboard while
      // the success dialog/print flow above was still running.
      ref.read(orderCreationProvider.notifier).clearOrder();
      context.go('/dashboard');
    } catch (e) {
      if (mounted) _snack('Failed: $e', AppColors.pinkFg);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: color));
  }

  // A dialog (rather than a snackbar) so "Print Again" doesn't disappear
  // before the user has a chance to tap it.
  Future<void> _showPrintedDialog(String invoiceId) => showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.check_circle_rounded, color: AppColors.mintFg, size: 48),
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
                _printOrPreview(invoiceId);
              },
              icon: const Icon(Icons.print_outlined, size: 18),
              label: const Text('Print Again'),
            ),
          ],
        ),
      );

  void _snackBluetoothPermission(BluetoothPermissionDeniedException e) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(e.message),
      backgroundColor: AppColors.pinkFg,
      duration: const Duration(seconds: 8),
      action: e.permanentlyDenied
          ? SnackBarAction(
              label: 'Open Settings',
              textColor: Colors.white,
              onPressed: () => ref.read(printerServiceProvider).openSettings(),
            )
          : null,
    ));
  }

  // ── Success dialog ─────────────────────────────────────────────────────────

  Future<bool> _showSuccessDialog(String orderNumber, bool hasInvoice) async =>
      await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              icon: const Icon(Icons.check_circle_rounded,
                  color: AppColors.mintFg, size: 60),
              title: const Text('Order Placed!',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(orderNumber,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 10),
                Text(
                  hasInvoice
                      ? 'Your order has been placed and invoiced successfully.\n\nDo you need to print the invoice?'
                      : 'Your order has been submitted for approval.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.grey, fontSize: 13, height: 1.5),
                ),
                const SizedBox(height: 20),
                if (hasInvoice) ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.print_rounded, size: 16),
                      label: const Text('Print Invoice'),
                      onPressed: () => Navigator.pop(ctx, true),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('No, Thanks'),
                    ),
                  ),
                ] else
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Continue'),
                    ),
                  ),
              ]),
              actionsPadding: EdgeInsets.zero,
              actions: const [],
            ),
          ) ??
          false;

  // ── Print flow ─────────────────────────────────────────────────────────────

  // TEMPORARY (debug-only): the thermal print preview is gated behind the
  // 'invoice_print_preview_enabled' system setting (default OFF), so normal
  // use prints directly. See [project_temp_invoice_thermal_preview] memory —
  // the whole preview feature is still slated for removal before production.
  Future<void> _printOrPreview(String invoiceId) {
    final previewEnabled = LocalDb.getSystemSettingBool(
        'invoice_print_preview_enabled', defaultValue: false);
    return previewEnabled ? _openPrintPreview(invoiceId) : _printInvoice(invoiceId);
  }

  // Shows the same A4 invoice PDF the backend generates before committing to
  // the Bluetooth print — lets the user check line items/totals are right
  // instead of firing straight at the thermal printer.
  Future<void> _openPrintPreview(String invoiceId) {
    return Navigator.push(context, MaterialPageRoute(
      builder: (_) => InvoicePrintPreviewScreen(
        invoice: {'id': invoiceId, 'invoiceNumber': _lastOrderNumber},
        // Awaited (not fired-and-forgotten) so the preview route — and its
        // caller's post-print navigation — doesn't proceed until the actual
        // Bluetooth print (with its own picker/progress/result dialogs) is done.
        onPrint: () async {
          await _printInvoice(invoiceId);
          if (mounted) Navigator.pop(context);
        },
      ),
    ));
  }

  Future<void> _printInvoice(String invoiceId) async {
    if (!mounted) return;

    List<int> bytes;
    try {
      final resp = await ref.read(dioProvider).get(
          '/invoices/$invoiceId/thermal',
          options: Options(responseType: ResponseType.bytes));
      bytes = resp.data as List<int>;
    } catch (e) {
      if (mounted) _snack('Could not load invoice: $e', AppColors.pinkFg);
      return;
    }

    BluetoothInfo? printer = _lastPrinter;
    if (printer == null) {
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
          title: Text('Searching for printers…', style: TextStyle(fontSize: 16)),
          content: Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(),
          ),
        ),
      );

      List<BluetoothInfo> devices;
      try {
        devices = await ref.read(printerServiceProvider).pairedDevices();
      } catch (e) {
        if (mounted) {
          Navigator.of(context, rootNavigator: true).pop();
          if (e is BluetoothPermissionDeniedException) {
            _snackBluetoothPermission(e);
          } else {
            _snack('Bluetooth scan failed: $e', AppColors.pinkFg);
          }
        }
        return;
      }
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      printer = await showModalBottomSheet<BluetoothInfo>(
        context: context,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg))),
        builder: (_) => _PrinterSheet(devices: devices),
      );
      if (printer == null || !mounted) return;
    }

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        title: Text('Printing…', style: TextStyle(fontSize: 16)),
        content: Padding(
          padding: EdgeInsets.only(top: 8),
          child: LinearProgressIndicator(),
        ),
      ),
    );

    try {
      final printerSvc = ref.read(printerServiceProvider);
      // This device's Bluetooth stack refuses a fresh connect() outright
      // (returns false) if a prior socket wasn't explicitly released first,
      // so disconnect() is required — but calling connect() immediately
      // after raced the OS's own socket teardown and left the link dead
      // right after reporting "connected". Give the disconnect a moment to
      // actually settle before reconnecting.
      try { await printerSvc.disconnect(); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 400));

      final connected = await printerSvc.connect(printer.macAdress);
      if (!connected) throw Exception('Could not connect to ${printer.name}');
      await Future.delayed(const Duration(milliseconds: 500));

      final sent = await printerSvc.printBytes(bytes);
      if (!sent) throw Exception('Printer did not accept the print job');

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _lastPrinter = printer;
        await _showPrintedDialog(invoiceId);
      }
    } catch (e) {
      _lastPrinter = null; // stale/unreachable — re-show the picker next attempt
      if (mounted) {
        try { Navigator.of(context, rootNavigator: true).pop(); } catch (_) {}
        if (e is BluetoothPermissionDeniedException) {
          _snackBluetoothPermission(e);
        } else {
          _snack('Print failed: $e', AppColors.pinkFg);
        }
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(orderCreationProvider);
    if (draft == null) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => context.go('/dashboard'));
      return const SizedBox.shrink();
    }
    final taxedItem = draft.items.where((i) => i.taxPct > 0).firstOrNull;

    final addresses = _customerAddresses(draft.customerId);
    final canSubmit = _canSubmit(addresses);

    return Scaffold(
      appBar: AppBar(title: const Text('Review Order')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Customer info ──────────────────────────────────────────────────
          _InfoCard(label: 'Customer', value: draft.customerName),
          Builder(builder: (_) {
            final cachedCustomer = LocalDb.customers
                .where((c) => c['id'] == draft.customerId)
                .firstOrNull;
            final creditDays =
                (cachedCustomer?['creditDays'] as num?)?.toInt();
            if (creditDays == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _InfoCard(
                  label: 'Credit Days', value: '$creditDays days'),
            );
          }),

          const SizedBox(height: 12),

          // ── Delivery address ───────────────────────────────────────────────
          if (addresses.isNotEmpty) _buildDeliveryAddressCard(addresses),

          // ── Items ──────────────────────────────────────────────────────────
          Text('Items', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          ...draft.items.asMap().entries.map((entry) {
            final index       = entry.key;
            final item        = entry.value;
            final hasDiscount = item.discountPct > 0;
            final isFree      = item.priceSource == 'FREE_PRODUCT';
            final card = AppCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Row(children: [
                          Flexible(
                            child: Text(item.productName,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 13)),
                          ),
                          if (isFree) ...[
                            const SizedBox(width: 6),
                            const StatusBadge(label: 'FREE', tone: AppTone.mint),
                          ],
                        ]),
                      ),
                      Text(
                          // Each row shows price × qty (minus any per-item discount)
                          // only — tax is an order-level concern shown once in the
                          // Totals section below, not baked into each line (same
                          // convention as the printed invoice's item table). A free
                          // line's lineTotal is always 0 by design (100% discount), so
                          // show its gross value (unit price × qty) instead of 0.00.
                          'LKR ${formatAmount(isFree ? item.unitPrice * item.qty : item.lineTotal - item.taxAmount)}',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold)),
                    ]),
                    const SizedBox(height: 4),
                    Row(children: [
                      Expanded(
                        child: Text(
                          '${item.qty.toStringAsFixed(item.qty % 1 == 0 ? 0 : 2)} × LKR ${formatAmount(item.unitPrice)}',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade700),
                        ),
                      ),
                      if (hasDiscount)
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.local_offer_outlined,
                              size: 11, color: AppColors.orangeFg),
                          const SizedBox(width: 2),
                          Text('${item.discountPct.toStringAsFixed(0)}%',
                              style: const TextStyle(
                                  fontSize: 11, color: AppColors.orangeFg)),
                        ]),
                    ]),
                  ]),
            );

            List<Widget> buildActions() => [
                  if (!isFree) ...[
                    SlidableAction(
                      onPressed: (_) => _editQty(item),
                      backgroundColor: AppColors.skyFg,
                      foregroundColor: Colors.white,
                      icon: Icons.edit_outlined,
                      label: 'Qty',
                    ),
                    SlidableAction(
                      onPressed: (_) => _changeTier(item, index),
                      backgroundColor: AppColors.orangeFg,
                      foregroundColor: Colors.white,
                      icon: Icons.sell_outlined,
                      label: 'Batch',
                    ),
                  ],
                  SlidableAction(
                    onPressed: (_) => ref
                        .read(orderCreationProvider.notifier)
                        .removeLine(index),
                    backgroundColor: AppColors.pinkFg,
                    foregroundColor: Colors.white,
                    icon: Icons.delete_outline,
                    label: 'Delete',
                  ),
                ];
            final extentRatio = isFree ? 0.25 : 0.75;

            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Slidable(
                key: ValueKey(item.productId),
                // Both directions wired — some users naturally swipe the "wrong" way.
                startActionPane: ActionPane(
                  motion: const ScrollMotion(),
                  extentRatio: extentRatio,
                  children: buildActions(),
                ),
                endActionPane: ActionPane(
                  motion: const ScrollMotion(),
                  extentRatio: extentRatio,
                  children: buildActions(),
                ),
                child: card,
              ),
            );
          }),

          const SizedBox(height: 16),

          // ── Totals ─────────────────────────────────────────────────────────
          AppCard(
            tone: AppTone.violet,
            padding: const EdgeInsets.all(14),
            child: Column(children: [
              _Total(draft.discountTotal > 0 ? 'Full Total' : 'Subtotal',
                  'LKR ${formatAmount(draft.grossTotal)}', false),
              if (draft.discountTotal > 0) ...[
                _Total('Discount',
                    'LKR ${formatAmount(-draft.discountTotal)}', false,
                    color: AppColors.mintFg),
                // Amount tax is actually calculated on — makes it explicit that tax
                // applies after the discount, not on the pre-discount full total.
                _Total('Net Amount',
                    'LKR ${formatAmount(draft.subtotal)}', false),
              ],
              if (draft.taxTotal > 0)
                _Total(
                    taxedItem != null
                        ? 'Tax (${taxedItem.taxPct.toStringAsFixed(0)}%)'
                        : 'Tax',
                    'LKR ${formatAmount(draft.taxTotal)}', false,
                    color: AppColors.skyFg),
              const Divider(height: 12),
              _Total('TOTAL',
                  'LKR ${formatAmount(draft.grandTotal)}', true,
                  color: AppColors.violetFg),
            ]),
          ),

          const SizedBox(height: 20),

          // ── PO Number (optional) ────────────────────────────────────────────
          _buildPoNumberCard(),

          const SizedBox(height: 20),

          // ── Signatures ─────────────────────────────────────────────────────
          _buildSignaturesCard(),

          const SizedBox(height: 8),
        ],
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Row(children: [
          Expanded(
              child: OutlinedButton(
            onPressed: () => context.pop(),
            child: const Text('Back'),
          )),
          const SizedBox(width: 12),
          Expanded(
              flex: 2,
              child: ElevatedButton(
                onPressed: (_submitting || !canSubmit)
                    ? null
                    : () => _submit(addresses),
                style: ElevatedButton.styleFrom(
                  backgroundColor: canSubmit ? null : Colors.grey.shade300,
                ),
                child: _submitting
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Submit Order'),
              )),
        ]),
      ),
    );
  }

  // ── PO Number card (optional) ─────────────────────────────────────────────

  Widget _buildPoNumberCard() {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SectionHeader(title: 'PO Number', icon: Icons.confirmation_number_outlined),
        const SizedBox(height: 10),
        TextField(
          controller: _poNumberCtrl,
          decoration: const InputDecoration(
            hintText: 'Customer\'s purchase order number (optional)',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
      ]),
    );
  }

  // ── Delivery address card ─────────────────────────────────────────────────

  Widget _buildDeliveryAddressCard(List<Map> addresses) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Expanded(
              child: SectionHeader(
                  title: 'Delivery Address',
                  icon: Icons.local_shipping_outlined),
            ),
            Text('*',
                style: TextStyle(
                    color: AppColors.pinkFg,
                    fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 10),
          ...addresses.map((addr) {
            final label      = addr['label']       as String? ?? '';
            final addressLine = addr['addressLine'] as String? ?? '';
            final selected   = _deliveryAddressLine == addressLine;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: AppCard(
                tone: selected ? AppTone.violet : AppTone.neutral,
                radius: AppRadius.sm,
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 8),
                onTap: () => setState(() {
                  _deliveryAddressLabel = label;
                  _deliveryAddressLine  = addressLine;
                }),
                child: Row(children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: selected ? AppColors.violetFg : Colors.grey,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(label,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13)),
                          Text(addressLine,
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey.shade700)),
                        ]),
                  ),
                ]),
              ),
            );
          }),
          if (_deliveryAddressLine == null)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Please select a delivery address',
                  style: TextStyle(
                      fontSize: 11, color: AppColors.pinkFg)),
            ),
        ]),
      ),
    );
  }

  // ── Signatures card ───────────────────────────────────────────────────────

  Widget _buildSignaturesCard() {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SectionHeader(title: 'Signatures', icon: Icons.draw_outlined),
        const SizedBox(height: 14),

        // Customer signature
        _buildSigPad(
          label: 'Customer Signature',
          controller: _customerSigCtrl,
          isSigned: _customerSigned,
        ),

        const Divider(height: 24),

        // Sales person signature
        _buildSigPad(
          label: 'Sales Person Signature',
          controller: _salespersonSigCtrl,
          isSigned: _salespersonSigned,
        ),
      ]),
    );
  }

  Widget _buildSigPad({
    required String label,
    required SignatureController controller,
    required bool isSigned,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Text(label,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500)),
        ),
        const Text(' *',
            style: TextStyle(
                color: AppColors.pinkFg, fontWeight: FontWeight.bold)),
        if (isSigned)
          const Icon(Icons.check_circle_outline,
              size: 16, color: AppColors.mintFg),
      ]),
      const SizedBox(height: 8),
      Container(
        height: 150,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          color: isSigned ? AppColors.mintBg : AppColors.scaffoldBg,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.lg - 3),
          child: Signature(
            controller: controller,
            backgroundColor: Colors.white,
          ),
        ),
      ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          icon: const Icon(Icons.clear, size: 14),
          label: const Text('Clear', style: TextStyle(fontSize: 12)),
          style: TextButton.styleFrom(
              foregroundColor: Colors.grey.shade600,
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 4)),
          onPressed: () {
            controller.clear();
            setState(() {});
          },
        ),
      ),
      if (!isSigned)
        const Text('Please sign above',
            style: TextStyle(
                fontSize: 11, color: AppColors.pinkFg)),
    ]);
  }
}

// ── Printer picker ────────────────────────────────────────────────────────────

class _PrinterSheet extends StatelessWidget {
  final List<BluetoothInfo> devices;
  const _PrinterSheet({required this.devices});

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(children: [
              const Icon(Icons.bluetooth_rounded, size: 20),
              const SizedBox(width: 8),
              Text('Select Printer',
                  style: Theme.of(context).textTheme.titleMedium),
            ]),
          ),
          const Divider(height: 1),
          if (devices.isEmpty)
            const EmptyState(
              icon: Icons.bluetooth_disabled_rounded,
              message:
                  'No paired printers found\nPair one in system Bluetooth settings first',
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

// ── Shared widgets ────────────────────────────────────────────────────────────

class _InfoCard extends StatelessWidget {
  final String label, value;
  const _InfoCard({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => AppCard(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Text('$label: ',
              style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
          Text(value,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 13, color: AppColors.ink)),
        ]),
      );
}

class _Total extends StatelessWidget {
  final String label, value;
  final bool   bold;
  final Color? color;
  const _Total(this.label, this.value, this.bold, {this.color});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontWeight: bold
                          ? FontWeight.bold
                          : FontWeight.normal,
                      fontSize: bold ? 15 : 13,
                      color: color))),
          Text(value,
              style: TextStyle(
                  fontWeight:
                      bold ? FontWeight.bold : FontWeight.normal,
                  fontSize: bold ? 15 : 13,
                  color: color)),
        ]),
      );
}

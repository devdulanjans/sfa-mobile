import 'package:flutter/material.dart';
import '../../utils/formatters.dart';

/// Shared batch-price tier picker bottom sheet — used both when first adding a
/// product to the cart and when changing an existing cart/review line's tier.
class PriceTiersSheet extends StatefulWidget {
  final String productName;
  final String unit;
  final List<Map<String, dynamic>> tiers;
  final Future<void> Function(double price, double qty, String priceSource, String? batchPriceId) onConfirm;
  final double? initialQty;    // pre-fill qty (update flow)
  final double? initialPrice;  // pre-select matching tier (update flow)
  final String confirmLabel;   // button text

  const PriceTiersSheet({
    super.key,
    required this.productName,
    required this.unit,
    required this.tiers,
    required this.onConfirm,
    this.initialQty,
    this.initialPrice,
    this.confirmLabel = 'Add to Cart',
  });

  @override
  State<PriceTiersSheet> createState() => _PriceTiersSheetState();
}

class _PriceTiersSheetState extends State<PriceTiersSheet> {
  int    _selected = 0;
  double _qty      = 1;
  bool   _adding   = false;

  @override
  void initState() {
    super.initState();
    // Pre-select the tier whose price matches the current cart item price
    if (widget.initialPrice != null) {
      final match = widget.tiers.indexWhere(
          (t) => (t['price'] as num).toDouble() == widget.initialPrice);
      if (match >= 0) _selected = match;
    }
    _qty = widget.initialQty ?? _minQtyOf(_selected);
  }

  double _minQtyOf(int i) {
    final v = widget.tiers[i]['minQty'];
    if (v == null) return 1;
    final d = (v as num).toDouble();
    return d > 0 ? d : 1;
  }

  double get _price  => (widget.tiers[_selected]['price'] as num).toDouble();
  String get _source => widget.tiers[_selected]['customerSpecific'] == true
      ? 'CUSTOMER_PRICE' : 'BATCH_PRICE';
  String? get _batchPriceId => widget.tiers[_selected]['id'] as String?;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final subtotal = _price * _qty;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              width: 40, height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.productName,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 2),
              const Text('Select a price tier',
                  style: TextStyle(fontSize: 13, color: Colors.grey)),
            ]),
          ),

          const Divider(height: 1),

          // Tier list
          ...widget.tiers.asMap().entries.map((e) {
            final i    = e.key;
            final tier = e.value;
            final sel  = i == _selected;
            final price = (tier['price'] as num).toDouble();
            final minQtyRaw = tier['minQty'];
            final minQty = minQtyRaw != null ? (minQtyRaw as num).toDouble() : null;
            final isCustomer = tier['customerSpecific'] == true;
            final label = tier['label'] as String? ??
                (isCustomer ? 'Customer Price' : 'General Price');

            return InkWell(
              onTap: () => setState(() {
                _selected = i;
                _qty = _minQtyOf(i);
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: sel ? primary.withOpacity(0.06) : null,
                  border: Border(
                    left: BorderSide(
                        color: sel ? primary : Colors.transparent, width: 3),
                  ),
                ),
                child: Row(children: [
                  Icon(
                    sel ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    color: sel ? primary : Colors.grey.shade400,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text(label,
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                                color: sel ? primary : null)),
                        if (isCustomer) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade50,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('Your Price',
                                style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.blue.shade700,
                                    fontWeight: FontWeight.w500)),
                          ),
                        ],
                      ]),
                      if (minQty != null && minQty > 1)
                        Text(
                          'Min ${minQty % 1 == 0 ? minQty.toInt() : minQty}'
                          '${widget.unit.isNotEmpty ? " ${widget.unit}" : ""}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey),
                        ),
                    ]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('LKR ${formatAmount(price)}',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: isCustomer
                                ? Colors.blue.shade700
                                : Colors.grey.shade800)),
                    if (widget.unit.isNotEmpty)
                      Text('/ ${widget.unit}',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey)),
                  ]),
                ]),
              ),
            );
          }),

          const Divider(height: 1),

          // Qty row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(children: [
              const Text('Quantity',
                  style: TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
              const Spacer(),
              QtyCounter(
                qty: _qty,
                primary: primary,
                onDecrement: () {
                  final min = _minQtyOf(_selected);
                  if (_qty > min) setState(() => _qty--);
                },
                onIncrement: () => setState(() => _qty++),
                onQtyChanged: (newQty) {
                  final min = _minQtyOf(_selected);
                  setState(() => _qty = newQty < min ? min : newQty);
                },
              ),
            ]),
          ),

          // Subtotal preview
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${_qty % 1 == 0 ? _qty.toInt() : _qty} × LKR ${formatAmount(_price)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                Text('LKR ${formatAmount(subtotal)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14)),
              ],
            ),
          ),

          // Add button
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
            child: ElevatedButton(
              onPressed: _adding
                  ? null
                  : () async {
                      setState(() => _adding = true);
                      await widget.onConfirm(_price, _qty, _source, _batchPriceId);
                      if (mounted) Navigator.of(context).pop();
                    },
              style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48)),
              child: _adding
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(
                      '${widget.confirmLabel}  ·  LKR ${formatAmount(subtotal)}',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}

class QtyCounter extends StatelessWidget {
  final double qty;
  final Color primary;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;
  final ValueChanged<double>? onQtyChanged;
  const QtyCounter({
    super.key,
    required this.qty,
    required this.primary,
    required this.onDecrement,
    required this.onIncrement,
    this.onQtyChanged,
  });

  Future<void> _editQty(BuildContext context) async {
    if (onQtyChanged == null) return;
    final ctrl = TextEditingController(
        text: qty % 1 == 0 ? qty.toInt().toString() : qty.toString());
    final entered = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Quantity'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          onSubmitted: (v) => Navigator.of(ctx).pop(double.tryParse(v)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(double.tryParse(ctrl.text)),
              child: const Text('Set')),
        ],
      ),
    );
    if (entered != null && entered > 0) onQtyChanged!(entered);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.06),
        borderRadius: BorderRadius.circular(50),
        border: Border.all(color: Colors.black.withOpacity(0.2)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _Btn(icon: Icons.remove_rounded, onTap: onDecrement, color: Colors.black),
        InkWell(
          onTap: onQtyChanged == null ? null : () => _editQty(context),
          child: SizedBox(
            width: 34,
            child: Text(
              qty % 1 == 0 ? qty.toInt().toString() : qty.toStringAsFixed(1),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: Colors.black),
            ),
          ),
        ),
        _Btn(icon: Icons.add_rounded, onTap: onIncrement, color: Colors.black),
      ]),
    );
  }
}

class _Btn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color color;
  const _Btn({required this.icon, required this.onTap, required this.color});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(50),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(icon, size: 18, color: color),
        ),
      );
}

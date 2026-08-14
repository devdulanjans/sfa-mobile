import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/colors.dart';
import '../../app/radii.dart';
import '../../core/network/api_client.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/empty_state.dart';
import '../../utils/formatters.dart';

// ── Line item model ────────────────────────────────────────────────────────────

class _Line {
  final String description;
  final double unitPrice;
  final double qty;

  const _Line({required this.description, required this.unitPrice, required this.qty});

  double get lineTotal => unitPrice * qty;
}

// ── Screen ─────────────────────────────────────────────────────────────────────

class PosCalculatorScreen extends ConsumerStatefulWidget {
  const PosCalculatorScreen({super.key});

  @override
  ConsumerState<PosCalculatorScreen> createState() => _PosCalculatorScreenState();
}

class _PosCalculatorScreenState extends ConsumerState<PosCalculatorScreen> {
  final _descCtl  = TextEditingController();
  final _priceCtl = TextEditingController();
  final _qtyCtl   = TextEditingController(text: '1');

  final _priceFocus = FocusNode();
  final _qtyFocus   = FocusNode();

  final List<_Line> _lines = [];

  double get _grandTotal => _lines.fold(0.0, (s, l) => s + l.lineTotal);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _priceFocus.requestFocus());
  }

  @override
  void dispose() {
    _descCtl.dispose();
    _priceCtl.dispose();
    _qtyCtl.dispose();
    _priceFocus.dispose();
    _qtyFocus.dispose();
    super.dispose();
  }

  // ── Add line ─────────────────────────────────────────────────────────────────

  void _addLine() {
    final price = double.tryParse(_priceCtl.text.replaceAll(',', ''));
    final qty   = double.tryParse(_qtyCtl.text) ?? 1.0;

    if (price == null || price <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid amount'), duration: Duration(seconds: 1)),
      );
      _priceFocus.requestFocus();
      return;
    }

    setState(() {
      _lines.add(_Line(
        description: _descCtl.text.trim(),
        unitPrice:   price,
        qty:         qty <= 0 ? 1 : qty,
      ));
      _descCtl.clear();
      _priceCtl.clear();
      _qtyCtl.text = '1';
    });

    _priceFocus.requestFocus();
  }

  void _removeLine(int index) => setState(() => _lines.removeAt(index));

  void _clearAll() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear all items?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () { setState(() => _lines.clear()); Navigator.pop(context); },
            child: const Text('Clear', style: TextStyle(color: AppColors.pinkFg)),
          ),
        ],
      ),
    );
  }

  // ── Complete sale ─────────────────────────────────────────────────────────────

  Future<void> _completeSale() async {
    if (_lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one item first')),
      );
      return;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _PaymentSheet(
        total: _grandTotal,
        onSubmit: _submitSale,
      ),
    );
  }

  Future<void> _submitSale({
    required String paymentMethod,
    required double? amountTendered,
    required String customerName,
    required String notes,
  }) async {
    final dio = ref.read(dioProvider);

    try {
      final resp = await dio.post('/pos/sales', data: {
        if (customerName.isNotEmpty) 'customerName': customerName,
        'paymentMethod': paymentMethod,
        if (amountTendered != null) 'amountTendered': amountTendered,
        if (notes.isNotEmpty) 'notes': notes,
        'items': _lines.map((l) => {
          'productName': l.description.isEmpty ? 'Item' : l.description,
          'quantity':    l.qty,
          'unitPrice':   l.unitPrice,
          'discountPct': 0,
          'taxPct':      0,
        }).toList(),
      });

      final saleNo = resp.data['saleNumber'] as String? ?? '';

      if (mounted) {
        Navigator.of(context).pop(); // close payment sheet
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sale $saleNo recorded successfully'),
            backgroundColor: AppColors.mintFg,
          ),
        );
        setState(() => _lines.clear());
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save sale: ${e.toString()}'),
            backgroundColor: AppColors.pinkFg,
          ),
        );
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBg,
      appBar: AppBar(
        title: const Text('POS Calculator'),
        actions: [
          if (_lines.isNotEmpty)
            TextButton(
              onPressed: _clearAll,
              child: const Text('Clear', style: TextStyle(color: AppColors.pinkFg)),
            ),
        ],
      ),

      body: Column(
        children: [
          // ── Entry card ───────────────────────────────────────────────────────
          _EntryCard(
            descCtl:    _descCtl,
            priceCtl:   _priceCtl,
            qtyCtl:     _qtyCtl,
            priceFocus: _priceFocus,
            qtyFocus:   _qtyFocus,
            onAdd:      _addLine,
          ),

          // ── Line items list ──────────────────────────────────────────────────
          Expanded(
            child: _lines.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: EmptyState(
                      message: 'No items yet. Enter amount & qty above, then tap Add.',
                      icon: Icons.calculate_outlined,
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    itemCount: _lines.length,
                    itemBuilder: (ctx, i) {
                      final line = _lines[i];
                      return Dismissible(
                        key: ValueKey(Object.hash(i, line.description, line.unitPrice, line.qty)),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: AppColors.pinkFg,
                            borderRadius: BorderRadius.circular(AppRadius.lg),
                          ),
                          child: const Icon(Icons.delete_rounded, color: Colors.white),
                        ),
                        onDismissed: (_) => _removeLine(i),
                        child: _LineCard(
                          line:    line,
                          index:   i + 1,
                          onDelete: () => _removeLine(i),
                        ),
                      );
                    },
                  ),
          ),

          // ── Total bar + complete button ───────────────────────────────────────
          _TotalBar(
            total:        _grandTotal,
            lineCount:    _lines.length,
            onComplete:   _completeSale,
          ),
        ],
      ),
    );
  }
}

// ── Entry card ─────────────────────────────────────────────────────────────────

class _EntryCard extends StatelessWidget {
  final TextEditingController descCtl, priceCtl, qtyCtl;
  final FocusNode priceFocus, qtyFocus;
  final VoidCallback onAdd;

  const _EntryCard({
    required this.descCtl, required this.priceCtl, required this.qtyCtl,
    required this.priceFocus, required this.qtyFocus, required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Description row
            TextField(
              controller: descCtl,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                hintText:  'e.g. Ice Block 5kg',
                isDense: true,
                prefixIcon: Icon(Icons.label_outline, size: 18),
              ),
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => priceFocus.requestFocus(),
            ),
            const SizedBox(height: 10),

            // Price + Qty + Add row
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Unit price
                Expanded(
                  flex: 5,
                  child: TextField(
                    controller: priceCtl,
                    focusNode:  priceFocus,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
                    decoration: const InputDecoration(
                      labelText: 'Amount (LKR)',
                      hintText:  '0.00',
                      isDense: true,
                      prefixText: 'Rs ',
                    ),
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => qtyFocus.requestFocus(),
                  ),
                ),
                const SizedBox(width: 8),

                // Qty
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: qtyCtl,
                    focusNode:  qtyFocus,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
                    decoration: const InputDecoration(
                      labelText: 'Qty',
                      hintText:  '1',
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => onAdd(),
                  ),
                ),
                const SizedBox(width: 8),

                // Add button
                SizedBox(
                  height: 56,
                  child: ElevatedButton(
                    onPressed: onAdd,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_rounded, size: 20),
                        Text('Add', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Line card ──────────────────────────────────────────────────────────────────

class _LineCard extends StatelessWidget {
  final _Line line;
  final int index;
  final VoidCallback onDelete;

  const _LineCard({required this.line, required this.index, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final qtyStr = line.qty == line.qty.truncateToDouble()
        ? line.qty.toInt().toString()
        : line.qty.toStringAsFixed(2);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            // Index badge
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: AppColors.violetBg,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              alignment: Alignment.center,
              child: Text(
                '$index',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppColors.violetFg,
                ),
              ),
            ),
            const SizedBox(width: 12),

            // Description + qty × price
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    line.description.isEmpty ? 'Item' : line.description,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$qtyStr × ${formatAmount(line.unitPrice)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),

            // Line total
            Text(
              formatAmount(line.lineTotal),
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: AppColors.violetFg,
              ),
            ),
            const SizedBox(width: 4),

            // Delete
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              color: AppColors.pinkFg,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              tooltip: 'Remove',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Total bar ──────────────────────────────────────────────────────────────────

class _TotalBar extends StatelessWidget {
  final double total;
  final int lineCount;
  final VoidCallback onComplete;

  const _TotalBar({required this.total, required this.lineCount, required this.onComplete});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.scaffoldBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Total display
          AppCard(
            tone: AppTone.mint,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$lineCount item${lineCount == 1 ? '' : 's'}',
                      style: TextStyle(fontSize: 12, color: AppColors.mintFg.withValues(alpha: 0.75)),
                    ),
                    const Text('Total', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.mintFg)),
                  ],
                ),
                Text(
                  'LKR ${formatAmount(total)}',
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: AppColors.mintFg,
                    letterSpacing: -0.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Complete sale button
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              onPressed: lineCount > 0 ? onComplete : null,
              icon: const Icon(Icons.point_of_sale_rounded),
              label: const Text('Complete Sale', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Payment sheet ──────────────────────────────────────────────────────────────

typedef _OnSubmit = Future<void> Function({
  required String paymentMethod,
  required double? amountTendered,
  required String customerName,
  required String notes,
});

class _PaymentSheet extends StatefulWidget {
  final double total;
  final _OnSubmit onSubmit;

  const _PaymentSheet({required this.total, required this.onSubmit});

  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  String _method      = 'CASH';
  bool   _submitting  = false;
  double? _change;

  final _custCtl      = TextEditingController();
  final _notesCtl     = TextEditingController();
  final _tenderedCtl  = TextEditingController();

  @override
  void dispose() {
    _custCtl.dispose();
    _notesCtl.dispose();
    _tenderedCtl.dispose();
    super.dispose();
  }

  void _calcChange() {
    final tendered = double.tryParse(_tenderedCtl.text) ?? 0;
    setState(() => _change = tendered >= widget.total ? tendered - widget.total : null);
  }

  Future<void> _submit() async {
    if (_method == 'CASH') {
      final tendered = double.tryParse(_tenderedCtl.text) ?? 0;
      if (tendered < widget.total) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Amount tendered must be ≥ total')),
        );
        return;
      }
    }

    setState(() => _submitting = true);
    await widget.onSubmit(
      paymentMethod:  _method,
      amountTendered: _method == 'CASH' ? double.tryParse(_tenderedCtl.text) : null,
      customerName:   _custCtl.text.trim(),
      notes:          _notesCtl.text.trim(),
    );
    if (mounted) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 16),

            Text('Complete Sale', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Total: LKR ${formatAmount(widget.total)}',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            const SizedBox(height: 20),

            // Payment method
            const Text('Payment Method', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(
              children: ['CASH', 'CARD', 'CREDIT'].map((m) {
                final active = _method == m;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() { _method = m; _change = null; _tenderedCtl.clear(); }),
                    child: Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color:  active ? AppColors.violetBg : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        m,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: active ? AppColors.violetFg : Colors.grey.shade700,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            // Cash tendered (only for CASH)
            if (_method == 'CASH') ...[
              TextField(
                controller: _tenderedCtl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
                decoration: const InputDecoration(
                  labelText: 'Amount Tendered (LKR)',
                  prefixText: 'Rs ',
                  isDense: true,
                ),
                onChanged: (_) => _calcChange(),
              ),
              if (_change != null) ...[
                const SizedBox(height: 8),
                AppCard(
                  tone: AppTone.mint,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  radius: AppRadius.sm,
                  child: Row(
                    children: [
                      const Icon(Icons.payments_outlined, size: 16, color: AppColors.mintFg),
                      const SizedBox(width: 8),
                      Text('Change: LKR ${formatAmount(_change!)}',
                          style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.mintFg)),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
            ],

            // Customer name
            TextField(
              controller: _custCtl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Customer Name (optional)',
                hintText:  'Walk-in customer',
                isDense: true,
                prefixIcon: Icon(Icons.person_outline, size: 18),
              ),
            ),
            const SizedBox(height: 12),

            // Notes
            TextField(
              controller: _notesCtl,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                isDense: true,
                prefixIcon: Icon(Icons.notes_outlined, size: 18),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 20),

            // Submit
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox(width: 22, height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Record Sale', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

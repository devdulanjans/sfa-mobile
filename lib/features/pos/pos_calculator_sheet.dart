import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/network/api_client.dart';
import '../../utils/formatters.dart';

// ── Entry point ────────────────────────────────────────────────────────────────

void showPosCalculator(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _PosCalculatorSheet(),
  );
}

// ── Line item model ────────────────────────────────────────────────────────────

class _Line {
  final String description;
  final double unitPrice;
  final double qty;

  const _Line({required this.description, required this.unitPrice, required this.qty});

  double get lineTotal => unitPrice * qty;
}

// ── Sheet root ─────────────────────────────────────────────────────────────────

class _PosCalculatorSheet extends ConsumerStatefulWidget {
  const _PosCalculatorSheet();

  @override
  ConsumerState<_PosCalculatorSheet> createState() => _PosCalculatorSheetState();
}

class _PosCalculatorSheetState extends ConsumerState<_PosCalculatorSheet> {
  final _descCtl  = TextEditingController();
  final _priceCtl = TextEditingController();
  final _qtyCtl   = TextEditingController(text: '1');

  final _priceFocus = FocusNode();
  final _qtyFocus   = FocusNode();

  final List<_Line> _lines = [];

  double get _grandTotal => _lines.fold(0.0, (s, l) => s + l.lineTotal);

  // Live preview of the current entry (before pressing Add)
  double get _entryPreview {
    final price = double.tryParse(_priceCtl.text) ?? 0;
    final qty   = double.tryParse(_qtyCtl.text)   ?? 1;
    return price * (qty <= 0 ? 1 : qty);
  }

  @override
  void initState() {
    super.initState();
    _priceCtl.addListener(() => setState(() {}));
    _qtyCtl.addListener(() => setState(() {}));
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
    final price = double.tryParse(_priceCtl.text);
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
        content: const Text('This will remove all lines from the calculator.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () { setState(() => _lines.clear()); Navigator.pop(context); },
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
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
      builder: (_) => _PaymentSheet(total: _grandTotal, onSubmit: _submitSale),
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
        Navigator.of(context)
          ..pop()   // payment sheet
          ..pop();  // calculator sheet
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Sale $saleNo recorded'),
          backgroundColor: Colors.green.shade700,
        ));
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // payment sheet
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to save sale: $e'),
          backgroundColor: Colors.red.shade700,
        ));
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sheetH = MediaQuery.of(context).size.height * 0.88;

    return Container(
      height: sheetH,
      decoration: const BoxDecoration(
        color: Color(0xFFF5F5F5),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // ── Header ──────────────────────────────────────────────────────────
          _SheetHeader(
            lineCount: _lines.length,
            onClear:   _lines.isEmpty ? null : _clearAll,
          ),

          // ── Entry card ───────────────────────────────────────────────────────
          _EntryCard(
            descCtl:       _descCtl,
            priceCtl:      _priceCtl,
            qtyCtl:        _qtyCtl,
            priceFocus:    _priceFocus,
            qtyFocus:      _qtyFocus,
            entryPreview:  _entryPreview,
            onAdd:         _addLine,
          ),

          // ── Line items ───────────────────────────────────────────────────────
          Expanded(
            child: _lines.isEmpty
                ? _EmptyHint()
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
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
                            color: Colors.red.shade400,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.delete_rounded, color: Colors.white),
                        ),
                        onDismissed: (_) => _removeLine(i),
                        child: _LineCard(line: line, index: i + 1, onDelete: () => _removeLine(i)),
                      );
                    },
                  ),
          ),

          // ── Total + action bar ────────────────────────────────────────────────
          _TotalBar(
            total:      _grandTotal,
            lineCount:  _lines.length,
            onComplete: _completeSale,
          ),
        ],
      ),
    );
  }
}

// ── Sheet header ───────────────────────────────────────────────────────────────

class _SheetHeader extends StatelessWidget {
  final int lineCount;
  final VoidCallback? onClear;

  const _SheetHeader({required this.lineCount, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.calculate_rounded, size: 20, color: Colors.blueGrey),
              const SizedBox(width: 8),
              const Text('POS Calculator',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const Spacer(),
              if (onClear != null)
                TextButton(
                  onPressed: onClear,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.red,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  child: const Text('Clear all'),
                ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 20),
                onPressed: () => Navigator.pop(context),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 4),
            ],
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
  final double entryPreview;
  final VoidCallback onAdd;

  const _EntryCard({
    required this.descCtl, required this.priceCtl, required this.qtyCtl,
    required this.priceFocus, required this.qtyFocus,
    required this.entryPreview, required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasPreview = entryPreview > 0;

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1),
          const SizedBox(height: 10),

          // Description
          TextField(
            controller: descCtl,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Description',
              hintText:  'e.g. Ice Block 5kg  (optional)',
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => priceFocus.requestFocus(),
          ),
          const SizedBox(height: 8),

          // Amount × Qty row
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Amount
              Expanded(
                flex: 5,
                child: TextField(
                  controller: priceCtl,
                  focusNode:  priceFocus,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
                  decoration: const InputDecoration(
                    labelText: 'Amount',
                    hintText:  '0.00',
                    prefixText: 'Rs ',
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => qtyFocus.requestFocus(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text('×', style: TextStyle(fontSize: 18, color: Colors.grey.shade500)),
              ),

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
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => onAdd(),
                ),
              ),
              const SizedBox(width: 6),

              // Live preview
              SizedBox(
                width: 90,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      hasPreview ? '= ${formatAmount(entryPreview)}' : '= —',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: hasPreview ? Colors.green.shade700 : Colors.grey.shade400,
                      ),
                    ),
                    Text('LKR', style: TextStyle(fontSize: 10, color: Colors.grey.shade400)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Add button
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add Item', style: TextStyle(fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: scheme.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
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
    final scheme = Theme.of(context).colorScheme;
    final qtyStr = line.qty == line.qty.truncateToDouble()
        ? line.qty.toInt().toString()
        : line.qty.toStringAsFixed(2);

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            // Index
            Container(
              width: 24, height: 24,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              alignment: Alignment.center,
              child: Text('$index',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold,
                      color: scheme.onPrimaryContainer)),
            ),
            const SizedBox(width: 10),

            // Description + qty × price
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    line.description.isEmpty ? 'Item' : line.description,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '$qtyStr × ${formatAmount(line.unitPrice)}',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),

            // Line total
            Text(formatAmount(line.lineTotal),
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: scheme.primary)),
            const SizedBox(width: 4),

            // Delete
            GestureDetector(
              onTap: onDelete,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.close_rounded, size: 16, color: Colors.grey.shade400),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Empty hint ─────────────────────────────────────────────────────────────────

class _EmptyHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.receipt_long_outlined, size: 48, color: Colors.grey.shade300),
          const SizedBox(height: 8),
          Text('No items yet',
              style: TextStyle(color: Colors.grey.shade500, fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text('Enter amount & qty, then tap Add Item',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
        ],
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
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, MediaQuery.of(context).padding.bottom + 12),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, -2))],
      ),
      child: Row(
        children: [
          // Total
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$lineCount item${lineCount == 1 ? '' : 's'}',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                Text(
                  'LKR ${formatAmount(total)}',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: lineCount > 0 ? scheme.primary : Colors.grey.shade400,
                    letterSpacing: -0.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),

          // Complete button
          ElevatedButton.icon(
            onPressed: lineCount > 0 ? onComplete : null,
            icon: const Icon(Icons.point_of_sale_rounded, size: 18),
            label: const Text('Complete Sale', style: TextStyle(fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
  String  _method     = 'CASH';
  double? _change;
  bool    _submitting = false;

  final _custCtl     = TextEditingController();
  final _notesCtl    = TextEditingController();
  final _tenderedCtl = TextEditingController();

  @override
  void dispose() {
    _custCtl.dispose(); _notesCtl.dispose(); _tenderedCtl.dispose();
    super.dispose();
  }

  void _calcChange() {
    final t = double.tryParse(_tenderedCtl.text) ?? 0;
    setState(() => _change = t >= widget.total ? t - widget.total : null);
  }

  Future<void> _submit() async {
    if (_method == 'CASH') {
      final t = double.tryParse(_tenderedCtl.text) ?? 0;
      if (t < widget.total) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Amount tendered must be ≥ total')));
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
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Container(width: 36, height: 4,
                decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 14),

            Text('Complete Sale', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text('Total: LKR ${formatAmount(widget.total)}',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            const SizedBox(height: 18),

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
                        color: active ? scheme.primary : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(10),
                        border: active ? null : Border.all(color: Colors.grey.shade300),
                      ),
                      alignment: Alignment.center,
                      child: Text(m,
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13,
                              color: active ? Colors.white : Colors.grey.shade700)),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 14),

            // Cash tendered
            if (_method == 'CASH') ...[
              TextField(
                controller: _tenderedCtl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
                decoration: const InputDecoration(
                  labelText: 'Amount Tendered (LKR)',
                  prefixText: 'Rs ',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => _calcChange(),
              ),
              if (_change != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    border: Border.all(color: Colors.green.shade200),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    const Icon(Icons.payments_outlined, size: 16, color: Colors.green),
                    const SizedBox(width: 8),
                    Text('Change: LKR ${formatAmount(_change!)}',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
                  ]),
                ),
              ],
              const SizedBox(height: 14),
            ],

            // Customer name
            TextField(
              controller: _custCtl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Customer Name (optional)',
                hintText:  'Walk-in customer',
                isDense: true,
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person_outline, size: 18),
              ),
            ),
            const SizedBox(height: 10),

            // Notes
            TextField(
              controller: _notesCtl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                isDense: true,
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.notes_outlined, size: 18),
              ),
            ),
            const SizedBox(height: 18),

            // Submit
            SizedBox(
              width: double.infinity, height: 50,
              child: ElevatedButton(
                onPressed: _submitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: scheme.primary, foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _submitting
                    ? const SizedBox(width: 22, height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Record Sale',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '../../utils/formatters.dart';

/// Shown when more than one promotion is active for a product and the
/// `promotion_manual_selection` system setting is on (the default) — lets the rep
/// pick exactly one. That choice is exclusive: the backend prices the paid unit from
/// the chosen promotion only, and excludes any other (e.g. a Buy-X-Get-Y) promotion's
/// free item for this product — see PricingEngine.resolve's promotionId javadoc.
class PromotionPickerSheet extends StatefulWidget {
  final String productName;
  final List<Map<String, dynamic>> promotions;
  final void Function(Map<String, dynamic> promotion) onConfirm;

  const PromotionPickerSheet({
    super.key,
    required this.productName,
    required this.promotions,
    required this.onConfirm,
  });

  @override
  State<PromotionPickerSheet> createState() => _PromotionPickerSheetState();
}

class _PromotionPickerSheetState extends State<PromotionPickerSheet> {
  int _selected = 0;

  String _describe(Map<String, dynamic> promo) {
    final type = promo['type'] as String?;
    final value = (promo['discountValue'] as num?)?.toDouble() ?? 0;
    switch (type) {
      case 'PERCENTAGE':
        return '${value % 1 == 0 ? value.toInt() : value}% off';
      case 'FIXED_AMOUNT':
        return 'LKR ${formatAmount(value)} off';
      case 'FREE_PRODUCT':
        final name = promo['freeProductName'] as String? ?? 'item';
        final count = (promo['maxFreeCount'] as num?)?.toInt() ?? 1;
        final minQty = (promo['minOrderQty'] as num?)?.toInt() ?? 1;
        return 'Buy $minQty+, get $count free $name';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              width: 40, height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.productName,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 2),
              const Text('More than one promotion applies — choose one',
                  style: TextStyle(fontSize: 13, color: Colors.grey)),
            ]),
          ),

          const Divider(height: 1),

          ...widget.promotions.asMap().entries.map((e) {
            final i = e.key;
            final promo = e.value;
            final sel = i == _selected;

            return InkWell(
              onTap: () => setState(() => _selected = i),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: sel ? primary.withValues(alpha: 0.06) : null,
                  border: Border(
                      left: BorderSide(
                          color: sel ? primary : Colors.transparent, width: 3)),
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
                      Text(promo['name'] as String? ?? '',
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: sel ? primary : null)),
                      const SizedBox(height: 2),
                      Text(_describe(promo),
                          style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    ]),
                  ),
                ]),
              ),
            );
          }),

          const Divider(height: 1),

          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            child: ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                widget.onConfirm(widget.promotions[_selected]);
              },
              style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
              child: const Text('Apply Promotion',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';
import '../../app/colors.dart';
import '../../app/radii.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/local_db.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/section_header.dart';
import '../../shared/widgets/status_badge.dart';
import '../../utils/formatters.dart';
import 'offline_pricing.dart';
import 'order_provider.dart';
import 'price_tiers_sheet.dart';

class OrderCreationScreen extends ConsumerStatefulWidget {
  const OrderCreationScreen({super.key});
  @override
  ConsumerState<OrderCreationScreen> createState() => _OrderCreationScreenState();
}

class _OrderCreationScreenState extends ConsumerState<OrderCreationScreen> {
  Map<String, dynamic>? _selectedCustomer;
  String _customerQuery = '';
  String _productQuery  = '';

  /// productId → customer-specific price; empty when no overrides or offline.
  Map<String, double> _customerPriceOverrides = {};

  /// productIds with active batch pricing visible to this customer — loaded
  /// live so it doesn't depend on Full Sync having been run recently.
  Set<String> _batchPricingProductIds = {};

  @override
  void initState() {
    super.initState();
    // Restore customer from an in-progress draft so cart survives navigation.
    // Look the full record up in the local cache (by id) rather than
    // fabricating a bare {id, name} stub — a stub is missing fields like
    // assignedProductIds, which would silently disable the customer's
    // product-visibility restriction (empty list reads as "no restriction").
    final draft = ref.read(orderCreationProvider);
    if (draft != null) {
      final cached = LocalDb.customers
          .where((c) => c['id'] == draft.customerId)
          .firstOrNull;
      _selectedCustomer = cached != null
          ? Map<String, dynamic>.from(cached)
          : {'id': draft.customerId, 'name': draft.customerName};
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadCustomerPriceOverrides(draft.customerId);
        _loadBatchPricingProductIds(draft.customerId);
      });
    }
  }

  Future<void> _loadBatchPricingProductIds(String customerId) async {
    try {
      final dio  = ref.read(dioProvider);
      final resp = await dio.get('/pricing/batch-product-ids',
          queryParameters: {'customerId': customerId});
      final ids = List<String>.from((resp.data as List).map((e) => e.toString()));
      if (!mounted) return;
      setState(() => _batchPricingProductIds = ids.toSet());
    } catch (e) {
      debugPrint('[BatchPricing] Live lookup failed, falling back to cache: $e');
      // Offline / request failed — fall back to whatever was last synced locally.
      final ids = LocalDb.products
          .map((p) => p['id'] as String? ?? '')
          .where((id) => id.isNotEmpty && hasBatchPricing(id, customerId))
          .toSet();
      if (!mounted) return;
      setState(() => _batchPricingProductIds = ids);
    }
  }

  Future<void> _loadCustomerPriceOverrides(String customerId) async {
    try {
      final dio  = ref.read(dioProvider);
      final resp = await dio.get('/pricing/customer-overrides',
          queryParameters: {'customerId': customerId});
      final raw = (resp.data as Map<String, dynamic>);
      debugPrint('[PriceOverrides] ${raw.length} override(s): $raw');
      if (!mounted) return;
      setState(() {
        _customerPriceOverrides = raw.map((k, v) => MapEntry(k, (v as num).toDouble()));
      });
      if (raw.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${raw.length} special price(s) loaded'),
          duration: const Duration(seconds: 2),
          backgroundColor: Colors.green.shade700,
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No special prices found for this customer'),
          duration: Duration(seconds: 3),
        ));
      }
    } catch (e) {
      debugPrint('[PriceOverrides] FAILED — ${e.runtimeType}: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Special prices unavailable: ${e.runtimeType}'),
          duration: const Duration(seconds: 3),
          backgroundColor: Colors.red.shade700,
        ));
      }
    }
  }

  List<Map> get _customers {
    final q = _customerQuery.toLowerCase();
    return LocalDb.customers
        .where((c) => c['deletedAt'] == null && (
            q.isEmpty ||
            (c['name'] as String? ?? '').toLowerCase().contains(q) ||
            (c['code'] as String? ?? '').toLowerCase().contains(q) ||
            (c['placeOfSupplier'] as String? ?? '').toLowerCase().contains(q)))
        .toList();
  }

  List<Map> get _products {
    final q = _productQuery.toLowerCase();
    var all = LocalDb.products
        .where((p) =>
            p['status'] == 'ACTIVE' &&
            (q.isEmpty ||
                (p['name'] as String? ?? '').toLowerCase().contains(q) ||
                (p['code'] as String? ?? '').toLowerCase().contains(q)))
        .toList();

    // Assignment itself is the signal that restricts the catalog — not the
    // visibilityRule flag, which can drift out of sync with the actual
    // assignment list. A customer with no assigned products sees the full
    // catalog; any assignment narrows it to just those products.
    // effectiveAssignedProductIds includes both this customer's direct
    // assignments and every customer group they belong to.
    if (_selectedCustomer != null) {
      final assigned = List<String>.from(
          (_selectedCustomer!['effectiveAssignedProductIds'] as List?)?.map((e) => e.toString()) ?? []);
      if (assigned.isNotEmpty) {
        all = all.where((p) => assigned.contains(p['id'] as String? ?? '')).toList();
      }
    }

    return all;
  }

  Future<void> _selectCustomer(Map c) async {
    final existing = ref.read(orderCreationProvider);
    final isSame = existing?.customerId == (c['id'] as String);

    if (!isSame && existing != null && existing.items.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Change customer?'),
          content: const Text('Switching customer will clear the current cart.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Clear & Switch')),
          ],
        ),
      );
      if (ok != true) return;
    }

    if (!isSame) {
      ref.read(orderCreationProvider.notifier).startOrder(
          c['id'] as String, c['name'] as String);
      setState(() {
        _customerPriceOverrides = {};
        _batchPricingProductIds = {};
      });
      _loadCustomerPriceOverrides(c['id'] as String);
      _loadBatchPricingProductIds(c['id'] as String);
    }
    setState(() {
      _selectedCustomer = Map<String, dynamic>.from(c);
      _customerQuery = '';
    });
  }

  Future<void> _proceed() async {
    final draft = ref.read(orderCreationProvider);
    if (draft == null || draft.items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Add at least one product')));
      return;
    }
    context.push('/orders/review');
  }

  @override
  Widget build(BuildContext context) {
    final draft      = ref.watch(orderCreationProvider);
    final cartCount  = draft?.items.fold<int>(0, (s, i) => s + i.qty.ceil()) ?? 0;
    final hasItems   = cartCount > 0;
    final primary    = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('New Order'),
        actions: [
          // Cart badge
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Stack(
              alignment: Alignment.center,
              children: [
                IconButton(
                  icon: Icon(hasItems
                      ? Icons.shopping_cart
                      : Icons.shopping_cart_outlined),
                  color: hasItems ? primary : null,
                  onPressed: hasItems ? () => _showCartSheet(context, draft!) : null,
                  tooltip: 'View cart',
                ),
                if (hasItems)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        color: AppColors.pinkFg,
                        shape: BoxShape.circle,
                      ),
                      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                      child: Text(
                        cartCount > 99 ? '99+' : '$cartCount',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),

      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(16, 16, 16, hasItems ? 88 : 16),
            children: [
              // ── Customer ──────────────────────────────────────────────────
              const SectionHeader(
                  title: 'Customer',
                  icon: Icons.person_outline,
                  tone: AppTone.violet),
              const SizedBox(height: 10),
              if (_selectedCustomer == null) ...[
                TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search by name or code…',
                    prefixIcon: Icon(Icons.search, size: 18),
                  ),
                  onChanged: (v) => setState(() => _customerQuery = v),
                ),
                const SizedBox(height: 8),
                if (_customers.isEmpty)
                  const EmptyState(
                      message: 'No customers found',
                      icon: Icons.person_search_outlined)
                else
                  ...(_customers.take(8).map((c) => _CustomerPickerCard(
                        customer: c,
                        onTap: () => _selectCustomer(c),
                      ))),
              ] else
                _SelectedCustomerCard(
                  customer: _selectedCustomer!,
                  onClear: () {
                    ref.read(orderCreationProvider.notifier).clearOrder();
                    setState(() {
                      _selectedCustomer = null;
                      _customerQuery = '';
                    });
                  },
                ),

              // ── Products ──────────────────────────────────────────────────
              if (_selectedCustomer != null) ...[
                const SizedBox(height: 20),
                Row(children: [
                  const Expanded(
                    child: SectionHeader(
                        title: 'Products',
                        icon: Icons.inventory_2_outlined,
                        tone: AppTone.violet),
                  ),
                  if (_productQuery.isEmpty && _products.isNotEmpty)
                    Text('${_products.length} available',
                        style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ]),
                const SizedBox(height: 10),
                TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search products…',
                    prefixIcon: Icon(Icons.search, size: 18),
                  ),
                  onChanged: (v) => setState(() => _productQuery = v),
                ),
                const SizedBox(height: 10),
                if (_products.isEmpty)
                  const EmptyState(
                      message: 'No products found',
                      icon: Icons.inventory_2_outlined)
                else
                  ...(_products.take(20).map((p) => _ProductCard(
                        product: p,
                        customerId: _selectedCustomer!['id'] as String,
                        customerPrice:
                            _customerPriceOverrides[p['id'] as String? ?? ''],
                        hasBatchPricing: _batchPricingProductIds
                            .contains(p['id'] as String? ?? ''),
                      ))),
              ],

              const SizedBox(height: 8),
            ],
          ),

          // ── Floating cart bar ──────────────────────────────────────────────
          if (hasItems && _selectedCustomer != null)
            Positioned(
              left: 16, right: 16, bottom: 16,
              child: SafeArea(
                top: false,
                child: Material(
                  color: AppColors.violetBg,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    onTap: _proceed,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _selectedCustomer!['name'] as String? ?? '',
                                  style: const TextStyle(
                                      color: AppColors.violetFg,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  '${draft!.items.length} item${draft.items.length == 1 ? '' : 's'}',
                                  style: TextStyle(
                                      color: AppColors.violetFg.withValues(alpha: 0.75),
                                      fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            // No tax here — tax is an order-level concern shown
                            // once in Review Order, not during cart-building.
                            'LKR ${formatAmount(draft!.subtotal)}',
                            style: const TextStyle(
                                color: AppColors.violetFg,
                                fontWeight: FontWeight.w800,
                                fontSize: 16),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.arrow_forward_ios_rounded,
                              color: AppColors.violetFg, size: 14),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),

    );
  }

  void _showCartSheet(BuildContext context, OrderDraft draft) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl))),
      builder: (_) => _CartBottomSheet(draft: draft, onProceed: _proceed),
    );
  }
}

// ─── Product Card ─────────────────────────────────────────────────────────────

class _ProductCard extends ConsumerStatefulWidget {
  final Map product;
  final String customerId;
  /// Pre-loaded customer-specific price (null = none assigned for this customer).
  final double? customerPrice;
  /// Whether this product has any active batch price tier for this customer.
  final bool hasBatchPricing;
  const _ProductCard({
    required this.product,
    required this.customerId,
    this.customerPrice,
    this.hasBatchPricing = false,
  });

  @override
  ConsumerState<_ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends ConsumerState<_ProductCard> {
  bool _loading = false;

  String get _productId => widget.product['id'] as String;

  double _cartQty(OrderDraft? draft) {
    if (draft == null) return 0;
    // Exclude FREE_PRODUCT lines so the qty counter reflects paid qty only
    return draft.items
        .where((i) => i.productId == _productId && i.priceSource != 'FREE_PRODUCT')
        .fold<double>(0, (s, i) => s + i.qty);
  }

  Future<void> _addFirst() async {
    if (_loading) return;
    setState(() => _loading = true);

    debugPrint('[AddFirst] ${widget.product['name']} customerPrice=${widget.customerPrice}');

    // Resolve full pricing (customer price → promotion → batch price → default;
    // works offline too) so any FREE_PRODUCT promotion is detected regardless of
    // which price source ends up pricing the paid unit — a customer-specific
    // override doesn't preclude this product also being a promotion's trigger.
    //
    // Deliberately NOT short-circuiting on a pre-loaded `widget.customerPrice`
    // here: a customer can have a baseline customer-specific price *and* a
    // separate higher-qty tier (customer-specific or general) — resolvedSource
    // only reflects whichever one step 1 of the pricing priority picked, so
    // relying on it (or skipping resolution altogether) can hide real tiers
    // that `widget.hasBatchPricing` below already knows exist.
    final result = await resolvePricing(
        ref.read(dioProvider), _productId, widget.customerId);
    final resolvedSource = result['priceSource'] as String? ?? 'DEFAULT_PRICE';
    final freeProductData = result['freeProduct'] as Map<String, dynamic>?;
    debugPrint('[AddFirst] Resolved ${widget.product['name']} → $result');

    if (!mounted) return;

    // Check tiers whenever ANY batch price (general or customer-specific) is
    // active for this product — not just when resolvedSource says 'BATCH_PRICE',
    // since a customer-specific price can win step 1 even while other qty
    // tiers also apply. Also check for a FREE_PRODUCT promo trigger, whose
    // own unit price is unaffected (only the separate free line is discounted).
    final shouldCheckTiers = widget.hasBatchPricing ||
        (resolvedSource == 'PROMOTION' && freeProductData != null);

    if (shouldCheckTiers) {
      try {
        final dio  = ref.read(dioProvider);
        final resp = await dio.get('/pricing/tiers', queryParameters: {
          'productId':  _productId,
          'customerId': widget.customerId,
        });
        final tiers = List<Map<String, dynamic>>.from(resp.data as List? ?? []);
        if (!mounted) return;

        if (tiers.isEmpty) {
          await _addResolved(result);
          if (mounted) setState(() => _loading = false);
        } else {
          setState(() => _loading = false);
          _showTierSheet(tiers, freeProductData: freeProductData);
        }
      } catch (e) {
        if (!mounted) return;
        debugPrint('[AddFirst] Tiers fetch failed: $e');
        await _addResolved(result);
        if (mounted) setState(() => _loading = false);
      }
    } else {
      // No batch tiers and no FREE_PRODUCT trigger — add directly, no tier picker.
      await _addResolved(result);
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Adds a line from an already-resolved `/pricing/resolve` (or offline) result,
  /// carrying through the resolved tax rate and any FREE_PRODUCT promotion so
  /// both register correctly in the cart.
  Future<void> _addResolved(Map<String, dynamic> result) async {
    await ref.read(orderCreationProvider.notifier).addLine(
      _productId, widget.product['name'] as String, 1.0, 0.0,
      unitPrice:       (result['unitPrice'] as num).toDouble(),
      priceSource:     result['priceSource'] as String?,
      taxPct:          (result['taxPct'] as num?)?.toDouble(),
      freeProductData: result['freeProduct'] as Map<String, dynamic>?,
    );
  }

  void _showTierSheet(List<Map<String, dynamic>> tiers,
      {Map<String, dynamic>? freeProductData}) {
    final name = widget.product['name'] as String? ?? '';
    final unit = (widget.product['unit'] as Map?)?['name'] as String? ?? '';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl))),
      builder: (_) => PriceTiersSheet(
        productName: name,
        unit: unit,
        tiers: tiers,
        onConfirm: (price, qty, source) async {
          await ref.read(orderCreationProvider.notifier).addLine(
            _productId, name, qty, 0.0,
            unitPrice: price, priceSource: source,
            // Batch tiers carry no tax info — tax depends on the customer's
            // own Tax Type/Tax Rate, not on which tier was picked.
            taxPct: resolveTaxPctForCustomer(_productId, widget.customerId),
            // Carry through any FREE_PRODUCT promo this product triggers, so
            // picking a tier doesn't lose the free-item registration.
            freeProductData: freeProductData,
          );
        },
      ),
    );
  }

  void _increment() {
    final qty = _cartQty(ref.read(orderCreationProvider));
    ref.read(orderCreationProvider.notifier).updateLineQty(_productId, qty + 1);
  }

  void _decrement() {
    final qty = _cartQty(ref.read(orderCreationProvider));
    ref.read(orderCreationProvider.notifier).updateLineQty(_productId, qty - 1);
  }

  @override
  Widget build(BuildContext context) {
    final draft   = ref.watch(orderCreationProvider);
    final qty     = _cartQty(draft);
    final inCart  = qty > 0;
    final primary = Theme.of(context).colorScheme.primary;

    final name         = widget.product['name'] as String? ?? '';
    final code         = widget.product['code'] as String? ?? '';
    final defaultPrice = (widget.product['defaultPrice'] as num?)?.toDouble() ?? 0;
    final displayPrice = widget.customerPrice ?? defaultPrice;
    final hasOverride  = widget.customerPrice != null && widget.customerPrice != defaultPrice;
    final category     = (widget.product['category'] as Map?)?['name'] as String?;
    final unit         = (widget.product['unit'] as Map?)?['name'] as String?;
    // A pre-loaded customer-specific price can coexist with other qty tiers
    // (customer-specific at a higher minQty, or general) — whenever any batch
    // tier exists, prefer that badge over a flat override price, since tapping
    // "Add" always opens the tier picker in that case (see _addFirst).
    final hasBatch = widget.hasBatchPricing;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        tone: inCart ? AppTone.violet : AppTone.neutral,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          // Product icon — stays the same regardless of cart state
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.skyBg,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: const Icon(Icons.inventory_2_outlined,
                size: 22, color: AppColors.skyFg),
          ),
          const SizedBox(width: 12),

          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  [code, if (category != null) category].join('  ·  '),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                if (hasBatch)
                  const StatusBadge(
                    label: 'Batch pricing — select qty to see price',
                    tone: AppTone.sky,
                  )
                else
                  Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                    Flexible(
                      child: Text(
                        'LKR ${formatAmount(displayPrice)}${unit != null ? ' / $unit' : ''}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: hasOverride
                              ? AppColors.mintFg
                              : Colors.grey.shade700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (hasOverride) ...[
                      const SizedBox(width: 5),
                      Text(
                        'LKR ${formatAmount(defaultPrice)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade400,
                          decoration: TextDecoration.lineThrough,
                          decorationColor: Colors.grey.shade400,
                        ),
                      ),
                      const SizedBox(width: 5),
                      const StatusBadge(label: 'Special', tone: AppTone.mint),
                    ],
                  ]),
              ],
            ),
          ),
          const SizedBox(width: 8),

          // Action: loading → + button → counter
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: _loading
                ? const SizedBox(
                    key: ValueKey('loading'),
                    width: 36,
                    height: 36,
                    child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : inCart
                    ? QtyCounter(
                        key: const ValueKey('counter'),
                        qty: qty,
                        primary: primary,
                        onDecrement: _decrement,
                        onIncrement: _increment,
                        onQtyChanged: (newQty) => ref
                            .read(orderCreationProvider.notifier)
                            .updateLineQty(_productId, newQty),
                      )
                    : _AddBtn(
                        key: const ValueKey('add'),
                        onTap: _addFirst,
                        primary: primary,
                      ),
          ),
        ]),
      ),
    );
  }
}

class _AddBtn extends StatelessWidget {
  final VoidCallback onTap;
  final Color primary;
  const _AddBtn({super.key, required this.onTap, required this.primary});

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.violetBg,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: const Icon(Icons.add_rounded, size: 20, color: AppColors.violetFg),
          ),
        ),
      );
}

// ─── Cart summary (inline) ────────────────────────────────────────────────────

class _CartSummaryCard extends ConsumerWidget {
  final OrderDraft draft;
  const _CartSummaryCard({required this.draft});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppCard(
      tone: AppTone.violet,
      padding: const EdgeInsets.all(14),
      child: Column(children: [
        _TotalRow('Subtotal', draft.subtotal),
        const SizedBox(height: 4),
        _TotalRow('Tax', draft.taxTotal),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Divider(height: 1),
        ),
        _TotalRow('Total', draft.grandTotal, bold: true),
      ]),
    );
  }
}

class _TotalRow extends StatelessWidget {
  final String label;
  final double value;
  final bool bold;
  const _TotalRow(this.label, this.value, {this.bold = false});

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: bold ? 14 : 13,
                    fontWeight:
                        bold ? FontWeight.w700 : FontWeight.normal,
                    color: bold ? null : Colors.grey.shade700))),
        Text(
          'LKR ${formatAmount(value)}',
          style: TextStyle(
              fontSize: bold ? 15 : 13,
              fontWeight: bold ? FontWeight.w700 : FontWeight.normal),
        ),
      ]);
}

// ─── Cart bottom sheet ────────────────────────────────────────────────────────

class _CartBottomSheet extends ConsumerWidget {
  final OrderDraft draft;
  final VoidCallback? onProceed;
  const _CartBottomSheet({required this.draft, this.onProceed});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Re-watch so it live-updates while the sheet is open
    final live = ref.watch(orderCreationProvider) ?? draft;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.85,
      builder: (_, controller) => Column(children: [
        // Handle
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(children: [
            const Text('Cart',
                style: TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 17)),
            const SizedBox(width: 8),
            StatusBadge(
              label: '${live.items.length} item${live.items.length == 1 ? '' : 's'}',
              tone: AppTone.violet,
            ),
          ]),
        ),
        Expanded(
          child: ListView.separated(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            itemCount: live.items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (_, i) => _CartItemRow(
              key: ValueKey(live.items[i].productId),
              item: live.items[i],
              index: i,
              customerId: live.customerId,
            ),
          ),
        ),
        // Totals + Review button
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: AppCard(
            tone: AppTone.violet,
            child: Column(children: [
              // No Tax row here — tax is an order-level concern shown once in
              // Review Order, not during cart-building. Total matches the sum
              // of the line items shown above (price × qty, minus discount).
              _TotalRow('Total', live.subtotal, bold: true),
              if (onProceed != null) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      onProceed!();
                    },
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: AppColors.violetFg,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    label: const Text('Review Order',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ]),
          ),
        ),
      ]),
    );
  }
}

// ─── Shared helpers ───────────────────────────────────────────────────────────

class _CustomerPickerCard extends StatelessWidget {
  final Map customer;
  final VoidCallback onTap;
  const _CustomerPickerCard({required this.customer, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final name     = customer['name'] as String? ?? '';
    final code     = customer['code'] as String? ?? '';
    final phone    = customer['phone'] as String? ?? '';
    final category = (customer['category'] as Map?)?['name'] as String?;
    final status   = customer['status'] as String? ?? 'ACTIVE';
    final placeOfSupplier = customer['placeOfSupplier'] as String?;
    final initial  = name.isNotEmpty ? name[0].toUpperCase() : '?';

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        onTap: onTap,
        child: Row(children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: AppColors.violetBg,
            child: Text(initial,
                style: const TextStyle(
                    color: AppColors.violetFg,
                    fontWeight: FontWeight.bold,
                    fontSize: 16)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14)),
              const SizedBox(height: 2),
              Text('$code${phone.isNotEmpty ? '  ·  $phone' : ''}',
                  style: const TextStyle(
                      fontSize: 12, color: Colors.grey)),
              if (category != null) ...[
                const SizedBox(height: 2),
                Text(category,
                    style: TextStyle(
                        fontSize: 11,
                        color: AppColors.violetFg.withValues(alpha: 0.8))),
              ],
              if (placeOfSupplier != null && placeOfSupplier.isNotEmpty) ...[
                const SizedBox(height: 4),
                StatusBadge(label: placeOfSupplier, tone: AppTone.orange),
              ],
            ]),
          ),
          const SizedBox(width: 8),
          StatusBadge(
            label: status,
            tone: status == 'ACTIVE' ? AppTone.mint : AppTone.neutral,
          ),
        ]),
      ),
    );
  }
}

// ─── Cart item row ─────────────────────────────────────────────────────────────

class _CartItemRow extends ConsumerStatefulWidget {
  final OrderLineItem item;
  final int index;
  final String customerId;
  const _CartItemRow({
    super.key,
    required this.item,
    required this.index,
    required this.customerId,
  });
  @override
  ConsumerState<_CartItemRow> createState() => _CartItemRowState();
}

class _CartItemRowState extends ConsumerState<_CartItemRow> {
  bool _loadingTiers = false;

  Future<void> _changeTier() async {
    if (_loadingTiers) return;
    setState(() => _loadingTiers = true);
    try {
      final resp = await ref.read(dioProvider).get('/pricing/tiers', queryParameters: {
        'productId':  widget.item.productId,
        'customerId': widget.customerId,
      });
      final tiers = List<Map<String, dynamic>>.from(resp.data as List? ?? []);
      if (!mounted) return;
      setState(() => _loadingTiers = false);
      if (tiers.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No batch price tiers for this product')));
        return;
      }
      _showTierSheet(tiers);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingTiers = false);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load price tiers')));
    }
  }

  void _showTierSheet(List<Map<String, dynamic>> tiers) {
    final product = LocalDb.products.firstWhere(
        (p) => p['id'] == widget.item.productId,
        orElse: () => <String, dynamic>{});
    final unit = (product['unit'] as Map?)?['name'] as String? ?? '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl))),
      builder: (_) => PriceTiersSheet(
        productName: widget.item.productName,
        unit: unit,
        tiers: tiers,
        initialQty: widget.item.qty,
        initialPrice: widget.item.unitPrice,
        confirmLabel: 'Update Cart',
        onConfirm: (price, qty, source) async {
          ref.read(orderCreationProvider.notifier)
              .replaceLine(widget.index, price, qty, source);
        },
      ),
    );
  }

  Future<void> _editQty() async {
    final qty = widget.item.qty;
    final controller = TextEditingController(
        text: qty % 1 == 0 ? qty.toInt().toString() : qty.toString());
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
        .updateLineQty(widget.item.productId, newQty);
  }

  @override
  Widget build(BuildContext context) {
    final item       = widget.item;
    final isFree     = item.priceSource == 'FREE_PRODUCT';
    final isCustomer = item.priceSource == 'CUSTOMER_PRICE';
    final isBatch    = item.priceSource == 'BATCH_PRICE';
    final isPromo    = item.priceSource == 'PROMOTION';
    final hasBatchTier = isCustomer || isBatch;
    final qtyStr = item.qty % 1 == 0
        ? item.qty.toInt().toString()
        : item.qty.toStringAsFixed(1);
    // For a free line, lineTotal is always 0 by design (it carries its own 100%
    // discount so the order total nets out correctly) — the gross value (what the
    // item is actually worth before that discount) is what should be shown here.
    final grossValue = item.unitPrice * item.qty;
    // The cart line shows price × qty (minus any per-item discount) only — tax is
    // an order-level concern shown once in Review Order, not baked into each line.
    final displayTotal = isFree ? grossValue : (grossValue - item.discountAmount);

    final card = AppCard(
      tone: isFree ? AppTone.mint : AppTone.neutral,
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Product name + FREE badge on same row
            Row(children: [
              if (isFree) ...[
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: StatusBadge(label: 'FREE', tone: AppTone.mint),
                ),
              ],
              Expanded(
                child: Text(item.productName,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
            const SizedBox(height: 2),
            Text(
              isFree
                  ? '$qtyStr  ×  LKR ${formatAmount(item.unitPrice)}  (Complimentary)'
                  : '$qtyStr  ×  LKR ${formatAmount(item.unitPrice)}'
                      '${item.discountPct > 0 ? '  |  disc ${item.discountPct.toStringAsFixed(0)}%' : ''}',
              style: TextStyle(
                  fontSize: 12,
                  color: isFree ? AppColors.mintFg : Colors.grey),
            ),
            if (!isFree) ...[
              const SizedBox(height: 5),
              Row(children: [
                if (hasBatchTier) ...[
                  StatusBadge(
                    label: isCustomer ? 'Customer Price' : 'General Price',
                    tone: isCustomer ? AppTone.mint : AppTone.sky,
                  ),
                  const SizedBox(width: 8),
                ],
                if (isPromo) ...[
                  const StatusBadge(label: 'Promotion', tone: AppTone.orange),
                  const SizedBox(width: 8),
                ],
                GestureDetector(
                  onTap: _changeTier,
                  child: _loadingTiers
                      ? const SizedBox(
                          width: 12, height: 12,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.5, color: AppColors.violetFg))
                      : Text(
                          hasBatchTier ? 'Change tier' : 'Apply batch price',
                          style: const TextStyle(
                              fontSize: 10,
                              color: AppColors.violetFg,
                              fontWeight: FontWeight.w500,
                              decoration: TextDecoration.underline,
                              decorationColor: AppColors.violetFg),
                        ),
                ),
              ]),
            ],
          ]),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'LKR ${formatAmount(displayTotal)}',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: isFree ? AppColors.mintFg : null),
            ),
            const SizedBox(height: 2),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              color: AppColors.pinkFg,
              onPressed: () => ref
                  .read(orderCreationProvider.notifier)
                  .removeLine(widget.index),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      ]),
    );

    List<Widget> buildActions() => [
          if (!isFree) ...[
            SlidableAction(
              onPressed: (_) => _editQty(),
              backgroundColor: AppColors.skyFg,
              foregroundColor: Colors.white,
              icon: Icons.edit_outlined,
              label: 'Qty',
            ),
            SlidableAction(
              onPressed: (_) => _changeTier(),
              backgroundColor: AppColors.orangeFg,
              foregroundColor: Colors.white,
              icon: Icons.sell_outlined,
              label: 'Batch',
            ),
          ],
          SlidableAction(
            onPressed: (_) => ref
                .read(orderCreationProvider.notifier)
                .removeLine(widget.index),
            backgroundColor: AppColors.pinkFg,
            foregroundColor: Colors.white,
            icon: Icons.delete_outline,
            label: 'Delete',
          ),
        ];
    final extentRatio = isFree ? 0.25 : 0.75;

    return Slidable(
      key: ValueKey(item.productId),
      // Both directions wired — some users naturally swipe the "wrong" way,
      // and this ensures the actions reveal regardless of swipe direction.
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
    );
  }
}

// ─── Selected customer display ────────────────────────────────────────────────

class _SelectedCustomerCard extends StatelessWidget {
  final Map customer;
  final VoidCallback onClear;
  const _SelectedCustomerCard(
      {required this.customer, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final name     = customer['name'] as String? ?? '';
    final code     = customer['code'] as String? ?? '';
    final phone    = customer['phone'] as String? ?? '';
    final category = (customer['category'] as Map?)?['name'] as String?;
    final initial  = name.isNotEmpty ? name[0].toUpperCase() : '?';

    return AppCard(
      tone: AppTone.violet,
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: AppColors.violetFg.withValues(alpha: 0.18),
          child: Text(initial,
              style: const TextStyle(
                  color: AppColors.violetFg,
                  fontWeight: FontWeight.bold,
                  fontSize: 15)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Text(name,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14)),
            Text('$code${phone.isNotEmpty ? '  ·  $phone' : ''}',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            if (category != null)
              Text(category,
                  style: TextStyle(
                      fontSize: 11, color: AppColors.violetFg.withValues(alpha: 0.8))),
          ]),
        ),
        TextButton(
          onPressed: onClear,
          style: TextButton.styleFrom(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            visualDensity: VisualDensity.compact,
          ),
          child: const Text('Change', style: TextStyle(fontSize: 12)),
        ),
      ]),
    );
  }
}

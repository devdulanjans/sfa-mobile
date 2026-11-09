import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/local_db.dart';
import '../../core/storage/sync_service.dart';
import '../auth/auth_provider.dart';
import '../sync/sync_provider.dart';
import 'offline_pricing.dart';

/// Resolves pricing/promotions for a product+customer, live from the backend
/// when reachable, falling back to [resolvePriceOffline] against the synced
/// local cache otherwise. This is the single source of pricing truth for the
/// cart — every call site should go through this rather than hitting
/// `/pricing/resolve` directly, so promotions are never silently dropped.
/// Takes a plain [Dio] (rather than a Riverpod ref) so it works uniformly from
/// both `WidgetRef` (screens) and `Ref` (notifiers) call sites.
Future<Map<String, dynamic>> resolvePricing(
    Dio dio, String productId, String customerId,
    {String? promotionId, bool ignorePromotions = false}) async {
  try {
    final resp = await dio.get('/pricing/resolve', queryParameters: {
      'productId': productId,
      'customerId': customerId,
      if (promotionId != null) 'promotionId': promotionId,
      if (ignorePromotions) 'ignorePromotions': true,
    });
    return Map<String, dynamic>.from(resp.data as Map);
  } catch (_) {
    return resolvePriceOffline(productId, customerId,
        promotionId: promotionId, ignorePromotions: ignorePromotions);
  }
}

/// Promotions active for a product+customer, live when reachable, else from the
/// synced cache.
Future<List<Map<String, dynamic>>> fetchPromotionOptions(
    Dio dio, String productId, String customerId) async {
  try {
    final resp = await dio.get('/pricing/promotions', queryParameters: {
      'productId': productId,
      'customerId': customerId,
    });
    return List<Map<String, dynamic>>.from(resp.data as List? ?? []);
  } catch (e) {
    return activePromotionsFor(productId, customerId)
        .map((p) => Map<String, dynamic>.from(p))
        .toList();
  }
}

/// The discount promotion that applies on top of a batch tier: the rep's explicit
/// pick if there is one, otherwise the first discount-type promotion. Mirrors the
/// backend's `PricingEngine.applyPromotionToSelectedTier`.
Map<String, dynamic>? discountPromotion(List<Map<String, dynamic>> options,
    {String? promotionId}) {
  final chosen = options.where((p) => p['id'] == promotionId).firstOrNull;
  if (chosen != null) {
    return chosen['type'] == 'FREE_PRODUCT' || _unlockQty(chosen) > 1 ? null : chosen;
  }
  return options.where((p) => p['type'] != 'FREE_PRODUCT' && _unlockQty(p) <= 1).firstOrNull;
}

int _unlockQty(Map promotion) => (promotion['minOrderQty'] as num?)?.toInt() ?? 1;

/// Discount promotions the cart must switch on and off as quantities change — empty
/// unless at least one of them has an unlock quantity above 1.
List<Map<String, dynamic>> unlockablePromotions(List<Map<String, dynamic>> options,
    {String? promotionId}) {
  final chosen = options.where((p) => p['id'] == promotionId).firstOrNull;
  final discounts =
      (chosen != null ? [chosen] : options).where((p) => p['type'] != 'FREE_PRODUCT').toList();
  return discounts.any((p) => _unlockQty(p) > 1) ? discounts : const [];
}

// ---------- Free-product promotion snapshot ----------

/// Immutable snapshot of a FREE_PRODUCT promotion returned by /pricing/resolve.
/// Keyed in OrderDraft.activePromos by [freeProductId].
class _FreePromo {
  final String freeProductId;
  final String freeProductName;
  final double maxFreeCount;
  final int    minOrderQty;
  final int?   repeatEveryQty;  // null = rewarded once
  final int?   maxFreeTotal;    // null = no limit
  final List<String> triggerProductIds; // products that count toward the threshold

  const _FreePromo({
    required this.freeProductId,
    required this.freeProductName,
    required this.maxFreeCount,
    required this.minOrderQty,
    required this.triggerProductIds,
    this.repeatEveryQty,
    this.maxFreeTotal,
  });
}

// ---------- State ----------

class OrderDraft {
  final String customerId;
  final String customerName;
  final List<OrderLineItem> items;
  final String notes;
  final Map<String, _FreePromo> activePromos; // key = freeProductId

  const OrderDraft({
    required this.customerId,
    required this.customerName,
    this.items = const [],
    this.notes = '',
    this.activePromos = const {},
  });

  OrderDraft copyWith({
    List<OrderLineItem>? items,
    String? notes,
    Map<String, _FreePromo>? activePromos,
  }) =>
      OrderDraft(
        customerId:   customerId,
        customerName: customerName,
        items:        items        ?? this.items,
        notes:        notes        ?? this.notes,
        activePromos: activePromos ?? this.activePromos,
      );

  // subtotal = pre-tax (after discount); lineTotal already includes tax
  double get subtotal      => items.fold(0, (s, i) => s + i.lineTotal - i.taxAmount);
  double get taxTotal      => items.fold(0, (s, i) => s + i.taxAmount);
  double get grandTotal    => subtotal + taxTotal;
  // grossTotal/discountTotal = pre-discount total and the value discounted away
  // (e.g. a promotion's free item priced at its real value with a 100% discount).
  double get grossTotal    => items.fold(0, (s, i) => s + (i.listPrice ?? i.unitPrice) * i.qty);
  double get discountTotal => items.fold(
      0, (s, i) => s + i.discountAmount + ((i.listPrice ?? i.unitPrice) - i.unitPrice) * i.qty);
}

class OrderLineItem {
  final String productId;
  final String productName;
  final double qty;
  final double unitPrice;
  final double discountPct;
  final double taxPct;
  final double discountAmount;
  final double taxAmount;
  final double lineTotal;
  final String priceSource;
  // The specific BatchPrice row id this line's price came from, when picked via the price-tier
  // sheet — sent to the backend so it charges exactly this tier instead of independently
  // re-resolving "the best" batch price, which is ambiguous when several tiers are equally
  // specific (see PricingEngine.resolve on the backend).
  final String? batchPriceId;
  // The specific Promotion this line's price/free-item eligibility came from, when the rep
  // explicitly picked one via the promotion picker (more than one was active) — sent to the
  // backend so it honors exactly that choice, excluding the other promotion, instead of
  // auto-picking (see PricingEngine.resolve's promotionId javadoc on the backend).
  final String? promotionId;
  // Unit price before a promotion, when one lowered [unitPrice] — a promotion is baked into
  // the unit price with discountPct staying 0, so this is what lets the totals show its value.
  final double? listPrice;
  // Set only for lines whose discount depends on an unlock quantity: the promotions to
  // try, and the price/source to fall back to while none of them is unlocked.
  final List<Map<String, dynamic>> unlockable;
  final double? basePrice;
  final String? baseSource;

  const OrderLineItem({
    required this.productId, required this.productName, required this.qty,
    required this.unitPrice, required this.discountPct, required this.taxPct,
    required this.discountAmount, required this.taxAmount, required this.lineTotal,
    required this.priceSource, this.batchPriceId, this.promotionId, this.listPrice,
    this.unlockable = const [], this.basePrice, this.baseSource,
  });
}

// ---------- Order list filters ----------

/// "My Orders" filter selection — order#/invoice# search plus a date range.
class OrderListFilters {
  final String orderNo;
  final String invoiceNo;
  final DateTime? dateFrom;
  final DateTime? dateTo;

  const OrderListFilters({
    this.orderNo = '',
    this.invoiceNo = '',
    this.dateFrom,
    this.dateTo,
  });

  bool get isActive =>
      orderNo.isNotEmpty || invoiceNo.isNotEmpty || dateFrom != null || dateTo != null;

  int get activeCount => [
        orderNo.isNotEmpty,
        invoiceNo.isNotEmpty,
        dateFrom != null || dateTo != null,
      ].where((b) => b).length;

  OrderListFilters copyWith({
    String? orderNo,
    String? invoiceNo,
    DateTime? dateFrom,
    DateTime? dateTo,
    bool clearDates = false,
  }) =>
      OrderListFilters(
        orderNo: orderNo ?? this.orderNo,
        invoiceNo: invoiceNo ?? this.invoiceNo,
        dateFrom: clearDates ? null : (dateFrom ?? this.dateFrom),
        dateTo: clearDates ? null : (dateTo ?? this.dateTo),
      );
}

// ---------- Providers ----------

final orderDraftProvider = StateProvider<OrderDraft?>((ref) => null);

final orderFiltersProvider =
    StateProvider<OrderListFilters>((ref) => const OrderListFilters());

final orderListProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final dio    = ref.read(dioProvider);
  final filters = ref.watch(orderFiltersProvider);
  final apiFmt = DateFormat('yyyy-MM-dd');

  final resp = await dio.get('/orders', queryParameters: {
    'page': 0,
    'size': 50,
    if (filters.orderNo.isNotEmpty) 'orderNo': filters.orderNo,
    if (filters.invoiceNo.isNotEmpty) 'invoiceNo': filters.invoiceNo,
    if (filters.dateFrom != null) 'dateFrom': apiFmt.format(filters.dateFrom!),
    if (filters.dateTo != null) 'dateTo': apiFmt.format(filters.dateTo!),
  });
  return List<Map<String, dynamic>>.from(resp.data['content'] as List);
});

class OrderCreationNotifier extends Notifier<OrderDraft?> {
  @override
  OrderDraft? build() => null;

  void startOrder(String customerId, String customerName) {
    state = OrderDraft(customerId: customerId, customerName: customerName);
  }

  Future<void> addLine(
    String productId,
    String productName,
    double qty,
    double discountPct, {
    double? unitPrice,       // supplied when user picks a batch price tier
    String? priceSource,
    double? taxPct,          // supplied when caller already resolved the tax rate
    Map<String, dynamic>? freeProductData, // supplied when caller already resolved pricing
    String? batchPriceId,    // id of the specific tier picked, when unitPrice came from one
    String? promotionId,     // id of the specific promotion picked, when more than one applied
    double? listPrice,       // unit price before a promotion, when one lowered unitPrice
    List<Map<String, dynamic>> unlockable = const [], // see OrderLineItem.unlockable
  }) async {
    if (state == null) return;

    double resolvedPrice  = unitPrice ?? 0;
    double resolvedTaxPct = taxPct ?? 0;
    String resolvedSource = priceSource ?? 'DEFAULT_PRICE';

    if (unitPrice == null) {
      // Resolve price live, falling back to the offline cache when unreachable.
      final result = await resolvePricing(
          ref.read(dioProvider), productId, state!.customerId, promotionId: promotionId);
      resolvedPrice   = (result['unitPrice'] as num).toDouble();
      resolvedSource  = result['priceSource'] as String? ?? 'DEFAULT_PRICE';
      resolvedTaxPct  = (result['taxPct']    as num?)?.toDouble() ?? 0.0;
      freeProductData = result['freeProduct'] as Map<String, dynamic>?;
    }

    final unitPrice0   = resolvedPrice;
    final priceSource0 = resolvedSource;

    final gross          = unitPrice0 * qty;
    final discountAmount = gross * discountPct / 100;
    final afterDiscount  = gross - discountAmount;
    final taxAmount      = afterDiscount * resolvedTaxPct / 100;
    final lineTotal      = afterDiscount + taxAmount;

    double? basePrice;
    String? baseSource;
    if (unlockable.isNotEmpty) {
      if (batchPriceId != null) {
        basePrice  = listPrice ?? unitPrice0;
        baseSource = priceSource0 == 'PROMOTION' ? 'BATCH_PRICE' : priceSource0;
      } else {
        final regular = await resolvePricing(
            ref.read(dioProvider), productId, state!.customerId, ignorePromotions: true);
        basePrice  = (regular['unitPrice'] as num).toDouble();
        baseSource = regular['priceSource'] as String?;
      }
    }

    final newLine = OrderLineItem(
      productId: productId, productName: productName, qty: qty,
      unitPrice: unitPrice0, discountPct: discountPct, taxPct: resolvedTaxPct,
      discountAmount: discountAmount, taxAmount: taxAmount, lineTotal: lineTotal,
      priceSource: priceSource0, batchPriceId: batchPriceId, promotionId: promotionId,
      listPrice: listPrice,
      unlockable: unlockable, basePrice: basePrice, baseSource: baseSource,
    );

    state = state!.copyWith(items: [...state!.items, newLine]);
    _applyUnlockablePromotions();

    // Register free-product promotion and re-evaluate threshold
    if (freeProductData != null) {
      final fpId      = freeProductData['id']           as String;
      final fpName    = freeProductData['name']         as String;
      final maxFree   = (freeProductData['maxFreeCount'] as num?)?.toDouble() ?? 1.0;
      final minOrdQty = (freeProductData['minOrderQty']  as num?)?.toInt()    ?? 1;
      final repeatEvery = (freeProductData['repeatEveryQty'] as num?)?.toInt();
      final maxTotal  = (freeProductData['maxFreeTotal'] as num?)?.toInt();
      final rawIds    = freeProductData['applicableProductIds'] as List<dynamic>? ?? [];
      final triggerIds = rawIds.map((e) => e.toString()).toList();

      final promo = _FreePromo(
        freeProductId:    fpId,
        freeProductName:  fpName,
        maxFreeCount:     maxFree,
        minOrderQty:      minOrdQty,
        triggerProductIds: triggerIds,
        repeatEveryQty:   repeatEvery,
        maxFreeTotal:     maxTotal,
      );

      final updatedPromos = Map<String, _FreePromo>.from(state!.activePromos)
        ..[fpId] = promo;
      state = state!.copyWith(activePromos: updatedPromos);

      await _syncFreeProducts();
    }
  }

  /// Switches each unlock-gated discount on or off from current cart quantities, counted
  /// across all of a promotion's products. Mirrors PricingEngine.eligiblePromotions.
  void _applyUnlockablePromotions() {
    if (state == null || state!.items.every((i) => i.unlockable.isEmpty)) return;
    final paid = state!.items.where((i) => i.priceSource != 'FREE_PRODUCT').toList();

    state = state!.copyWith(
      items: state!.items.map((i) {
        final base = i.basePrice;
        if (i.unlockable.isEmpty || base == null) return i;
        final promo = i.unlockable.where((p) {
          final ids = promotionProductIds(p);
          final total = paid
              .where((l) => ids.contains(l.productId))
              .fold<double>(0, (s, l) => s + l.qty);
          return total >= _unlockQty(p);
        }).firstOrNull;

        final unitPrice      = applyPromotionDiscount(base, promo);
        final gross          = unitPrice * i.qty;
        final discountAmount = gross * i.discountPct / 100;
        final afterDiscount  = gross - discountAmount;
        final taxAmount      = afterDiscount * i.taxPct / 100;
        return OrderLineItem(
          productId: i.productId, productName: i.productName,
          qty: i.qty, unitPrice: unitPrice,
          discountPct: i.discountPct, taxPct: i.taxPct,
          discountAmount: discountAmount, taxAmount: taxAmount,
          lineTotal: afterDiscount + taxAmount,
          priceSource: promo != null ? 'PROMOTION' : (i.baseSource ?? 'DEFAULT_PRICE'),
          batchPriceId: i.batchPriceId, promotionId: i.promotionId,
          listPrice: promo != null ? base : null,
          unlockable: i.unlockable, basePrice: base, baseSource: i.baseSource,
        );
      }).toList(),
    );
  }

  /// Re-evaluates every known free-product promotion against current cart qty.
  /// Adds the free line when the threshold is met; removes it when it is not.
  /// The free line always carries the product's real price/qty (and a 100%
  /// discount so it still nets to zero in the running total) so the rep can
  /// see what the free item is actually worth — never a bare "0.00" row.
  Future<void> _syncFreeProducts() async {
    _applyUnlockablePromotions();
    if (state == null || state!.activePromos.isEmpty) return;

    // Keep all non-free lines as the authoritative base
    final baseItems = state!.items
        .where((i) => i.priceSource != 'FREE_PRODUCT')
        .toList();

    final freeLines = <OrderLineItem>[];

    for (final promo in state!.activePromos.values) {
      // Sum qty of all trigger products currently in the cart
      final totalQty = baseItems
          .where((i) => promo.triggerProductIds.contains(i.productId))
          .fold(0.0, (s, i) => s + i.qty);

      if (totalQty >= promo.minOrderQty) {
        final result = await resolvePricing(
            ref.read(dioProvider), promo.freeProductId, state!.customerId,
            ignorePromotions: true); // a free item shows its real, undiscounted value
        // A free item that is also being bought at a picked batch tier is valued at that
        // tier's price; otherwise at its regular price. Mirrors PricingEngine.resolveFreeItems.
        final paidLine = baseItems
            .where((i) => i.productId == promo.freeProductId && i.batchPriceId != null)
            .firstOrNull;
        final unitPrice = paidLine != null
            ? (paidLine.listPrice ?? paidLine.unitPrice)
            : (result['unitPrice'] as num?)?.toDouble() ?? 0.0;
        final taxPct    = (result['taxPct']    as num?)?.toDouble() ?? 0.0;
        const discountPct = 100.0;

        // Counted from the first unit once unlocked. Mirrors PricingEngine.freeQuantity.
        final repeat = promo.repeatEveryQty;
        var freeQty = repeat == null || repeat < 1
            ? promo.maxFreeCount
            : promo.maxFreeCount * (totalQty / repeat).floorToDouble();
        final cap = promo.maxFreeTotal;
        if (cap != null && freeQty > cap) freeQty = cap.toDouble();
        if (freeQty <= 0) continue;

        final gross          = unitPrice * freeQty;
        final discountAmount = gross * discountPct / 100;
        final afterDiscount  = gross - discountAmount;
        final taxAmount      = afterDiscount * taxPct / 100;

        freeLines.add(OrderLineItem(
          productId:      promo.freeProductId,
          productName:    promo.freeProductName,
          qty:            freeQty,
          unitPrice:      unitPrice,
          discountPct:    discountPct,
          taxPct:         taxPct,
          discountAmount: discountAmount,
          taxAmount:      taxAmount,
          lineTotal:      afterDiscount + taxAmount,
          priceSource:    'FREE_PRODUCT',
        ));
      }
    }

    state = state!.copyWith(items: [...baseItems, ...freeLines]);
  }

  void clearOrder() => state = null;

  void replaceLine(int index, double newUnitPrice, double newQty, String newSource,
      [String? newBatchPriceId, double? newListPrice]) {
    if (state == null) return;
    final items = [...state!.items];
    if (index < 0 || index >= items.length) return;
    final old = items[index];
    final gross          = newUnitPrice * newQty;
    final discountAmount = gross * old.discountPct / 100;
    final afterDiscount  = gross - discountAmount;
    final taxAmount      = afterDiscount * old.taxPct / 100;
    items[index] = OrderLineItem(
      productId: old.productId, productName: old.productName,
      qty: newQty, unitPrice: newUnitPrice,
      discountPct: old.discountPct, taxPct: old.taxPct,
      discountAmount: discountAmount, taxAmount: taxAmount,
      lineTotal: afterDiscount + taxAmount, priceSource: newSource,
      batchPriceId: newBatchPriceId, promotionId: old.promotionId,
      listPrice: newListPrice,
      unlockable: old.unlockable,
      basePrice: old.unlockable.isEmpty ? null : (newListPrice ?? newUnitPrice),
      baseSource: old.unlockable.isEmpty
          ? null
          : (newSource == 'PROMOTION' ? 'BATCH_PRICE' : newSource),
    );
    state = state!.copyWith(items: items);
    _syncFreeProducts(); // a tier change can change the free item's value
  }

  void removeLine(int index) {
    if (state == null) return;
    final items = [...state!.items]..removeAt(index);
    state = state!.copyWith(items: items);
    _syncFreeProducts();
  }

  void updateLineQty(String productId, double newQty) {
    if (state == null) return;
    if (newQty <= 0) {
      state = state!.copyWith(
          items: state!.items.where((i) => i.productId != productId).toList());
      _syncFreeProducts();
      return;
    }
    state = state!.copyWith(
      items: state!.items.map((i) {
        // Exclude FREE_PRODUCT lines from the match — when the free product is the
        // same product as the trigger, matching by productId alone would also resize
        // the free line to the paid quantity. _syncFreeProducts() (below) independently
        // re-evaluates the free line's own quantity from the promo's maxFreeCount.
        if (i.productId != productId || i.priceSource == 'FREE_PRODUCT') return i;
        final gross          = i.unitPrice * newQty;
        final discountAmount = gross * i.discountPct / 100;
        final afterDiscount  = gross - discountAmount;
        final taxAmount      = afterDiscount * i.taxPct / 100;
        return OrderLineItem(
          productId: i.productId, productName: i.productName,
          qty: newQty, unitPrice: i.unitPrice,
          discountPct: i.discountPct, taxPct: i.taxPct,
          discountAmount: discountAmount, taxAmount: taxAmount,
          lineTotal: afterDiscount + taxAmount, priceSource: i.priceSource,
          batchPriceId: i.batchPriceId, promotionId: i.promotionId,
          listPrice: i.listPrice,
          unlockable: i.unlockable, basePrice: i.basePrice, baseSource: i.baseSource,
        );
      }).toList(),
    );
    _syncFreeProducts();
  }

  Future<void> reorderFromOrder(String orderId) async {
    final dio = ref.read(dioProvider);
    final resp = await dio.get('/orders/$orderId');
    final order = resp.data as Map<String, dynamic>;

    final customer = order['customer'] as Map<String, dynamic>;
    startOrder(customer['id'] as String, customer['name'] as String);

    for (final item in (order['items'] as List? ?? [])) {
      final product = item['product'] as Map<String, dynamic>;
      await addLine(
        product['id'] as String,
        product['name'] as String,
        (item['quantity'] as num).toDouble(),
        (item['discountPct'] as num? ?? 0).toDouble(),
      );
    }
  }

  Future<Map<String, dynamic>?> submitOrder({
    String? deliveryAddressLabel,
    String? deliveryAddressLine,
    String? customerSignature,
    String? salespersonSignature,
    String? poNumber,
  }) async {
    if (state == null) return null;
    final distributorId =
        ref.read(authNotifierProvider).valueOrNull?.activeDistributorId;
    final payload = {
      'customerId': state!.customerId,
      'notes': state!.notes,
      if (distributorId != null) 'distributorId': distributorId,
      if (deliveryAddressLabel != null) 'deliveryAddressLabel': deliveryAddressLabel,
      if (deliveryAddressLine != null)  'deliveryAddressLine': deliveryAddressLine,
      if (customerSignature != null)    'customerSignature': customerSignature,
      if (salespersonSignature != null) 'salespersonSignature': salespersonSignature,
      if (poNumber != null)             'poNumber': poNumber,
      // Free-promotion lines are computed authoritatively by the backend from the
      // real purchased quantities below — don't submit our local preview of them.
      'items': state!.items
          .where((i) => i.priceSource != 'FREE_PRODUCT')
          .map((i) => {
                'productId': i.productId,
                'quantity': i.qty,
                'discountPct': i.discountPct,
                if (i.batchPriceId != null) 'batchPriceId': i.batchPriceId,
                if (i.promotionId != null) 'promotionId': i.promotionId,
              }).toList(),
    };

    try {
      final dio = ref.read(dioProvider);
      // Create as DRAFT then immediately submit for manager approval
      final createResp = await dio.post('/orders', data: payload);
      final orderId = createResp.data['id'] as String;
      final submitResp = await dio.post('/orders/$orderId/submit');
      // NOTE: the draft is deliberately NOT cleared here. OrderReviewScreen
      // watches this provider and redirects to /dashboard the instant the
      // draft becomes null — clearing it here raced with (and cut short)
      // the caller's post-submit success dialog and invoice print flow. The
      // caller clears it explicitly via clearOrder() once that flow is done.
      return submitResp.data as Map<String, dynamic>;
    } catch (e) {
      final statusCode = e is DioException ? (e.response?.statusCode ?? 0) : 0;
      final isNetworkFailure = e is DioException &&
          (e.type == DioExceptionType.connectionError ||
           e.type == DioExceptionType.connectionTimeout ||
           e.type == DioExceptionType.sendTimeout ||
           e.type == DioExceptionType.receiveTimeout ||
           e.type == DioExceptionType.unknown ||
           statusCode >= 500);

      if (isNetworkFailure) {
        // Save offline only for network / server errors — not validation failures
        await LocalDb.saveOfflineOrder(
          customerId:   state!.customerId,
          customerName: state!.customerName,
          grandTotal:   state!.grandTotal,
          itemCount:    state!.items.length,
          payload:      payload,
        );
        ref.read(syncNotifierProvider.notifier).refreshPendingCount();
      } else {
        // 4xx validation / auth error — log it, don't queue for retry
        final detail = e is DioException
            ? (e.response?.data?.toString() ?? e.message ?? e.toString())
            : e.toString();
        await LocalDb.logError(
          'Order submit failed (${statusCode > 0 ? statusCode : "unknown"})',
          detail,
          endpoint: '/orders',
        );
      }
      state = null;
      return null;
    }
  }
}

final orderCreationProvider =
    NotifierProvider<OrderCreationNotifier, OrderDraft?>(OrderCreationNotifier.new);

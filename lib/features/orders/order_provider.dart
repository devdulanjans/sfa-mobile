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
    Dio dio, String productId, String customerId, {String? promotionId}) async {
  try {
    final resp = await dio.get('/pricing/resolve', queryParameters: {
      'productId': productId,
      'customerId': customerId,
      if (promotionId != null) 'promotionId': promotionId,
    });
    return Map<String, dynamic>.from(resp.data as Map);
  } catch (_) {
    return resolvePriceOffline(productId, customerId, promotionId: promotionId);
  }
}

// ---------- Free-product promotion snapshot ----------

/// Immutable snapshot of a FREE_PRODUCT promotion returned by /pricing/resolve.
/// Keyed in OrderDraft.activePromos by [freeProductId].
class _FreePromo {
  final String freeProductId;
  final String freeProductName;
  final double maxFreeCount;
  final int    minOrderQty;
  final List<String> triggerProductIds; // products that count toward the threshold

  const _FreePromo({
    required this.freeProductId,
    required this.freeProductName,
    required this.maxFreeCount,
    required this.minOrderQty,
    required this.triggerProductIds,
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
  double get grossTotal    => items.fold(0, (s, i) => s + i.unitPrice * i.qty);
  double get discountTotal => items.fold(0, (s, i) => s + i.discountAmount);
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

  const OrderLineItem({
    required this.productId, required this.productName, required this.qty,
    required this.unitPrice, required this.discountPct, required this.taxPct,
    required this.discountAmount, required this.taxAmount, required this.lineTotal,
    required this.priceSource, this.batchPriceId, this.promotionId,
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

    final newLine = OrderLineItem(
      productId: productId, productName: productName, qty: qty,
      unitPrice: unitPrice0, discountPct: discountPct, taxPct: resolvedTaxPct,
      discountAmount: discountAmount, taxAmount: taxAmount, lineTotal: lineTotal,
      priceSource: priceSource0, batchPriceId: batchPriceId, promotionId: promotionId,
    );

    state = state!.copyWith(items: [...state!.items, newLine]);

    // Register free-product promotion and re-evaluate threshold
    if (freeProductData != null) {
      final fpId      = freeProductData['id']           as String;
      final fpName    = freeProductData['name']         as String;
      final maxFree   = (freeProductData['maxFreeCount'] as num?)?.toDouble() ?? 1.0;
      final minOrdQty = (freeProductData['minOrderQty']  as num?)?.toInt()    ?? 1;
      final rawIds    = freeProductData['applicableProductIds'] as List<dynamic>? ?? [];
      final triggerIds = rawIds.map((e) => e.toString()).toList();

      final promo = _FreePromo(
        freeProductId:    fpId,
        freeProductName:  fpName,
        maxFreeCount:     maxFree,
        minOrderQty:      minOrdQty,
        triggerProductIds: triggerIds,
      );

      final updatedPromos = Map<String, _FreePromo>.from(state!.activePromos)
        ..[fpId] = promo;
      state = state!.copyWith(activePromos: updatedPromos);

      await _syncFreeProducts();
    }
  }

  /// Re-evaluates every known free-product promotion against current cart qty.
  /// Adds the free line when the threshold is met; removes it when it is not.
  /// The free line always carries the product's real price/qty (and a 100%
  /// discount so it still nets to zero in the running total) so the rep can
  /// see what the free item is actually worth — never a bare "0.00" row.
  Future<void> _syncFreeProducts() async {
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
            ref.read(dioProvider), promo.freeProductId, state!.customerId);
        final unitPrice = (result['unitPrice'] as num?)?.toDouble() ?? 0.0;
        final taxPct    = (result['taxPct']    as num?)?.toDouble() ?? 0.0;
        const discountPct = 100.0;

        final gross          = unitPrice * promo.maxFreeCount;
        final discountAmount = gross * discountPct / 100;
        final afterDiscount  = gross - discountAmount;
        final taxAmount      = afterDiscount * taxPct / 100;

        freeLines.add(OrderLineItem(
          productId:      promo.freeProductId,
          productName:    promo.freeProductName,
          qty:            promo.maxFreeCount,
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
      [String? newBatchPriceId]) {
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
    );
    state = state!.copyWith(items: items);
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

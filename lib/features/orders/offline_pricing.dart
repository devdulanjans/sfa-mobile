import '../../core/storage/local_db.dart';

/// Tax rate for a product+customer, from the local cache only (no network call).
/// Tax is driven by the customer's own Tax Type/Tax Rate (see
/// `_resolveTaxPctOffline`), not by whichever price source won — so callers that
/// already resolved a price through some other path (a batch-price tier, a
/// pre-loaded customer-specific price) can still get the correct tax rate here
/// instead of silently defaulting to 0%.
double resolveTaxPctForCustomer(String productId, String customerId) {
  final product = LocalDb.products.where((p) => p['id'] == productId).firstOrNull;
  final customer = LocalDb.customers.where((c) => c['id'] == customerId).firstOrNull;
  return _resolveTaxPctOffline(product, customer);
}

/// Whether any batch price (general, or specific to this customer) is
/// currently active for this product — used to decide whether the product
/// list should hide the plain default price (since the real price depends on
/// the quantity tier the rep picks when adding to cart).
bool hasBatchPricing(String productId, String customerId) {
  return LocalDb.batchPrices.any((bp) {
    final p = bp['product'] as Map?;
    final c = bp['customer'] as Map?;
    if (p?['id'] != productId) return false;
    if (c != null && c['id'] != customerId) return false;
    return _isActiveRange(bp['startDate'] as String?, bp['endDate'] as String?);
  });
}

/// Whether any promotion (percentage/fixed/free-product discount) is currently
/// active for this product and customer — used by the product list to show a
/// "Promotion" indicator before the item is even added to cart, mirroring
/// [hasBatchPricing] above. Mirrors the same filter [resolvePriceOffline] uses
/// for `activePromotions`, since `/promotions/sync` already flattens any
/// customer-group targeting into per-member rows before this syncs locally.
bool hasActivePromotion(String productId, String customerId) {
  return activePromotionsFor(productId, customerId).isNotEmpty;
}

/// All promotions currently active for this product+customer, customer-specific ranked
/// before general — the shared filter behind [hasActivePromotion], [resolvePriceOffline],
/// and the "choose a promotion" picker (used when more than one is returned and the
/// `promotion_manual_selection` system setting is on).
List<Map> activePromotionsFor(String productId, String customerId) {
  final matches = LocalDb.promotions.where((promo) {
    if (promo['isActive'] != true) return false;
    if (!_isActiveRange(promo['startDate'] as String?, promo['endDate'] as String?)) return false;
    final products = (promo['products'] as List? ?? const []);
    final matchesProduct = products.any((p) => (p as Map)['id'] == productId);
    if (!matchesProduct) return false;
    final c = promo['customer'] as Map?;
    return c == null || c['id'] == customerId;
  }).toList();
  matches.sort((a, b) {
    final aSpecific = (a['customer'] as Map?)?['id'] == customerId ? 0 : 1;
    final bSpecific = (b['customer'] as Map?)?['id'] == customerId ? 0 : 1;
    return aSpecific.compareTo(bSpecific);
  });
  return matches;
}

bool _isActiveRange(String? start, String? end) {
  final today = DateTime.now();
  final s = start != null ? DateTime.tryParse(start) : null;
  final e = end != null ? DateTime.tryParse(end) : null;
  if (s != null && today.isBefore(DateTime(s.year, s.month, s.day))) return false;
  if (e != null && today.isAfter(DateTime(e.year, e.month, e.day, 23, 59, 59))) return false;
  return true;
}

/// Offline mirror of the backend's `PricingEngine.resolve()` — used when
/// `/pricing/resolve` can't be reached. Operates on the locally-synced
/// products/customers/batchPrices/promotions caches and returns the same
/// shape as `PriceResolveResponse` so callers can treat both paths identically:
/// `{unitPrice, priceSource, promotionName, maxDiscountAmount, taxPct, freeProduct}`.
Map<String, dynamic> resolvePriceOffline(String productId, String customerId, {String? promotionId}) {
  final product = LocalDb.products.where((p) => p['id'] == productId).firstOrNull;
  final customer = LocalDb.customers.where((c) => c['id'] == customerId).firstOrNull;

  final defaultPrice = (product?['defaultPrice'] as num?)?.toDouble() ?? 0.0;
  final maxDiscountAmount = (product?['maxDiscountAmount'] as num?)?.toDouble();
  final taxPct = _resolveTaxPctOffline(product, customer);

  Map<String, dynamic> result({
    required double unitPrice,
    required String priceSource,
    String? promotionName,
    Map<String, dynamic>? freeProduct,
  }) =>
      {
        'unitPrice': unitPrice,
        'priceSource': priceSource,
        'promotionName': promotionName,
        'maxDiscountAmount': maxDiscountAmount,
        'taxPct': taxPct,
        'freeProduct': freeProduct,
      };

  // Active promotions for this product, customer-specific ranked before general.
  final activePromotions = activePromotionsFor(productId, customerId);

  // A FREE_PRODUCT promotion's eligibility is independent of which price source prices
  // the paid unit below — a product can have both a customer-specific batch price and an
  // active "buy X get Y free" promotion at once, so this is resolved once up front and
  // attached to whichever step returns, mirroring the backend's PricingEngine.resolve().
  final freeProductPromo = activePromotions.where((p) =>
      p['type'] == 'FREE_PRODUCT' && p['freeProduct'] != null).firstOrNull;
  Map<String, dynamic>? freeInfo;
  if (freeProductPromo != null) {
    final fp = freeProductPromo['freeProduct'] as Map;
    final productIds = (freeProductPromo['products'] as List? ?? const [])
        .map((p) => (p as Map)['id'])
        .toList();
    freeInfo = {
      'id': fp['id'],
      'name': fp['name'],
      'productCode': fp['productCode'],
      'maxFreeCount': freeProductPromo['maxFreeCount'] ?? 1,
      'minOrderQty': freeProductPromo['minOrderQty'] ?? 1,
      'applicableProductIds': productIds,
    };
  }

  // 1. Customer-specific batch price — most recently started active row wins.
  final customerRows = LocalDb.batchPrices.where((bp) {
    final p = bp['product'] as Map?;
    final c = bp['customer'] as Map?;
    return p?['id'] == productId &&
        c?['id'] == customerId &&
        _isActiveRange(bp['startDate'] as String?, bp['endDate'] as String?);
  }).toList()
    ..sort((a, b) => (b['startDate'] as String).compareTo(a['startDate'] as String));
  if (customerRows.isNotEmpty) {
    return result(
      unitPrice: (customerRows.first['price'] as num).toDouble(),
      priceSource: 'CUSTOMER_PRICE',
      freeProduct: freeInfo,
    );
  }

  Map? generalBatchRow() {
    final rows = LocalDb.batchPrices.where((bp) {
      final p = bp['product'] as Map?;
      final c = bp['customer'] as Map?;
      return p?['id'] == productId &&
          c == null &&
          _isActiveRange(bp['startDate'] as String?, bp['endDate'] as String?);
    }).toList()
      ..sort((a, b) => (b['startDate'] as String).compareTo(a['startDate'] as String));
    return rows.firstOrNull;
  }

  // 2. Active promotion. An explicit choice (if given and still active) is used verbatim;
  // otherwise a discount-type promotion (PERCENTAGE/FIXED_AMOUNT) always wins over a
  // FREE_PRODUCT one — a FREE_PRODUCT promo's own effect is the separate free item above
  // (freeInfo), so it must never silently suppress an active discount just because it
  // happened to sort first. Mirrors the backend's PricingEngine.resolve() exactly.
  if (activePromotions.isNotEmpty) {
    Map? chosen;
    Map<String, dynamic>? lineFreeInfo = freeInfo;
    if (promotionId != null) {
      chosen = activePromotions.where((p) => p['id'] == promotionId).firstOrNull;
      if (chosen != null) {
        // An explicit pick is exclusive — choosing the discount promotion means the other
        // (free-item) promotion's trigger isn't surfaced for this line either.
        lineFreeInfo = chosen['type'] == 'FREE_PRODUCT' ? freeInfo : null;
      }
    }
    chosen ??= activePromotions.where((p) => p['type'] != 'FREE_PRODUCT').firstOrNull ??
        activePromotions.first;

    final base = (generalBatchRow()?['price'] as num?)?.toDouble() ?? defaultPrice;
    final type = chosen['type'] as String?;
    final promotionName = chosen['name'] as String?;

    if (type == 'FREE_PRODUCT') {
      return result(
        unitPrice: base,
        priceSource: 'PROMOTION',
        promotionName: promotionName,
        freeProduct: lineFreeInfo,
      );
    }

    final discountValue = (chosen['discountValue'] as num?)?.toDouble() ?? 0.0;
    double price = base;
    if (type == 'PERCENTAGE') {
      price = base * (1 - discountValue / 100);
    } else if (type == 'FIXED_AMOUNT') {
      price = (base - discountValue).clamp(0, double.infinity);
    }
    return result(
      unitPrice: price,
      priceSource: 'PROMOTION',
      promotionName: promotionName,
      freeProduct: lineFreeInfo,
    );
  }

  // 3. General batch price.
  final general = generalBatchRow();
  if (general != null) {
    return result(
      unitPrice: (general['price'] as num).toDouble(),
      priceSource: 'BATCH_PRICE',
      freeProduct: freeInfo,
    );
  }

  // 4. Default price.
  return result(unitPrice: defaultPrice, priceSource: 'DEFAULT_PRICE', freeProduct: freeInfo);
}

double _resolveTaxPctOffline(Map? product, Map? customer) {
  final productTaxRate = (product?['taxRate'] as num?)?.toDouble() ?? 0.0;
  if (customer == null) return productTaxRate;
  // A customer is taxable unless explicitly Exempt/Zero Rated — Tax Number is
  // just an optional record field, not a precondition (matches the backend's
  // PricingEngine.resolveTaxPct).
  final taxType = customer['taxType'] as String?;
  final taxable = taxType == null || taxType == 'STANDARD';
  if (!taxable) return 0.0;
  // The customer's own tax rate takes priority over the product's rate.
  final customerTaxRate = (customer['taxRate'] as num?)?.toDouble();
  return customerTaxRate ?? productTaxRate;
}

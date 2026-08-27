import 'package:hive_flutter/hive_flutter.dart';

class LocalDb {
  static late Box<Map> customersBox;
  static late Box<Map> productsBox;
  static late Box<Map> ordersBox;        // cached server orders (last 90 days)
  static late Box<Map> invoicesBox;      // cached server invoices (last 90 days)
  static late Box<Map> promotionsBox;    // cached promotions (manager/admin only)
  static late Box<Map> batchPricesBox;   // cached batch prices (manager/admin only)
  static late Box<Map> pricingOverridesBox; // customerId -> {productId: price}
  static late Box<Map> syncQueueBox;     // generic pending mutations (non-order)
  static late Box<Map> offlineOrdersBox; // orders saved while offline
  static late Box<Map> errorLogsBox;     // runtime error log
  static late Box     settingsBox;

  static Future<void> init() async {
    customersBox        = await Hive.openBox<Map>('customers');
    productsBox         = await Hive.openBox<Map>('products');
    ordersBox           = await Hive.openBox<Map>('orders');
    invoicesBox         = await Hive.openBox<Map>('invoices');
    promotionsBox       = await Hive.openBox<Map>('promotions');
    batchPricesBox      = await Hive.openBox<Map>('batch_prices');
    pricingOverridesBox = await Hive.openBox<Map>('pricing_overrides');
    syncQueueBox        = await Hive.openBox<Map>('sync_queue');
    offlineOrdersBox    = await Hive.openBox<Map>('offline_orders');
    errorLogsBox        = await Hive.openBox<Map>('error_logs');
    settingsBox         = await Hive.openBox('settings');
  }

  static DateTime? get lastSyncAt {
    final raw = settingsBox.get('last_sync_at');
    return raw != null ? DateTime.parse(raw as String) : null;
  }

  static Future<void> setLastSyncAt(DateTime dt) =>
      settingsBox.put('last_sync_at', dt.toIso8601String());

  // ── Global system settings (synced via Full Refresh) ─────────────────────

  static Future<void> setSystemSetting(String key, String value) =>
      settingsBox.put('setting_$key', value);

  static bool getSystemSettingBool(String key, {bool defaultValue = false}) {
    final v = settingsBox.get('setting_$key') as String?;
    return v == null ? defaultValue : v == 'true';
  }

  // Queue a mutation for background sync
  static Future<void> enqueue(String method, String path, Map body) async {
    await syncQueueBox.add({
      'method': method,
      'path': path,
      'body': body,
      'timestamp': DateTime.now().toIso8601String(),
      'retries': 0,
    });
  }

  static List<Map> get pendingMutations =>
      syncQueueBox.values.toList().cast<Map>();

  static Future<void> clearQueue() => syncQueueBox.clear();

  // Merge server data into local boxes (delta — only upserts, keeps existing records)
  static Future<void> mergeCustomers(List<Map> items) async {
    for (final item in items) {
      await customersBox.put(item['id'] as String, item);
    }
  }

  // Full replace — clears the box first so removed/restricted customers are evicted
  static Future<void> replaceCustomers(List<Map> items) async {
    await customersBox.clear();
    for (final item in items) {
      await customersBox.put(item['id'] as String, item);
    }
  }

  // Call on login to force a full customer/product re-sync for the new user session
  static Future<void> clearCustomerCache() async {
    await customersBox.clear();
    await productsBox.clear();
    await settingsBox.delete('last_sync_at');
  }

  // ── Offline orders ────────────────────────────────────────────────────────

  static Future<void> saveOfflineOrder({
    required String customerId,
    required String customerName,
    required double grandTotal,
    required int itemCount,
    required Map payload,
  }) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    await offlineOrdersBox.put(id, {
      'id': id,
      'timestamp': DateTime.now().toIso8601String(),
      'customerId': customerId,
      'customerName': customerName,
      'grandTotal': grandTotal,
      'itemCount': itemCount,
      'payload': payload,
    });
  }

  static List<Map> get offlineOrders {
    final list = offlineOrdersBox.values.toList().cast<Map>().toList();
    list.sort((a, b) =>
        (b['timestamp'] as String).compareTo(a['timestamp'] as String));
    return list;
  }

  static Future<void> removeOfflineOrder(String id) =>
      offlineOrdersBox.delete(id);

  // ── Sync metadata ─────────────────────────────────────────────────────────

  static int? get lastSyncCustomers =>
      settingsBox.get('last_sync_customers') as int?;
  static int? get lastSyncProducts =>
      settingsBox.get('last_sync_products') as int?;

  static Future<void> setLastSyncCounts(int customers, int products) async {
    await settingsBox.put('last_sync_customers', customers);
    await settingsBox.put('last_sync_products', products);
  }

  // ── Error logs ────────────────────────────────────────────────────────────

  static Future<void> logError(
    String title,
    String detail, {
    String? endpoint,
  }) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    await errorLogsBox.put(id, {
      'id':        id,
      'timestamp': DateTime.now().toIso8601String(),
      'title':     title,
      'detail':    detail,
      'endpoint':  endpoint,
    });
    // Keep at most 500 entries to prevent unbounded growth
    if (errorLogsBox.length > 500) {
      final oldest = (errorLogsBox.keys.toList()..sort()).first;
      await errorLogsBox.delete(oldest);
    }
  }

  static List<Map> get errorLogs {
    final list = errorLogsBox.values.toList().cast<Map>();
    list.sort((a, b) =>
        (b['timestamp'] as String).compareTo(a['timestamp'] as String));
    return list;
  }

  static Future<void> clearErrorLogs() => errorLogsBox.clear();

  // Call on logout to wipe all local data for the session
  static Future<void> clearAll() async {
    await customersBox.clear();
    await productsBox.clear();
    await ordersBox.clear();
    await invoicesBox.clear();
    await promotionsBox.clear();
    await batchPricesBox.clear();
    await pricingOverridesBox.clear();
    await syncQueueBox.clear();
    await offlineOrdersBox.clear();
    await errorLogsBox.clear();
    await settingsBox.clear();
  }

  static Future<void> mergeProducts(List<Map> items) async {
    for (final item in items) {
      await productsBox.put(item['id'] as String, item);
    }
  }

  // Full replace — evicts products that were deactivated/removed server-side
  static Future<void> replaceProducts(List<Map> items) async {
    await productsBox.clear();
    for (final item in items) {
      await productsBox.put(item['id'] as String, item);
    }
  }

  static List<Map> get customers =>
      customersBox.values.toList().cast<Map>();

  static List<Map> get products =>
      productsBox.values.toList().cast<Map>();

  // ── Full-sync caches ──────────────────────────────────────────────────────
  // Each of these is a full replace: the full-sync step re-fetches the whole
  // (bounded) window from the server, so stale local records must be evicted.

  static Future<void> replaceServerOrders(List<Map> items) async {
    await ordersBox.clear();
    for (final item in items) {
      await ordersBox.put(item['id'] as String, item);
    }
  }

  static List<Map> get serverOrders => ordersBox.values.toList().cast<Map>();

  static Future<void> replaceInvoices(List<Map> items) async {
    await invoicesBox.clear();
    for (final item in items) {
      await invoicesBox.put(item['id'] as String, item);
    }
  }

  static List<Map> get invoices => invoicesBox.values.toList().cast<Map>();

  static Future<void> replacePromotions(List<Map> items) async {
    await promotionsBox.clear();
    for (final item in items) {
      await promotionsBox.put(item['id'] as String, item);
    }
  }

  static List<Map> get promotions => promotionsBox.values.toList().cast<Map>();

  static Future<void> replaceBatchPrices(List<Map> items) async {
    await batchPricesBox.clear();
    for (final item in items) {
      await batchPricesBox.put(item['id'] as String, item);
    }
  }

  static List<Map> get batchPrices => batchPricesBox.values.toList().cast<Map>();

  // Keyed by customerId; value is {productId: price} for that customer's active overrides.
  static Future<void> setPricingOverrides(String customerId, Map<String, dynamic> priceMap) =>
      pricingOverridesBox.put(customerId, priceMap);

  static Map<String, dynamic>? pricingOverridesFor(String customerId) =>
      pricingOverridesBox.get(customerId)?.cast<String, dynamic>();
}

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/local_db.dart';
import '../../core/storage/sync_service.dart';
import '../auth/auth_provider.dart';
import '../mileage/mileage_provider.dart';
import '../orders/order_provider.dart';

// ── Full-sync step model ────────────────────────────────────────────────────

enum FullSyncStatus { pending, running, success, failed, skipped }

class FullSyncStep {
  final String key;
  final String label;
  final FullSyncStatus status;
  final int? count;
  final String? error;

  const FullSyncStep({
    required this.key,
    required this.label,
    this.status = FullSyncStatus.pending,
    this.count,
    this.error,
  });

  FullSyncStep copyWith({
    FullSyncStatus? status,
    int? count,
    String? error,
  }) =>
      FullSyncStep(
        key:    key,
        label:  label,
        status: status ?? this.status,
        count:  count  ?? this.count,
        error:  error  ?? this.error,
      );
}

// Roles allowed to pull the Promotions / Batch Pricing catalogs. Sales reps need
// this data too — they apply promotions/batch pricing while placing orders.
const _pricingSyncRoles = {'SUPER_ADMIN', 'SALES_MANAGER', 'SALES_REP'};

// ── State ─────────────────────────────────────────────────────────────────────

class SyncState {
  final bool isSyncing;
  final bool isFullSyncing;
  final List<FullSyncStep> fullSyncSteps;
  final int pendingOrderCount;
  final Set<String> pushingIds;
  final Set<String> failedIds;
  final Map<String, String> failedErrors; // localId → error message
  final DateTime? lastSyncAt;
  final String? syncMessage;

  const SyncState({
    this.isSyncing = false,
    this.isFullSyncing = false,
    this.fullSyncSteps = const [],
    this.pendingOrderCount = 0,
    this.pushingIds = const {},
    this.failedIds = const {},
    this.failedErrors = const {},
    this.lastSyncAt,
    this.syncMessage,
  });

  SyncState copyWith({
    bool? isSyncing,
    bool? isFullSyncing,
    List<FullSyncStep>? fullSyncSteps,
    int? pendingOrderCount,
    Set<String>? pushingIds,
    Set<String>? failedIds,
    Map<String, String>? failedErrors,
    DateTime? lastSyncAt,
    Object? syncMessage = _sentinel,
  }) =>
      SyncState(
        isSyncing:         isSyncing         ?? this.isSyncing,
        isFullSyncing:     isFullSyncing     ?? this.isFullSyncing,
        fullSyncSteps:     fullSyncSteps     ?? this.fullSyncSteps,
        pendingOrderCount: pendingOrderCount  ?? this.pendingOrderCount,
        pushingIds:        pushingIds         ?? this.pushingIds,
        failedIds:         failedIds          ?? this.failedIds,
        failedErrors:      failedErrors       ?? this.failedErrors,
        lastSyncAt:        lastSyncAt         ?? this.lastSyncAt,
        syncMessage: syncMessage == _sentinel
            ? this.syncMessage
            : syncMessage as String?,
      );
}

const _sentinel = Object();

// ── Paging helper ────────────────────────────────────────────────────────────

/// Pages through a Spring Data `Page<T>` endpoint, collecting `content` until
/// the last page, a safety cap, or [stopBefore] matches (used to cut off a
/// descending-sorted list once it crosses a date boundary).
Future<List<Map>> _fetchAllPages(
  Dio dio,
  String path, {
  Map<String, dynamic> baseParams = const {},
  int pageSize = 100,
  int maxPages = 20,
  bool Function(Map item)? stopBefore,
}) async {
  final items = <Map>[];
  for (var page = 0; page < maxPages; page++) {
    final resp = await dio.get(path, queryParameters: {
      ...baseParams,
      'page': page,
      'size': pageSize,
    });
    final data = resp.data as Map<String, dynamic>;
    final content = List<Map>.from(data['content'] as List? ?? const []);

    if (stopBefore != null) {
      final idx = content.indexWhere(stopBefore);
      if (idx != -1) {
        items.addAll(content.sublist(0, idx));
        return items;
      }
    }
    items.addAll(content);

    final isLast = data['last'] as bool? ?? true;
    if (isLast || content.isEmpty) break;
  }
  return items;
}

// ── Notifier ──────────────────────────────────────────────────────────────────

class SyncNotifier extends Notifier<SyncState> {
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  @override
  SyncState build() {
    ref.onDispose(() => _connectivitySub?.cancel());

    // Auto-push offline orders when connectivity is restored
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNetwork = results.any((r) => r != ConnectivityResult.none);
      if (hasNetwork && LocalDb.offlineOrders.isNotEmpty) {
        pushAllOrders();
      }
    });

    return SyncState(
      pendingOrderCount: LocalDb.offlineOrders.length,
      lastSyncAt: LocalDb.lastSyncAt,
    );
  }

  /// Push a single offline order to the backend.
  Future<void> pushOrder(String localId, Map payload) async {
    state = state.copyWith(
      pushingIds:  {...state.pushingIds, localId},
      syncMessage: null,
    );
    try {
      final dio       = ref.read(dioProvider);
      final createResp = await dio.post('/orders', data: payload);
      final orderId   = createResp.data['id'] as String;
      await dio.post('/orders/$orderId/submit');
      await LocalDb.removeOfflineOrder(localId);

      final newFailed = Map<String, String>.from(state.failedErrors)
        ..remove(localId);
      state = state.copyWith(
        pushingIds:        {...state.pushingIds}..remove(localId),
        failedIds:         {...state.failedIds}..remove(localId),
        failedErrors:      newFailed,
        pendingOrderCount: LocalDb.offlineOrders.length,
      );
    } catch (e) {
      final detail = e is DioException
          ? (e.response?.data?.toString() ?? e.message ?? e.toString())
          : e.toString();

      await LocalDb.logError(
        'Offline order push failed',
        detail,
        endpoint: '/orders',
      );

      final newFailed = Map<String, String>.from(state.failedErrors)
        ..[localId] = detail;
      state = state.copyWith(
        pushingIds:   {...state.pushingIds}..remove(localId),
        failedIds:    {...state.failedIds, localId},
        failedErrors: newFailed,
      );
    }
  }

  /// Push all pending offline orders sequentially.
  Future<void> pushAllOrders() async {
    final orders = List<Map>.from(LocalDb.offlineOrders);
    if (orders.isEmpty) return;
    for (final order in orders) {
      await pushOrder(order['id'] as String, order['payload'] as Map);
    }
  }

  /// Pull latest reference data from the server.
  Future<void> syncData({bool force = false}) async {
    if (state.isSyncing) return;
    state = state.copyWith(isSyncing: true, syncMessage: null);
    try {
      final result = await ref.read(syncServiceProvider).sync(force: force);
      final msg = force
          ? 'Full refresh complete — all data updated'
          : (result.customersUpdated + result.productsUpdated == 0
              ? 'Already up to date'
              : 'Updated ${result.customersUpdated} customer'
                '${result.customersUpdated == 1 ? '' : 's'}'
                ', ${result.productsUpdated} product'
                '${result.productsUpdated == 1 ? '' : 's'}');
      state = state.copyWith(
        isSyncing:   false,
        lastSyncAt:  LocalDb.lastSyncAt,
        syncMessage: msg,
      );
    } catch (e) {
      await LocalDb.logError(
        'Data sync failed',
        e.toString(),
        endpoint: '/sync/delta',
      );
      state = state.copyWith(
        isSyncing:   false,
        syncMessage: 'Sync failed — check your connection',
      );
    }
  }

  /// Refresh the pending count (call after a new offline order is saved).
  void refreshPendingCount() {
    state = state.copyWith(pendingOrderCount: LocalDb.offlineOrders.length);
  }

  // ── Full sync ───────────────────────────────────────────────────────────

  /// Runs every reference-data API individually (Customers, Products, Orders,
  /// Invoices, Pricing, Promotions, Batch Pricing …), replacing the previous
  /// single `/sync/delta` full-refresh call. Each call's outcome is tracked in
  /// [SyncState.fullSyncSteps] so the UI can render a live checklist while the
  /// run is in progress, and failures are recorded via [LocalDb.logError].
  Future<void> fullSync() async {
    if (state.isFullSyncing) return;

    final role = ref.read(authNotifierProvider).valueOrNull?.role;
    final canPullPricing = _pricingSyncRoles.contains(role);

    final steps = <FullSyncStep>[
      const FullSyncStep(key: 'customers', label: 'Customers'),
      const FullSyncStep(key: 'products',  label: 'Products'),
      const FullSyncStep(key: 'orders',    label: 'Orders (last 90 days)'),
      const FullSyncStep(key: 'invoices',  label: 'Invoices (last 90 days)'),
      const FullSyncStep(key: 'pricing',   label: 'Customer Pricing'),
      FullSyncStep(
        key: 'promotions',
        label: 'Promotions',
        status: canPullPricing ? FullSyncStatus.pending : FullSyncStatus.skipped,
        error: canPullPricing ? null : 'Requires Sales Rep / Manager / Admin role',
      ),
      FullSyncStep(
        key: 'batchPrices',
        label: 'Batch Pricing',
        status: canPullPricing ? FullSyncStatus.pending : FullSyncStatus.skipped,
        error: canPullPricing ? null : 'Requires Sales Rep / Manager / Admin role',
      ),
      const FullSyncStep(key: 'settings', label: 'System Settings'),
    ];

    state = state.copyWith(isFullSyncing: true, fullSyncSteps: steps, syncMessage: null);

    final dio    = ref.read(dioProvider);
    final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 90));
    var failures = 0;

    Future<void> runStep(String key, String label, Future<int> Function() task) async {
      _updateFullSyncStep(key, status: FullSyncStatus.running);
      try {
        final count = await task();
        _updateFullSyncStep(key, status: FullSyncStatus.success, count: count);
      } catch (e) {
        failures++;
        final detail = e is DioException
            ? (e.response?.data?.toString() ?? e.message ?? e.toString())
            : e.toString();
        await LocalDb.logError('Full sync: $label failed', detail, endpoint: key);
        _updateFullSyncStep(key, status: FullSyncStatus.failed, error: detail);
      }
    }

    await runStep('customers', 'Customers', () async {
      final items = await _fetchAllPages(dio, '/customers', pageSize: 200, maxPages: 50);
      await LocalDb.replaceCustomers(items);
      return items.length;
    });

    await runStep('products', 'Products', () async {
      final items = await _fetchAllPages(dio, '/products', pageSize: 200, maxPages: 50);
      await LocalDb.replaceProducts(items);
      return items.length;
    });

    await runStep('orders', 'Orders', () async {
      final items = await _fetchAllPages(
        dio, '/orders',
        baseParams: {'sort': 'createdAt,DESC'},
        pageSize: 100,
        maxPages: 20,
        stopBefore: (item) {
          final createdAt = DateTime.tryParse(item['createdAt'] as String? ?? '');
          return createdAt != null && createdAt.isBefore(cutoff);
        },
      );
      await LocalDb.replaceServerOrders(items);
      return items.length;
    });

    await runStep('invoices', 'Invoices', () async {
      final items = await _fetchAllPages(
        dio, '/invoices',
        baseParams: {'issuedFrom': cutoff.toIso8601String().split('T').first},
        pageSize: 100,
        maxPages: 20,
      );
      await LocalDb.replaceInvoices(items);
      return items.length;
    });

    await runStep('pricing', 'Customer Pricing', () async {
      const customerCap = 100;
      final customers = LocalDb.customers;
      var synced = 0;
      for (final c in customers.take(customerCap)) {
        final id = c['id'] as String?;
        if (id == null) continue;
        final resp = await dio.get('/pricing/customer-overrides',
            queryParameters: {'customerId': id});
        await LocalDb.setPricingOverrides(id, Map<String, dynamic>.from(resp.data as Map));
        synced++;
      }
      if (customers.length > customerCap) {
        await LocalDb.logError(
          'Full sync: Customer Pricing truncated',
          'Cached price overrides for $customerCap of ${customers.length} customers',
          endpoint: 'pricing',
        );
      }
      return synced;
    });

    if (canPullPricing) {
      await runStep('promotions', 'Promotions', () async {
        // /sync flattens any customer-group-targeted promotion into one row per current group
        // member server-side — see BatchPriceController.syncPromotions.
        final items = await _fetchAllPages(dio, '/promotions/sync', pageSize: 100, maxPages: 20);
        await LocalDb.replacePromotions(items);
        return items.length;
      });

      await runStep('batchPrices', 'Batch Pricing', () async {
        // /sync (not the plain admin list endpoint) flattens any customer-group/product-group
        // targeted rule into one row per current group member server-side, since this app has
        // no group concept of its own — see BatchPriceController.syncBatchPrices.
        final items = await _fetchAllPages(dio, '/batch-prices/sync', pageSize: 100, maxPages: 20);
        await LocalDb.replaceBatchPrices(items);
        return items.length;
      });
    }

    await runStep('settings', 'System Settings', () async {
      final resp = await dio.get('/settings');
      final items = List<Map<String, dynamic>>.from(resp.data as List);
      for (final s in items) {
        await LocalDb.setSystemSetting(s['key'] as String, s['value'] as String);
      }
      ref.invalidate(mileageNotifierProvider);

      final reasonsResp = await dio.get('/reasons');
      final reasons = List<Map<String, dynamic>>.from(reasonsResp.data as List);
      await LocalDb.replaceReasons(reasons);

      return items.length;
    });

    await LocalDb.setLastSyncAt(DateTime.now().toUtc());

    // A Full Sync just replaced the products/pricing/promotions caches, so any
    // in-progress "add to cart" draft may be holding stale prices/promotions —
    // clear it rather than let the rep submit against data that no longer
    // matches what's cached. Orders/Invoices (already synced above) are kept.
    if (ref.read(orderCreationProvider) != null) {
      ref.read(orderCreationProvider.notifier).clearOrder();
    }

    state = state.copyWith(
      isFullSyncing: false,
      lastSyncAt:    LocalDb.lastSyncAt,
      syncMessage: failures == 0
          ? 'Full sync complete — all data updated'
          : 'Full sync finished with $failures issue${failures == 1 ? '' : 's'} — see details below',
    );
  }

  void _updateFullSyncStep(String key, {FullSyncStatus? status, int? count, String? error}) {
    final updated = state.fullSyncSteps
        .map((s) => s.key == key ? s.copyWith(status: status, count: count, error: error) : s)
        .toList();
    state = state.copyWith(fullSyncSteps: updated);
  }
}

final syncNotifierProvider =
    NotifierProvider<SyncNotifier, SyncState>(SyncNotifier.new);

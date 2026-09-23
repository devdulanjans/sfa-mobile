import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../network/api_client.dart';
import 'local_db.dart';
import '../../features/mileage/mileage_provider.dart';

final syncServiceProvider = Provider((ref) => SyncService(ref));

class SyncResult {
  final int customersUpdated;
  final int productsUpdated;
  const SyncResult(this.customersUpdated, this.productsUpdated);
}

class SyncService {
  final Ref _ref;
  bool _syncing = false;

  SyncService(this._ref);

  /// [force] = true performs a full replace (same as first-ever sync).
  Future<SyncResult> sync({bool force = false}) async {
    if (_syncing) return const SyncResult(0, 0);
    _syncing = true;
    try {
      final dio = _ref.read(dioProvider);

      // 1. Flush any generic pending mutations
      final queue = LocalDb.pendingMutations;
      for (final item in queue) {
        try {
          final method = item['method'] as String;
          final path   = item['path']   as String;
          final body   = item['body']   as Map;
          switch (method) {
            case 'POST':   await dio.post(path,  data: body); break;
            case 'PUT':    await dio.put(path,   data: body); break;
            case 'DELETE': await dio.delete(path);             break;
          }
        } catch (_) {}
      }
      await LocalDb.clearQueue();

      // 2. Pull global settings (small list) so tenant-level feature toggles
      // (e.g. mileage management) are current as of every login/sync, not
      // only after a manual Full Sync.
      try {
        final settingsResp = await dio.get('/settings');
        final settingsList = List<Map<String, dynamic>>.from(settingsResp.data as List);
        for (final s in settingsList) {
          await LocalDb.setSystemSetting(s['key'] as String, s['value'] as String);
        }
        _ref.invalidate(mileageNotifierProvider);
      } catch (_) {}

      // 2b. Pull Damage/Return reasons (small, admin-managed list) — kept fresh
      // every sync so an admin-added/removed reason shows up on the next login
      // or background sync, not only after a manual Full Sync.
      try {
        final reasonsResp = await dio.get('/reasons');
        final reasonsList = List<Map<String, dynamic>>.from(reasonsResp.data as List);
        await LocalDb.replaceReasons(reasonsList);
      } catch (_) {}

      // 3. Pull delta (or full snapshot when force=true or first login)
      final since = force ? null : LocalDb.lastSyncAt;
      final params = since != null
          ? {'since': since.toIso8601String()}
          : <String, dynamic>{};

      final resp = await dio.get('/sync/delta', queryParameters: params);
      final data = resp.data as Map<String, dynamic>;

      int cCount = 0, pCount = 0;

      if (data['customers'] != null) {
        final list = List<Map>.from(data['customers'] as List);
        cCount = list.length;
        if (since == null) {
          await LocalDb.replaceCustomers(list);
        } else {
          await LocalDb.mergeCustomers(list);
        }
      }
      if (data['products'] != null) {
        final list = List<Map>.from(data['products'] as List);
        pCount = list.length;
        await LocalDb.mergeProducts(list);
      }

      await LocalDb.setLastSyncAt(DateTime.now().toUtc());
      await LocalDb.setLastSyncCounts(cCount, pCount);
      return SyncResult(cCount, pCount);
    } catch (_) {
      return const SyncResult(0, 0);
    } finally {
      _syncing = false;
    }
  }
}

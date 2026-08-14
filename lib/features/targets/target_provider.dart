import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../auth/auth_provider.dart';

/// One targeted product's status for the current month, as computed live by the backend
/// (see SalesTargetService.computeStatus) — never stored client-side beyond this fetch.
class TargetStatus {
  final String productName;
  final String productCode;
  final double targetQty;
  final double achievedQty;
  final double remainingQty;
  final double? todayTarget;
  final double? achievedToday;

  const TargetStatus({
    required this.productName,
    required this.productCode,
    required this.targetQty,
    required this.achievedQty,
    required this.remainingQty,
    this.todayTarget,
    this.achievedToday,
  });

  factory TargetStatus.fromJson(Map<String, dynamic> json) => TargetStatus(
        productName: json['productName'] as String? ?? '',
        productCode: json['productCode'] as String? ?? '',
        targetQty: (json['targetQty'] as num?)?.toDouble() ?? 0,
        achievedQty: (json['achievedQty'] as num?)?.toDouble() ?? 0,
        remainingQty: (json['remainingQty'] as num?)?.toDouble() ?? 0,
        todayTarget: (json['todayTarget'] as num?)?.toDouble(),
        achievedToday: (json['achievedToday'] as num?)?.toDouble(),
      );
}

/// This SALES_REP's current-month targets with today's computed daily target. Empty list
/// covers every "nothing to show" case uniformly — feature disabled, no targets assigned,
/// non-SALES_REP role, or a fetch error — so the dashboard card just doesn't render rather
/// than needing separate branches for each (unlike mileage, this isn't a compliance gate,
/// so failing silently on error is the right call here).
class SalesTargetNotifier extends AsyncNotifier<List<TargetStatus>> {
  @override
  Future<List<TargetStatus>> build() async {
    final user = ref.watch(authNotifierProvider).valueOrNull;
    if (user == null || user.role != 'SALES_REP') return [];

    final dio = ref.read(dioProvider);
    try {
      final resp = await dio.get('/sales-targets/my-today');
      final list = resp.data as List? ?? [];
      return list
          .map((e) => TargetStatus.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}

final salesTargetNotifierProvider =
    AsyncNotifierProvider<SalesTargetNotifier, List<TargetStatus>>(SalesTargetNotifier.new);

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/colors.dart';
import '../../app/radii.dart';
import '../../core/app_info.dart';
import '../../core/storage/local_db.dart';
import '../../shared/widgets/app_card.dart';
import '../../utils/formatters.dart';
import 'sync_provider.dart';

class SyncScreen extends ConsumerWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state    = ref.watch(syncNotifierProvider);
    final notifier = ref.read(syncNotifierProvider.notifier);
    // Re-read from LocalDb each build (state changes trigger rebuilds)
    final orders   = LocalDb.offlineOrders;

    // Open the blocking progress dialog the moment a full sync starts; the
    // dialog closes itself (via its own Done button) once it completes.
    ref.listen<SyncState>(syncNotifierProvider, (prev, next) {
      final justStarted = next.isFullSyncing && !(prev?.isFullSyncing ?? false);
      if (justStarted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const _FullSyncDialog(),
        );
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Sync')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [

          // ── Offline Orders ─────────────────────────────────────────────────
          if (orders.isNotEmpty) ...[
            _SectionHeader(
              label: 'Offline Orders',
              badge: '${orders.length}',
              trailing: orders.length > 1
                  ? FilledButton.tonal(
                      onPressed: state.pushingIds.isNotEmpty
                          ? null
                          : notifier.pushAllOrders,
                      child: const Text('Push All'),
                    )
                  : null,
            ),
            const SizedBox(height: 8),
            ...orders.map((o) => _OfflineOrderCard(
                  order: o,
                  isPushing: state.pushingIds.contains(o['id']),
                  hasFailed: state.failedIds.contains(o['id']),
                  onPush: () => notifier.pushOrder(
                      o['id'] as String, o['payload'] as Map),
                )),
            const SizedBox(height: 24),
          ],

          if (orders.isEmpty)
            const _EmptyOrdersCard(),

          const SizedBox(height: 20),

          // ── App Data ───────────────────────────────────────────────────────
          const _SectionHeader(label: 'App Data'),
          const SizedBox(height: 8),
          _DataSyncCard(state: state, notifier: notifier),
          const SizedBox(height: 20),
          const _AppVersionFooter(),
        ],
      ),
    );
  }
}

// ── App version footer ───────────────────────────────────────────────────────

class _AppVersionFooter extends ConsumerWidget {
  const _AppVersionFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(appInfoProvider);
    return Center(
      child: info.when(
        data: (i) => Text(
          'App v${i.version} (${i.buildNumber})',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        loading: () => const SizedBox.shrink(),
        error: (_, __) => const SizedBox.shrink(),
      ),
    );
  }
}

// ── Offline order card ────────────────────────────────────────────────────────

class _OfflineOrderCard extends StatelessWidget {
  final Map order;
  final bool isPushing;
  final bool hasFailed;
  final VoidCallback onPush;

  const _OfflineOrderCard({
    required this.order,
    required this.isPushing,
    required this.hasFailed,
    required this.onPush,
  });

  @override
  Widget build(BuildContext context) {
    final primary      = Theme.of(context).colorScheme.primary;
    final customerName = order['customerName'] as String? ?? 'Unknown Customer';
    final ts           = DateTime.tryParse(order['timestamp'] as String? ?? '') ??
        DateTime.now();
    final grandTotal   = (order['grandTotal'] as num?)?.toDouble() ?? 0;
    final itemCount    = order['itemCount'] as int? ?? 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          // Icon
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(
              color: hasFailed ? AppColors.pinkBg : AppColors.violetBg,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(
              hasFailed
                  ? Icons.cloud_off_rounded
                  : Icons.cloud_upload_outlined,
              color: hasFailed ? AppColors.pinkFg : AppColors.violetFg,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),

          // Details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(customerName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  '$itemCount item${itemCount == 1 ? '' : 's'}  ·  ${_timeAgo(ts)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                if (hasFailed)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      'Upload failed — tap Retry',
                      style: TextStyle(
                          fontSize: 11, color: Colors.red.shade600),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),

          // Amount + action
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('LKR ${formatAmount(grandTotal)}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 13)),
              const SizedBox(height: 6),
              isPushing
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: primary))
                  : FilledButton(
                      onPressed: onPush,
                      style: FilledButton.styleFrom(
                        backgroundColor:
                            hasFailed ? Colors.red.shade600 : null,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        minimumSize: Size.zero,
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      child: Text(hasFailed ? 'Retry' : 'Push'),
                    ),
            ],
          ),
        ]),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyOrdersCard extends StatelessWidget {
  const _EmptyOrdersCard();

  @override
  Widget build(BuildContext context) => const AppCard(
        tone: AppTone.mint,
        padding: EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Row(children: [
          Icon(Icons.check_circle_outline_rounded,
              color: AppColors.mintFg, size: 28),
          SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('All orders uploaded',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              SizedBox(height: 2),
              Text('No offline orders pending',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
          ),
        ]),
      );
}

// ── Data sync card ────────────────────────────────────────────────────────────

class _DataSyncCard extends StatelessWidget {
  final SyncState state;
  final SyncNotifier notifier;
  const _DataSyncCard({required this.state, required this.notifier});

  @override
  Widget build(BuildContext context) {
    final primary     = Theme.of(context).colorScheme.primary;
    final lastSync    = state.lastSyncAt;
    final isSuccess   = state.syncMessage != null &&
        !state.syncMessage!.contains('fail') &&
        !state.syncMessage!.contains('failed');

    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header row
          Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: AppColors.violetBg,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: const Icon(Icons.sync_rounded, color: AppColors.violetFg, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Products, Customers & Prices',
                    style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 2),
                Text(
                  lastSync != null
                      ? 'Last synced ${_timeAgo(lastSync)}'
                      : 'Never synced',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ]),
            ),
          ]),

          // Result message
          if (state.syncMessage != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: isSuccess ? AppColors.mintBg : AppColors.pinkBg,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Row(children: [
                Icon(
                  isSuccess
                      ? Icons.check_circle_outline_rounded
                      : Icons.error_outline_rounded,
                  size: 16,
                  color: isSuccess ? AppColors.mintFg : AppColors.pinkFg,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state.syncMessage!,
                    style: TextStyle(
                        fontSize: 12,
                        color: isSuccess ? AppColors.mintFg : AppColors.pinkFg),
                  ),
                ),
              ]),
            ),
          ],

          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 14),

          // Info text
          const Text(
            'Sync Changes pulls only records updated since the last sync. '
            'Full Refresh calls every data API individually — channels, customers, '
            'products, orders, invoices, pricing, promotions & batch pricing — '
            'and shows live progress for each.',
            style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.4),
          ),
          const SizedBox(height: 14),

          // Buttons
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: (state.isSyncing || state.isFullSyncing)
                    ? null
                    : () => notifier.syncData(),
                icon: state.isSyncing
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: primary))
                    : const Icon(Icons.download_rounded, size: 16),
                label: Text(
                    state.isSyncing ? 'Syncing…' : 'Sync Changes'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: (state.isSyncing || state.isFullSyncing)
                    ? null
                    : () => notifier.fullSync(),
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Full Refresh'),
              ),
            ),
          ]),
        ]),
    );
  }
}

// ── Section header ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final String? badge;
  final Widget? trailing;
  const _SectionHeader({required this.label, this.badge, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Text(label,
          style: const TextStyle(
              fontWeight: FontWeight.w700, fontSize: 13)),
      if (badge != null) ...[
        const SizedBox(width: 6),
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
          decoration: BoxDecoration(
            color: AppColors.pinkFg,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Text(badge!,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold)),
        ),
      ],
      const Spacer(),
      if (trailing != null) trailing!,
    ]);
  }
}

// ── Full sync progress dialog ─────────────────────────────────────────────────
//
// Blocking (barrierDismissible: false, PopScope(canPop: false)) so the user
// can't navigate away mid-run; the per-API checklist updates live as each
// call completes.

class _FullSyncDialog extends ConsumerWidget {
  const _FullSyncDialog();

  IconData _iconFor(FullSyncStatus s) => switch (s) {
        FullSyncStatus.pending => Icons.radio_button_unchecked_rounded,
        FullSyncStatus.running => Icons.sync_rounded,
        FullSyncStatus.success => Icons.check_circle_rounded,
        FullSyncStatus.failed  => Icons.error_rounded,
        FullSyncStatus.skipped => Icons.remove_circle_outline_rounded,
      };

  Color _colorFor(BuildContext context, FullSyncStatus s) => switch (s) {
        FullSyncStatus.pending => Colors.grey,
        FullSyncStatus.running => Theme.of(context).colorScheme.primary,
        FullSyncStatus.success => Colors.green.shade600,
        FullSyncStatus.failed  => Colors.red.shade600,
        FullSyncStatus.skipped => Colors.orange.shade700,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(syncNotifierProvider);

    return PopScope(
      canPop: !state.isFullSyncing,
      child: AlertDialog(
        title: const Text('Full Sync'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final step in state.fullSyncSteps)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        step.status == FullSyncStatus.running
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _colorFor(context, step.status)),
                              )
                            : Icon(_iconFor(step.status),
                                size: 18, color: _colorFor(context, step.status)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(step.label,
                                  style: const TextStyle(
                                      fontSize: 13, fontWeight: FontWeight.w600)),
                              if (step.status == FullSyncStatus.success)
                                Text(
                                  '${step.count ?? 0} synced',
                                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                                ),
                              if (step.status == FullSyncStatus.failed && step.error != null)
                                Text(
                                  step.error!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 11, color: Colors.red.shade600),
                                ),
                              if (step.status == FullSyncStatus.skipped && step.error != null)
                                Text(
                                  step.error!,
                                  style: TextStyle(fontSize: 11, color: Colors.orange.shade700),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: state.isFullSyncing ? null : () => Navigator.of(context).pop(),
            child: Text(state.isFullSyncing ? 'Syncing…' : 'Done'),
          ),
        ],
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _timeAgo(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inSeconds < 60)  return 'just now';
  if (diff.inMinutes < 60)  return '${diff.inMinutes}m ago';
  if (diff.inHours < 24)    return '${diff.inHours}h ago';
  if (diff.inDays < 7)      return '${diff.inDays}d ago';
  return '${dt.day}/${dt.month}/${dt.year}';
}

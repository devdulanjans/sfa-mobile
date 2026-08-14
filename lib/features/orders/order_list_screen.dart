import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../app/colors.dart';
import '../../app/radii.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/local_db.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/status_badge.dart';
import '../../utils/formatters.dart';
import '../sync/sync_provider.dart';
import 'order_provider.dart';

final _statusTones = {
  'DRAFT':     AppTone.neutral,
  'SUBMITTED': AppTone.orange,
  'APPROVED':  AppTone.mint,
  'INVOICED':  AppTone.violet,
  'CANCELLED': AppTone.pink,
};

// ── Helpers ───────────────────────────────────────────────────────────────────

Future<bool?> _confirmDelete(BuildContext context, String orderNumber) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete Draft Order'),
      content: Text('Delete $orderNumber? This cannot be undone.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red.shade600),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
}

Future<void> _deleteDraftOrder(
    BuildContext context, WidgetRef ref, String orderId) async {
  try {
    await ref.read(dioProvider).delete('/orders/$orderId');
    ref.invalidate(orderListProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Draft order deleted'),
                       backgroundColor: Colors.green));
    }
  } catch (e) {
    ref.invalidate(orderListProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete: $e'),
                 backgroundColor: Colors.red));
    }
  }
}

// ── Screen ────────────────────────────────────────────────────────────────────

Future<void> _openFilters(BuildContext context, WidgetRef ref) async {
  final current = ref.read(orderFiltersProvider);
  final result = await showModalBottomSheet<OrderListFilters>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _OrderFilterSheet(initial: current),
  );
  if (result != null) {
    ref.read(orderFiltersProvider.notifier).state = result;
  }
}

class OrderListScreen extends ConsumerWidget {
  const OrderListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async      = ref.watch(orderListProvider);
    final syncState  = ref.watch(syncNotifierProvider);
    final filters    = ref.watch(orderFiltersProvider);
    final offline    = LocalDb.offlineOrders;
    final hasPending = offline.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Orders'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/dashboard'),
        ),
        actions: [
          IconButton(
            icon: Badge(
              isLabelVisible: filters.activeCount > 0,
              label: Text('${filters.activeCount}'),
              child: const Icon(Icons.filter_list),
            ),
            tooltip: 'Filter Orders',
            onPressed: () => _openFilters(context, ref),
          ),
          if (hasPending)
            TextButton.icon(
              onPressed: syncState.isSyncing ||
                      syncState.pushingIds.isNotEmpty
                  ? null
                  : () => ref.read(syncNotifierProvider.notifier).pushAllOrders(),
              icon: syncState.pushingIds.isNotEmpty
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2,
                          color: Colors.black),
                    )
                  : const Icon(Icons.cloud_upload_outlined, size: 18),
              label: Text('Push All (${offline.length})'),
              style: TextButton.styleFrom(foregroundColor: Colors.black),
            ),
          IconButton(
            icon: const Icon(Icons.bug_report_outlined),
            tooltip: 'Error Logs',
            onPressed: () => context.push('/logs'),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error:   (e, _) => Center(child: Text('Error: $e')),
        data:    (orders) {
          if (orders.isEmpty && offline.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: EmptyState(
                  message: 'No orders yet',
                  icon: Icons.receipt_long_outlined,
                ),
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              // ── Pending offline orders ──────────────────────────────────
              if (hasPending) ...[
                _SectionHeader(
                  label: 'Pending Upload  •  ${offline.length}',
                  color: Colors.orange.shade700,
                ),
                const SizedBox(height: 6),
                ...offline.map((o) => _OfflineOrderCard(
                      order:      o,
                      syncState:  syncState,
                      onPush:     () => ref
                          .read(syncNotifierProvider.notifier)
                          .pushOrder(o['id'] as String, o['payload'] as Map),
                    )),
                const SizedBox(height: 16),
              ],

              // ── Server orders ───────────────────────────────────────────
              if (orders.isNotEmpty) ...[
                if (hasPending)
                  const _SectionHeader(label: 'Submitted Orders', color: Colors.black54),
                if (hasPending) const SizedBox(height: 6),
                ...List.generate(orders.length, (i) {
                  final o          = orders[i];
                  final status     = o['status'] as String? ?? '';
                  final isDraft    = status == 'DRAFT';
                  final canInvoice = status == 'APPROVED' || status == 'INVOICED';
                  final orderId    = o['id'] as String;
                  final orderNum   = o['orderNumber'] as String? ?? orderId;

                  final card = _ServerOrderCard(
                    order:      o,
                    status:     status,
                    canInvoice: canInvoice,
                    onTap: () => context.push('/orders/$orderId'),
                  );

                  if (!isDraft) return card;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Dismissible(
                      key: Key(orderId),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        decoration: BoxDecoration(
                          color: Colors.red.shade600,
                          borderRadius: BorderRadius.circular(AppRadius.lg),
                        ),
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.delete_outline_rounded,
                                color: Colors.white, size: 26),
                            SizedBox(height: 4),
                            Text('Delete',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                      confirmDismiss: (_) => _confirmDelete(context, orderNum),
                      onDismissed:    (_) =>
                          _deleteDraftOrder(context, ref, orderId),
                      child: card,
                    ),
                  );
                }),
              ],
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/orders/new'),
        backgroundColor: AppColors.ink,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill)),
        label: const Text('New Order'),
        icon: const Icon(Icons.add),
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final Color color;
  const _SectionHeader({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 2),
        child: Text(label,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: color,
                letterSpacing: .4)),
      );
}

class _ServerOrderCard extends StatelessWidget {
  final Map<String, dynamic> order;
  final String status;
  final bool canInvoice;
  final VoidCallback? onTap;
  const _ServerOrderCard({
    required this.order,
    required this.status,
    required this.canInvoice,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final orderNum     = order['orderNumber'] as String? ?? order['id'] as String;
    final invoiceNum   = order['invoiceNumber'] as String?;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: AppCard(
        padding: EdgeInsets.zero,
        onTap: onTap,
        child: ListTile(
          onTap: onTap,
          title: Text(orderNum,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text((order['customer'] as Map?)?['name'] as String? ?? ''),
              if (invoiceNum != null && invoiceNum.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('Inv# $invoiceNum',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade600)),
                ),
            ],
          ),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(
              'LKR ${formatAmount((order['total'] as num?) ?? 0)}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            StatusBadge(label: status, tone: _statusTones[status] ?? AppTone.neutral),
            if (canInvoice) ...[
              const SizedBox(width: 6),
              const Icon(Icons.print_outlined, size: 18, color: Colors.teal),
            ],
          ]),
        ),
      ),
    );
  }
}

class _OfflineOrderCard extends StatelessWidget {
  final Map order;
  final SyncState syncState;
  final VoidCallback onPush;
  const _OfflineOrderCard({
    required this.order,
    required this.syncState,
    required this.onPush,
  });

  @override
  Widget build(BuildContext context) {
    final localId    = order['id'] as String;
    final isPushing  = syncState.pushingIds.contains(localId);
    final hasFailed  = syncState.failedIds.contains(localId);
    final errMsg     = syncState.failedErrors[localId];
    final ts         = DateTime.tryParse(order['timestamp'] as String? ?? '');
    final dateStr    = ts != null
        ? '${ts.day}/${ts.month}/${ts.year}  ${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}'
        : '—';

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: AppCard(
        tone: hasFailed ? AppTone.pink : AppTone.orange,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(
                  hasFailed
                      ? Icons.error_outline_rounded
                      : Icons.cloud_off_rounded,
                  size: 16,
                  color: hasFailed ? Colors.red : Colors.orange.shade700,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    order['customerName'] as String? ?? '—',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                ),
                if (isPushing)
                  const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else
                  GestureDetector(
                    onTap: onPush,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(50),
                      ),
                      child: Text(
                        hasFailed ? 'Retry' : 'Push',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
              ]),
              const SizedBox(height: 4),
              Row(children: [
                Text(
                  'LKR ${formatAmount((order['grandTotal'] as num?) ?? 0)}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(width: 10),
                Text(
                  '${order['itemCount'] ?? 0} item(s)',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const Spacer(),
                Text(dateStr,
                    style: const TextStyle(color: Colors.grey, fontSize: 11)),
              ]),
              if (hasFailed && errMsg != null) ...[
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    errMsg,
                    style: TextStyle(
                        fontSize: 11, color: Colors.red.shade800),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
      ),
    );
  }
}

// ── Filter sheet ──────────────────────────────────────────────────────────────

class _OrderFilterSheet extends StatefulWidget {
  final OrderListFilters initial;
  const _OrderFilterSheet({required this.initial});

  @override
  State<_OrderFilterSheet> createState() => _OrderFilterSheetState();
}

class _OrderFilterSheetState extends State<_OrderFilterSheet> {
  late final TextEditingController _orderNoCtrl;
  late final TextEditingController _invoiceNoCtrl;
  DateTime? _dateFrom;
  DateTime? _dateTo;

  static final _displayFmt = DateFormat('dd MMM yyyy');

  @override
  void initState() {
    super.initState();
    _orderNoCtrl   = TextEditingController(text: widget.initial.orderNo);
    _invoiceNoCtrl = TextEditingController(text: widget.initial.invoiceNo);
    _dateFrom = widget.initial.dateFrom;
    _dateTo   = widget.initial.dateTo;
  }

  @override
  void dispose() {
    _orderNoCtrl.dispose();
    _invoiceNoCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: now,
      initialDateRange: _dateFrom != null && _dateTo != null
          ? DateTimeRange(start: _dateFrom!, end: _dateTo!)
          : null,
    );
    if (picked != null) {
      setState(() {
        _dateFrom = picked.start;
        _dateTo   = picked.end;
      });
    }
  }

  void _apply() {
    Navigator.pop(
      context,
      OrderListFilters(
        orderNo:   _orderNoCtrl.text.trim(),
        invoiceNo: _invoiceNoCtrl.text.trim(),
        dateFrom:  _dateFrom,
        dateTo:    _dateTo,
      ),
    );
  }

  void _clear() {
    Navigator.pop(context, const OrderListFilters());
  }

  @override
  Widget build(BuildContext context) {
    final hasDateRange = _dateFrom != null && _dateTo != null;
    return Padding(
      padding: EdgeInsets.only(
        left: 16, right: 16, top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Filter Orders', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            TextField(
              controller: _orderNoCtrl,
              decoration: const InputDecoration(
                labelText: 'Order Number',
                prefixIcon: Icon(Icons.receipt_long_outlined, size: 18),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _invoiceNoCtrl,
              decoration: const InputDecoration(
                labelText: 'Invoice Number',
                prefixIcon: Icon(Icons.description_outlined, size: 18),
              ),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _pickDateRange,
              borderRadius: BorderRadius.circular(8),
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Order Date',
                  prefixIcon: Icon(Icons.date_range_outlined, size: 18),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        hasDateRange
                            ? '${_displayFmt.format(_dateFrom!)}  -  ${_displayFmt.format(_dateTo!)}'
                            : 'All dates',
                        style: TextStyle(
                            color: hasDateRange ? null : Colors.grey.shade600),
                      ),
                    ),
                    if (hasDateRange)
                      GestureDetector(
                        onTap: () => setState(() {
                          _dateFrom = null;
                          _dateTo   = null;
                        }),
                        child: const Icon(Icons.close, size: 16),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _clear,
                    child: const Text('Clear'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: _apply,
                    child: const Text('Apply Filters'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

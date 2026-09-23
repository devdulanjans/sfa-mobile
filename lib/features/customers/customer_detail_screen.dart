import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import '../../app/colors.dart';
import '../../app/radii.dart';
import '../../core/bluetooth/thermal_print_flow.dart';
import '../../core/storage/local_db.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/section_header.dart';
import '../../shared/widgets/stat_tile.dart';
import '../../shared/widgets/status_badge.dart';
import '../../utils/formatters.dart';
import '../damages/damage_print_preview_screen.dart';
import '../orders/order_provider.dart';
import '../returns/return_print_preview_screen.dart';
import 'customer_analytics_provider.dart';

const _orderStatusTones = {
  'DRAFT':     AppTone.neutral,
  'SUBMITTED': AppTone.orange,
  'APPROVED':  AppTone.mint,
  'INVOICED':  AppTone.violet,
  'CANCELLED': AppTone.pink,
};

const _returnStatusTones = {
  'APPROVED':  AppTone.mint,
  'REJECTED':  AppTone.pink,
  'PROCESSED': AppTone.sky,
  // PENDING falls through to the default below.
};

class CustomerDetailScreen extends ConsumerStatefulWidget {
  final String id;
  const CustomerDetailScreen({super.key, required this.id});

  @override
  ConsumerState<CustomerDetailScreen> createState() => _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends ConsumerState<CustomerDetailScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final customer = LocalDb.customers.where((c) => c['id'] == widget.id).firstOrNull;
    if (customer == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Customer')),
        body: const Center(child: Text('Customer not found')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(customer['name'] as String? ?? '',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          Text(customer['code'] as String? ?? '',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.assignment_return_outlined),
            tooltip: 'New Return',
            onPressed: () => context.push('/returns/new',
                extra: {'id': widget.id, 'name': customer['name'] as String? ?? ''}),
          ),
          IconButton(
            icon: const Icon(Icons.report_problem_outlined),
            tooltip: 'Record Damage',
            onPressed: () => context.push('/damages/new',
                extra: {'id': widget.id, 'name': customer['name'] as String? ?? ''}),
          ),
          IconButton(
            icon: const Icon(Icons.add_shopping_cart_outlined),
            tooltip: 'New Order',
            onPressed: () {
              ref.read(orderCreationProvider.notifier)
                  .startOrder(widget.id, customer['name'] as String? ?? '');
              context.push('/orders/new');
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: Colors.green.shade700,
          unselectedLabelColor: Colors.green.shade200,
          indicatorColor: Colors.green.shade700,
          tabs: const [
            Tab(icon: Icon(Icons.person_outline, size: 18), text: 'Overview'),
            Tab(icon: Icon(Icons.receipt_long_outlined, size: 18), text: 'Orders'),
            Tab(icon: Icon(Icons.assignment_return_outlined, size: 18), text: 'Returns'),
            Tab(icon: Icon(Icons.report_problem_outlined, size: 18), text: 'Damages'),
            Tab(icon: Icon(Icons.bar_chart_outlined, size: 18), text: 'Analytics'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _OverviewTab(customer: customer, customerId: widget.id),
          _OrdersTab(
            customerId: widget.id,
            customerName: customer['name'] as String? ?? '',
          ),
          _ReturnsTab(customerId: widget.id),
          _DamagesTab(customerId: widget.id),
          _AnalyticsTab(customerId: widget.id),
        ],
      ),
    );
  }
}

// ─── Overview Tab ─────────────────────────────────────────────────────────────

class _OverviewTab extends ConsumerWidget {
  final Map customer;
  final String customerId;
  const _OverviewTab({required this.customer, required this.customerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final creditLimit    = (customer['creditLimit'] as num?)?.toDouble() ?? 0;
    final creditDays     = (customer['creditDays'] as num?)?.toInt();
    final currentBalance = (customer['currentBalance'] as num?)?.toDouble() ?? 0;
    final utilization    = creditLimit > 0 ? (currentBalance / creditLimit).clamp(0.0, 1.0) : 0.0;
    final category       = (customer['category'] as Map?)?['name'] as String? ?? '—';
    final status         = customer['status'] as String? ?? 'ACTIVE';
    final isActive       = status == 'ACTIVE';

    final utilizationColor = utilization > 0.9
        ? AppColors.pinkFg
        : utilization > 0.7
            ? AppColors.orangeFg
            : AppColors.mintFg;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Status badge
        Row(children: [
          StatusBadge(label: status, tone: isActive ? AppTone.mint : AppTone.pink),
          const Spacer(),
          Text(customer['taxType'] as String? ?? '',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
        const SizedBox(height: 16),

        // Create Order button
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () {
              ref.read(orderCreationProvider.notifier)
                  .startOrder(customerId, customer['name'] as String? ?? '');
              context.push('/orders/new');
            },
            icon: const Icon(Icons.add_shopping_cart_outlined),
            label: const Text('Create Order'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.ink,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md)),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Info card
        _SectionCard(
          title: 'Contact Details',
          icon: Icons.badge_outlined,
          tone: AppTone.violet,
          child: Column(children: [
            ..._buildAddressRows(customer),
            _InfoRow(Icons.phone_outlined,
                customer['phone'] as String? ?? '—'),
            _InfoRow(Icons.email_outlined,
                customer['email'] as String? ?? '—'),
            _InfoRow(Icons.location_city_outlined,
                'Location: ${customer['location'] ?? '—'}'),
            _InfoRow(Icons.store_outlined,
                'Place of Supplier: ${customer['placeOfSupplier'] ?? '—'}'),
            _InfoRow(Icons.person_outline,
                'Contact: ${customer['contactPerson'] ?? '—'}'),
            _InfoRow(Icons.category_outlined, 'Category: $category'),
            _InfoRow(Icons.receipt_outlined,
                'Tax No: ${customer['taxNumber'] ?? '—'}'),
          ]),
        ),
        const SizedBox(height: 16),

        // Credit card
        _SectionCard(
          title: 'Credit & Balance',
          icon: Icons.account_balance_wallet_outlined,
          tone: AppTone.sky,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              _CreditStat('Credit Limit', 'LKR ${formatAmount(creditLimit)}'),
              if (creditDays != null)
                _CreditStat('Credit Days', '$creditDays days',
                    align: CrossAxisAlignment.center),
              _CreditStat('Balance Used', 'LKR ${formatAmount(currentBalance)}',
                  align: CrossAxisAlignment.end),
            ]),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: utilization,
                minHeight: 10,
                backgroundColor: Colors.grey.shade100,
                valueColor: AlwaysStoppedAnimation(utilizationColor),
              ),
            ),
            const SizedBox(height: 4),
            Text('${(utilization * 100).toStringAsFixed(0)}% of credit limit used',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ]),
        ),
      ],
    );
  }

  List<Widget> _buildAddressRows(Map customer) {
    final addresses = customer['addresses'] as List?;
    if (addresses == null || addresses.isEmpty) {
      return [const _InfoRow(Icons.location_on_outlined, '—')];
    }
    return addresses.map<Widget>((a) {
      final label = a['label'] as String? ?? '';
      final line = a['addressLine'] as String? ?? '';
      return _InfoRow(Icons.location_on_outlined, '$label: $line');
    }).toList();
  }
}

class _CreditStat extends StatelessWidget {
  final String label;
  final String value;
  final CrossAxisAlignment align;
  const _CreditStat(this.label, this.value,
      {this.align = CrossAxisAlignment.start});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: align,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 15)),
        ],
      );
}

// ─── Orders Tab ───────────────────────────────────────────────────────────────

class _OrdersTab extends ConsumerWidget {
  final String customerId;
  final String customerName;
  const _OrdersTab({required this.customerId, required this.customerName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(customerOrdersProvider(customerId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_outlined, size: 48, color: Colors.grey),
          const SizedBox(height: 8),
          const Text('Could not load orders',
              style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => ref.invalidate(customerOrdersProvider(customerId)),
            child: const Text('Retry'),
          ),
        ]),
      ),
      data: (orders) {
        if (orders.isEmpty) {
          return const Center(
            child: EmptyState(
                message: 'No orders yet', icon: Icons.receipt_long_outlined));
        }
        return RefreshIndicator(
          onRefresh: () async =>
              ref.invalidate(customerOrdersProvider(customerId)),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: orders.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) => _OrderCard(
              order: orders[i],
              customerId: customerId,
              customerName: customerName,
            ),
          ),
        );
      },
    );
  }
}

class _OrderCard extends ConsumerWidget {
  final Map<String, dynamic> order;
  final String customerId;
  final String customerName;
  const _OrderCard(
      {required this.order,
      required this.customerId,
      required this.customerName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status      = order['status'] as String? ?? '';
    final orderNumber = order['orderNumber'] as String? ?? '';
    final total       = (order['total'] as num?)?.toDouble() ?? 0;
    final dateRaw     = order['orderDate'] as String? ?? '';
    final itemCount   = (order['items'] as List?)?.length ?? 0;
    final canReorder  = ['SUBMITTED', 'APPROVED', 'INVOICED'].contains(status);

    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(orderNumber,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 15)),
          ),
          StatusBadge(label: status, tone: _orderStatusTones[status] ?? AppTone.neutral),
        ]),
        const SizedBox(height: 4),
        Text(_fmtDate(dateRaw),
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        if (itemCount > 0)
          Text('$itemCount item${itemCount == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('LKR ${formatAmount(total)}',
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w700)),
          if (canReorder)
            OutlinedButton.icon(
              onPressed: () => _confirmReorder(context, ref),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Reorder', style: TextStyle(fontSize: 13)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                visualDensity: VisualDensity.compact,
              ),
            ),
        ]),
      ]),
    );
  }

  Future<void> _confirmReorder(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reorder'),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Recreate order ${order['orderNumber']} for $customerName?'),
              const SizedBox(height: 8),
              const Text(
                  'Prices and promotions will be recalculated at current rates.',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reorder')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await ref
          .read(orderCreationProvider.notifier)
          .reorderFromOrder(order['id'] as String);
      if (context.mounted) context.push('/orders/new');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load order: $e')));
      }
    }
  }

  String _fmtDate(String iso) {
    if (iso.length < 10) return iso;
    const m = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final p = iso.split('T')[0].split('-');
    if (p.length < 3) return iso;
    return '${p[2]} ${m[int.tryParse(p[1]) ?? 0]} ${p[0]}';
  }
}

// ─── Returns Tab ──────────────────────────────────────────────────────────────

class _ReturnsTab extends ConsumerWidget {
  final String customerId;
  const _ReturnsTab({required this.customerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(customerReturnsProvider(customerId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_outlined, size: 48, color: Colors.grey),
          const SizedBox(height: 8),
          const Text('Could not load returns',
              style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => ref.invalidate(customerReturnsProvider(customerId)),
            child: const Text('Retry'),
          ),
        ]),
      ),
      data: (returns) {
        if (returns.isEmpty) {
          return const Center(
            child: EmptyState(
                message: 'No returns yet', icon: Icons.assignment_return_outlined));
        }
        return RefreshIndicator(
          onRefresh: () async =>
              ref.invalidate(customerReturnsProvider(customerId)),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: returns.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) => _ReturnCard(ret: returns[i]),
          ),
        );
      },
    );
  }
}

class _ReturnCard extends ConsumerStatefulWidget {
  final Map<String, dynamic> ret;
  const _ReturnCard({required this.ret});

  @override
  ConsumerState<_ReturnCard> createState() => _ReturnCardState();
}

class _ReturnCardState extends ConsumerState<_ReturnCard> {
  BluetoothInfo? _printer;
  bool _printing = false;

  Map<String, dynamic> get ret => widget.ret;

  // Mirrors ReturnFormScreen's post-submit print flow (see
  // _printOrPreview/_openPrintPreview/_printNote there) so a return note can
  // be reprinted later from the customer's Returns tab the same way it's
  // printed right after the return is placed.
  Future<void> _reprint(String id, String returnNumber) async {
    setState(() => _printing = true);
    try {
      final previewEnabled = LocalDb.getSystemSettingBool(
          'invoice_print_preview_enabled', defaultValue: false);
      if (previewEnabled) {
        await Navigator.push(context, MaterialPageRoute(
          builder: (_) => ReturnPrintPreviewScreen(
            returnId: id,
            returnNumber: returnNumber,
            onPrint: () async {
              await _print(id);
              if (mounted) Navigator.pop(context);
            },
          ),
        ));
      } else {
        await _print(id);
      }
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  Future<void> _print(String id) async {
    final printer = await printThermalReceipt(
      context: context,
      ref: ref,
      path: '/returns/$id/thermal',
      printer: _printer,
    );
    if (printer != null) _printer = printer;
  }

  @override
  Widget build(BuildContext context) {
    final status       = ret['status'] as String? ?? '';
    final returnId     = ret['id'] as String?;
    final returnNumber = ret['returnNumber'] as String? ?? '';
    final orderNumber  = (ret['order'] as Map?)?['orderNumber'] as String?;
    final reason       = ret['reason'] as String? ?? '';
    final items        = (ret['items'] as List? ?? []).cast<Map>();
    final dateRaw      = ret['createdAt'] as String? ?? '';

    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(returnNumber,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 15)),
          ),
          StatusBadge(label: status, tone: _returnStatusTones[status] ?? AppTone.orange),
        ]),
        const SizedBox(height: 4),
        Text(
          orderNumber != null
              ? '${_fmtDate(dateRaw)}  ·  Order $orderNumber'
              : _fmtDate(dateRaw),
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 10),
        ...items.map((it) {
          final product = it['product'] as Map?;
          final qty = it['quantity'];
          return Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(children: [
              const Icon(Icons.inventory_2_outlined, size: 14, color: Colors.grey),
              const SizedBox(width: 6),
              Expanded(
                child: Text(product?['name'] as String? ?? '—',
                    style: const TextStyle(fontSize: 13)),
              ),
              Text('× ${qty ?? '—'}',
                  style: const TextStyle(fontSize: 13, color: Colors.grey)),
            ]),
          );
        }),
        if (reason.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Reason: $reason',
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ],
        if (returnId != null) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: _printing ? null : () => _reprint(returnId, returnNumber),
              icon: _printing
                  ? const SizedBox(height: 14, width: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.print_outlined, size: 16),
              label: Text(_printing ? 'Printing…' : 'Reprint',
                  style: const TextStyle(fontSize: 13)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ]),
    );
  }

  String _fmtDate(String iso) {
    if (iso.length < 10) return iso;
    const m = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final p = iso.split('T')[0].split('-');
    if (p.length < 3) return iso;
    return '${p[2]} ${m[int.tryParse(p[1]) ?? 0]} ${p[0]}';
  }
}

// ─── Damages Tab ──────────────────────────────────────────────────────────────

class _DamagesTab extends ConsumerWidget {
  final String customerId;
  const _DamagesTab({required this.customerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(customerDamagesProvider(customerId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_outlined, size: 48, color: Colors.grey),
          const SizedBox(height: 8),
          const Text('Could not load damages',
              style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => ref.invalidate(customerDamagesProvider(customerId)),
            child: const Text('Retry'),
          ),
        ]),
      ),
      data: (damages) {
        if (damages.isEmpty) {
          return const Center(
            child: EmptyState(
                message: 'No damages recorded', icon: Icons.report_problem_outlined));
        }
        return RefreshIndicator(
          onRefresh: () async =>
              ref.invalidate(customerDamagesProvider(customerId)),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: damages.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) => _DamageCard(damage: damages[i]),
          ),
        );
      },
    );
  }
}

class _DamageCard extends ConsumerStatefulWidget {
  final Map<String, dynamic> damage;
  const _DamageCard({required this.damage});

  @override
  ConsumerState<_DamageCard> createState() => _DamageCardState();
}

class _DamageCardState extends ConsumerState<_DamageCard> {
  BluetoothInfo? _printer;
  bool _printing = false;

  Map<String, dynamic> get damage => widget.damage;

  // Mirrors DamageFormScreen's post-submit print flow (see
  // _printOrPreview/_openPrintPreview/_printNote there) so a damage note can
  // be reprinted later from the customer's Damages tab the same way it's
  // printed right after the damage is recorded.
  Future<void> _reprint(String id, String damageNumber) async {
    setState(() => _printing = true);
    try {
      final previewEnabled = LocalDb.getSystemSettingBool(
          'invoice_print_preview_enabled', defaultValue: false);
      if (previewEnabled) {
        await Navigator.push(context, MaterialPageRoute(
          builder: (_) => DamagePrintPreviewScreen(
            damageId: id,
            damageNumber: damageNumber,
            onPrint: () async {
              await _print(id);
              if (mounted) Navigator.pop(context);
            },
          ),
        ));
      } else {
        await _print(id);
      }
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  Future<void> _print(String id) async {
    final printer = await printThermalReceipt(
      context: context,
      ref: ref,
      path: '/damages/$id/thermal',
      printer: _printer,
    );
    if (printer != null) _printer = printer;
  }

  @override
  Widget build(BuildContext context) {
    final status       = damage['status'] as String? ?? '';
    final damageId     = damage['id'] as String?;
    final damageNumber = damage['damageNumber'] as String? ?? '';
    final description  = damage['description'] as String? ?? '';
    final items        = (damage['items'] as List? ?? []).cast<Map>();
    final dateRaw       = damage['damageDate'] as String? ?? '';

    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(damageNumber,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 15)),
          ),
          StatusBadge(label: status, tone: _returnStatusTones[status] ?? AppTone.orange),
        ]),
        const SizedBox(height: 4),
        Text(_fmtDate(dateRaw),
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 10),
        ...items.map((it) {
          final product = it['product'] as Map?;
          final qty = it['quantity'];
          return Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(children: [
              const Icon(Icons.inventory_2_outlined, size: 14, color: Colors.grey),
              const SizedBox(width: 6),
              Expanded(
                child: Text(product?['name'] as String? ?? '—',
                    style: const TextStyle(fontSize: 13)),
              ),
              Text('× ${qty ?? '—'}',
                  style: const TextStyle(fontSize: 13, color: Colors.grey)),
            ]),
          );
        }),
        if (description.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Description: $description',
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ],
        if (damageId != null) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: _printing ? null : () => _reprint(damageId, damageNumber),
              icon: _printing
                  ? const SizedBox(height: 14, width: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.print_outlined, size: 16),
              label: Text(_printing ? 'Printing…' : 'Reprint',
                  style: const TextStyle(fontSize: 13)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ]),
    );
  }

  String _fmtDate(String iso) {
    if (iso.length < 10) return iso;
    const m = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final p = iso.split('T')[0].split('-');
    if (p.length < 3) return iso;
    return '${p[2]} ${m[int.tryParse(p[1]) ?? 0]} ${p[0]}';
  }
}

// ─── Analytics Tab ────────────────────────────────────────────────────────────

class _AnalyticsTab extends ConsumerWidget {
  final String customerId;
  const _AnalyticsTab({required this.customerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(customerAnalyticsProvider(customerId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_outlined, size: 48, color: Colors.grey),
          const SizedBox(height: 8),
          const Text('Could not load analytics',
              style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => ref.invalidate(customerAnalyticsProvider(customerId)),
            child: const Text('Retry'),
          ),
        ]),
      ),
      data: (data) {
        final trend    = (data['monthlyTrend'] as List? ?? []).cast<Map<String, dynamic>>();
        final products = (data['topProducts']  as List? ?? []).cast<Map<String, dynamic>>();
        final breakdown = (data['statusBreakdown'] as Map? ?? {}).cast<String, dynamic>();

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Summary row
            _SummaryRow(
              totalOrders:  (data['totalOrders']  as num? ?? 0).toInt(),
              totalRevenue: (data['totalRevenue'] as num? ?? 0).toDouble(),
              avgOrder:     (data['avgOrderValue'] as num? ?? 0).toDouble(),
              lastOrderDate: data['lastOrderDate'] as String?,
            ),
            const SizedBox(height: 16),

            // Order status breakdown
            _SectionCard(
              title: 'Order Breakdown',
              icon: Icons.donut_large_outlined,
              tone: AppTone.orange,
              child: _StatusBreakdown(breakdown: breakdown),
            ),
            const SizedBox(height: 16),

            // Monthly revenue trend
            _SectionCard(
              title: 'Monthly Revenue',
              subtitle: 'Last 6 months',
              icon: Icons.show_chart_rounded,
              tone: AppTone.mint,
              child: trend.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: EmptyState(
                          message: 'No data yet', icon: Icons.show_chart_rounded))
                  : _MonthlyBars(trend: trend),
            ),
            const SizedBox(height: 16),

            // Top products
            _SectionCard(
              title: 'Top Products',
              subtitle: 'Last 3 months · by quantity',
              icon: Icons.emoji_events_outlined,
              tone: AppTone.violet,
              child: products.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: EmptyState(
                          message: 'No product data', icon: Icons.inventory_2_outlined))
                  : _TopProducts(products: products),
            ),
          ],
        );
      },
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final int totalOrders;
  final double totalRevenue;
  final double avgOrder;
  final String? lastOrderDate;
  const _SummaryRow(
      {required this.totalOrders,
      required this.totalRevenue,
      required this.avgOrder,
      required this.lastOrderDate});

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(child: StatTile(
            icon: Icons.shopping_bag_outlined,
            label: 'Orders',
            value: '$totalOrders',
            tone: AppTone.violet)),
        const SizedBox(width: 8),
        Expanded(child: StatTile(
            icon: Icons.payments_outlined,
            label: 'Revenue',
            value: 'LKR ${formatAmount(totalRevenue)}',
            tone: AppTone.mint)),
        const SizedBox(width: 8),
        Expanded(child: StatTile(
            icon: Icons.analytics_outlined,
            label: 'Avg Order',
            value: 'LKR ${formatAmount(avgOrder)}',
            tone: AppTone.sky)),
      ]);
}

class _StatusBreakdown extends StatelessWidget {
  final Map<String, dynamic> breakdown;
  const _StatusBreakdown({required this.breakdown});

  @override
  Widget build(BuildContext context) {
    if (breakdown.isEmpty) {
      return const Text('No orders', style: TextStyle(color: Colors.grey));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: breakdown.entries.map((e) {
        final tone  = _orderStatusTones[e.key] ?? AppTone.neutral;
        final count = (e.value as num? ?? 0).toInt();
        return StatusBadge(label: '${e.key}  $count', tone: tone);
      }).toList(),
    );
  }
}

class _MonthlyBars extends StatelessWidget {
  final List<Map<String, dynamic>> trend;
  const _MonthlyBars({required this.trend});

  @override
  Widget build(BuildContext context) {
    final maxRev = trend.fold<double>(
        0, (m, r) => ((r['revenue'] as num?)?.toDouble() ?? 0) > m
            ? (r['revenue'] as num).toDouble()
            : m);

    return Column(
      children: trend.map((m) {
        final rev      = (m['revenue'] as num? ?? 0).toDouble();
        final month    = m['month'] as String? ?? '';
        final count    = (m['orderCount'] as num? ?? 0).toInt();
        final fraction = maxRev > 0 ? rev / maxRev : 0.0;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            SizedBox(
                width: 52,
                child: Text(_fmtMonth(month),
                    style: const TextStyle(fontSize: 11))),
            const SizedBox(width: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (ctx, c) => Stack(children: [
                  Container(
                      height: 22,
                      decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(4))),
                  Container(
                      height: 22,
                      width: c.maxWidth * fraction,
                      decoration: BoxDecoration(
                          color: AppColors.violetFg.withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(4))),
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '$count order${count == 1 ? '' : 's'}',
                          style: TextStyle(
                            fontSize: 10,
                            color: fraction > 0.3
                                ? Colors.white
                                : Colors.grey.shade600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 72,
              child: Text('LKR ${formatAmount(rev)}',
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w500),
                  textAlign: TextAlign.right),
            ),
          ]),
        );
      }).toList(),
    );
  }

  String _fmtMonth(String ym) {
    if (ym.length < 7) return ym;
    const m = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final p = ym.split('-');
    return '${m[int.tryParse(p[1]) ?? 0]}\n${p[0]}';
  }
}

class _TopProducts extends StatelessWidget {
  final List<Map<String, dynamic>> products;
  const _TopProducts({required this.products});

  @override
  Widget build(BuildContext context) {
    final maxQty = products.fold<double>(
        0, (m, p) => ((p['totalQty'] as num?)?.toDouble() ?? 0) > m
            ? (p['totalQty'] as num).toDouble()
            : m);

    return Column(
      children: products.asMap().entries.map((entry) {
        final i   = entry.key;
        final p   = entry.value;
        final qty = (p['totalQty']     as num? ?? 0).toDouble();
        final rev = (p['totalRevenue'] as num? ?? 0).toDouble();
        final fraction = maxQty > 0 ? qty / maxQty : 0.0;

        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (i > 0) const Divider(height: 16),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 24, height: 24,
              decoration: BoxDecoration(
                  color: AppColors.violetFg.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.sm)),
              alignment: Alignment.center,
              child: Text('${i + 1}',
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.violetFg)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(p['productName'] as String? ?? '',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                Text(
                    '${p['productCode'] ?? ''}  ·  ${p['unit'] ?? ''}',
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey)),
              ]),
            ),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${qty.toStringAsFixed(0)} units',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              Text('LKR ${formatAmount(rev)}',
                  style: const TextStyle(
                      fontSize: 11, color: Colors.grey)),
            ]),
          ]),
          const SizedBox(height: 6),
          LayoutBuilder(
            builder: (ctx, c) => Stack(children: [
              Container(
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(2))),
              Container(
                  height: 4,
                  width: c.maxWidth * fraction,
                  decoration: BoxDecoration(
                      color: AppColors.violetFg.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(2))),
            ]),
          ),
        ]);
      }).toList(),
    );
  }
}

// ─── Shared helpers ───────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final AppTone tone;
  final Widget child;
  const _SectionCard({
    required this.title,
    required this.child,
    this.subtitle,
    this.icon,
    this.tone = AppTone.violet,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(title: title, icon: icon, tone: tone),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Text(subtitle!,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          ],
          const SizedBox(height: 10),
          AppCard(child: child),
        ],
      );
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoRow(this.icon, this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: Colors.grey),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ]),
      );
}

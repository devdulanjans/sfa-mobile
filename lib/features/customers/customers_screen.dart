import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/colors.dart';
import '../../app/radii.dart';
import '../../core/storage/local_db.dart';
import '../../core/storage/sync_service.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/status_badge.dart';

class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});
  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  String _query = '';
  bool _syncing = false;

  List<Map> get _filtered {
    final q = _query.toLowerCase();
    return LocalDb.customers.where((c) =>
      c['deletedAt'] == null && (
        q.isEmpty ||
        (c['name'] as String? ?? '').toLowerCase().contains(q) ||
        (c['code'] as String? ?? '').toLowerCase().contains(q) ||
        (c['placeOfSupplier'] as String? ?? '').toLowerCase().contains(q)
      )
    ).toList();
  }

  Future<void> _refresh() async {
    setState(() => _syncing = true);
    await ref.read(syncServiceProvider).sync();
    if (mounted) setState(() => _syncing = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Customers'),
        actions: [
          if (_syncing)
            const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2)))
          else
            IconButton(icon: const Icon(Icons.sync), onPressed: _refresh, tooltip: 'Sync'),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search customers...',
                prefixIcon: Icon(Icons.search, size: 18),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: _filtered.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: EmptyState(
                        message: 'No customers found',
                        icon: Icons.people_outline,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (context, i) {
                      final c = _filtered[i];
                      return _CustomerTile(customer: c,
                          onTap: () => context.push('/customers/${c['id']}'));
                    },
                  ),
          ),
        ],
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

class _CustomerTile extends StatelessWidget {
  final Map customer;
  final VoidCallback onTap;
  const _CustomerTile({required this.customer, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final status = customer['status'] as String? ?? 'ACTIVE';
    final placeOfSupplier = customer['placeOfSupplier'] as String?;
    return AppCard(
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: AppColors.violetBg,
          child: Text(
            (customer['name'] as String? ?? '?')[0].toUpperCase(),
            style: const TextStyle(color: AppColors.violetFg, fontWeight: FontWeight.w800),
          ),
        ),
        title: Text(customer['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
                [customer['phone'], customer['location']]
                    .where((v) => v != null && (v as String).isNotEmpty)
                    .join(' · '),
                style: const TextStyle(fontSize: 12)),
            if (placeOfSupplier != null && placeOfSupplier.isNotEmpty) ...[
              const SizedBox(height: 4),
              StatusBadge(label: placeOfSupplier, tone: AppTone.orange),
            ],
          ],
        ),
        trailing: StatusBadge(
          label: status,
          tone: status == 'ACTIVE' ? AppTone.mint : AppTone.sky,
        ),
      ),
    );
  }
}

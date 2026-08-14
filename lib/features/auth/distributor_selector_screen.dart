import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/colors.dart';
import '../../app/radii.dart';
import '../../shared/widgets/app_card.dart';
import 'auth_provider.dart';
import '../orders/order_provider.dart';

/// Shown after login when a user belongs to multiple distributors.
/// Also accessible from the dashboard via the distributor switcher.
class DistributorSelectorScreen extends ConsumerWidget {
  final bool isSwitch;
  const DistributorSelectorScreen({super.key, this.isSwitch = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authAsync = ref.watch(authNotifierProvider);

    return authAsync.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error:   (e, _) => Scaffold(body: Center(child: Text('Error: $e'))),
      data:    (user) {
        if (user == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => context.go('/login'));
          return const SizedBox.shrink();
        }
        return _DistributorList(user: user, isSwitch: isSwitch);
      },
    );
  }
}

class _DistributorList extends ConsumerWidget {
  final AuthUser user;
  final bool isSwitch;
  const _DistributorList({required this.user, required this.isSwitch});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: Text(isSwitch ? 'Switch Distributor' : 'Select Distributor'),
        automaticallyImplyLeading: isSwitch,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            color: AppColors.violetBg,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Welcome, ${user.fullName.isEmpty ? user.username : user.fullName}',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text('Choose a distributor to work with',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            ]),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: user.distributors.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final dist     = user.distributors[i];
                final isActive = dist.id == user.activeDistributorId;
                return _DistributorTile(
                  dist:     dist,
                  isActive: isActive,
                  onTap:    () async {
                    ref.read(orderCreationProvider.notifier).clearOrder();
                    await ref.read(authNotifierProvider.notifier).switchDistributor(dist.id);
                    if (context.mounted) context.go('/dashboard');
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DistributorTile extends StatelessWidget {
  final DistributorInfo dist;
  final bool isActive;
  final VoidCallback onTap;
  const _DistributorTile({required this.dist, required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      tone: isActive ? AppTone.violet : AppTone.neutral,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      onTap: onTap,
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: isActive ? AppColors.violetFg : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(Icons.storefront_outlined,
              color: isActive ? Colors.white : Colors.grey.shade600, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(dist.name,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: isActive ? AppColors.violetFg : null,
                )),
            const SizedBox(height: 2),
            Text(dist.code,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500, fontFamily: 'monospace')),
          ]),
        ),
        if (isActive)
          const Icon(Icons.check_circle_rounded, color: AppColors.violetFg, size: 22),
      ]),
    );
  }
}

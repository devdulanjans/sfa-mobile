import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/colors.dart';
import '../../app/radii.dart';
import '../../shared/widgets/app_card.dart';
import 'auth_provider.dart';

/// Shown after login when a user belongs to multiple channels and hasn't
/// picked one yet — the backend refuses tenant-scoped reads (customers,
/// products) until a channel is selected. Also reachable from the dashboard
/// via the channel switcher for a user who wants to change channels mid-session.
class ChannelSelectorScreen extends ConsumerWidget {
  final bool isSwitch;
  const ChannelSelectorScreen({super.key, this.isSwitch = false});

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
        return _ChannelList(user: user, isSwitch: isSwitch);
      },
    );
  }
}

class _ChannelList extends ConsumerStatefulWidget {
  final AuthUser user;
  final bool isSwitch;
  const _ChannelList({required this.user, required this.isSwitch});

  @override
  ConsumerState<_ChannelList> createState() => _ChannelListState();
}

class _ChannelListState extends ConsumerState<_ChannelList> {
  String? _switchingId;
  String? _error;

  Future<void> _select(String tenantId) async {
    if (_switchingId != null) return;
    setState(() { _switchingId = tenantId; _error = null; });
    try {
      await ref.read(authNotifierProvider.notifier).switchChannel(tenantId);
      if (mounted) context.go('/dashboard');
    } catch (e) {
      if (mounted) setState(() { _error = 'Could not switch channel. Please try again.'; });
    } finally {
      if (mounted) setState(() => _switchingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isSwitch ? 'Switch Channel' : 'Select Channel'),
        automaticallyImplyLeading: widget.isSwitch,
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
              Text('Choose a channel to work with',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            ]),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
            ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: user.tenants.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final tenant   = user.tenants[i];
                final isActive = tenant.id == user.activeTenantId;
                return _ChannelTile(
                  tenant:     tenant,
                  isActive:   isActive,
                  isSwitching: _switchingId == tenant.id,
                  onTap:      () => _select(tenant.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final TenantInfo tenant;
  final bool isActive;
  final bool isSwitching;
  final VoidCallback onTap;
  const _ChannelTile({
    required this.tenant,
    required this.isActive,
    required this.isSwitching,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      tone: isActive ? AppTone.violet : AppTone.neutral,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      onTap: isActive ? null : onTap,
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: isActive ? AppColors.violetFg : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(Icons.hub_outlined,
              color: isActive ? Colors.white : Colors.grey.shade600, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tenant.name,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: isActive ? AppColors.violetFg : null,
                )),
            const SizedBox(height: 2),
            Text(tenant.code,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500, fontFamily: 'monospace')),
          ]),
        ),
        if (isSwitching)
          const SizedBox(
            width: 20, height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else if (isActive)
          const Icon(Icons.check_circle_rounded, color: AppColors.violetFg, size: 22),
      ]),
    );
  }
}

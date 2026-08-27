import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/colors.dart';
import '../../features/auth/auth_provider.dart';

/// Persistent, always-visible strip showing the channel the current session is
/// scoped to — shown above every tab (not just Dashboard) so a user never loses
/// track of which channel's data they're looking at. Shows even for a
/// single-channel account (there's nothing to switch, but the name still tells
/// the user where they are); tapping it only does anything when there's more
/// than one channel to switch between.
class ChannelBanner extends ConsumerWidget {
  const ChannelBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authNotifierProvider).valueOrNull;
    if (user == null) return const SizedBox.shrink();

    final channelName = user.activeTenant?.name;
    if (channelName == null) return const SizedBox.shrink();

    final canSwitch = user.tenants.length > 1;

    return Material(
      color: AppColors.violetBg,
      child: InkWell(
        onTap: canSwitch ? () => context.push('/select-channel?switch=true') : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.hub_outlined, size: 13, color: AppColors.violetFg),
              const SizedBox(width: 5),
              Text(
                channelName,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.violetFg,
                ),
              ),
              if (canSwitch) ...[
                const SizedBox(width: 2),
                const Icon(Icons.arrow_drop_down, size: 16, color: AppColors.violetFg),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

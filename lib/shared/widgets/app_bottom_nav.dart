import 'package:flutter/material.dart';
import '../../app/colors.dart';
import '../../app/radii.dart';

class AppNavItem {
  final IconData icon;
  final IconData selectedIcon;
  final int badgeCount;
  const AppNavItem({
    required this.icon,
    required this.selectedIcon,
    this.badgeCount = 0,
  });
}

/// Floating dark pill bottom nav with a circular white active-tab indicator,
/// matching the reference design's icon-only floating nav bar.
class AppBottomNav extends StatelessWidget {
  final List<AppNavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onTap;

  const AppBottomNav({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          // Same brand teal used for primary buttons/active states across
          // the admin sidebar and mobile buttons (see AppTheme.light).
          color: const Color(0xFF237A7D),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF237A7D).withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: List.generate(items.length, (i) {
            final item = items[i];
            final selected = i == selectedIndex;
            return _NavIcon(
              item: item,
              selected: selected,
              onTap: () => onTap(i),
            );
          }),
        ),
      ),
    );
  }
}

class _NavIcon extends StatelessWidget {
  final AppNavItem item;
  final bool selected;
  final VoidCallback onTap;
  const _NavIcon(
      {required this.item, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              // Subtle highlight for the selected tab now that the bar itself
              // is the same brand teal — a solid circle would be invisible.
              color: selected ? Colors.white.withValues(alpha: 0.22) : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(
              selected ? item.selectedIcon : item.icon,
              color: Colors.white,
              size: 22,
            ),
          ),
          if (item.badgeCount > 0)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                    color: AppColors.pinkFg, shape: BoxShape.circle),
                constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
                child: Text(
                  item.badgeCount > 9 ? '9+' : '${item.badgeCount}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                      height: 1),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'app_card.dart';
import '../../app/colors.dart';

/// Flat pastel stat card: icon, big bold value, small muted label.
class StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final AppTone tone;

  const StatTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final fg = AppColors.foreground(tone);
    return AppCard(
      tone: tone,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(height: 10),
          Text(
            value,
            style: TextStyle(
                color: fg, fontSize: 20, fontWeight: FontWeight.w800),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(color: fg.withValues(alpha: 0.75), fontSize: 11),
          ),
        ],
      ),
    );
  }
}

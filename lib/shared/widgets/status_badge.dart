import 'package:flutter/material.dart';
import '../../app/colors.dart';
import '../../app/radii.dart';

/// Small pill badge used for order/return/damage status labels.
class StatusBadge extends StatelessWidget {
  final String label;
  final AppTone tone;

  const StatusBadge({super.key, required this.label, required this.tone});

  @override
  Widget build(BuildContext context) {
    final fg = AppColors.foreground(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}

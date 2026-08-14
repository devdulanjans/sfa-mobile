import 'package:flutter/material.dart';
import '../../app/colors.dart';
import '../../app/radii.dart';

class SectionHeader extends StatelessWidget {
  final String title;
  final IconData? icon;
  final AppTone tone;

  const SectionHeader({
    super.key,
    required this.title,
    this.icon,
    this.tone = AppTone.violet,
  });

  @override
  Widget build(BuildContext context) {
    final fg = AppColors.foreground(tone);
    return Row(children: [
      if (icon != null) ...[
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: fg.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(icon, color: fg, size: 16),
        ),
        const SizedBox(width: 10),
      ],
      Text(title,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w700)),
    ]);
  }
}

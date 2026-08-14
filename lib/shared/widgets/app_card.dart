import 'package:flutter/material.dart';
import '../../app/colors.dart';
import '../../app/radii.dart';

/// Flat pastel-block card used throughout the redesigned UI.
/// [AppTone.neutral] gives the plain white content-card variant used for lists.
class AppCard extends StatelessWidget {
  final Widget child;
  final AppTone tone;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;

  const AppCard({
    super.key,
    required this.child,
    this.tone = AppTone.neutral,
    this.padding = const EdgeInsets.all(16),
    this.radius = AppRadius.lg,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.background(tone),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: child,
    );

    if (onTap == null) return content;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: onTap,
        child: content,
      ),
    );
  }
}

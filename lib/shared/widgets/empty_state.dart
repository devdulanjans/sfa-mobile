import 'package:flutter/material.dart';
import '../../app/radii.dart';

class EmptyState extends StatelessWidget {
  final String message;
  final IconData icon;

  const EmptyState({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 32),
    decoration: BoxDecoration(
      color: Colors.grey.shade50,
      borderRadius: BorderRadius.circular(AppRadius.lg),
    ),
    child: Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 40, color: Colors.grey.shade400),
        const SizedBox(height: 10),
        Text(message,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
      ]),
    ),
  );
}

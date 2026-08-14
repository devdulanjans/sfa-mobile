import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/colors.dart';
import '../auth/auth_provider.dart';
import 'mileage_provider.dart';

/// Mandatory start-of-session gate reached only via the router's redirect
/// (see app/router.dart) — no back button, no way to dismiss. Mirrors
/// DistributorSelectorScreen's shape (full screen, self-contained).
class StartMileageScreen extends ConsumerStatefulWidget {
  const StartMileageScreen({super.key});
  @override
  ConsumerState<StartMileageScreen> createState() => _StartMileageScreenState();
}

class _StartMileageScreenState extends ConsumerState<StartMileageScreen> {
  final _controller = TextEditingController();
  String? _error;
  bool _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final value = double.tryParse(_controller.text);
    if (value == null || value < 0) {
      setState(() => _error = 'Enter a valid starting mileage');
      return;
    }
    setState(() { _error = null; _submitting = true; });
    try {
      await ref.read(mileageNotifierProvider.notifier).recordStart(value);
      if (mounted) context.go('/dashboard');
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authNotifierProvider).valueOrNull;
    final lastEndMileage = ref.watch(mileageNotifierProvider).valueOrNull?.lastEndMileage;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Start of Day'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout_outlined),
            tooltip: 'Logout',
            onPressed: () => ref.read(authNotifierProvider.notifier).logout(),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Welcome${user != null && user.fullName.isNotEmpty ? ', ${user.fullName}' : ''}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              'Enter your starting odometer reading before you continue. '
              'This is required at the start of every session.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600, height: 1.4),
            ),
            if (lastEndMileage != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.violetBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  const Icon(Icons.history_rounded, size: 16, color: AppColors.violetFg),
                  const SizedBox(width: 8),
                  Text(
                    'Last end mileage: ${lastEndMileage.toStringAsFixed(1)} km',
                    style: const TextStyle(fontSize: 12.5, color: AppColors.violetFg, fontWeight: FontWeight.w500),
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 24),
            TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Starting Mileage (km)',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submitting ? null : _submit,
                style: FilledButton.styleFrom(backgroundColor: AppColors.violetFg),
                child: _submitting
                    ? const SizedBox(
                        height: 18, width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Start My Day'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

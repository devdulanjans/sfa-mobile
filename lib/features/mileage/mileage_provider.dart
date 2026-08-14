import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/storage/local_db.dart';
import '../auth/auth_provider.dart';

const _mileageSettingKey = 'mileage_management_enabled';

/// Mileage state for the signed-in user, tracked per login/logout session rather
/// than per calendar day — a rep who logs out (recording end mileage) and logs
/// back in later the same day must start a new session. [startMileage] non-null
/// means a session is currently open (start recorded, end not yet). When no
/// session is open, [lastEndMileage] (if any) is the last closed session's end
/// reading — shown as a reference on the start-mileage screen. [applicable] is
/// false for any role other than SALES_REP (or when logged out), or when the
/// tenant has switched mileage management off (see [_mileageSettingKey],
/// synced from the backend's global settings) — the router and the logout gate
/// both skip mileage entirely in that case.
class MileageStatus {
  final bool applicable;
  final double? startMileage;
  final double? lastEndMileage;

  const MileageStatus({
    required this.applicable,
    this.startMileage,
    this.lastEndMileage,
  });

  bool get needsStart => applicable && startMileage == null;
  bool get needsEnd    => applicable && startMileage != null;
}

class MileageNotifier extends AsyncNotifier<MileageStatus> {
  @override
  Future<MileageStatus> build() async {
    final user = ref.watch(authNotifierProvider).valueOrNull;
    if (user == null || user.role != 'SALES_REP') {
      return const MileageStatus(applicable: false);
    }
    if (!LocalDb.getSystemSettingBool(_mileageSettingKey, defaultValue: true)) {
      return const MileageStatus(applicable: false);
    }

    final dio = ref.read(dioProvider);
    try {
      final resp = await dio.get('/mileage/current');
      final data = resp.data as Map<String, dynamic>;
      return MileageStatus(
        applicable: true,
        startMileage:   (data['startMileage']   as num?)?.toDouble(),
        lastEndMileage: (data['lastEndMileage'] as num?)?.toDouble(),
      );
    } catch (_) {
      // This is a mandatory compliance gate — if the check itself can't be
      // reached (network blip, stale endpoint, server error), default to
      // "needs start" rather than silently letting the rep through. Worst
      // case they're asked to re-enter start mileage; if a session actually
      // already exists server-side, recordStart() will say so explicitly
      // instead of the gate just being bypassed.
      return const MileageStatus(applicable: true);
    }
  }

  Future<void> recordStart(double startMileage) async {
    final dio = ref.read(dioProvider);
    final resp = await dio.post('/mileage/start', data: {'startMileage': startMileage});
    final data = resp.data as Map<String, dynamic>;
    state = AsyncData(MileageStatus(
      applicable: true,
      startMileage: (data['startMileage'] as num?)?.toDouble(),
    ));
  }

  Future<void> recordEnd(double endMileage) async {
    final dio = ref.read(dioProvider);
    await dio.post('/mileage/end', data: {'endMileage': endMileage});
    // Session is now closed — the next login (even later the same day) must
    // start a new one.
    state = AsyncData(MileageStatus(applicable: true, lastEndMileage: endMileage));
  }
}

final mileageNotifierProvider =
    AsyncNotifierProvider<MileageNotifier, MileageStatus>(MileageNotifier.new);

/// Wraps the Logout action: if this SALES_REP has an open mileage session,
/// blocks logout behind a mandatory "Enter end mileage" dialog; otherwise logs
/// out immediately, unchanged from before this feature existed.
Future<void> handleLogoutTap(BuildContext context, WidgetRef ref) async {
  final status = ref.read(mileageNotifierProvider).valueOrNull;
  if (status == null || !status.needsEnd) {
    await ref.read(authNotifierProvider.notifier).logout();
    return;
  }

  final controller = TextEditingController();
  String? errorText;

  final submitted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Enter End Mileage'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Start mileage: ${status.startMileage?.toStringAsFixed(1) ?? '—'} km',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'End Mileage (km)',
                errorText: errorText,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = double.tryParse(controller.text);
              if (value == null) {
                setState(() => errorText = 'Enter a valid number');
                return;
              }
              if (status.startMileage != null && value < status.startMileage!) {
                setState(() => errorText = 'Must be ≥ start mileage');
                return;
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('Submit & Logout'),
          ),
        ],
      ),
    ),
  );

  if (submitted != true) return;

  try {
    await ref.read(mileageNotifierProvider.notifier).recordEnd(double.parse(controller.text));
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save end mileage: $e')),
      );
    }
    return;
  }

  await ref.read(authNotifierProvider.notifier).logout();
}

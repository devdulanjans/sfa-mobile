import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/colors.dart';
import '../../app/radii.dart';
import '../../core/storage/local_db.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/empty_state.dart';

// Refreshable provider so we can invalidate after clear
final _errorLogsProvider = Provider<List<Map>>((ref) => LocalDb.errorLogs);

class ErrorLogScreen extends ConsumerWidget {
  const ErrorLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(_errorLogsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Error Logs'),
        actions: [
          if (logs.isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Clear Logs'),
                    content: const Text(
                        'Delete all error logs? This cannot be undone.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          style: FilledButton.styleFrom(
                              backgroundColor: Colors.red.shade600),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Clear All')),
                    ],
                  ),
                );
                if (confirm == true) {
                  await LocalDb.clearErrorLogs();
                  ref.invalidate(_errorLogsProvider);
                }
              },
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text('Clear All'),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
            ),
        ],
      ),
      body: logs.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: EmptyState(
                  message: 'No errors logged',
                  icon: Icons.check_circle_outline_rounded,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: logs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (context, i) => _ErrorCard(log: logs[i]),
            ),
    );
  }
}

class _ErrorCard extends StatefulWidget {
  final Map log;
  const _ErrorCard({required this.log});

  @override
  State<_ErrorCard> createState() => _ErrorCardState();
}

class _ErrorCardState extends State<_ErrorCard> {
  bool _expanded = false;

  String _formatTime(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    final local = dt.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/'
        '${local.year}  '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final title    = widget.log['title'] as String? ?? 'Error';
    final detail   = widget.log['detail'] as String? ?? '';
    final endpoint = widget.log['endpoint'] as String?;
    final ts       = _formatTime(widget.log['timestamp'] as String?);

    return AppCard(
      padding: const EdgeInsets.all(12),
      onTap: () => setState(() => _expanded = !_expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.error_outline_rounded,
                size: 16, color: AppColors.pinkFg),
            const SizedBox(width: 6),
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13)),
            ),
            Icon(
              _expanded
                  ? Icons.expand_less_rounded
                  : Icons.expand_more_rounded,
              size: 18,
              color: Colors.grey,
            ),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            Icon(Icons.access_time_rounded,
                size: 12, color: Colors.grey.shade500),
            const SizedBox(width: 4),
            Text(ts,
                style: TextStyle(
                    fontSize: 11, color: Colors.grey.shade600)),
            if (endpoint != null) ...[
              const SizedBox(width: 10),
              Icon(Icons.link_rounded,
                  size: 12, color: Colors.grey.shade500),
              const SizedBox(width: 4),
              Text(endpoint,
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey.shade600)),
            ],
          ]),
          if (_expanded && detail.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.pinkBg,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: SelectableText(
                detail,
                style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.pinkFg,
                    fontFamily: 'monospace'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

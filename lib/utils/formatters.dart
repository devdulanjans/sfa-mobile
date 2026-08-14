import 'package:intl/intl.dart';

final NumberFormat _amountFormat = NumberFormat('#,##0.00;(#,##0.00)');

/// Standard accounting-format money string: comma-grouped, 2 decimals,
/// negative values wrapped in parentheses (e.g. "1,234.50", "(1,234.50)").
String formatAmount(num value) => _amountFormat.format(value);

final DateFormat _dateTimeFormat = DateFormat('dd MMM yyyy, hh:mm a');

/// Formats an ISO-8601 instant string (as sent by the backend, UTC) into a
/// readable local date+time string, e.g. "12 Jul 2026, 03:57 PM".
/// Returns '—' for null/empty input, or the raw string if unparseable.
String formatDateTime(String? isoInstant) {
  if (isoInstant == null || isoInstant.isEmpty) return '—';
  final parsed = DateTime.tryParse(isoInstant);
  if (parsed == null) return isoInstant;
  return _dateTimeFormat.format(parsed.toLocal());
}

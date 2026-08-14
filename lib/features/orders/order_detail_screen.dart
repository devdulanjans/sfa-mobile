import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/colors.dart';
import '../../core/network/api_client.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/status_badge.dart';
import '../../utils/formatters.dart';

final _statusTones = {
  'DRAFT':     AppTone.neutral,
  'SUBMITTED': AppTone.orange,
  'APPROVED':  AppTone.mint,
  'INVOICED':  AppTone.violet,
  'CANCELLED': AppTone.pink,
};

final _orderDetailProvider =
    FutureProvider.family<Map<String, dynamic>, String>((ref, id) async {
  final dio = ref.read(dioProvider);
  final resp = await dio.get('/orders/$id');
  return resp.data as Map<String, dynamic>;
});

class OrderDetailScreen extends ConsumerStatefulWidget {
  final String id;
  const OrderDetailScreen({super.key, required this.id});

  @override
  ConsumerState<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends ConsumerState<OrderDetailScreen> {
  bool _openingInvoice = false;

  Future<void> _openInvoice(Map<String, dynamic> order) async {
    final status = order['status'] as String? ?? '';
    setState(() => _openingInvoice = true);
    try {
      final dio = ref.read(dioProvider);
      String invoiceId;
      if (status == 'INVOICED') {
        final resp = await dio.get('/invoices/by-order/${widget.id}');
        invoiceId = resp.data['id'] as String;
      } else {
        final resp = await dio.post('/invoices/generate/${widget.id}');
        invoiceId = resp.data['id'] as String;
      }
      if (mounted) context.push('/invoices/$invoiceId');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open invoice: $e'),
              backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _openingInvoice = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_orderDetailProvider(widget.id));
    return Scaffold(
      appBar: AppBar(title: const Text('Order Details')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error:   (e, _) => Center(child: Text('Error: $e')),
        data:    (order) => _Body(order: order),
      ),
      bottomNavigationBar: async.valueOrNull != null &&
              (async.value!['status'] == 'APPROVED' ||
                  async.value!['status'] == 'INVOICED')
          ? Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: ElevatedButton.icon(
                onPressed:
                    _openingInvoice ? null : () => _openInvoice(async.value!),
                icon: _openingInvoice
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.receipt_long_outlined),
                label: Text(_openingInvoice ? 'Opening…' : 'View Invoice'),
              ),
            )
          : null,
    );
  }
}

class _Body extends StatelessWidget {
  final Map<String, dynamic> order;
  const _Body({required this.order});

  @override
  Widget build(BuildContext context) {
    final status = order['status'] as String? ?? '';
    final items  = (order['items'] as List?) ?? const [];
    final taxedItem = items.cast<Map<String, dynamic>>().where(
        (i) => ((i['taxPct'] as num?) ?? 0) > 0).firstOrNull;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text(
                    order['orderNumber'] as String? ?? '',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                ),
                StatusBadge(label: status, tone: _statusTones[status] ?? AppTone.neutral),
              ]),
              const SizedBox(height: 16),
              _InfoRow('Customer', (order['customer'] as Map?)?['name'] as String? ?? '—'),
              _InfoRow('Sales Rep', (order['salesRep'] as Map?)?['fullName'] as String? ?? '—'),
              if ((order['distributor'] as Map?)?['name'] != null)
                _InfoRow('Distributor', (order['distributor'] as Map)['name'] as String),
              _InfoRow('Order Date', formatDateTime(order['orderDate'] as String?)),
              if ((order['poNumber'] as String?)?.isNotEmpty == true)
                _InfoRow('PO Number', order['poNumber'] as String),
              ..._buildDeliveryAddress(order),
              if ((order['notes'] as String?)?.isNotEmpty == true)
                _InfoRow('Notes', order['notes'] as String),
            ],
          ),
        ),

        const SizedBox(height: 16),
        Text('Items (${items.length})',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        ...items.map((raw) => _ItemCard(item: raw as Map<String, dynamic>)),

        const SizedBox(height: 8),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _InfoRow('Subtotal', 'LKR ${formatAmount((order['subtotal'] as num?) ?? 0)}'),
            if (((order['discountAmount'] as num?) ?? 0) > 0) ...[
              _InfoRow('Discount', 'LKR ${formatAmount(-(((order['discountAmount'] as num?) ?? 0)))}'),
              // Amount tax is actually calculated on — makes it explicit that tax
              // applies after the discount, not on the pre-discount subtotal.
              _InfoRow('Net Amount',
                  'LKR ${formatAmount(((order['subtotal'] as num?) ?? 0) - ((order['discountAmount'] as num?) ?? 0))}'),
            ],
            _InfoRow(
                taxedItem != null
                    ? 'Tax (${((taxedItem['taxPct'] as num).toDouble()).toStringAsFixed(0)}%)'
                    : 'Tax',
                'LKR ${formatAmount((order['taxAmount'] as num?) ?? 0)}'),
            const Divider(height: 20),
            _InfoRow('Total', 'LKR ${formatAmount((order['total'] as num?) ?? 0)}', bold: true),
          ]),
        ),

        ..._buildSignatures(order),
      ],
    );
  }

  List<Widget> _buildDeliveryAddress(Map<String, dynamic> order) {
    final label = order['deliveryAddressLabel'] as String?;
    final line  = order['deliveryAddressLine']  as String?;
    if (line == null || line.isEmpty) return [];
    final display = (label != null && label.isNotEmpty) ? '$label: $line' : line;
    return [_InfoRow('Delivery', display)];
  }

  List<Widget> _buildSignatures(Map<String, dynamic> order) {
    final customerSig    = order['customerSignature']    as String?;
    final salespersonSig = order['salespersonSignature'] as String?;
    if (customerSig == null && salespersonSig == null) return [];

    return [
      const SizedBox(height: 16),
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Signatures',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 10),
            if (customerSig != null) ...[
              const Text('Customer',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 4),
              _SignatureImage(base64Png: customerSig),
              const SizedBox(height: 12),
            ],
            if (salespersonSig != null) ...[
              const Text('Sales Person',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 4),
              _SignatureImage(base64Png: salespersonSig),
            ],
          ],
        ),
      ),
    ];
  }
}

class _ItemCard extends StatelessWidget {
  final Map<String, dynamic> item;
  const _ItemCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final product      = item['product'] as Map?;
    final name         = product?['name'] as String? ?? 'Item';
    final code         = product?['productCode'] as String?;
    final quantity     = (item['quantity'] as num?)?.toDouble() ?? 0;
    final unitPrice    = (item['unitPrice'] as num?)?.toDouble() ?? 0;
    final discountPct  = (item['discountPct'] as num?)?.toDouble() ?? 0;
    final taxPct       = (item['taxPct'] as num?)?.toDouble() ?? 0;
    final taxAmount    = (item['taxAmount'] as num?)?.toDouble() ?? 0;
    // Each row shows price × qty (minus any per-item discount) only — tax is an
    // order-level concern shown once in the totals card below, not per line.
    final lineTotal    = ((item['lineTotal'] as num?)?.toDouble() ?? 0) - taxAmount;
    final hasDiscount  = discountPct > 0;
    final hasTax       = taxPct > 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: AppCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(
                  code != null ? '$name  ($code)' : name,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
              Text('LKR ${formatAmount(lineTotal)}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(
                child: Text(
                  '${quantity.toStringAsFixed(quantity % 1 == 0 ? 0 : 2)} × LKR ${formatAmount(unitPrice)}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
              if (hasDiscount || hasTax)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  if (hasDiscount) ...[
                    const Icon(Icons.local_offer_outlined, size: 11, color: Colors.orange),
                    const SizedBox(width: 2),
                    Text('${discountPct.toStringAsFixed(0)}%',
                        style: const TextStyle(fontSize: 11, color: Colors.orange)),
                  ],
                  if (hasDiscount && hasTax) const SizedBox(width: 8),
                  if (hasTax) ...[
                    const Icon(Icons.receipt_outlined, size: 11, color: Colors.blueGrey),
                    const SizedBox(width: 2),
                    Text('tax ${taxPct.toStringAsFixed(0)}%',
                        style: const TextStyle(fontSize: 11, color: Colors.blueGrey)),
                  ],
                ]),
            ]),
          ],
        ),
      ),
    );
  }
}

class _SignatureImage extends StatelessWidget {
  final String base64Png;
  const _SignatureImage({required this.base64Png});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 100,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Image.memory(
          base64Decode(base64Png),
          fit: BoxFit.contain,
          width: double.infinity,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label, value;
  final bool bold;
  const _InfoRow(this.label, this.value, {this.bold = false});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(
            width: 90,
            child: Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                fontSize: bold ? 16 : 14,
              ),
            ),
          ),
        ]),
      );
}

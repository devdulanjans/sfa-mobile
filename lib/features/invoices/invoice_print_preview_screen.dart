import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import '../../core/network/api_client.dart';

/// TEMPORARY — dev/QA aid, remove before production. When removing: point
/// `_fetchPdf` back at `/invoices/{id}/pdf` (or retire this screen/button
/// entirely), and remove the matching `/thermal-preview` endpoint in
/// InvoiceController + InvoiceService + InvoicePdfGenerator.generateThermalPreview.
///
/// Renders the narrow receipt-style PDF the backend generates for
/// `/api/invoices/{id}/thermal-preview` — the exact same content/line-order as
/// the actual Bluetooth ESC/POS print (`/api/invoices/{id}/thermal`), just
/// rendered as a monospace PDF instead of raw printer bytes, so what's shown
/// here always matches what actually prints on the thermal printer. This is
/// deliberately NOT the A4 tax-invoice design (`/api/invoices/{id}/pdf`) —
/// that's a different layout meant for office/email use, not the receipt.
class InvoicePrintPreviewScreen extends ConsumerWidget {
  final Map<String, dynamic> invoice;

  /// When provided, shows a "Print via Bluetooth" bottom action — callers
  /// that don't already offer a separate print button (e.g. the order
  /// submission flow) pass this to let the user proceed to the thermal
  /// printer straight from the preview. Callers that have their own print
  /// button elsewhere on screen (e.g. InvoiceScreen) omit it.
  final VoidCallback? onPrint;

  const InvoicePrintPreviewScreen({super.key, required this.invoice, this.onPrint});

  Future<Uint8List> _fetchPdf(WidgetRef ref) async {
    final dio = ref.read(dioProvider);
    final resp = await dio.get(
      '/invoices/${invoice['id']}/thermal-preview',
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(resp.data as List<int>);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invNo = invoice['invoiceNumber'] as String? ?? 'Invoice';

    return Scaffold(
      appBar: AppBar(
        title: Text(invNo),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close, color: Colors.white70, size: 18),
              label: const Text('Close', style: TextStyle(color: Colors.white70)),
            ),
          ),
        ],
      ),
      body: PdfPreview(
        build: (_) => _fetchPdf(ref),
        // Matches the backend's receipt page width (280pt ≈ 99mm) — the actual
        // rendered page always comes from the PDF bytes themselves, this is just
        // the hint used for the system print-dialog default (canChangePageFormat
        // is false, so it's never user-facing as a picker).
        initialPageFormat: const PdfPageFormat(280, 1400),
        allowPrinting: true,
        allowSharing: true,
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
        pdfFileName: '$invNo.pdf',
        loadingWidget: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('Building preview...'),
            ],
          ),
        ),
      ),
      bottomNavigationBar: onPrint == null
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onPrint,
                  icon: const Icon(Icons.print_rounded, size: 18),
                  label: const Text('Print via Bluetooth'),
                ),
              ),
            ),
    );
  }
}

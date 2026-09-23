import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import '../../core/network/api_client.dart';

/// TEMPORARY — dev/QA aid, remove before production. See the matching note on
/// InvoicePrintPreviewScreen — when removing, also retire the `/thermal-preview`
/// endpoint in ReturnController + ReturnService + ReturnDamageNoteGenerator.
///
/// Renders the narrow receipt-style PDF the backend generates for
/// `/api/returns/{id}/thermal-preview` — the exact same content/line-order as
/// the actual Bluetooth ESC/POS print (`/api/returns/{id}/thermal`), just
/// rendered as a monospace PDF instead of raw printer bytes, so what's shown
/// here always matches what actually prints on the thermal printer.
class ReturnPrintPreviewScreen extends ConsumerWidget {
  final String returnId;
  final String returnNumber;

  /// When provided, shows a "Print via Bluetooth" bottom action so the caller
  /// can proceed straight to the thermal printer from the preview.
  final VoidCallback? onPrint;

  const ReturnPrintPreviewScreen({
    super.key,
    required this.returnId,
    required this.returnNumber,
    this.onPrint,
  });

  Future<Uint8List> _fetchPdf(WidgetRef ref) async {
    final dio = ref.read(dioProvider);
    final resp = await dio.get(
      '/returns/$returnId/thermal-preview',
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(resp.data as List<int>);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: Text(returnNumber),
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
        initialPageFormat: const PdfPageFormat(280, 1400),
        allowPrinting: true,
        allowSharing: true,
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
        pdfFileName: '$returnNumber.pdf',
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

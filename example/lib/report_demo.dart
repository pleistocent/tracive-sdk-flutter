// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// A mock transaction detail with a "Report" button: the place a bank or wallet
// app would call `openReportForm`.
//
// The receipt is drawn in code — one PNG and one small PDF — so the screen
// needs no assets and no storage permission. It works in every flavor,
// `demo` included: opening the report form makes no request and needs no
// grant.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:tracive_sdk/tracive_sdk.dart';

/// Which Tracive build the Report button opens.
enum ReportTargetChoice {
  sandbox('Sandbox'),
  production('Production'),
  dev('Dev build (QA)');

  const ReportTargetChoice(this.label);

  final String label;

  ReportFormTarget get target => switch (this) {
        sandbox => ReportFormTarget.sandbox,
        production => ReportFormTarget.production,
        // A build the SDK does not know about, reached through the explicit
        // override. Its package and schemes are declared in this app's
        // AndroidManifest.xml and Info.plist; yours need neither.
        dev => ReportFormTarget(
            androidPackage: 'com.pleistocent.tracive.dev',
            iosBundleId: 'com.pleistocent.tracive.dev',
            appScheme: 'tracivedev',
            capabilityScheme: 'tracivedev-report',
            fileExtension: 'tracivedevreport',
          ),
      };
}

/// The mock transaction this screen shows. Fictional throughout.
class MockTransaction {
  const MockTransaction({
    required this.amount,
    required this.date,
    required this.bankCode,
    required this.account,
    required this.recipientName,
  });

  /// Yesterday, as a calendar date.
  factory MockTransaction.yesterday() {
    final now = DateTime.now();
    return MockTransaction(
      amount: 'Rp 2.500.000',
      date: DateTime(now.year, now.month, now.day - 1),
      bankCode: 'BCA',
      account: '1234567890',
      recipientName: 'Toko Gadget Murah',
    );
  }

  final String amount;
  final DateTime date;
  final String bankCode;
  final String account;
  final String recipientName;

  String get dateLabel =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  List<String> get receiptLines => <String>[
        'Transfer receipt',
        'Amount: $amount',
        'Date: $dateLabel',
        'To: $bankCode $account',
        'Name: $recipientName',
      ];
}

/// The transaction detail screen.
class TransactionDetailScreen extends StatefulWidget {
  const TransactionDetailScreen({
    super.key,
    required this.client,
    this.transaction,
  });

  final TraciveClient client;

  final MockTransaction? transaction;

  @override
  State<TransactionDetailScreen> createState() =>
      _TransactionDetailScreenState();
}

class _TransactionDetailScreenState extends State<TransactionDetailScreen> {
  late final MockTransaction _transaction =
      widget.transaction ?? MockTransaction.yesterday();
  ReportTargetChoice _target = ReportTargetChoice.sandbox;
  bool _busy = false;
  ReportFormResult? _result;

  Future<void> _report(BuildContext buttonContext) async {
    // Where the iOS sheet points from on iPad. Read before the first await,
    // while the button is certainly laid out.
    final box = buttonContext.findRenderObject()! as RenderBox;
    final origin = box.localToGlobal(Offset.zero);
    final anchor = ReportFormAnchor(
      left: origin.dx,
      top: origin.dy,
      width: box.size.width,
      height: box.size.height,
    );

    setState(() {
      _busy = true;
      _result = null;
    });
    final transaction = _transaction;
    final result = await widget.client.openReportForm(
      TraciveQuery.bankAccount(
        countryAlpha3: 'IDN',
        bankCode: transaction.bankCode,
        account: transaction.account,
      ),
      incidentDate: transaction.date,
      attachments: <ReportAttachment>[
        ReportAttachment.image(
          await receiptPng(transaction.receiptLines),
          'image/png',
        ),
        ReportAttachment.pdf(receiptPdf(transaction.receiptLines)),
      ],
      anchor: anchor,
      target: _target.target,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final transaction = _transaction;
    final result = _result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transaction detail'),
        backgroundColor: theme.colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Bank transfer', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 8),
                    Text(transaction.amount,
                        style: theme.textTheme.headlineSmall),
                    const Divider(height: 24),
                    _Line(label: 'Date', value: transaction.dateLabel),
                    _Line(
                      label: 'Recipient',
                      value: '${transaction.bankCode} · ${transaction.account}',
                    ),
                    _Line(label: 'Name', value: transaction.recipientName),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('Open the report form in', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<ReportTargetChoice>(
              segments: <ButtonSegment<ReportTargetChoice>>[
                for (final choice in ReportTargetChoice.values)
                  ButtonSegment<ReportTargetChoice>(
                    value: choice,
                    label: Text(choice.label),
                  ),
              ],
              selected: <ReportTargetChoice>{_target},
              onSelectionChanged: (selection) =>
                  setState(() => _target = selection.first),
            ),
            const SizedBox(height: 16),
            Builder(
              builder: (buttonContext) => FilledButton.icon(
                onPressed: _busy ? null : () => _report(buttonContext),
                icon: const Icon(Icons.report_outlined),
                label: const Text('Report'),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Sends the recipient account, the date and a generated receipt '
              '(one PNG, one PDF) to the Tracive app on this phone. Nothing is '
              'uploaded until the user submits there.',
              style: theme.textTheme.bodySmall,
            ),
            if (result != null) ...<Widget>[
              const SizedBox(height: 16),
              Card(
                color: result is ReportFormFailed
                    ? theme.colorScheme.errorContainer
                    : theme.colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(describeReportResult(result)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// What to tell the user for each outcome.
String describeReportResult(ReportFormResult result) => switch (result) {
      ReportFormOpened(attachmentsDelivered: true) =>
        'Opened in Tracive with the account, the date and the receipt.',
      ReportFormOpened(attachmentsDelivered: false) =>
        'Opened in Tracive with the account only: that version of the app '
            'takes no attachments.',
      ReportFormCancelled() => 'Cancelled. Nothing was sent.',
      ReportFormInstallPageOpened() =>
        'Tracive is not installed. The install page was opened.',
      ReportFormFailed(:final error) => 'Nothing was opened: $error',
    };

/// A receipt image, drawn with the engine's own renderer.
Future<Uint8List> receiptPng(List<String> lines) async {
  const width = 360.0;
  const height = 200.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawRect(
      const Rect.fromLTWH(0, 0, width, height),
      Paint()..color = Colors.white,
    );
  final painter = TextPainter(
    text: TextSpan(
      text: lines.join('\n'),
      style: const TextStyle(color: Colors.black, fontSize: 18, height: 1.5),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width - 40);
  painter.paint(canvas, const Offset(20, 20));
  final image =
      await recorder.endRecording().toImage(width.toInt(), height.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// A one-page PDF with [lines] in Helvetica. ASCII only.
Uint8List receiptPdf(List<String> lines) {
  String escape(String line) => line
      .replaceAll(r'\', r'\\')
      .replaceAll('(', r'\(')
      .replaceAll(')', r'\)');
  final content = StringBuffer('BT /F1 14 Tf 20 170 Td 22 TL\n');
  for (final line in lines) {
    content.write('(${escape(line)}) Tj T*\n');
  }
  content.write('ET');
  final stream = content.toString();
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 360 200] /Contents 4 0 R '
        '/Resources << /Font << /F1 5 0 R >> >> >>',
    '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];

  // The cross-reference table holds byte offsets, which equal string offsets
  // only because every character here is ASCII.
  final pdf = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(pdf.length);
    pdf.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = pdf.length;
  pdf.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    pdf.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  pdf.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xref\n%%EOF\n');
  return ascii.encode(pdf.toString());
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 100,
              child: Text(label, style: Theme.of(context).textTheme.bodySmall),
            ),
            Expanded(child: Text(value)),
          ],
        ),
      );
}

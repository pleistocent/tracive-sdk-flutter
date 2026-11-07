// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:tracive_sdk/tracive_sdk.dart';
import 'package:tracive_sdk_extended/tracive_sdk_extended.dart';

import 'example_environment.dart';
import 'local_backend.dart';

// TODO(partner): your own brand.
const TraciveReportTheme _theme = TraciveReportTheme(
  primaryColor: Color(0xFF00695C),
  cornerRadius: 16,
);

// A made-up account, so the example runs with one tap and reports nobody real.
final TraciveQuery _fakeScammer = TraciveQuery.bankAccount(
  countryAlpha3: 'IDN',
  bankCode: 'BCA',
  account: '0000000001',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ExampleApp(
      backend: ExampleEnvironment.isLocal ? await LocalBackend.start() : null,
    ),
  );
}

/// The example application.
class ExampleApp extends StatelessWidget {
  /// Creates the app. [backend] is set for a local build only.
  const ExampleApp({super.key, this.backend});

  /// The stand-in for the Tracive API.
  final LocalBackend? backend;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Tracive reports example',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00695C)),
        ),
        home: ReportDemo(backend: backend),
      );
}

/// One screen: authorize, then report through either path.
class ReportDemo extends StatefulWidget {
  /// Creates the screen.
  const ReportDemo({super.key, this.backend});

  /// The stand-in for the Tracive API.
  final LocalBackend? backend;

  @override
  State<ReportDemo> createState() => _ReportDemoState();
}

class _ReportDemoState extends State<ReportDemo> {
  // TODO(partner): the user writes this. A chronology is their own account of
  // what happened, and your own UI must not fill it in.
  final TextEditingController _chronology = TextEditingController(
    text: 'Example only: I paid for a phone, and the seller stopped answering '
        'my messages the same day.',
  );

  TraciveClient? _client;
  late final TraciveReports _reports;
  StreamSubscription<Uri>? _links;

  ReportDraft? _ownDraft;
  String _message = 'Ready.';
  String? _lastReportId;
  List<RequiredTerm> _terms = const <RequiredTerm>[];
  double? _progress;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final backend = widget.backend;
    if (backend != null) {
      _reports = TraciveReports.withTokens(
        environment: TraciveEnvironment.custom(backend.baseUrl),
        accessToken: (_) async => backend.acceptedToken,
      );
      return;
    }
    final client = TraciveClient(
      mode: TraciveMode.oauth(
        // TODO(partner): your own stable id for this user, never a phone
        // number or an email.
        partnerUserId: 'partner-user-1',
        clientId: ExampleEnvironment.clientId,
        redirectUri: ExampleEnvironment.redirectUri,
        scopes: const <String>[
          TraciveReportScopes.create,
          TraciveReportScopes.read,
        ],
      ),
      environment: ExampleEnvironment.api,
    );
    _client = client;
    _reports = TraciveReports(
      client: client,
      target: ExampleEnvironment.target,
    );
    _links = AppLinks().uriLinkStream.listen(_onLink);
  }

  @override
  void dispose() {
    unawaited(_links?.cancel());
    unawaited(_reports.dispose());
    _client?.close();
    _chronology.dispose();
    super.dispose();
  }

  Future<void> _authorize() async {
    final start = await _client!.authorize();
    _say(
      switch (start) {
        null => 'Consent opened. Finish it in the Tracive app.',
        AuthAppNotInstalled() => 'Install Tracive first. Its page was opened.',
        AuthFailed(:final error) => 'Authorize failed: ${error.message}',
        _ => 'Unexpected: $start',
      },
    );
  }

  Future<void> _onLink(Uri uri) async {
    final result = await _client!.handleCallback(uri);
    if (result == null) return;
    _say(
      switch (result) {
        AuthAuthorized(:final grantedScopes) =>
          'Granted: ${grantedScopes.join(', ')}',
        AuthDenied() => 'You declined.',
        AuthFailed(:final error) => 'Authorize failed: ${error.message}',
        _ => 'Unexpected: $result',
      },
    );
  }

  Future<void> _openForm() => _guarded(() async {
        final outcome = await TraciveReportForm.present(
          _reports,
          prefill: ReportPrefill.forQuery(
            _fakeScammer,
            incidentDate: _yesterday(),
            title: 'Example: fake seller',
            attachments: <ReportAttachment>[
              ReportAttachment.image(await _sampleReceipt(), 'image/png'),
            ],
          ),
          theme: _theme,
        );
        switch (outcome) {
          case ReportFormSubmitted(:final reportId, :final status):
            _lastReportId = reportId;
            _say('Form: submitted $reportId, ${status.wire}');
          case ReportFormNeedsConsent():
            _say('Form: needs consent. Authorize, then open it again.');
          case ReportFormUserCancelled():
            _say('Form: cancelled.');
        }
      });

  Future<void> _sendWithOwnUi() => _guarded(() async {
        final requirements = await _reports.requirements();
        setState(() => _terms = requirements.terms);

        final draft = _ownDraft?.chronology == _chronology.text
            ? _ownDraft!
            : ReportDraft.forQuery(
                query: _fakeScammer,
                title: 'Example: own UI',
                chronology: _chronology.text,
                incidentDate: _yesterday(),
                evidence: <PreparedEvidence>[
                  await _reports.prepare(
                    await _sampleReceipt(),
                    mimeType: 'image/png',
                  ),
                ],
                acceptedTerms: requirements.terms,
              );
        _ownDraft = draft;

        final problems = draft.problems(requirements.limits);
        if (problems.isNotEmpty) {
          _say('Fix first: ${problems.map((p) => p.name).join(', ')}');
          return;
        }

        final result = await _reports.submit(
          draft,
          onProgress: (fraction) => setState(() => _progress = fraction),
        );
        setState(() => _progress = null);
        switch (result) {
          case ReportSubmitted(:final reportId, :final status):
            _ownDraft = null;
            _lastReportId = reportId;
            _say('Own UI: submitted $reportId, ${status.wire}');
          case ReportNeedsConsent():
            _say('Own UI: needs consent. Authorize, then try again.');
          case ReportFailed(:final error):
            _say('Own UI failed: ${error.code.wire}. Try again.');
        }
      });

  Future<void> _openStatus() => _guarded(() async {
        final outcome = await TraciveReportStatus.present(
          _reports,
          _lastReportId!,
          theme: _theme,
        );
        _say('Status screen: ${outcome.name}');
      });

  Future<void> _checkStatus() => _guarded(() async {
        final status = await _reports.status(_lastReportId!);
        _say('Own UI: status is ${status.wire}');
      });

  Future<void> _openInTracive() => _guarded(() async {
        final opened = await _reports.openInTracive(_lastReportId!);
        _say(opened ? 'Opened in Tracive.' : 'Tracive is not installed.');
      });

  Future<void> _guarded(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on TraciveReportException catch (failure) {
      _say(
        failure.code == ReportErrorCode.needsConsent
            ? 'Needs consent. Authorize first.'
            : 'Failed: ${failure.code.wire}',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String message) {
    if (mounted) setState(() => _message = message);
  }

  DateTime _yesterday() => DateTime.now().subtract(const Duration(days: 1));

  /// A plain image, so nobody needs a receipt to try this.
  Future<Uint8List> _sampleReceipt() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(
      const Color(0xFFB2DFDB),
      ui.BlendMode.src,
    );
    final image = await recorder.endRecording().toImage(600, 800);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    final hasReport = _lastReportId != null && !_busy;
    return Scaffold(
      appBar: AppBar(title: const Text('Tracive reports')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(_message, key: const Key('message')),
          const SizedBox(height: 16),
          if (_client != null)
            OutlinedButton(
              onPressed: _busy ? null : _authorize,
              child: const Text('Authorize'),
            ),
          FilledButton(
            onPressed: _busy ? null : _openForm,
            child: const Text("Report on Tracive's form"),
          ),
          const Divider(height: 32),
          TextField(
            controller: _chronology,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Your own UI: what happened',
            ),
          ),
          if (_progress != null) LinearProgressIndicator(value: _progress),
          // TODO(partner): your own UI must show these next to Send.
          for (final term in _terms) Text('${term.id}: ${term.url}'),
          FilledButton.tonal(
            onPressed: _busy ? null : _sendWithOwnUi,
            child: const Text('Report on your own UI'),
          ),
          const Divider(height: 32),
          Text('Last report: ${_lastReportId ?? 'none yet'}'),
          OutlinedButton(
            onPressed: hasReport ? _openStatus : null,
            child: const Text("Status on Tracive's screen"),
          ),
          OutlinedButton(
            onPressed: hasReport ? _checkStatus : null,
            child: const Text('Status on your own UI'),
          ),
          OutlinedButton(
            onPressed: hasReport ? _openInTracive : null,
            child: const Text('Open in Tracive'),
          ),
        ],
      ),
    );
  }
}

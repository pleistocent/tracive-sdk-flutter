// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

/// Lets a user report a scammer without leaving your app, on Tracive's native
/// form or on your own Flutter UI, and check that report's status.
///
/// ```dart
/// final reports = TraciveReports(client: traciveClient);
/// final outcome = await TraciveReportForm.present(
///   reports,
///   prefill: ReportPrefill.forQuery(query, title: 'Fake seller'),
/// );
/// ```
///
/// The user needs a Tracive account and a grant with
/// [TraciveReportScopes.create]. Without one, calls answer
/// [ReportErrorCode.needsConsent] or [ReportNeedsConsent]: run your authorize
/// flow with the scope added, and call again.
library;

export 'src/report_draft.dart'
    hide markEvidenceReleased, newPreparedEvidence, reportDay;
export 'src/report_error.dart';
export 'src/report_models.dart';
export 'src/report_screens.dart';
export 'src/tracive_reports.dart' hide reportsHandle;

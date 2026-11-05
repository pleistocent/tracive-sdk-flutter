// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// The non-Flutter half of a conditional import, for the same reason as
// `../oauth/platform_default.dart`: under `dart test` there is no platform to
// hand a file to, and the report-form chain stays testable without an engine.

import 'report_form_launcher.dart';

/// The default [ReportFormLauncher] outside Flutter: one that accepts nothing.
ReportFormLauncher createDefaultReportFormLauncher() =>
    const UnsupportedReportFormLauncher();

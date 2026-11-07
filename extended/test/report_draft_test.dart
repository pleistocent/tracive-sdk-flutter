// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tracive_sdk/tracive_sdk.dart';
import 'package:tracive_sdk_extended/tracive_sdk_extended.dart';

import 'fake_native.dart';

const ReportLimits _limits = ReportLimits(
  titleMaxLength: 50,
  chronologyMinLength: 50,
  chronologyMaxLength: 2000,
  commentMaxLength: 150,
  maxIdentifiers: 10,
  attachmentsPerIdentifier: 5,
  extraAttachmentsWithPhone: 5,
  maxAttachmentBytes: 1048575,
  attachmentTypes: <String>[],
);

final DateTime _today = DateTime(2026, 11, 6);

// The same cases as the Kotlin core's draft test, so the two stay one rule.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNative native;
  late PreparedEvidence file;

  setUp(() async {
    native = FakeNative();
    file = await TraciveReports.withTokens(
      environment: TraciveEnvironment.sandbox,
      accessToken: (_) async => 'token',
    ).prepare(Uint8List(1), mimeType: 'image/png');
  });
  tearDown(() => native.close());

  ReportDraft draft({
    List<String> identifiers = const <String>['BANK_IDN_BCA_1'],
    String title = 't',
    String? chronology,
    String? comment,
    String incidentDate = '2026-11-06',
    List<PreparedEvidence>? evidence,
  }) =>
      ReportDraft(
        identifiers: identifiers,
        title: title,
        chronology: chronology ?? 'c' * 50,
        comment: comment,
        incidentDate: incidentDate,
        evidence: evidence ?? <PreparedEvidence>[file],
        acceptedTerms: const <RequiredTerm>[],
      );

  List<ReportFieldProblem> problems(ReportDraft draft) =>
      draft.problems(_limits, today: _today);

  test('a good draft has no problems', () {
    expect(problems(draft()), isEmpty);
  });

  test('each limit has its problem', () {
    final cases = <(ReportDraft, ReportFieldProblem)>[
      (draft(identifiers: const <String>[]), ReportFieldProblem.noIdentifier),
      (
        draft(identifiers: List<String>.generate(11, (i) => 'EMAIL_$i')),
        ReportFieldProblem.tooManyIdentifiers,
      ),
      (draft(title: ' '), ReportFieldProblem.titleMissing),
      (draft(title: 't' * 51), ReportFieldProblem.titleTooLong),
      (draft(chronology: 'c' * 49), ReportFieldProblem.chronologyTooShort),
      (draft(chronology: 'c' * 2001), ReportFieldProblem.chronologyTooLong),
      (draft(comment: 'c' * 151), ReportFieldProblem.commentTooLong),
      (draft(evidence: <PreparedEvidence>[]), ReportFieldProblem.noEvidence),
      (
        draft(evidence: List<PreparedEvidence>.filled(6, file)),
        ReportFieldProblem.tooManyEvidence,
      ),
      (
        draft(incidentDate: '04/11/2026'),
        ReportFieldProblem.incidentDateInvalid,
      ),
      (
        draft(incidentDate: '2026-11-07'),
        ReportFieldProblem.incidentDateInFuture,
      ),
    ];
    for (final (draft, problem) in cases) {
      expect(problems(draft), <ReportFieldProblem>[problem]);
    }
  });

  test('the boundaries themselves pass', () {
    expect(
      problems(
        draft(title: 't' * 50, chronology: 'c' * 2000, comment: 'c' * 150),
      ),
      isEmpty,
    );
  });

  test('a phone adds the extra files', () {
    const phone = <String>['PHONE_+6281234567891'];
    expect(
      problems(
        draft(
          identifiers: phone,
          evidence: List<PreparedEvidence>.filled(10, file),
        ),
      ),
      isEmpty,
    );
    expect(
      problems(
        draft(
          identifiers: phone,
          evidence: List<PreparedEvidence>.filled(11, file),
        ),
      ),
      <ReportFieldProblem>[ReportFieldProblem.tooManyEvidence],
    );
  });

  test('a day that does not exist is invalid', () {
    expect(
      problems(draft(incidentDate: '2026-02-30')),
      <ReportFieldProblem>[ReportFieldProblem.incidentDateInvalid],
    );
  });

  test('problems come in form order', () {
    expect(
      problems(draft(title: ' ', incidentDate: 'x', chronology: '')),
      <ReportFieldProblem>[
        ReportFieldProblem.incidentDateInvalid,
        ReportFieldProblem.titleMissing,
        ReportFieldProblem.chronologyTooShort,
      ],
    );
  });

  test('every draft has its own key', () {
    expect(draft().idempotencyKey, isNot(draft().idempotencyKey));
    expect(draft().idempotencyKey, matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('forQuery writes the calendar day it was given', () {
    final draft = ReportDraft.forQuery(
      query: TraciveQuery.bankAccount(
        countryAlpha3: 'IDN',
        bankCode: 'BCA',
        account: '1234567890',
      ),
      title: 't',
      chronology: 'c',
      incidentDate: DateTime(2026, 1, 2, 23, 59),
      evidence: <PreparedEvidence>[file],
      acceptedTerms: const <RequiredTerm>[],
    );
    expect(draft.incidentDate, '2026-01-02');
    expect(draft.identifiers.single, startsWith('BANK_IDN_'));
  });
}

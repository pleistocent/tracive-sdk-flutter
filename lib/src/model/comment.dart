// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'json.dart';

/// A comment left on a report.
///
/// Returned only for `detail = full`, and never cached.
class Comment {
  /// Creates a comment.
  const Comment({
    required this.date,
    required this.text,
    required this.fromCredibleReport,
  });

  /// Decodes a comment object. Unknown fields are ignored.
  factory Comment.fromJson(Map<String, Object?> json) => Comment(
        date: asStringOr(json['date'], ''),
        text: asStringOr(json['text'], ''),
        fromCredibleReport: asBool(json['fromCredibleReport']),
      );

  /// The month the comment was written, as `"YYYY-MM"` (e.g. `"2026-06"`).
  ///
  /// A `String` by contract: display text with no day in it. Do not parse it.
  final String date;

  /// The comment body.
  final String text;

  /// Whether it is attached to a report the server considers credible.
  final bool fromCredibleReport;

  /// Wire form.
  Map<String, Object?> toJson() => <String, Object?>{
        'date': date,
        'text': text,
        'fromCredibleReport': fromCredibleReport,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Comment &&
          other.date == date &&
          other.text == text &&
          other.fromCredibleReport == fromCredibleReport;

  @override
  int get hashCode => Object.hash(date, text, fromCredibleReport);

  /// Redacted: user-written text routinely contains identifiers.
  @override
  String toString() => 'Comment(date: $date, credible: $fromCredibleReport, '
      'text: ${text.length} chars)';
}

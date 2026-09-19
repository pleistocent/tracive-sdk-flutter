// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'json.dart';

/// One narrative of what a reported scammer did.
///
/// Returned only for `detail = full`, and never cached: the text is
/// locale-dependent, so caching it would make the cache key `(query, detail,
/// locale)` rather than `query`.
class Chronology {
  /// Creates a chronology entry.
  const Chronology({
    required this.chronology,
    required this.riskLevel,
    this.incidentDate,
  });

  /// Decodes a chronology object. Unknown fields are ignored.
  factory Chronology.fromJson(Map<String, Object?> json) => Chronology(
        chronology: asStringOr(json['chronology'], ''),
        riskLevel: asInt(json['riskLevel']),
        incidentDate: asString(json['incidentDate']),
      );

  /// The free-text narrative.
  final String chronology;

  /// Server-assigned severity of this narrative.
  final int riskLevel;

  /// When it happened, as sent by the server.
  ///
  /// Kept as a `String?` on purpose: the contract types it as a string, and
  /// it can be a partial date (`"2026-03"`) that no `DateTime` can hold
  /// faithfully.
  final String? incidentDate;

  /// Wire form.
  Map<String, Object?> toJson() => <String, Object?>{
        'chronology': chronology,
        'riskLevel': riskLevel,
        if (incidentDate != null) 'incidentDate': incidentDate,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Chronology &&
          other.chronology == chronology &&
          other.riskLevel == riskLevel &&
          other.incidentDate == incidentDate;

  @override
  int get hashCode => Object.hash(chronology, riskLevel, incidentDate);

  /// Redacted: the narrative can name people and account numbers.
  @override
  String toString() =>
      'Chronology(riskLevel: $riskLevel, incidentDate: $incidentDate, '
      'text: ${chronology.length} chars)';
}

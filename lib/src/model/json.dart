// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Tolerant JSON readers shared by the hand-written `fromJson` constructors.
//
// There is no code generation in this SDK (no build_runner step), so every
// model parses itself. Two rules run through all of it:
//
//  1. Unknown fields are ignored, never fatal (the SDK specification §4, forward
//     compatibility with phase 2).
//  2. A field of an unexpected *type* degrades to the fallback instead of
//     throwing. A malformed number in an optional field must not turn a usable
//     fraud warning into a crash on someone's checkout screen.
//
// Not exported from `lib/tracive_sdk.dart` — internal plumbing.

/// Reads a string field. Returns `null` for a missing field or a non-string.
String? asString(Object? value) => value is String ? value : null;

/// Reads a non-null string field, degrading to [fallback].
String asStringOr(Object? value, String fallback) =>
    value is String ? value : fallback;

/// Reads an integer, accepting `1`, `1.0` and `"1"`. Returns `null` when the
/// value is missing or unparsable.
int? asIntOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// Reads an integer, degrading to [fallback] (0 by default).
int asInt(Object? value, {int fallback = 0}) => asIntOrNull(value) ?? fallback;

/// Reads a double, accepting `1`, `1.5` and `"1.5"`.
double? asDoubleOrNull(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

/// Reads a boolean, accepting `true`, `"true"`, `1` and `0`.
bool asBool(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final text = value.trim().toLowerCase();
    if (text == 'true') return true;
    if (text == 'false') return false;
  }
  return fallback;
}

/// Reads an instant and returns it in **UTC**.
///
/// Accepts an ISO-8601 string (the documented wire form), an epoch-millisecond
/// number, and a seconds-based `{"_seconds":…}` / `{"seconds":…}` map —
/// the last purely defensively, in case a Timestamp is ever serialised raw.
/// Anything else yields `null`.
DateTime? asUtcDateTime(Object? value) {
  if (value is DateTime) return value.toUtc();
  if (value is String) {
    final parsed = DateTime.tryParse(value.trim());
    return parsed?.toUtc();
  }
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
  }
  if (value is Map) {
    final seconds = asIntOrNull(value['_seconds'] ?? value['seconds']);
    if (seconds != null) {
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    }
  }
  return null;
}

/// Serialises an instant as ISO-8601 UTC (`…Z`), or `null`.
String? toIso8601Utc(DateTime? value) => value?.toUtc().toIso8601String();

/// Reads a list of strings, skipping non-string members. A missing or
/// non-list value yields an empty list.
List<String> asStringList(Object? value) {
  if (value is! List) return const <String>[];
  return <String>[
    for (final item in value)
      if (item is String) item,
  ];
}

/// Reads a JSON object, or `null`.
Map<String, Object?>? asJsonMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries) '${entry.key}': entry.value,
    };
  }
  return null;
}

/// Reads a list of JSON objects, skipping members that are not objects.
/// Returns `null` when the field is absent — which is meaningful: for
/// `topChronologies` and `comments`, absent means "not requested"
/// (`detail = minimal`), while `[]` means "requested, none found".
List<Map<String, Object?>>? asJsonMapList(Object? value) {
  if (value is! List) return null;
  return <Map<String, Object?>>[
    for (final item in value)
      if (asJsonMap(item) case final map?) map,
  ];
}

/// Reads a `currency -> amount` map, skipping unparsable entries.
Map<String, double> asAmountMap(Object? value) {
  final source = asJsonMap(value);
  if (source == null) return const <String, double>{};
  final out = <String, double>{};
  for (final entry in source.entries) {
    final amount = asDoubleOrNull(entry.value);
    if (amount != null) out[entry.key] = amount;
  }
  return out;
}

// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// Deep equality helpers for the value models.
//
// Hand-written rather than pulled from `package:collection` so that `lib/` has
// no package dependency at all. Not exported from `lib/tracive_sdk.dart`.

/// Element-wise equality for two nullable lists.
bool listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Entry-wise equality for two nullable maps.
bool mapEquals<K, V>(Map<K, V>? a, Map<K, V>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key)) return false;
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

/// Order-sensitive hash for a nullable list.
int listHash<T>(List<T>? items) {
  if (items == null) return 0;
  return Object.hashAll(items);
}

/// Order-insensitive hash for a nullable map.
int mapHash<K, V>(Map<K, V>? map) {
  if (map == null) return 0;
  return Object.hashAllUnordered(
    map.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );
}

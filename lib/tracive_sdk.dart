// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.

/// Tracive SDK for Dart and Flutter — check a phone number, e-mail address,
/// bank account, crypto address or social handle against Tracive's scam
/// reports.
///
/// **Status: phase 1, OAuth mode only. The backend Open API is not live yet.**
/// Everything here is built against a frozen contract; no
/// test in this repo talks to a network, and none can.
///
/// Two invariants worth knowing before you integrate:
///
/// * **There is no API-key parameter anywhere in this surface, in any mode.**
///   That is deliberate. Authentication is OAuth with PKCE, so no
///   long-lived secret is ever shipped inside your binary.
/// * **A miss is billed.** Every query builder validates before anything
///   leaves the device, and throws [TraciveQueryException] rather than send a
///   key that could not possibly match.
///
/// ```dart
/// final query = TraciveQuery.phone('+62 812 3456 7891');
/// // query.searchQueryIndex == 'PHONE_+6281234567891'
/// ```
///
/// This file is the public surface. Anything under `lib/src/` that is not
/// exported here is internal and may change without a major version bump.
library;

export 'src/cache/cache_database.dart';
export 'src/cache/cache_secret_store.dart';
export 'src/cache/check_cache.dart';
export 'src/cache/check_cache_store.dart';
export 'src/cache/sql_check_cache_store.dart';
export 'src/cache/tracive_cache.dart';
export 'src/client/clock.dart';
export 'src/client/http_package_transport.dart';
export 'src/client/http_transport.dart';
export 'src/client/retry_policy.dart';
export 'src/client/tracive_client.dart';
export 'src/exception.dart';
export 'src/model/auth_result.dart';
export 'src/model/billing.dart';
export 'src/model/cache_policy.dart';
export 'src/model/check_result.dart';
export 'src/model/chronology.dart';
export 'src/model/client_type.dart';
export 'src/model/comment.dart';
export 'src/model/credits_info.dart';
export 'src/model/detail.dart';
export 'src/model/origin.dart';
export 'src/model/profile_info.dart';
export 'src/model/risk_tier.dart';
export 'src/model/source.dart';
export 'src/model/tracive_environment.dart';
export 'src/model/tracive_mode.dart';
export 'src/oauth/auth_launcher.dart';
export 'src/oauth/token_store.dart';
export 'src/oauth/tracive_oauth.dart';
export 'src/query/normalizer.dart';
export 'src/query/query_type.dart';
export 'src/query/tracive_query.dart';
export 'src/query/unorm_normalizer.dart';

// Not exported on purpose:
//   src/model/json.dart                — tolerant JSON readers, internal
//   src/model/collection_equality.dart — deep-equality helpers, internal
//   src/query/document_id.dart         — record-key guard; an invariant of
//                                        key construction, not public surface
//                                        (the grammar test imports it directly)
//   src/query/js_string.dart           — JavaScript string semantics; an
//                                        implementation detail of the fold
//                                        (the grammar test imports it directly)
//   src/client/error_envelope.dart     — wire-error decoding, internal
//   src/oauth/pkce.dart                — PKCE pair generation, internal
//   src/oauth/authorize_url.dart       — URL and form building, internal
//   src/oauth/platform_default.dart    — conditional-import halves; the picked
//   src/oauth/platform_flutter.dart      implementation is reached through
//                                        TraciveOAuth's defaults

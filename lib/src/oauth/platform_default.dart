// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// Platform wiring for a **non-Flutter** Dart process.
//
// This is the stub half of a conditional import:
//
//     import 'platform_default.dart' if (dart.library.ui) 'platform_flutter.dart';
//
// `dart.library.ui` is defined exactly when `dart:ui` is available, i.e. under
// Flutter (every target, including web). So:
//
//   * `flutter run` / `flutter test`  -> `platform_flutter.dart`, which stores
//     tokens in the Keystore/Keychain via `flutter_secure_storage` and opens
//     URLs with `url_launcher`.
//   * `dart run` / `dart test`        -> this file.
//
// The point of the split is not portability for its own sake. It is that the
// whole OAuth state machine — PKCE, state validation, single-flight refresh,
// token rotation — can then be unit-tested by a plain `dart test` with no
// Flutter engine, no platform channels and no device. Those are the parts where
// a bug is silent and expensive; they should not be gated behind an emulator.

import 'auth_launcher.dart';
import 'token_store.dart';

/// The default [TokenStore] outside Flutter: in-memory.
///
/// There is no Keychain in a bare Dart VM, and inventing a file-backed store
/// here would break the "never … plain files" rule in the one place nobody would
/// think to look. Losing tokens at process exit is the honest behaviour.
///
/// A real app never reaches this: under Flutter the conditional import selects
/// `SecureStorageTokenStore` instead.
TokenStore createDefaultTokenStore() => InMemoryTokenStore();

/// The default [AuthLauncher] outside Flutter: one that cannot open anything.
///
/// A bare Dart process has no OS UI to hand a URL to, so `authorize()` reports
/// `AuthResult.appNotInstalled` rather than throwing.
AuthLauncher createDefaultAuthLauncher() => const UnsupportedAuthLauncher();

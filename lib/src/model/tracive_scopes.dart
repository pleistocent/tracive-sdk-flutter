// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.

/// The OAuth scopes the authorization server recognises, as their exact wire
/// strings.
///
/// Prefer these over string literals. A scope name is only ever validated by
/// the authorization server, and it rejects the whole consent request when it
/// does not recognise one — so a typo does not degrade gracefully into a
/// narrower grant. It is an integration that cannot authorize at all, and it
/// fails identically whichever name is wrong, with nothing local to debug.
///
/// The names are dot-separated, `resource.action`, and the resource is the
/// thing being acted on rather than the endpoint's path segment.
///
/// Ask for the narrowest set that works: an unused scope on the consent screen
/// is one more permission the user has to accept. This list is exactly the
/// scopes the calls in this SDK need, not the server's whole catalogue — a
/// constant for a call this SDK cannot make would only invite requesting a
/// permission nothing here would ever use.
///
/// ```dart
/// TraciveMode.oauth(
///   clientId: 'your-client-id',
///   redirectUri: 'https://your.app/oauth/callback',
///   scopes: const [TraciveScopes.scammerCheck, TraciveScopes.creditsRead],
/// );
/// ```
///
/// Constants rather than an enum, as `QueryRejectionReason` is and for the same
/// reason: the wire form has to stay byte-identical across the Tracive SDKs,
/// and a value whose text comes from its own identifier drifts the moment
/// somebody renames it.
abstract final class TraciveScopes {
  /// Run a scammer check. Required by `TraciveClient.checkScammer`.
  static const String scammerCheck = 'scammer.check';

  /// Read the user's remaining subscription credits. Required by
  /// `TraciveClient.credits`.
  static const String creditsRead = 'credits.read';

  /// Read the minimal user profile. Required by `TraciveClient.profile`.
  ///
  /// Which fields of `ProfileInfo` actually come back still depends on what the
  /// user granted, so a null field means "not shared" rather than "not set".
  static const String profileRead = 'profile.read';
}

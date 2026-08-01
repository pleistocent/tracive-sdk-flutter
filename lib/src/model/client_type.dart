// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.

/// Which half of the OAuth exchange the SDK performs.
enum ClientType {
  /// The SDK completes the PKCE exchange itself and stores the tokens.
  ///
  /// The right choice for a mobile app: it has no place to keep a client
  /// secret, which is exactly why PKCE exists.
  public('public'),

  /// The SDK stops at the authorization code and hands it back
  /// (`AuthResult.codeReceived`). The partner's **backend** exchanges it with
  /// its `client_secret`; see `doc/oauth.md`. No token ever reaches
  /// the device through this SDK.
  confidential('confidential');

  const ClientType(this.wireValue);

  /// Stable string form.
  final String wireValue;

  /// Decodes [wireValue] case-insensitively; unknown values fall back to
  /// [public], the mode that is safe without a secret.
  static ClientType fromWire(Object? value) {
    if (value is String && value.trim().toLowerCase() == 'confidential') {
      return ClientType.confidential;
    }
    return ClientType.public;
  }
}

// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// The OAuth flow — the SDK specification §6, "phase 1 core".
//
// NO NETWORK. Every token-endpoint answer is a literal `TraciveHttpResponse`
// and every URL is opened into `_FakeLauncher`, which records rather than
// launches. Nothing here has ever spoken to a server or to an operating system,
// and the file is written so that stays true.
//
// The four things in this file that are worth the most:
//
//   1. **RFC 7636 appendix B.** The one published (verifier -> challenge) pair.
//      If this vector passes, the S256 derivation is right; if it were wrong,
//      every exchange would fail *after* the user had already consented, which
//      is the worst possible moment to find out.
//   2. **State mismatch.** A redirect this SDK did not start is a redirect from
//      somebody else, and its `code` must be discarded unexamined.
//   3. **Single-flight refresh.** Two refreshes present the same rotated
//      refresh token twice, which is exactly what the server's reuse detection
//      punishes — by revoking the whole grant (§6).
//   4. **The clean install link.** No OAuth parameter may travel through an
//      install-attribution chain (§6 step 3).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:tracive_sdk/tracive_sdk.dart';
// Imported by path on purpose: PKCE generation and URL/form building are
// deliberately NOT part of the public barrel (see the "not exported" list in
// `lib/tracive_sdk.dart`). They are internal invariants of the OAuth flow, and
// this test exercises them directly.
import 'package:tracive_sdk/src/oauth/authorize_url.dart';
import 'package:tracive_sdk/src/oauth/pkce.dart';

/// A fixed instant, so nothing here depends on when it is run.
final DateTime _t0 = DateTime.utc(2026, 7, 31, 12);

void main() {
  // ---------------------------------------------------------------------------
  // PKCE — §6 step 1, RFC 7636.
  // ---------------------------------------------------------------------------
  group('PKCE', () {
    test('RFC 7636 appendix B vector', () {
      // The published test vector, verbatim:
      //   code_verifier  = dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk
      //   code_challenge = E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      const challenge = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';

      expect(PkcePair.challengeFor(verifier), challenge);
      expect(PkcePair.fromVerifier(verifier).codeChallenge, challenge);
    });

    test('the challenge is unpadded base64url of SHA-256, not hex', () {
      // A padded challenge, or a hex one, is a challenge the server will not
      // match — and the failure lands after consent.
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      final challenge = PkcePair.challengeFor(verifier);
      expect(challenge, isNot(contains('=')));
      expect(challenge, isNot(contains('+')));
      expect(challenge, isNot(contains('/')));
      expect(
        base64Url.decode('$challenge='),
        sha256.convert(ascii.encode(verifier)).bytes,
      );
    });

    test('S256 is the only method this SDK knows how to name', () {
      // `plain` gives a public mobile client no protection at all: the verifier
      // travels in the authorization request, so anything able to intercept the
      // redirect has already read it (RFC 7636 §7.2).
      expect(PkcePair.codeChallengeMethod, 'S256');
    });

    test('a generated verifier is in RFC 7636 grammar', () {
      final pair = PkcePair.generate(random: Random(7));
      expect(pair.codeVerifier.length, inInclusiveRange(43, 128));
      expect(pair.codeVerifier, matches(RegExp(r'^[A-Za-z0-9\-._~]+$')));
      expect(pair.codeChallenge, PkcePair.challengeFor(pair.codeVerifier));
    });

    test('two generated verifiers differ', () {
      expect(
        PkcePair.generate().codeVerifier,
        isNot(PkcePair.generate().codeVerifier),
      );
    });

    test('a verifier outside the grammar is rejected before it is sent', () {
      expect(() => PkcePair.fromVerifier('too-short'), throwsArgumentError);
      expect(
        () => PkcePair.fromVerifier('a' * 129),
        throwsArgumentError,
      );
      expect(
        () => PkcePair.fromVerifier('${'a' * 42}/'),
        throwsArgumentError,
      );
      expect(() => PkcePair.generate(verifierLength: 12), throwsArgumentError);
    });

    test('a rejected verifier is never printed', () {
      try {
        PkcePair.fromVerifier('${'a' * 42}/');
        fail('expected a rejection');
      } on ArgumentError catch (error) {
        expect(error.toString(), isNot(contains('aaaa')));
      }
      expect(
        PkcePair.generate(random: Random(1)).toString(),
        isNot(contains(PkcePair.generate(random: Random(1)).codeVerifier)),
      );
    });

    test('state is unguessable and unpadded', () {
      final state = PkcePair.generateState();
      expect(state.length, greaterThanOrEqualTo(40));
      expect(state, isNot(contains('=')));
      expect(state, isNot(PkcePair.generateState()));
    });
  });

  // ---------------------------------------------------------------------------
  // URL construction — §6 steps 3-4.
  // ---------------------------------------------------------------------------
  group('authorize URL', () {
    test('carries the RFC 6749 + RFC 7636 parameters', () {
      final url = buildAuthorizeUrl(
        environment: TraciveEnvironment.production,
        clientId: 'partner-client-id',
        redirectUri: 'https://partner.example/oauth/callback',
        scopes: const <String>['scammer.check', 'profile'],
        state: 'state-abc',
        codeChallenge: 'challenge-abc',
        partnerUserId: 'partner-user-9',
      );

      expect(url.origin, 'https://api.tracive.id');
      expect(url.path, '/v1/oauth/authorize');
      expect(url.queryParameters['response_type'], 'code');
      expect(url.queryParameters['client_id'], 'partner-client-id');
      expect(
        url.queryParameters['redirect_uri'],
        'https://partner.example/oauth/callback',
      );
      expect(url.queryParameters['scope'], 'scammer.check profile');
      expect(url.queryParameters['state'], 'state-abc');
      expect(url.queryParameters['code_challenge'], 'challenge-abc');
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(url.queryParameters['partner_user_id'], 'partner-user-9');
    });

    test('never says code_challenge_method=plain', () {
      final url = buildAuthorizeUrl(
        environment: TraciveEnvironment.sandbox,
        clientId: 'c',
        redirectUri: 'https://partner.example/cb',
        scopes: const <String>[],
        state: 's',
        codeChallenge: 'ch',
      );
      expect(url.query, isNot(contains('plain')));
      expect(url.queryParameters.containsKey('code_verifier'), isFalse);
    });

    test('the token exchange carries no client_secret', () {
      // A public client has none — that is what PKCE replaces — and a secret
      // shipped in a mobile binary is a published secret.
      final form = buildTokenExchangeForm(
        code: 'auth-code',
        codeVerifier: 'verifier',
        redirectUri: 'https://partner.example/cb',
        clientId: 'partner-client-id',
      );
      expect(form['grant_type'], 'authorization_code');
      expect(form['code_verifier'], 'verifier');
      expect(form.containsKey('client_secret'), isFalse);
      expect(form.keys.any((k) => k.contains('api_key')), isFalse);
    });
  });

  group('install link (§6 step 3)', () {
    test('carries no OAuth parameter of any kind', () {
      final url = buildInstallUrl(
        'https://tracive.chottu.link/app',
        clientId: 'partner-client-id',
      );
      for (final name in oauthParameterNames) {
        expect(
          url.queryParameters.containsKey(name),
          isFalse,
          reason: '"$name" would travel through the attribution chain',
        );
      }
      expect(url.queryParameters['utm_source'], 'partner-client-id');
    });

    test('strips OAuth parameters that were already on the constant', () {
      // A misconfigured link constant must not be able to defeat this.
      final url = buildInstallUrl(
        'https://tracive.chottu.link/app?state=leaked&code_challenge=leaked&ref=x',
        clientId: 'c',
      );
      expect(url.queryParameters.containsKey('state'), isFalse);
      expect(url.queryParameters.containsKey('code_challenge'), isFalse);
      expect(url.queryParameters['ref'], 'x');
      expect(url.toString(), isNot(contains('leaked')));
    });
  });

  // ---------------------------------------------------------------------------
  // authorize() — §6 steps 2-4.
  // ---------------------------------------------------------------------------
  group('authorize()', () {
    test('app missing: opens the install link and starts nothing', () async {
      final launcher = _FakeLauncher(installed: false);
      final store = InMemoryTokenStore();
      final oauth = _oauth(launcher: launcher, tokenStore: store);

      final result = await oauth.authorize();

      expect(result, isA<AuthAppNotInstalled>());
      expect(launcher.opened, hasLength(1));
      expect(launcher.opened.single.host, 'tracive.chottu.link');
      // §6 step 3: no PKCE pair, no state, nothing persisted. There is no
      // deferred resume — the user retries here after installing.
      expect(await store.readPending(), isNull);
      for (final name in oauthParameterNames) {
        expect(
          launcher.opened.single.queryParameters.containsKey(name),
          isFalse,
          reason: '"$name" would travel through the attribution chain',
        );
      }
    });

    test('the presence check runs before anything is generated', () async {
      // "before any redirect" (§6 step 2). If the order were reversed, a
      // verifier and state would exist for a flow that never started.
      final launcher = _FakeLauncher(installed: false);
      final oauth = _oauth(launcher: launcher);

      await oauth.authorize();

      expect(launcher.probed, hasLength(1));
      expect(launcher.probed.single.scheme, 'tracive');
      expect(
        launcher.probed.single.scheme,
        isNot('https'),
        reason: 'canOpen on https is always true — a browser is always there',
      );
    });

    test(
        'app present: opens the authorize URL externally and persists the '
        'pending record first', () async {
      final launcher = _FakeLauncher(installed: true);
      final store = InMemoryTokenStore();
      final oauth = _oauth(launcher: launcher, tokenStore: store);

      final result = await oauth.authorize();

      expect(result, isNull, reason: 'null means "the browser is open"');
      final url = launcher.opened.single;
      expect(url.path, '/v1/oauth/authorize');
      expect(url.queryParameters['code_challenge_method'], 'S256');

      final pending = await store.readPending();
      expect(pending, isNotNull);
      expect(url.queryParameters['state'], pending!.state);
      // The challenge on the wire must match the persisted verifier, or the
      // exchange fails after the user has already consented.
      expect(
        url.queryParameters['code_challenge'],
        PkcePair.challengeFor(pending.codeVerifier),
      );
      // The verifier itself never leaves the device at this stage.
      expect(url.toString(), isNot(contains(pending.codeVerifier)));
    });

    test('a refused launch rolls the pending record back', () async {
      // Otherwise a later stray redirect could be matched against a flow the
      // user never actually saw.
      final launcher = _FakeLauncher(installed: true, canLaunch: false);
      final store = InMemoryTokenStore();
      final oauth = _oauth(launcher: launcher, tokenStore: store);

      final result = await oauth.authorize();

      expect(result, isA<AuthFailed>());
      expect(await store.readPending(), isNull);
    });

    test('the shipped launcher uses externalApplication, never a WebView', () {
      // §6 step 4: App Links do not fire from an in-app WebView, and RFC 8252
      // §8.12 forbids an embedded user-agent anyway — the embedding app can
      // read what the user types into it.
      //
      // This is asserted against the source of `platform_flutter.dart` rather
      // than by driving `url_launcher`, because driving it means mocking a
      // plugin's private method channel, whose shape changes between minor
      // versions — a test that breaks on an unrelated upgrade teaches people to
      // delete it. What must never change is the literal below, and this fails
      // the moment it does.
      // Comment lines are stripped: that file *documents* why
      // `LaunchMode.inAppWebView` is wrong, and matching prose would make this
      // assertion fire on the explanation rather than on the code.
      final source = File('lib/src/oauth/platform_flutter.dart')
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      expect(source, contains('LaunchMode.externalApplication'));
      expect(source, isNot(contains('LaunchMode.inAppWebView')));
      expect(source, isNot(contains('LaunchMode.inAppBrowserView')));

      // And the interface offers no other way: one opening method, no mode
      // parameter, so a caller could not ask for a WebView even by mistake.
      const launcher = UnsupportedAuthLauncher();
      expect(launcher, isA<AuthLauncher>());
    });
  });

  // ---------------------------------------------------------------------------
  // handleCallback() — §6 steps 5-6.
  // ---------------------------------------------------------------------------
  group('handleCallback()', () {
    test('a state mismatch is discarded without reading the code', () async {
      final store = InMemoryTokenStore();
      final transport = _FakeTransport(
        (_) => fail('a hostile redirect must not reach the token endpoint'),
      );
      final oauth = _oauth(tokenStore: store, transport: transport);
      await _startFlow(oauth, store);

      final result = await oauth.handleCallback(
        Uri.parse(
          'https://partner.example/oauth/callback?code=stolen&state=not-ours',
        ),
      );

      expect(result, isA<AuthFailed>());
      expect(
          (result as AuthFailed).error, isA<TraciveStateMismatchException>());
      expect(transport.requests, isEmpty);
      // The genuine flow the user is still in the middle of must survive: a
      // stray redirect may not cancel it.
      expect(await store.readPending(), isNotNull);
    });

    test('a missing state is a mismatch, not a pass', () async {
      final store = InMemoryTokenStore();
      final oauth = _oauth(tokenStore: store);
      await _startFlow(oauth, store);

      final result = await oauth.handleCallback(
        Uri.parse('https://partner.example/oauth/callback?code=stolen'),
      );

      expect(
          (result as AuthFailed).error, isA<TraciveStateMismatchException>());
    });

    test('an undecodable redirect is a mismatch, not a crash', () async {
      final store = InMemoryTokenStore();
      final oauth = _oauth(tokenStore: store);
      await _startFlow(oauth, store);

      final result = await oauth.handleCallback(
        Uri.parse(
            'https://partner.example/oauth/callback?code=a%ZZ&state=b%ZZ'),
      );

      expect(result, isA<AuthFailed>());
      expect(
          (result as AuthFailed).error, isA<TraciveStateMismatchException>());
    });

    test('a redirect with no flow in progress fails cleanly', () async {
      final oauth = _oauth();
      final result = await oauth.handleCallback(
        Uri.parse('https://partner.example/oauth/callback?code=c&state=s'),
      );
      expect(result, isA<AuthFailed>());
    });

    test('an abandoned attempt expires', () async {
      final clock = MutableClock(_t0);
      final store = InMemoryTokenStore();
      final oauth = _oauth(tokenStore: store, clock: clock);
      final pending = await _startFlow(oauth, store);

      clock.advance(const Duration(hours: 2));
      final result = await oauth.handleCallback(
        _callback(pending.state, code: 'auth-code'),
      );

      expect(result, isA<AuthFailed>());
      expect(await store.readPending(), isNull);
    });

    test('access_denied is a denial, not a failure', () async {
      final store = InMemoryTokenStore();
      final oauth = _oauth(tokenStore: store);
      final pending = await _startFlow(oauth, store);

      final result = await oauth.handleCallback(
        Uri.parse(
          'https://partner.example/oauth/callback'
          '?error=access_denied&state=${pending.state}',
        ),
      );

      expect(result, isA<AuthDenied>());
      expect(await store.readPending(), isNull);
    });

    test('any other error surfaces with its code', () async {
      final store = InMemoryTokenStore();
      final oauth = _oauth(tokenStore: store);
      final pending = await _startFlow(oauth, store);

      final result = await oauth.handleCallback(
        Uri.parse(
          'https://partner.example/oauth/callback'
          '?error=server_error&error_description=upstream+down'
          '&state=${pending.state}',
        ),
      );

      expect(result, isA<AuthFailed>());
      expect((result as AuthFailed).error.code, 'server_error');
    });

    test('a redirect with no code at all fails rather than exchanging',
        () async {
      final store = InMemoryTokenStore();
      final transport = _FakeTransport((_) => fail('nothing to exchange'));
      final oauth = _oauth(tokenStore: store, transport: transport);
      final pending = await _startFlow(oauth, store);

      final result = await oauth.handleCallback(_callback(pending.state));

      expect(result, isA<AuthFailed>());
      expect(transport.requests, isEmpty);
    });

    test('public client: exchanges, stores the tokens, clears the flow',
        () async {
      final store = InMemoryTokenStore();
      final transport = _FakeTransport((_) => _ok(_tokenBody()));
      final oauth = _oauth(tokenStore: store, transport: transport);
      final pending = await _startFlow(oauth, store);

      final result = await oauth.handleCallback(
        _callback(pending.state, code: 'auth-code'),
      );

      expect(result, isA<AuthAuthorized>());
      expect(
        (result as AuthAuthorized).grantedScopes,
        <String>['scammer.check'],
      );

      final form = Uri.splitQueryString(transport.requests.single.body!);
      expect(transport.requests.single.url.path, '/v1/oauth/token');
      expect(form['grant_type'], 'authorization_code');
      expect(form['code'], 'auth-code');
      expect(form['code_verifier'], pending.codeVerifier);
      expect(form['redirect_uri'], pending.redirectUri);
      expect(form.containsKey('client_secret'), isFalse);

      final stored = await store.read();
      expect(stored?.accessToken, 'access-token-2');
      expect(stored?.refreshToken, 'refresh-token-2');
      expect(await store.readPending(), isNull);
    });

    test('the same redirect cannot be replayed', () async {
      final store = InMemoryTokenStore();
      var exchanges = 0;
      final transport = _FakeTransport((_) {
        exchanges++;
        return _ok(_tokenBody());
      });
      final oauth = _oauth(tokenStore: store, transport: transport);
      final pending = await _startFlow(oauth, store);
      final redirect = _callback(pending.state, code: 'auth-code');

      expect(await oauth.handleCallback(redirect), isA<AuthAuthorized>());
      expect(await oauth.handleCallback(redirect), isA<AuthFailed>());
      expect(exchanges, 1);
    });

    test('a rejected exchange surfaces as AuthFailed, not as a throw',
        () async {
      final store = InMemoryTokenStore();
      final transport = _FakeTransport(
        (_) => TraciveHttpResponse(
          statusCode: 400,
          body: jsonEncode(<String, Object?>{'error': 'invalid_grant'}),
        ),
      );
      final oauth = _oauth(tokenStore: store, transport: transport);
      final pending = await _startFlow(oauth, store);

      final result = await oauth.handleCallback(
        _callback(pending.state, code: 'auth-code'),
      );

      expect(result, isA<AuthFailed>());
      expect((result as AuthFailed).error, isA<TraciveGrantRevokedException>());
      expect(await store.read(), isNull);
    });

    test('confidential client: hands the code back and exchanges nothing',
        () async {
      // §4.2: the partner's backend holds the client secret and performs the
      // exchange. No token ever reaches the device through this SDK.
      final store = InMemoryTokenStore();
      final transport = _FakeTransport(
        (_) => fail('a confidential client must not exchange on-device'),
      );
      final oauth = _oauth(
        tokenStore: store,
        transport: transport,
        clientType: ClientType.confidential,
      );
      final pending = await _startFlow(oauth, store);

      final result = await oauth.handleCallback(
        _callback(pending.state, code: 'auth-code'),
      );

      expect(result, isA<AuthCodeReceived>());
      final received = result as AuthCodeReceived;
      expect(received.code, 'auth-code');
      expect(received.codeVerifier, pending.codeVerifier);
      expect(received.redirectUri, 'https://partner.example/oauth/callback');
      expect(transport.requests, isEmpty);
      expect(await store.read(), isNull);
      expect(await store.readPending(), isNull);
      // The code and the verifier are bearer credentials until exchanged.
      expect(received.toString(), isNot(contains('auth-code')));
      expect(received.toString(), isNot(contains(pending.codeVerifier)));
    });

    test('parameters delivered in the fragment are read too', () async {
      final store = InMemoryTokenStore();
      final transport = _FakeTransport((_) => _ok(_tokenBody()));
      final oauth = _oauth(tokenStore: store, transport: transport);
      final pending = await _startFlow(oauth, store);

      final result = await oauth.handleCallback(
        Uri.parse(
          'https://partner.example/oauth/callback'
          '#code=auth-code&state=${pending.state}',
        ),
      );

      expect(result, isA<AuthAuthorized>());
    });
  });

  // ---------------------------------------------------------------------------
  // Tokens — §6.
  // ---------------------------------------------------------------------------
  group('access tokens', () {
    test('nothing stored is a typed error, not an empty bearer', () async {
      final oauth = _oauth();
      await expectLater(
        oauth.ensureAccessToken(),
        throwsA(isA<TraciveInvalidTokenException>()),
      );
    });

    test('a live token is returned untouched', () async {
      final transport = _FakeTransport((_) => fail('no refresh was needed'));
      final oauth = _oauth(
        tokenStore: _authorizedStore(),
        transport: transport,
      );
      expect(await oauth.ensureAccessToken(), 'access-token-1');
      expect(transport.requests, isEmpty);
    });

    test('an expired token is refreshed before the request goes out', () async {
      final clock = MutableClock(_t0);
      final store = _authorizedStore();
      final transport = _FakeTransport((_) => _ok(_tokenBody()));
      final oauth = _oauth(
        tokenStore: store,
        transport: transport,
        clock: clock,
      );

      clock.advance(const Duration(hours: 2));
      expect(await oauth.ensureAccessToken(), 'access-token-2');
      expect(transport.requests, hasLength(1));
    });

    test('the skew treats an about-to-expire token as expired', () async {
      // A token with four seconds left will be rejected by the time the request
      // lands, and that rejection costs a round trip and a refresh anyway.
      final clock = MutableClock(_t0);
      final transport = _FakeTransport((_) => _ok(_tokenBody()));
      final oauth = _oauth(
        tokenStore: _authorizedStore(),
        transport: transport,
        clock: clock,
      );

      clock.advance(const Duration(minutes: 59, seconds: 30));
      expect(await oauth.ensureAccessToken(), 'access-token-2');
    });

    test('expired with no refresh token is ExpiredToken, not a silent retry',
        () async {
      final clock = MutableClock(_t0);
      final store = InMemoryTokenStore(
        tokens: TraciveTokens(
          accessToken: 'access-token-1',
          expiresAt: _t0.add(const Duration(minutes: 1)),
        ),
      );
      final oauth = _oauth(tokenStore: store, clock: clock);

      clock.advance(const Duration(hours: 1));
      await expectLater(
        oauth.ensureAccessToken(),
        throwsA(isA<TraciveExpiredTokenException>()),
      );
    });
  });

  group('refresh (§6)', () {
    test('rotates the refresh token and stores the pair in one write',
        () async {
      // Writing them separately could strand a new access token beside a spent
      // refresh token, which is indistinguishable from a stolen-token replay.
      final store = _authorizedStore();
      final oauth = _oauth(
        tokenStore: store,
        transport: _FakeTransport((_) => _ok(_tokenBody())),
      );

      final tokens = await oauth.refreshTokens();

      expect(tokens.accessToken, 'access-token-2');
      expect(tokens.refreshToken, 'refresh-token-2');
      expect(store.writeCount, 1);
    });

    test('keeps the old refresh token when the server omits a new one',
        () async {
      final store = _authorizedStore();
      final oauth = _oauth(
        tokenStore: store,
        transport: _FakeTransport(
          (_) => _ok(
            jsonEncode(<String, Object?>{
              'access_token': 'access-token-2',
              'expires_in': 3600,
            }),
          ),
        ),
      );

      final tokens = await oauth.refreshTokens();
      expect(tokens.refreshToken, 'refresh-token-1');
    });

    test('concurrent refreshes make exactly one token request', () async {
      final store = _authorizedStore();
      final transport = _FakeTransport((_) async {
        // Yield, so a second refresh would have every chance to slip in.
        await Future<void>.delayed(Duration.zero);
        return _ok(_tokenBody());
      });
      final oauth = _oauth(tokenStore: store, transport: transport);

      final results = await Future.wait<TraciveTokens>(<Future<TraciveTokens>>[
        oauth.refreshTokens(staleAccessToken: 'access-token-1'),
        oauth.refreshTokens(staleAccessToken: 'access-token-1'),
        oauth.refreshTokens(staleAccessToken: 'access-token-1'),
        oauth.refreshTokens(staleAccessToken: 'access-token-1'),
      ]);

      expect(transport.requests, hasLength(1));
      for (final tokens in results) {
        expect(tokens.accessToken, 'access-token-2');
      }
      expect(store.writeCount, 1);
    });

    test('a 401 arriving after someone else refreshed does not refresh again',
        () async {
      final store = _authorizedStore();
      var calls = 0;
      final transport = _FakeTransport((_) {
        calls++;
        return _ok(_tokenBody());
      });
      final oauth = _oauth(tokenStore: store, transport: transport);

      await oauth.refreshTokens(staleAccessToken: 'access-token-1');
      // A request that was already in flight now reports its 401. The token it
      // used is stale; the store has moved on.
      final second = await oauth.refreshTokens(
        staleAccessToken: 'access-token-1',
      );

      expect(calls, 1);
      expect(second.accessToken, 'access-token-2');
    });

    test('a later refresh is allowed once the latch has cleared', () async {
      final store = _authorizedStore();
      var calls = 0;
      final transport = _FakeTransport((_) {
        calls++;
        return _ok(_tokenBody());
      });
      final oauth = _oauth(tokenStore: store, transport: transport);

      await oauth.refreshTokens();
      await oauth.refreshTokens();

      expect(calls, 2, reason: 'single-flight is per flight, not once ever');
    });

    test('invalid_grant clears the tokens and must not be retried', () async {
      // This is the wire shape refresh-token reuse detection takes. Retrying is
      // what it is looking for.
      final store = _authorizedStore();
      final transport = _FakeTransport(
        (_) => TraciveHttpResponse(
          statusCode: 400,
          body: jsonEncode(<String, Object?>{
            'error': 'invalid_grant',
            'error_description': 'refresh token already used',
          }),
        ),
      );
      final oauth = _oauth(tokenStore: store, transport: transport);

      await expectLater(
        oauth.refreshTokens(),
        throwsA(isA<TraciveGrantRevokedException>()),
      );
      expect(await store.read(), isNull);
      expect(transport.requests, hasLength(1));
    });

    test('a refresh token is never presented to the server twice', () async {
      // The single-flight latch protects the window between reading the latch
      // and setting it. It does NOT protect the store read that precedes it: a
      // read that begins before an earlier flight writes its new tokens, but
      // whose Future completes after that flight has finished and cleared the
      // latch, hands this caller a refresh token that has already been spent.
      //
      // Presenting a refresh token twice is exactly what reuse detection looks
      // for, and the server answers it by revoking the whole grant — the user
      // is silently signed out of the partner integration.
      //
      // The store below is the adversarial shape: it captures the value before
      // its own await and delivers it late. A real secure store can do this,
      // because its native side may read the keychain before another flight's
      // write lands while its reply arrives afterwards.
      final store = _StaleSnapshotStore(
        TraciveTokens(
          accessToken: 'access-token-1',
          refreshToken: 'refresh-token-1',
          expiresAt: _t0.add(const Duration(hours: 1)),
          grantedScopes: const <String>['scammer.check'],
        ),
      )..readDelays.addAll(const <Duration>[
          Duration.zero, // caller A reads instantly
          Duration(milliseconds: 150), // caller B's read outlives A's refresh
        ]);
      final presented = <String>[];
      final transport = _FakeTransport((request) async {
        presented.add(
          RegExp(r'refresh_token=([^&]+)')
                  .firstMatch(request.body ?? '')
                  ?.group(1) ??
              '?',
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return _ok(_tokenBody());
      });
      final oauth = _oauth(tokenStore: store, transport: transport);

      final a = oauth.refreshTokens(staleAccessToken: 'access-token-1');
      final b = oauth.refreshTokens(staleAccessToken: 'access-token-1');
      for (final f in <Future<TraciveTokens>>[a, b]) {
        await f.then<Object?>((v) => v, onError: (Object e) => e);
      }

      expect(
        presented.where((t) => t == 'refresh-token-1'),
        hasLength(1),
        reason: 'the same refresh token was presented more than once',
      );
    });

    test('a snapshot older than one rotation is still refused', () async {
      // The reuse guard used to remember exactly ONE spent refresh token. After
      // a second rotation the marker held R2 and no longer recognised R1, so a
      // caller whose store read had been in flight across both rotations fell
      // straight through and put R1 back on the wire — which is the signal
      // reuse detection revokes the whole grant for.
      //
      // Reproduced naturally rather than by forcing the store: the stale caller
      // issues its read FIRST, that read captures the pre-rotation snapshot,
      // and it is held open until two other callers have each rotated.
      final store = _StaleSnapshotStore(_tokensNumbered(1));
      final staleReadResolves = Completer<void>();
      store.readGates.add(staleReadResolves);
      final transport = _RotatingTokenTransport();
      final oauth = _oauth(tokenStore: store, transport: transport);

      // The caller with the doomed snapshot. Its read is gated open.
      final stale = oauth.refreshTokens();

      // Two complete rotations happen while that read is outstanding.
      await oauth.refreshTokens();
      await oauth.refreshTokens();
      expect(
        transport.presented,
        <String>['refresh-token-1', 'refresh-token-2'],
        reason: 'two rotations, each spending the token before it',
      );
      expect((await store.read())!.refreshToken, 'refresh-token-3');

      staleReadResolves.complete();
      final resolved = await stale;

      expect(
        transport.presented,
        <String>['refresh-token-1', 'refresh-token-2'],
        reason: 'the stale caller must not have presented a spent token',
      );
      expect(
        resolved.refreshToken,
        'refresh-token-3',
        reason: 'it should be handed what the store actually holds',
      );
    });

    test('the token presented is the stored one, never the caller snapshot',
        () async {
      // The guard above is a bounded history, so on its own it can only reach
      // back so far. The invariant that does not depend on how far back it
      // reaches is this one: whatever a caller's snapshot says, a flight sends
      // the refresh token the store holds when the flight actually runs. Ten
      // rotations is comfortably past any history a guard would keep.
      final store = _StaleSnapshotStore(_tokensNumbered(1));
      final staleReadResolves = Completer<void>();
      store.readGates.add(staleReadResolves);
      final transport = _RotatingTokenTransport();
      final oauth = _oauth(tokenStore: store, transport: transport);

      final stale = oauth.refreshTokens();
      for (var i = 0; i < 10; i++) {
        await oauth.refreshTokens();
      }
      expect((await store.read())!.refreshToken, 'refresh-token-11');

      staleReadResolves.complete();
      final resolved = await stale;

      expect(
        transport.presented.toSet(),
        hasLength(transport.presented.length),
        reason: 'no refresh token may be presented to the server twice',
      );
      expect(
        resolved.refreshToken,
        (await store.read())!.refreshToken,
        reason: 'the caller is handed the live pair, not a resurrected one',
      );
    });

    test('a failed refresh does not wedge the latch', () async {
      final store = _authorizedStore();
      var calls = 0;
      final transport = _FakeTransport((_) {
        calls++;
        return calls == 1
            ? TraciveHttpResponse(statusCode: 503, body: '{}')
            : _ok(_tokenBody());
      });
      final oauth = _oauth(tokenStore: store, transport: transport);

      await expectLater(
        oauth.refreshTokens(),
        throwsA(isA<TraciveServerException>()),
      );
      expect((await oauth.refreshTokens()).accessToken, 'access-token-2');
    });

    test('no refresh token at all is a typed error', () async {
      final store = InMemoryTokenStore(
        tokens: const TraciveTokens(accessToken: 'access-token-1'),
      );
      final oauth = _oauth(tokenStore: store);
      await expectLater(
        oauth.refreshTokens(),
        throwsA(isA<TraciveInvalidTokenException>()),
      );
    });

    test('a token response with no access_token is a Server error', () async {
      final oauth = _oauth(
        tokenStore: _authorizedStore(),
        transport: _FakeTransport(
          (_) => _ok(jsonEncode(<String, Object?>{'expires_in': 3600})),
        ),
      );
      await expectLater(
        oauth.refreshTokens(),
        throwsA(isA<TraciveServerException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Sign-out — §6.
  // ---------------------------------------------------------------------------
  group('signOut()', () {
    test('revokes the refresh token, then clears locally', () async {
      final store = _authorizedStore();
      final transport = _FakeTransport(
        (_) => TraciveHttpResponse(statusCode: 200, body: '{}'),
      );
      final oauth = _oauth(tokenStore: store, transport: transport);

      await oauth.signOut();

      final request = transport.requests.single;
      expect(request.url.path, '/v1/oauth/revoke');
      final form = Uri.splitQueryString(request.body!);
      // Revoking the refresh token ends the grant; revoking one access token
      // would leave it alive and re-issuable.
      expect(form['token'], 'refresh-token-1');
      expect(form['token_type_hint'], 'refresh_token');
      expect(await store.read(), isNull);
    });

    test('clears locally even when the revoke call fails', () async {
      // A user who taps sign-out on a train with no signal must still be signed
      // out on the device.
      final store = _authorizedStore();
      final oauth = _oauth(
        tokenStore: store,
        transport: _FakeTransport(
          (_) => throw const _SimulatedTimeout(),
        ),
      );

      await oauth.signOut();

      expect(await store.read(), isNull);
      expect(store.clearCount, 1);
    });

    test('clears locally even when the server rejects the revoke', () async {
      final store = _authorizedStore();
      final oauth = _oauth(
        tokenStore: store,
        transport: _FakeTransport(
          (_) => TraciveHttpResponse(statusCode: 500, body: '{}'),
        ),
      );

      await oauth.signOut();
      expect(await store.read(), isNull);
    });

    test('signing out when never signed in sends nothing', () async {
      final transport = _FakeTransport(
        (_) => fail('there is no grant to revoke'),
      );
      await _oauth(transport: transport).signOut();
      expect(transport.requests, isEmpty);
    });

    test('a refresh already in flight cannot undo it', () async {
      // Signing out while a background check is retrying a 401 is an ordinary
      // user action, and signOut() makes a network call of its own, which
      // widens the window. If the refresh's response is allowed to land in the
      // store afterwards, the user is signed out of the UI and still holds a
      // live grant on a phone they may be about to hand over — exactly what
      // signOut()'s own doc comment says must never happen.
      final store = _authorizedStore();
      final refreshReachedTheServer = Completer<void>();
      final releaseTheRefresh = Completer<void>();
      final transport = _FakeTransport((request) async {
        if (request.url.path.endsWith('/oauth/token')) {
          if (!refreshReachedTheServer.isCompleted) {
            refreshReachedTheServer.complete();
          }
          await releaseTheRefresh.future;
          return _ok(_tokenBody());
        }
        return TraciveHttpResponse(statusCode: 200, body: '{}');
      });
      final oauth = _oauth(tokenStore: store, transport: transport);

      final refresh = oauth.refreshTokens();
      await refreshReachedTheServer.future;

      await oauth.signOut();
      expect(await store.read(), isNull, reason: 'signOut cleared the store');

      releaseTheRefresh.complete();
      await expectLater(
        refresh,
        throwsA(isA<TraciveInvalidTokenException>()),
        reason: 'the caller must be told its refresh was discarded',
      );

      expect(
        await store.read(),
        isNull,
        reason: 'the in-flight refresh must not write tokens back',
      );
      expect(await oauth.isAuthorized, isFalse);
    });

    test('a token exchange already in flight cannot undo it', () async {
      // Same hole on the other write path: handleCallback() exchanges the code
      // and then writes. A sign-out that lands in between must win, or the
      // grant the user just revoked comes back.
      final store = InMemoryTokenStore();
      final exchangeReachedTheServer = Completer<void>();
      final releaseTheExchange = Completer<void>();
      final transport = _FakeTransport((request) async {
        if (request.url.path.endsWith('/oauth/token')) {
          if (!exchangeReachedTheServer.isCompleted) {
            exchangeReachedTheServer.complete();
          }
          await releaseTheExchange.future;
          return _ok(_tokenBody());
        }
        return TraciveHttpResponse(statusCode: 200, body: '{}');
      });
      final oauth = _oauth(tokenStore: store, transport: transport);
      final pending = await _startFlow(oauth, store);

      final callback = oauth.handleCallback(
        _callback(pending.state, code: 'auth-code'),
      );
      await exchangeReachedTheServer.future;

      await oauth.signOut();
      releaseTheExchange.complete();

      expect(await callback, isA<AuthFailed>());
      expect(await store.read(), isNull);
      expect(await oauth.isAuthorized, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Through TraciveClient — the path an app actually takes.
  // ---------------------------------------------------------------------------
  group('through TraciveClient', () {
    test('authorize/handleCallback/signOut delegate to the flow', () async {
      final launcher = _FakeLauncher(installed: true);
      final store = InMemoryTokenStore();
      final transport = _FakeTransport((request) {
        if (request.url.path.endsWith('/oauth/token')) return _ok(_tokenBody());
        return TraciveHttpResponse(statusCode: 200, body: '{}');
      });
      final client = TraciveClient(
        mode: _oauthMode,
        transport: transport,
        tokenStore: store,
        launcher: launcher,
        clock: MutableClock(_t0),
        retryPolicy: RetryPolicy.none,
      );

      expect(await client.authorize(), isNull);
      final pending = (await store.readPending())!;
      final result = await client.handleCallback(
        _callback(pending.state, code: 'auth-code'),
      );
      expect(result, isA<AuthAuthorized>());
      expect(await client.oauth!.isAuthorized, isTrue);
      expect(await client.oauth!.grantedScopes(), <String>['scammer.check']);

      await client.signOut();
      expect(await client.oauth!.isAuthorized, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Privacy. Every one of these values ends up in a crash report if it is ever
  // printed, and a refresh token in a crash report is a refresh token in
  // somebody else's hands.
  // ---------------------------------------------------------------------------
  group('privacy', () {
    test('tokens are never printed', () {
      const tokens = TraciveTokens(
        accessToken: 'super-secret-access-token',
        refreshToken: 'super-secret-refresh-token',
      );
      expect(tokens.toString(), isNot(contains('super-secret-access-token')));
      expect(tokens.toString(), isNot(contains('super-secret-refresh-token')));
    });

    test('a pending authorization prints neither verifier nor state', () {
      final pending = PendingAuthorization(
        state: 'state-secret',
        codeVerifier: 'verifier-secret',
        redirectUri: 'https://partner.example/cb',
        createdAt: _t0,
      );
      expect(pending.toString(), isNot(contains('state-secret')));
      expect(pending.toString(), isNot(contains('verifier-secret')));
    });

    test('the flow itself prints no credential', () {
      final oauth = _oauth(tokenStore: _authorizedStore());
      expect(oauth.toString(), isNot(contains('access-token-1')));
      expect(oauth.toString(), isNot(contains('refresh-token-1')));
    });
  });
}

// -----------------------------------------------------------------------------
// Fixtures and fakes.
// -----------------------------------------------------------------------------

const TraciveMode _oauthMode = TraciveMode.oauth(
  clientId: 'partner-client-id',
  redirectUri: 'https://partner.example/oauth/callback',
);

TraciveOAuth _oauth({
  AuthLauncher? launcher,
  TokenStore? tokenStore,
  HttpTransport? transport,
  MutableClock? clock,
  ClientType clientType = ClientType.public,
}) =>
    TraciveOAuth(
      mode: TraciveOAuthMode(
        clientId: 'partner-client-id',
        redirectUri: 'https://partner.example/oauth/callback',
        clientType: clientType,
      ),
      transport: transport ?? _FakeTransport((_) => fail('unexpected request')),
      tokenStore: tokenStore ?? InMemoryTokenStore(),
      launcher: launcher ?? _FakeLauncher(installed: true),
      clock: clock ?? MutableClock(_t0),
      // Seeded on purpose: these tests assert *relationships* between the verifier,
      // the challenge and the state, never their literal values. Production uses
      // Random.secure().
      random: Random(20260731),
    );

InMemoryTokenStore _authorizedStore() => InMemoryTokenStore(
      tokens: TraciveTokens(
        accessToken: 'access-token-1',
        refreshToken: 'refresh-token-1',
        expiresAt: _t0.add(const Duration(hours: 1)),
        grantedScopes: const <String>['scammer.check'],
      ),
    );

/// Runs `authorize()` and returns the persisted pending record.
Future<PendingAuthorization> _startFlow(
  TraciveOAuth oauth,
  InMemoryTokenStore store,
) async {
  final started = await oauth.authorize();
  expect(started, isNull, reason: 'the flow should have opened the browser');
  return (await store.readPending())!;
}

Uri _callback(String state, {String? code}) => Uri.parse(
      'https://partner.example/oauth/callback'
      '?state=$state${code == null ? '' : '&code=$code'}',
    );

/// The Nth generation of a rotating pair, so a test can say which one it means.
TraciveTokens _tokensNumbered(int generation) => TraciveTokens(
      accessToken: 'access-token-$generation',
      refreshToken: 'refresh-token-$generation',
      expiresAt: _t0.add(const Duration(hours: 1)),
      grantedScopes: const <String>['scammer.check'],
    );

String _tokenBody() => jsonEncode(<String, Object?>{
      'access_token': 'access-token-2',
      'refresh_token': 'refresh-token-2',
      'token_type': 'Bearer',
      'expires_in': 3600,
      'scope': 'scammer.check',
    });

TraciveHttpResponse _ok(String body) => TraciveHttpResponse(
      statusCode: 200,
      headers: const <String, String>{'content-type': 'application/json'},
      body: body,
    );

class _SimulatedTimeout implements Exception {
  const _SimulatedTimeout();

  @override
  String toString() => 'simulated socket timeout';
}

class _FakeTransport extends HttpTransport {
  _FakeTransport(this.handler);

  final FutureOr<TraciveHttpResponse> Function(TraciveHttpRequest) handler;
  final List<TraciveHttpRequest> requests = <TraciveHttpRequest>[];

  @override
  Future<TraciveHttpResponse> send(TraciveHttpRequest request) async {
    requests.add(request);
    return handler(request);
  }
}

/// Records what the SDK asked the operating system to do, and answers.
///
/// It has no `openInWebView`, because [AuthLauncher] has no such method — §6
/// step 4 and RFC 8252 §8.12 rule it out, and the interface is shaped so a
/// caller could not ask for one even by mistake.
class _FakeLauncher extends AuthLauncher {
  _FakeLauncher({required this.installed, this.canLaunch = true});

  /// Whether the presence probe reports the Tracive app.
  final bool installed;

  /// Whether the OS accepts what it is handed.
  final bool canLaunch;

  final List<Uri> probed = <Uri>[];
  final List<Uri> opened = <Uri>[];

  @override
  Future<bool> canOpen(Uri url) async {
    probed.add(url);
    return installed;
  }

  @override
  Future<bool> openExternally(Uri url) async {
    opened.add(url);
    return canLaunch;
  }
}

/// A token endpoint that rotates: every refresh answers with the next
/// generation of the pair, and records which refresh token it was given.
///
/// Lets a test say "this token was presented twice" as a fact about the wire
/// rather than as a fact about the SDK's internal state.
class _RotatingTokenTransport extends HttpTransport {
  final List<TraciveHttpRequest> requests = <TraciveHttpRequest>[];

  /// Every refresh token handed to the server, in order.
  final List<String> presented = <String>[];

  int _generation = 1;

  @override
  Future<TraciveHttpResponse> send(TraciveHttpRequest request) async {
    requests.add(request);
    presented.add(
      RegExp(r'refresh_token=([^&]+)')
              .firstMatch(request.body ?? '')
              ?.group(1) ??
          '?',
    );
    _generation++;
    return _ok(
      jsonEncode(<String, Object?>{
        'access_token': 'access-token-$_generation',
        'refresh_token': 'refresh-token-$_generation',
        'token_type': 'Bearer',
        'expires_in': 3600,
        'scope': 'scammer.check',
      }),
    );
  }
}

/// A [TokenStore] that captures its value BEFORE its own await and delivers it
/// late, so a read issued early can resolve with a snapshot that is already out
/// of date. Models real secure storage, whose native read may execute before
/// another write lands while its reply arrives after.
class _StaleSnapshotStore extends TokenStore {
  _StaleSnapshotStore(this._tokens);

  TraciveTokens? _tokens;
  PendingAuthorization? _pending;

  /// Delay applied to the Nth call to [read].
  final List<Duration> readDelays = <Duration>[];

  /// Gate held by the Nth call to [read]. A non-null entry takes precedence
  /// over [readDelays] and holds that read open until the test completes it,
  /// which is how a read can be made to span an arbitrary number of rotations
  /// without depending on wall-clock timing.
  final List<Completer<void>?> readGates = <Completer<void>?>[];
  int _reads = 0;

  @override
  Future<TraciveTokens?> read() async {
    final snapshot = _tokens;
    final index = _reads++;
    final gate = index < readGates.length ? readGates[index] : null;
    if (gate != null) {
      await gate.future;
      return snapshot;
    }
    await Future<void>.delayed(
      index < readDelays.length ? readDelays[index] : Duration.zero,
    );
    return snapshot;
  }

  @override
  Future<void> write(TraciveTokens tokens) async => _tokens = tokens;

  @override
  Future<void> clear() async => _tokens = null;

  @override
  Future<PendingAuthorization?> readPending() async => _pending;

  @override
  Future<void> writePending(PendingAuthorization? pending) async =>
      _pending = pending;
}

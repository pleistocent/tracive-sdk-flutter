// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// The OAuth flow — "phase 1 core".
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
//      punishes — by revoking the whole grant.
//   4. **The clean install link.** No OAuth parameter may travel through an
//      install-attribution chain.

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

/// An override of the install link, used to prove that overriding still works.
/// Left unset, the SDK opens [TraciveOAuth.defaultInstallUrl].
const String _installUrl = 'https://install.example/app';

void main() {
  // ---------------------------------------------------------------------------
  // PKCE — step 2 of the flow, RFC 7636.
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
  // URL construction — steps 3 and 4 of the flow.
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

      // The authorize host is NOT the API host. `api.tracive.id` answers the
      // data calls; only `tracive.id` is claimed by the Tracive app as an App
      // Link, so only it opens the app rather than a web page. This assertion
      // used to say `https://api.tracive.id` + `/v1/oauth/authorize`, and it
      // pinned a URL no Tracive build has ever claimed — the consent flow
      // could not complete at all, and no test in this repo could see it
      // because the test agreed with the bug.
      expect(url.origin, 'https://tracive.id');
      expect(url.path, '/oauth/authorize');
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
      // As written, not trimmed. The value is stored on the grant and echoed
      // back to the partner in `grant.revoked`; trimming it here would hand
      // them back something other than what they sent. This SDK trimmed it
      // until 2 August 2026 — the same defect its idempotency key had.
      expect(url.queryParameters['partner_user_id'], 'partner-user-9');
      // %20, not `+`. Dart's `queryParameters` emits `+` for a space; the other three SDKs emit
      // %20, and the app reads this field with getQueryParameter, which does not turn `+` back
      // into a space. A value we echo to the partner must survive the round trip unchanged.
      final spaced = buildAuthorizeUrl(
        environment: TraciveEnvironment.production,
        clientId: 'c',
        redirectUri: 'https://partner.example/cb',
        scopes: const <String>['a b'],
        state: 's',
        codeChallenge: 'ch',
        partnerUserId: 'user nine',
      );
      expect(spaced.query, contains('partner_user_id=user%20nine'));
      expect(spaced.query, isNot(contains('+')));
    });

    test('never says code_challenge_method=plain', () {
      final url = buildAuthorizeUrl(
        environment: TraciveEnvironment.sandbox,
        clientId: 'c',
        redirectUri: 'https://partner.example/cb',
        scopes: const <String>[],
        state: 's',
        codeChallenge: 'ch',
        partnerUserId: 'partner-user-1',
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

  group('the clean install link', () {
    test('is the cross-SDK default when nothing is configured', () {
      expect(
        TraciveOAuth.defaultInstallUrl,
        'https://tracive.chottu.link/install',
      );
      expect(_oauth().installUrl, TraciveOAuth.defaultInstallUrl);
      expect(
        TraciveClient(
          mode: _oauthMode,
          transport: _FakeTransport((_) => fail('unexpected request')),
          tokenStore: InMemoryTokenStore(),
          launcher: _FakeLauncher(installed: true),
        ).oauth!.installUrl,
        TraciveOAuth.defaultInstallUrl,
      );
    });

    test('omitting the parameter entirely still cannot throw', () {
      // The blank check below runs in the constructor, so this is the case it
      // must never catch: an app that never mentions `installUrl` at all. The
      // helper above always passes something, so this constructs both types
      // with the argument genuinely absent.
      late final TraciveOAuth oauth;
      expect(
        () => oauth = TraciveOAuth(
          mode: TraciveOAuthMode(
            partnerUserId: 'partner-user-1',
            clientId: 'partner-client-id',
            redirectUri: 'https://partner.example/oauth/callback',
          ),
          transport: _FakeTransport((_) => fail('unexpected request')),
          tokenStore: InMemoryTokenStore(),
          launcher: _FakeLauncher(installed: true),
        ),
        returnsNormally,
      );
      expect(oauth.installUrl, TraciveOAuth.defaultInstallUrl);

      late final TraciveClient client;
      expect(
        () => client = TraciveClient(
          mode: _oauthMode,
          transport: _FakeTransport((_) => fail('unexpected request')),
          tokenStore: InMemoryTokenStore(),
          launcher: _FakeLauncher(installed: true),
        ),
        returnsNormally,
      );
      expect(client.oauth!.installUrl, TraciveOAuth.defaultInstallUrl);
    });

    test('carries ref and utm_source, and nothing else', () {
      final url = buildInstallUrl(
        TraciveOAuth.defaultInstallUrl,
        clientId: 'partner-client-id',
      );
      expect(url.origin, 'https://tracive.chottu.link');
      expect(url.path, '/install');
      // `ref` is the PARTNER's identifier, not the end user's, and it ships in
      // the app binary already.
      expect(url.queryParameters['ref'], 'partner-client-id');
      expect(url.queryParameters['utm_source'], 'tracive-sdk-flutter');
      expect(url.queryParameters.keys.toSet(), <String>{'ref', 'utm_source'});
    });

    test('omits ref when there is no client id to name', () {
      for (final clientId in <String?>[null, '', '   ']) {
        final url = buildInstallUrl(
          TraciveOAuth.defaultInstallUrl,
          clientId: clientId,
        );
        expect(url.queryParameters.containsKey('ref'), isFalse);
        expect(url.queryParameters['utm_source'], 'tracive-sdk-flutter');
      }
    });

    test('carries no OAuth parameter of any kind', () {
      // The hard invariant: this link transits a third-party link service, so
      // not one of these may ride along.
      final url = buildInstallUrl(
        TraciveOAuth.defaultInstallUrl,
        clientId: 'partner-client-id',
      );
      for (final name in oauthParameterNames) {
        expect(
          url.queryParameters.containsKey(name),
          isFalse,
          reason: '"$name" would travel through the attribution chain',
        );
      }
      for (final name in <String>[
        'state',
        'code_challenge',
        'code_verifier',
        'partner_user_id',
        'redirect_uri',
        'scope',
      ]) {
        expect(
          oauthParameterNames.contains(name),
          isTrue,
          reason: '"$name" must be on the stripped list',
        );
      }
    });

    test('strips OAuth parameters that were already on the constant', () {
      // A misconfigured link constant must not be able to defeat this, so try
      // it with every one of them on the configured URL at once.
      final planted = Uri.parse(_installUrl).replace(
        queryParameters: <String, String>{
          for (final name in oauthParameterNames) name: 'leaked',
          'ref': 'x',
        },
      );
      final url = buildInstallUrl(planted.toString(), clientId: 'c');
      for (final name in oauthParameterNames) {
        expect(
          url.queryParameters.containsKey(name),
          isFalse,
          reason: '"$name" survived from the configured URL',
        );
      }
      // The client id wins over whatever `ref` the configured link carried.
      expect(url.queryParameters['ref'], 'c');
      expect(url.toString(), isNot(contains('leaked')));
    });

    test('an override is used instead of the default', () {
      final url = buildInstallUrl(_installUrl, clientId: 'c');
      expect(url.origin, 'https://install.example');
      expect(url.path, '/app');
      expect(url.queryParameters['ref'], 'c');
    });

    test('a blank override is rejected at construction', () {
      // Only `null` means "not configured", and `null` still means the default:
      // absence is a real answer. A blank string is not absence — it is a
      // configured value, and it is almost always a build variable that did not
      // expand.
      //
      // The comparison that decides this is against *silently substituting the
      // default*, and that comparison still holds: substituting would send a
      // partner's users to a link the partner never configured, and nobody
      // could tell, because `authorize()` returns the same
      // `AuthAppNotInstalled` either way and this SDK logs nothing. What does
      // not hold is the conclusion that used to be drawn from it — that passing
      // the blank through is therefore safe. It is not the partner's link
      // either. `buildInstallUrl('')` yields
      // `?ref=…&utm_source=…`, a schemeless relative string no OS will open,
      // and `buildInstallUrl('   ')` yields `%20%20%20?ref=…`. Both are broken,
      // and both fail late: only for a user without the Tracive app, only after
      // shipping, and with no error anywhere. So the right question is not
      // "default or blank" but "which failure is loud". Rejecting at
      // construction is the loudest point available — once, in host-app code,
      // on every run, during development, before an end user exists.
      //
      // `blank_install_url` is a cross-SDK contract token. It is asserted here
      // as a literal rather than through a constant, so that renaming or
      // re-spelling the constant fails this test instead of quietly redefining
      // the contract.
      for (final blank in <String>['', '   ', '\t\n']) {
        expect(
          () => _oauth(installUrl: blank),
          throwsA(
            isA<ArgumentError>()
                .having((ArgumentError e) => e.name, 'name', 'installUrl')
                .having(
                  (ArgumentError e) => e.message.toString(),
                  'message',
                  contains('blank_install_url'),
                ),
          ),
          reason: 'TraciveOAuth accepted a blank install URL',
        );
        expect(
          () => TraciveClient(
            mode: _oauthMode,
            installUrl: blank,
            transport: _FakeTransport((_) => fail('unexpected request')),
            tokenStore: InMemoryTokenStore(),
            launcher: _FakeLauncher(installed: true),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (ArgumentError e) => e.message.toString(),
              'message',
              contains('blank_install_url'),
            ),
          ),
          reason: 'the client normalised a blank away instead of rejecting it',
        );
      }
    });

    test('a non-blank override is used verbatim, however odd', () {
      // This is emphatically NOT URL validation. The only thing rejected is
      // "nothing at all"; a wrong-but-present value is the partner's to own,
      // and a check clever enough to judge it would be a check that rejects
      // link formats Tracive has not issued yet.
      for (final odd in <String>[
        '  not-a-url  ',
        'https://install.example/app',
        'tracive-install://open',
      ]) {
        expect(_oauth(installUrl: odd).installUrl, odd);
        expect(
          TraciveClient(
            mode: _oauthMode,
            installUrl: odd,
            transport: _FakeTransport((_) => fail('unexpected request')),
            tokenStore: InMemoryTokenStore(),
            launcher: _FakeLauncher(installed: true),
          ).oauth!.installUrl,
          odd,
          reason: 'the value was trimmed or rewritten on the way through',
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // authorize() — steps 1 to 3 of the flow.
  // ---------------------------------------------------------------------------
  group('authorize()', () {
    test('app missing: opens the install link and starts nothing', () async {
      final launcher = _FakeLauncher(installed: false);
      final store = InMemoryTokenStore();
      final oauth = _oauth(launcher: launcher, tokenStore: store);

      final result = await oauth.authorize();

      expect(result, isA<AuthAppNotInstalled>());
      expect(launcher.opened, hasLength(1));
      final opened = launcher.opened.single;
      expect(opened.host, Uri.parse(TraciveOAuth.defaultInstallUrl).host);
      expect(opened.path, '/install');
      expect(opened.queryParameters['ref'], 'partner-client-id');
      expect(opened.queryParameters['utm_source'], 'tracive-sdk-flutter');
      // No PKCE pair, no state, nothing persisted. There is no
      // deferred resume — the user retries here after installing.
      expect(await store.readPending(), isNull);
      for (final name in oauthParameterNames) {
        expect(
          opened.queryParameters.containsKey(name),
          isFalse,
          reason: '"$name" would travel through the attribution chain',
        );
      }
    });

    test('an overridden install link is the one opened', () async {
      final launcher = _FakeLauncher(installed: false);
      final oauth = _oauth(launcher: launcher, installUrl: _installUrl);

      await oauth.authorize();

      expect(launcher.opened.single.host, Uri.parse(_installUrl).host);
    });

    test('no blank install link ever reaches the OS', () async {
      // There is no `authorize()` case for a blank override any more, and this
      // test says why rather than leaving a gap where one used to be: the flow
      // cannot be built with one. What a blank used to hand the launcher was a
      // schemeless string — `?ref=…&utm_source=…` — which opens nothing and
      // reports nothing, so the mistake surfaced only for a user without the
      // Tracive app, long after the build that caused it. The rejection now
      // happens in the constructor, which is checked in "the clean install
      // link" group; this asserts the consequence, which is that the launcher
      // is never handed such a URL because no such flow exists.
      expect(() => _oauth(installUrl: ''), throwsArgumentError);

      // What does reach the OS for an app that configured nothing is the
      // shared default, in full.
      final launcher = _FakeLauncher(installed: false);
      final result = await _oauth(launcher: launcher).authorize();

      expect(result, isA<AuthAppNotInstalled>());
      final opened = launcher.opened.single;
      expect(opened.hasScheme, isTrue);
      expect(opened.host, Uri.parse(TraciveOAuth.defaultInstallUrl).host);
    });

    test('the presence check runs before anything is generated', () async {
      // "before any redirect". If the order were reversed, a
      // verifier and state would exist for a flow that never started.
      final launcher = _FakeLauncher(installed: false);
      final oauth = _oauth(launcher: launcher);

      await oauth.authorize();

      expect(launcher.probed, hasLength(1));
      expect(
        launcher.probed.single.scheme,
        isNot('https'),
        reason: 'canOpen on https is always true — a browser is always there',
      );
      // The whole URL, not just the scheme. Asserting the scheme alone is what
      // let `tracive://authorize` survive here: Android resolves a probe by
      // intent-filter matching, the app registers no custom-scheme host named
      // `authorize`, and the probe therefore answered "not installed" on every
      // Android device including the ones holding the app. The scheme was
      // right the whole time; the host was the bug, and nothing looked at it.
      expect(launcher.probed.single.toString(), 'tracive://');
    });

    test('probes the sandbox scheme when the environment is sandbox', () async {
      final launcher = _FakeLauncher(installed: true);
      final oauth = _oauth(
        launcher: launcher,
        environment: TraciveEnvironment.sandbox,
      );

      await oauth.authorize();

      // Sandbox and production are separate worlds: neither build claims the
      // other's scheme, so probing `tracive://` on a device carrying only the
      // sandbox app reports "not installed" for an app that is right there.
      expect(launcher.probed.single.toString(), 'tracivedev://');
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
      // Host and path together: what the app claims is the whole origin, and
      // asserting the path alone is what let the wrong host survive here.
      expect(url.origin, 'https://tracive.id');
      expect(url.path, '/oauth/authorize');
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
      // App Links do not fire from an in-app WebView, and RFC 8252
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
  // handleCallback() — steps 5 and 6 of the flow.
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

    // The three tests below pin the pending window at ten minutes. They are
    // separate on purpose: a single test would stop at its first failed
    // assertion, so the boundary halves would never run on the very drift they
    // exist to catch.
    //
    // The window is a cross-SDK contract — every Tracive SDK expires a pending
    // authorization after the same ten minutes — and nothing here used to
    // assert the number at all, which is how this SDK came to ship thirty while
    // its siblings shipped ten. The two-hour test above passes under either
    // value, so it pins nothing.
    test('the shipped pending window is ten minutes', () {
      expect(PendingAuthorization.defaultMaxAge, const Duration(minutes: 10));
      expect(_oauth().pendingAuthorizationMaxAge, const Duration(minutes: 10));
    });

    test('a redirect just inside the window is still exchanged', () async {
      final clock = MutableClock(_t0);
      final store = InMemoryTokenStore();
      final oauth = _oauth(
        tokenStore: store,
        transport: _FakeTransport((_) => _ok(_tokenBody())),
        clock: clock,
      );
      final pending = await _startFlow(oauth, store);

      clock.advance(const Duration(minutes: 9, seconds: 59));
      final result = await oauth.handleCallback(
        _callback(pending.state, code: 'auth-code'),
      );

      expect(result, isA<AuthAuthorized>());
    });

    test(
        'a forged redirect against a stale attempt reports the mismatch, '
        'not the staleness', () async {
      // The ordering test. `state` is compared before expiry, so a URL that
      // fails the state check gets the same answer whatever the record's age —
      // and, crucially, does not erase it. Checking expiry first would answer
      // "expired" here, which tells whoever sent the URL that an attempt exists
      // and has gone stale, and would clear the record on the way out, handing
      // any installed app a way to cancel a consent in progress.
      final clock = MutableClock(_t0);
      final store = InMemoryTokenStore();
      final oauth = _oauth(
        tokenStore: store,
        transport: _FakeTransport(
          (_) => fail('a forged redirect must not reach the token endpoint'),
        ),
        clock: clock,
      );
      await _startFlow(oauth, store);

      clock.advance(const Duration(minutes: 30));
      final result = await oauth.handleCallback(
        _callback('not-the-state', code: 'auth-code'),
      );

      expect(result, isA<AuthFailed>());
      expect((result as AuthFailed).error, isA<TraciveStateMismatchException>(),
          reason: 'a forgery learns nothing about the record it did not match');
      expect(await store.readPending(), isNotNull,
          reason: 'and cannot cancel the attempt by being late about it');
    });

    test('a genuine late redirect still reports the expiry, not a mismatch',
        () async {
      // The other half. Putting `state` first would be worth nothing if it cost
      // the accurate message for the honest case — it does not, because that
      // message only means anything once the state has matched.
      final clock = MutableClock(_t0);
      final store = InMemoryTokenStore();
      final oauth = _oauth(
        tokenStore: store,
        transport: _FakeTransport(
          (_) => fail('an expired attempt must not reach the token endpoint'),
        ),
        clock: clock,
      );
      final pending = await _startFlow(oauth, store);

      clock.advance(const Duration(minutes: 30));
      final result = await oauth.handleCallback(
        _callback(pending.state, code: 'auth-code'),
      );

      expect(result, isA<AuthFailed>());
      expect(
          (result as AuthFailed).error, isA<TraciveInvalidRequestException>());
      expect(await store.readPending(), isNull,
          reason: 'an attempt the user really did abandon is erased');
    });

    test('a redirect just outside the window is refused, unread', () async {
      final clock = MutableClock(_t0);
      final store = InMemoryTokenStore();
      final oauth = _oauth(
        tokenStore: store,
        transport: _FakeTransport(
          (_) => fail('an expired attempt must not reach the token endpoint'),
        ),
        clock: clock,
      );
      final pending = await _startFlow(oauth, store);

      clock.advance(const Duration(minutes: 10, seconds: 1));
      final result = await oauth.handleCallback(
        _callback(pending.state, code: 'auth-code'),
      );

      expect(result, isA<AuthFailed>());
      expect(
          (result as AuthFailed).error, isA<TraciveInvalidRequestException>());
      // The verifier is erased rather than left on the device.
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

    // The one non-denial code the server actually sends, kept as its own case.
    //
    // The test above already covers the mechanism with a stand-in code. This pins the code the
    // backend really emits, for the two situations that produce it: the partner organisation has
    // not accepted the current terms, and the device has hit its daily connection limit to this
    // partner. Neither is a refusal by this user, and a host that branches on the exception type
    // rather than the code cannot tell them apart — hence the assertion is on `code`.
    //
    // The description matters as much as the code: it carries the server's own wording, including
    // the reset time, which is what a partner app shows instead of 'you declined'. The attempt is
    // spent, so the user authorizes again rather than resuming.
    test('temporarily_unavailable reaches the host with its code', () async {
      final store = InMemoryTokenStore();
      final oauth = _oauth(tokenStore: store);
      final pending = await _startFlow(oauth, store);

      final result = await oauth.handleCallback(
        Uri.parse(
          'https://partner.example/oauth/callback'
          '?error=temporarily_unavailable'
          '&error_description=daily+connection+limit+for+this+device+reached'
          '&state=${pending.state}',
        ),
      );

      expect(result, isA<AuthFailed>());
      final error = (result as AuthFailed).error;
      expect(error.code, 'temporarily_unavailable');
      expect(
        error.message,
        contains('daily connection limit for this device reached'),
      );
      expect(await store.readPending(), isNull);
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
      // The partner's backend holds the client secret and performs the
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
  // Tokens.
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

    test(
        'an expired token is sent as it is — the 401 refreshes it, not a timer',
        () async {
      // Refresh is reactive, and only reactive. The stored token goes out even
      // when `expiresAt` has passed; the server is the authority on whether it
      // is still good, and its `401 expired_token` is what triggers the refresh.
      final clock = MutableClock(_t0);
      final store = _authorizedStore();
      final transport = _FakeTransport((_) => fail('nothing should refresh'));
      final oauth = _oauth(
        tokenStore: store,
        transport: transport,
        clock: clock,
      );

      clock.advance(const Duration(hours: 2));
      expect(await oauth.ensureAccessToken(), 'access-token-1');
      expect(transport.requests, isEmpty);
    });

    test('a device clock running fast cannot make this refresh', () async {
      // This is the case the removed skew got wrong. The comparison could only
      // ever be against the device's clock, so a phone ten minutes ahead
      // declared every token expired and refreshed on every single call — and
      // with rotating refresh tokens, every rotation is another chance to trip
      // reuse detection and sign the user out.
      final clock = MutableClock(_t0);
      final transport = _FakeTransport((_) => fail('nothing should refresh'));
      final oauth = _oauth(
        tokenStore: _authorizedStore(),
        transport: transport,
        clock: clock,
      );

      // Thirty seconds before the stored expiry: the old 60-second skew called
      // this expired and refreshed here.
      clock.advance(const Duration(minutes: 59, seconds: 30));
      expect(await oauth.ensureAccessToken(), 'access-token-1');
      expect(transport.requests, isEmpty);
    });

    test('an expired token with no refresh token is still handed over',
        () async {
      // There is nothing to refresh, but there is also nothing to decide: the
      // token is sent, and the server answers. Refusing here would be this SDK
      // making an expiry judgement on a clock it does not own — the very thing
      // that was removed.
      final clock = MutableClock(_t0);
      final store = InMemoryTokenStore(
        tokens: TraciveTokens(
          accessToken: 'access-token-1',
          expiresAt: _t0.add(const Duration(minutes: 1)),
        ),
      );
      final oauth = _oauth(tokenStore: store, clock: clock);

      clock.advance(const Duration(hours: 1));
      expect(await oauth.ensureAccessToken(), 'access-token-1');
    });

    test('an empty access token beside a refresh token is repaired, not sent',
        () async {
      // Reachable only from a damaged storage record, since the token endpoint
      // response is rejected when it carries no `access_token`. It must not
      // become `Bearer ` on the wire — nothing downstream of here can turn it
      // away, because an empty bearer is answered `invalid_token`, which is
      // terminal, rather than `expired_token`, which refreshes.
      //
      // Refusing it outright is not the answer either: the refresh token beside
      // it is a live credential, and spending it costs one round trip where
      // consent costs the user a trip through the Tracive app.
      final store = InMemoryTokenStore(
        tokens: const TraciveTokens(
          accessToken: '',
          refreshToken: 'refresh-token-1',
        ),
      );
      final transport = _FakeTransport((_) => _ok(_tokenBody()));
      final oauth = _oauth(tokenStore: store, transport: transport);

      expect(await oauth.ensureAccessToken(), 'access-token-2');

      // Exactly one request, and it is the refresh carrying the stored refresh
      // token. No bearer of any kind travelled, so certainly no empty one.
      expect(transport.requests, hasLength(1));
      final refresh = transport.requests.single;
      expect(refresh.url.path, endsWith('/oauth/token'));
      expect(refresh.body, contains('refresh_token=refresh-token-1'));
      expect(refresh.header('authorization'), isNull);
      // The damaged record is repaired in the store, so the next call needs no
      // refresh at all.
      expect((await store.read())?.accessToken, 'access-token-2');
      expect((await store.read())?.refreshToken, 'refresh-token-2');
    });

    test('a damaged record still counts as authorized, because it is',
        () async {
      // `isAuthorized` gates the host app's routing. If it answered false for a
      // record `ensureAccessToken` can repair, the app would send the user back
      // through consent to replace a grant that was never lost — and the repair
      // below would never get the chance to run.
      final repairable = _oauth(
        tokenStore: InMemoryTokenStore(
          tokens: const TraciveTokens(
            accessToken: '',
            refreshToken: 'refresh-token-1',
          ),
        ),
        transport: _FakeTransport((_) => fail('nothing should be sent')),
      );
      expect(await repairable.isAuthorized, isTrue);

      // A record holding neither credential is genuinely not signed in.
      final empty = _oauth(
        tokenStore: InMemoryTokenStore(
          tokens: const TraciveTokens(accessToken: ''),
        ),
        transport: _FakeTransport((_) => fail('nothing should be sent')),
      );
      expect(await empty.isAuthorized, isFalse);
    });

    test('isUsable is what the store and isAuthorized both ask', () {
      // The shipped secure store cannot be exercised here — its test harness
      // deliberately touches no platform channel — so the decision it makes is
      // pinned as the predicate instead of as a round trip through the plugin.
      const both = TraciveTokens(accessToken: 'at', refreshToken: 'rt');
      const accessOnly = TraciveTokens(accessToken: 'at');
      const refreshOnly = TraciveTokens(accessToken: '', refreshToken: 'rt');
      const neither = TraciveTokens(accessToken: '');

      expect(both.isUsable, isTrue);
      expect(accessOnly.isUsable, isTrue);
      expect(refreshOnly.isUsable, isTrue,
          reason: 'a live refresh token is a real credential');
      expect(neither.isUsable, isFalse);
    });

    test('"present" means non-blank, not merely non-empty', () {
      // Whitespace is damage of exactly the same kind as the empty string, and
      // the rule was written as "empty" — which is how `'   '` went on
      // surviving every guard that `''` had been taught to fail.
      for (final blank in <String>[' ', '   ', '\t', '\n', ' \t\n ']) {
        expect(TraciveTokens(accessToken: blank).hasAccessToken, isFalse,
            reason: 'a blank access token is not an access token');
        expect(
          TraciveTokens(accessToken: 'at', refreshToken: blank).canRefresh,
          isFalse,
          reason: 'a blank refresh token cannot refresh anything',
        );
        expect(
          TraciveTokens(accessToken: blank, refreshToken: blank).isUsable,
          isFalse,
          reason: 'two blanks are not a grant',
        );
      }
    });

    test('a whitespace-only access token is repaired, not sent', () async {
      // One step past the empty-token case. `Bearer    ` is answered
      // `invalid_token`, which this SDK treats as terminal, so nothing
      // downstream can turn it away: the damaged record would fail every call
      // from then on and fail by telling the user to authorize again.
      //
      // The stale token handed to the refresh is the damaged value itself, not
      // a hard-coded `''`. `refreshTokens` compares the stored token against
      // that argument to spot a caller who lost a race, so passing `''` here
      // would make this caller look raced and hand the damaged record straight
      // back — a repair that returns a token, and the token is the broken one.
      final store = InMemoryTokenStore(
        tokens: const TraciveTokens(
          accessToken: '   ',
          refreshToken: 'refresh-token-1',
        ),
      );
      final transport = _FakeTransport((_) => _ok(_tokenBody()));
      final oauth = _oauth(tokenStore: store, transport: transport);

      expect(await oauth.ensureAccessToken(), 'access-token-2');

      expect(transport.requests, hasLength(1));
      final refresh = transport.requests.single;
      expect(refresh.url.path, endsWith('/oauth/token'));
      expect(refresh.body, contains('refresh_token=refresh-token-1'));
      expect(refresh.header('authorization'), isNull);
      expect((await store.read())?.accessToken, 'access-token-2');
    });

    test(
        'a whitespace-only access token with nothing to spend is a typed error',
        () async {
      final oauth = _oauth(
        tokenStore: InMemoryTokenStore(
          tokens: const TraciveTokens(accessToken: '   '),
        ),
        transport: _FakeTransport((_) => fail('nothing should be sent')),
      );

      await expectLater(
        oauth.ensureAccessToken(),
        throwsA(isA<TraciveInvalidTokenException>()),
      );
    });

    test('a whitespace-only refresh token is refused before it is presented',
        () async {
      // Refusing locally is the whole point. Presenting a refresh token marks
      // it spent *before* the answer comes back, and a request that dies
      // without one leaves the marker in place on purpose — so offering a value
      // that could never have been a credential buys a certain rejection and
      // then lets one timeout refuse a grant that was never renewable.
      //
      // The transport answers normally rather than calling `fail()`. A `fail()`
      // inside a transport is caught by `_postForm` and re-thrown as a Tracive
      // exception, so the refusal this test is named after would look identical
      // to a request that went out and came back badly — the assertion has to
      // be that nothing was sent, not that something threw.
      final transport = _FakeTransport((_) => _ok(_tokenBody()));
      final oauth = _oauth(
        tokenStore: InMemoryTokenStore(
          tokens: const TraciveTokens(
            accessToken: 'access-token-1',
            refreshToken: '   ',
          ),
        ),
        transport: transport,
      );

      await expectLater(
        oauth.refreshTokens(),
        throwsA(isA<TraciveInvalidTokenException>()),
      );
      expect(
        transport.requests,
        isEmpty,
        reason: 'a blank refresh token must never reach the token endpoint',
      );
    });

    test('an empty access token with no refresh token is still a typed error',
        () async {
      // Nothing to spend, so there is nothing to recover: the user really does
      // have to authorize again. Still not `Bearer ` on the wire.
      final oauth = _oauth(
        tokenStore: InMemoryTokenStore(
          tokens: const TraciveTokens(accessToken: ''),
        ),
        transport: _FakeTransport((_) => fail('nothing should be sent')),
      );

      await expectLater(
        oauth.ensureAccessToken(),
        throwsA(isA<TraciveInvalidTokenException>()),
      );
    });
  });

  group('TraciveTokens.isExpiredAt', () {
    // Nothing in the SDK calls this; it is kept for an integrator who wants to
    // look at `expiresAt` and decide for themselves.
    test('answers on the instant, with no skew of its own', () {
      final tokens = TraciveTokens(
        accessToken: 'access-token-1',
        expiresAt: _t0.add(const Duration(hours: 1)),
      );

      expect(
        tokens.isExpiredAt(_t0.add(const Duration(minutes: 59, seconds: 59))),
        isFalse,
        reason: 'one second before expiry is not expired',
      );
      expect(
        tokens.isExpiredAt(_t0.add(const Duration(hours: 1))),
        isTrue,
        reason: 'the expiry instant itself is already expired',
      );
    });

    test('an unknown expiry is not expired', () {
      const tokens = TraciveTokens(accessToken: 'access-token-1');
      expect(tokens.isExpiredAt(DateTime.utc(2099)), isFalse);
    });
  });

  group('refresh', () {
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
        presented.add(_presentedRefreshToken(request));
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

    test('a refresh that times out never presents its token again', () async {
      // A timeout is indistinguishable from a success whose response was lost:
      // the server may already have rotated this refresh token. Sending it
      // again would be reuse, and reuse revokes the whole grant. Re-authorizing
      // is the strictly better outcome — if the server did consume the token,
      // re-authorization was required anyway and this avoids a revocation; if
      // it did not, the cost is one consent the user did not strictly need.
      final store = _authorizedStore();
      var calls = 0;
      final transport = _FakeTransport((_) {
        calls++;
        if (calls == 1) throw const _SimulatedTimeout();
        return _ok(_tokenBody());
      });
      final oauth = _oauth(tokenStore: store, transport: transport);

      await expectLater(
        oauth.refreshTokens(),
        throwsA(isA<TraciveInvalidTokenException>()),
        reason: 'the caller is told to re-authorize, not to retry',
      );
      await expectLater(
        oauth.refreshTokens(),
        throwsA(isA<TraciveInvalidTokenException>()),
      );
      expect(
        calls,
        1,
        reason: 'the possibly-consumed token must not go back on the wire',
      );
    });

    test('a 200 the SDK cannot decode still counts the token as spent',
        () async {
      // The other half of the same rule. A 2xx means the server DID issue a new
      // pair, so the old refresh token is definitely consumed — even if this
      // SDK cannot make sense of what came back.
      final store = _authorizedStore();
      var calls = 0;
      final transport = _FakeTransport((_) {
        calls++;
        return calls == 1 ? _ok('{"expires_in":3600}') : _ok(_tokenBody());
      });
      final oauth = _oauth(tokenStore: store, transport: transport);

      await expectLater(
        oauth.refreshTokens(),
        throwsA(isA<TraciveServerException>()),
      );
      await expectLater(
        oauth.refreshTokens(),
        throwsA(isA<TraciveInvalidTokenException>()),
      );
      expect(calls, 1);
    });

    test('a refresh token the server re-issued unchanged stays usable',
        () async {
      // RFC 6749 §6 does not oblige a token endpoint to rotate: answering with
      // the same refresh token is conforming. A 2xx is therefore not evidence
      // that the token was consumed, and treating it as evidence left the very
      // string the server had just re-issued sitting in the spent history — so
      // the NEXT refresh was refused here, in this process, for the life of the
      // process, and the user was sent back through consent by the guard that
      // exists to keep them from being signed out.
      final store = _authorizedStore();
      var calls = 0;
      final transport = _FakeTransport((_) {
        calls++;
        return _ok(
          jsonEncode(<String, Object?>{
            'access_token': 'access-token-${calls + 1}',
            // The same value every time, on purpose.
            'refresh_token': 'refresh-token-1',
            'token_type': 'Bearer',
            'expires_in': 3600,
            'scope': 'scammer.check',
          }),
        );
      });
      final oauth = _oauth(tokenStore: store, transport: transport);

      expect((await oauth.refreshTokens()).accessToken, 'access-token-2');
      expect((await oauth.refreshTokens()).accessToken, 'access-token-3');

      expect(
        transport.requests.map(_presentedRefreshToken),
        <String>['refresh-token-1', 'refresh-token-1'],
        reason: 'the second refresh must reach the server, not be refused here',
      );
      expect((await store.read())!.refreshToken, 'refresh-token-1');
    });

    test('a refresh token carried forward stays usable', () async {
      // The other shape of the same server behaviour, and the commoner one:
      // RFC 6749 §6 lets the response omit `refresh_token` to mean "keep the
      // one you have", which `TraciveTokens.fromTokenResponse` honours by
      // carrying the previous value forward. The token then in the store is
      // again the exact string this flow marked spent.
      final store = _authorizedStore();
      var calls = 0;
      final transport = _FakeTransport((_) {
        calls++;
        return _ok(
          jsonEncode(<String, Object?>{
            'access_token': 'access-token-${calls + 1}',
            'expires_in': 3600,
          }),
        );
      });
      final oauth = _oauth(tokenStore: store, transport: transport);

      expect((await oauth.refreshTokens()).refreshToken, 'refresh-token-1');
      expect((await oauth.refreshTokens()).accessToken, 'access-token-3');

      expect(
        transport.requests.map(_presentedRefreshToken),
        <String>['refresh-token-1', 'refresh-token-1'],
        reason: 'the second refresh must reach the server, not be refused here',
      );
    });

    test('a rotation the store refused to keep is not presented again',
        () async {
      // The release above is guarded on the returned refresh token being the
      // one that went out, and the guard is the whole safety of it. Drop the
      // condition and a genuine rotation releases the token it rotated away
      // from — which bites whenever the new pair does not reach the store,
      // because the store then still hands the old, spent token to the next
      // refresh. Presenting it is the reuse this history exists to prevent, and
      // the server answers reuse by revoking the entire grant.
      //
      // A store that reads fine and cannot write is what a Keystore entry that
      // will not re-encrypt after a backup restore looks like.
      final store = _RefusingStore(onWrite: true, tokens: _tokensNumbered(1));
      final transport = _RotatingTokenTransport();
      final oauth = _oauth(tokenStore: store, transport: transport);

      await expectLater(oauth.refreshTokens(), throwsA(isA<StateError>()));
      await expectLater(
        oauth.refreshTokens(),
        throwsA(isA<TraciveInvalidTokenException>()),
        reason: 'the stored token is spent; the answer is to authorize again',
      );

      expect(
        transport.presented,
        <String>['refresh-token-1'],
        reason: 'the token the server rotated away from must not go out twice',
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

    test('a whitespace-only access_token is rejected, not stored', () async {
      // Blank counts as absent on the way in as well as on the way out.
      // Storing it would manufacture, on the healthy path, exactly the damaged
      // record that `ensureAccessToken` exists to repair on the sick one — and
      // it would do it while spending the rotation that was the grant's one
      // renewable credential.
      final store = _authorizedStore();
      final oauth = _oauth(
        tokenStore: store,
        transport: _FakeTransport(
          (_) => _ok(
            jsonEncode(<String, Object?>{
              'access_token': '   ',
              'refresh_token': 'refresh-token-2',
              'expires_in': 3600,
            }),
          ),
        ),
      );

      await expectLater(
        oauth.refreshTokens(),
        throwsA(isA<TraciveServerException>()),
      );
      expect(
        (await store.read())?.accessToken,
        'access-token-1',
        reason: 'a malformed reply must not overwrite the stored grant',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Sign-out.
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
        installUrl: _installUrl,
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

  // ---------------------------------------------------------------------------
  // Whose redirect is this?
  //
  // Hosts are encouraged to route their whole deep-link surface through
  // handleCallback, and any app on the device can register a scheme and fire a
  // URL at yours. Without an ownership check, an unrelated link — a marketing
  // link, a share intent, a stray redirect from another app — is judged as an
  // OAuth redirect, and the honest verdict on a link carrying no `state` is a
  // state mismatch: an error raised at the user about a consent that is
  // perfectly fine.
  //
  // The check narrows what is accepted, so both directions are pinned here: a
  // foreign URL is refused, and the genuine redirect still completes.
  // ---------------------------------------------------------------------------
  group('callback ownership', () {
    test('a URL on somebody else\'s redirect is not ours', () async {
      final store = InMemoryTokenStore();
      final oauth = _oauth(tokenStore: store);
      final pending = await _startFlow(oauth, store);

      final result = await oauth.handleCallback(
        Uri.parse(
          'https://attacker.example/oauth/callback'
          '?state=${pending.state}&code=stolen',
        ),
      );

      expect(result, isNull, reason: '"not mine" is not an error');
      expect(
        await store.readPending(),
        isNotNull,
        reason: 'a foreign URL must not cancel a consent in progress',
      );
    });

    test('the same path on a different scheme is not ours either', () async {
      final oauth = _oauth();
      expect(
        await oauth.handleCallback(
          Uri.parse('myapp://partner.example/oauth/callback?code=c&state=s'),
        ),
        isNull,
      );
    });

    test('a different path on our own host is not ours', () async {
      final oauth = _oauth();
      expect(
        await oauth.handleCallback(
          Uri.parse('https://partner.example/other?code=c&state=s'),
        ),
        isNull,
      );
    });

    test('our own redirect carrying no OAuth parameter is left alone',
        () async {
      // The second gate. This is a real link on the registered redirect — a
      // browser landing on the bare callback page, for instance — and it did
      // not come from the authorization server.
      final oauth = _oauth();
      expect(
        await oauth.handleCallback(
          Uri.parse('https://partner.example/oauth/callback?utm_source=email'),
        ),
        isNull,
      );
    });

    test('a foreign URL is refused before the store is touched at all',
        () async {
      // "Nothing was touched" stated as a fact rather than as an intention: a
      // store that throws on every access proves the gate ran ahead of it.
      final oauth = _oauth(
        tokenStore: _RefusingStore(onReadPending: true, onWritePending: true),
      );

      expect(
        await oauth.handleCallback(
          Uri.parse('https://attacker.example/cb?state=s&code=c'),
        ),
        isNull,
      );
    });

    test('the genuine redirect still completes', () async {
      final store = InMemoryTokenStore();
      final oauth = _oauth(
        tokenStore: store,
        transport: _FakeTransport((_) => _ok(_tokenBody())),
      );
      final pending = await _startFlow(oauth, store);

      final result = await oauth.handleCallback(
        _callback(pending.state, code: 'auth-code'),
      );

      expect(result, isA<AuthAuthorized>());
      expect((await store.read())?.accessToken, isNotEmpty);
    });

    test('a normalised redirect is still ours', () async {
      // The comparison errs towards accepting on purpose: `state` is what
      // decides whether a code may be redeemed, so being generous here costs
      // nothing, while being strict would drop a real redirect. A browser that
      // upper-cases the host or appends a trailing slash must not cost a user
      // the consent they just gave.
      final store = InMemoryTokenStore();
      final oauth = _oauth(
        tokenStore: store,
        transport: _FakeTransport((_) => _ok(_tokenBody())),
      );
      final pending = await _startFlow(oauth, store);

      final result = await oauth.handleCallback(
        Uri.parse(
          'https://PARTNER.example/oauth/callback/'
          '?state=${pending.state}&code=auth-code',
        ),
      );

      expect(result, isA<AuthAuthorized>());
    });
  });

  // ---------------------------------------------------------------------------
  // Abandoning a flow the user walked away from.
  //
  // A browser that closes without a redirect produces no signal of its own: the
  // OS does not tell the SDK, and nothing ever arrives at handleCallback. The
  // record therefore sits on the device with a live PKCE verifier beside a
  // `state` this SDK will still accept, until it ages out ten minutes later.
  // The host app is the only party that knows the browser closed, so it is the
  // only party that can say so.
  // ---------------------------------------------------------------------------
  group('cancelPendingAuthorization', () {
    test('erases the record a started flow left on the device', () async {
      final store = InMemoryTokenStore();
      final oauth = _oauth(tokenStore: store);

      await oauth.authorize();
      expect(await store.readPending(), isNotNull);

      expect(await oauth.cancelPendingAuthorization(), isTrue);
      expect(
        await store.readPending(),
        isNull,
        reason: 'the verifier must not outlive the flow that generated it',
      );
    });

    test('answers false when nothing is pending', () async {
      final oauth = _oauth(tokenStore: InMemoryTokenStore());
      expect(await oauth.cancelPendingAuthorization(), isFalse);
    });

    test('answers false the second time — one attempt cancels once', () async {
      final oauth = _oauth(tokenStore: InMemoryTokenStore());
      await oauth.authorize();

      expect(await oauth.cancelPendingAuthorization(), isTrue);
      expect(await oauth.cancelPendingAuthorization(), isFalse);
    });

    test('a stale id does not cancel the attempt that superseded it', () async {
      // The double tap, which is the whole reason the id exists. `authorize`
      // runs twice; the second call supersedes the first; and only then does
      // the first browser's close event arrive. Cancelling unconditionally
      // there would kill the attempt the user is actually looking at.
      final store = InMemoryTokenStore();
      final oauth = _oauth(tokenStore: store);

      await oauth.authorize();
      final firstId = oauth.pendingAuthorizationId;
      await oauth.authorize();
      final secondId = oauth.pendingAuthorizationId;

      expect(firstId, isNotNull);
      expect(secondId, isNot(firstId));

      expect(
        await oauth.cancelPendingAuthorization(authorizationId: firstId),
        isFalse,
        reason: 'a late signal about a superseded attempt must be ignored',
      );
      expect(
        await store.readPending(),
        isNotNull,
        reason: 'the live attempt must survive the stale cancel',
      );

      expect(
        await oauth.cancelPendingAuthorization(authorizationId: secondId),
        isTrue,
      );
      expect(await store.readPending(), isNull);
    });

    test('the id is never the state, and never leaves the device', () async {
      final launcher = _FakeLauncher(installed: true);
      final store = InMemoryTokenStore();
      final oauth = _oauth(launcher: launcher, tokenStore: store);

      await oauth.authorize();

      final id = oauth.pendingAuthorizationId!;
      final pending = (await store.readPending())!;
      expect(id, isNot(pending.state));
      expect(launcher.opened.single.toString(), isNot(contains(id)));
    });

    test('an id from a previous process is refused, but a bare cancel is not',
        () async {
      // A cancel is a "this process saw the browser close" signal, and a
      // process that did not open the browser has no such signal to
      // disambiguate. Naming an id it never issued is refused; cancelling
      // whatever is on disk is still allowed, which is what lets a host clean
      // up after a process death.
      final store = InMemoryTokenStore();
      await _oauth(tokenStore: store).authorize();

      final restarted = _oauth(tokenStore: store);
      expect(restarted.pendingAuthorizationId, isNull);
      expect(
        await restarted.cancelPendingAuthorization(
          authorizationId: 'authorization-1',
        ),
        isFalse,
      );
      expect(await store.readPending(), isNotNull);

      expect(await restarted.cancelPendingAuthorization(), isTrue);
      expect(await store.readPending(), isNull);
    });

    test('a spent attempt cannot be cancelled afterwards', () async {
      // handleCallback erases the record on every terminal outcome, so the id
      // must go with it — otherwise a later cancel reports that it abandoned
      // something that was already finished.
      final store = InMemoryTokenStore();
      final oauth = _oauth(tokenStore: store);
      await oauth.authorize();
      final state = (await store.readPending())!.state;

      final result = await oauth.handleCallback(
        Uri.parse(
          'https://partner.example/oauth/callback'
          '?state=$state&error=access_denied',
        ),
      );

      expect(result, isA<AuthDenied>());
      expect(oauth.pendingAuthorizationId, isNull);
      expect(await oauth.cancelPendingAuthorization(), isFalse);
    });

    test('a store that refuses is reported as nothing to cancel', () async {
      // Called from a lifecycle callback, so it follows handleCallback's rule:
      // no throw, and an answer the caller can act on.
      final oauth = _oauth(
        tokenStore: _RefusingStore(onReadPending: true, onWritePending: true),
      );
      expect(await oauth.cancelPendingAuthorization(), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Neither half of the flow may throw at its caller.
  //
  // `handleCallback` is called from the host app's App Link / Universal Link
  // handler: a platform callback, usually two lines, essentially never wrapped
  // in a `try`. An exception escaping into it is an unhandled exception in
  // someone else's app, on a code path they did not write, for a reason (the
  // Keychain was locked) that has nothing to do with the deep link they were
  // routing. `authorize` follows the same rule so that both halves report a
  // failure the same way and one `switch` covers everything.
  //
  // The store is where this actually bites, because it is the one collaborator
  // that is not the SDK's own code and not a network call: `flutter_secure_
  // storage` raises a `PlatformException` when the Keychain is locked, when a
  // Keystore entry cannot be decrypted after a backup restore, or when the
  // platform channel is simply not there.
  // ---------------------------------------------------------------------------
  group('failures arrive as AuthFailed, never as a throw', () {
    test('handleCallback: a store that refuses to read', () async {
      final oauth = _oauth(tokenStore: _RefusingStore(onReadPending: true));

      final result = await oauth.handleCallback(
        Uri.parse('https://partner.example/oauth/callback?state=s&code=c'),
      );

      expect(result, isA<AuthFailed>());
      expect(
        (result as AuthFailed).error,
        isA<TraciveInvalidRequestException>(),
      );
    });

    test('handleCallback: a store that refuses to erase the spent record',
        () async {
      // Reached after the redirect has already been judged — the `state`
      // matched and the server said `access_denied` — so the throw comes from
      // the clean-up rather than from the decision.
      final store = _RefusingStore(onWritePending: true)
        ..seedPending(
          PendingAuthorization(
            state: 'the-state',
            codeVerifier: 'the-verifier',
            redirectUri: 'https://partner.example/oauth/callback',
            createdAt: _t0,
          ),
        );
      final oauth = _oauth(tokenStore: store);

      final result = await oauth.handleCallback(
        Uri.parse(
          'https://partner.example/oauth/callback'
          '?state=the-state&error=access_denied',
        ),
      );

      expect(result, isA<AuthFailed>());
    });

    test(
        'handleCallback: the error names the situation without quoting the '
        'platform', () async {
      // The message travels to crash reporters from a frame whose neighbouring
      // values are a PKCE verifier and a refresh token, so it carries nothing
      // this SDK did not write.
      final oauth = _oauth(
        tokenStore: _RefusingStore(onReadPending: true),
      );

      final result = await oauth.handleCallback(
        Uri.parse('https://partner.example/oauth/callback?state=s&code=c'),
      );

      final message = ((result as AuthFailed).error).message;
      expect(message, contains('secure store'));
      expect(message, isNot(contains(_RefusingStore.platformText)));
    });

    test('authorize: a store that refuses to persist the pending record',
        () async {
      final launcher = _FakeLauncher(installed: true);
      final oauth = _oauth(
        launcher: launcher,
        tokenStore: _RefusingStore(onWritePending: true),
      );

      final result = await oauth.authorize();

      expect(result, isA<AuthFailed>());
      expect(
        launcher.opened,
        isEmpty,
        reason: 'the verifier could not be persisted, so no browser was opened',
      );
    });

    test('authorize: a launcher that throws instead of answering', () async {
      // A platform channel that is not registered — the shape a plugin takes
      // on a platform it was never built for.
      final oauth = _oauth(launcher: _ThrowingLauncher());

      final result = await oauth.authorize();

      expect(result, isA<AuthFailed>());
    });
  });
}

// -----------------------------------------------------------------------------
// Fixtures and fakes.
// -----------------------------------------------------------------------------

final TraciveMode _oauthMode = TraciveMode.oauth(
  partnerUserId: 'partner-user-1',
  clientId: 'partner-client-id',
  redirectUri: 'https://partner.example/oauth/callback',
);

TraciveOAuth _oauth({
  AuthLauncher? launcher,
  TokenStore? tokenStore,
  HttpTransport? transport,
  MutableClock? clock,
  ClientType clientType = ClientType.public,
  String? installUrl,
  TraciveEnvironment environment = TraciveEnvironment.production,
}) =>
    TraciveOAuth(
      environment: environment,
      mode: TraciveOAuthMode(
        partnerUserId: 'partner-user-1',
        clientId: 'partner-client-id',
        redirectUri: 'https://partner.example/oauth/callback',
        clientType: clientType,
      ),
      // The shipped default unless a test overrides it: that is what an app
      // gets, so that is what these tests exercise.
      installUrl: installUrl ?? TraciveOAuth.defaultInstallUrl,
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

/// The refresh token a recorded token request actually carried.
///
/// Lets a test say "this token went to the server" as a fact about the wire
/// rather than as a fact about the SDK's internal state.
String _presentedRefreshToken(TraciveHttpRequest request) =>
    RegExp(r'refresh_token=([^&]+)').firstMatch(request.body ?? '')?.group(1) ??
    '?';

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
/// It has no `openInWebView`, because [AuthLauncher] has no such method —
/// step 3 and RFC 8252 §8.12 rule it out, and the interface is shaped so a
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
    presented.add(_presentedRefreshToken(request));
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

/// A [TokenStore] that raises the way a real one does when the platform refuses
/// — a locked Keychain, an undecryptable Keystore entry after a backup restore,
/// a platform channel that was never registered. Not a [TraciveException]: that
/// is the point, since the SDK's own error types are the easy half.
class _RefusingStore extends TokenStore {
  _RefusingStore({
    this.onReadPending = false,
    this.onWritePending = false,
    this.onWrite = false,
    TraciveTokens? tokens,
  }) : _tokens = tokens;

  /// Stands in for the plugin's own text, which must not reach the caller.
  static const String platformText = 'PlatformException(Keychain, -25308)';

  final bool onReadPending;
  final bool onWritePending;

  /// Whether [write] refuses. A store that reads back what it already holds and
  /// cannot persist anything new is the shape a refreshed pair gets lost in.
  final bool onWrite;

  TraciveTokens? _tokens;
  PendingAuthorization? _pending;

  /// Puts a record in place without going through [writePending], so a test can
  /// reach the paths that run after the redirect has been judged.
  void seedPending(PendingAuthorization pending) => _pending = pending;

  @override
  Future<TraciveTokens?> read() async => _tokens;

  @override
  Future<void> write(TraciveTokens tokens) async {
    if (onWrite) throw StateError(platformText);
    _tokens = tokens;
  }

  @override
  Future<void> clear() async {
    _tokens = null;
    _pending = null;
  }

  @override
  Future<PendingAuthorization?> readPending() async {
    if (onReadPending) throw StateError(platformText);
    return _pending;
  }

  @override
  Future<void> writePending(PendingAuthorization? pending) async {
    if (onWritePending) throw StateError(platformText);
    _pending = pending;
  }
}

/// A launcher whose platform channel is not there.
class _ThrowingLauncher extends AuthLauncher {
  @override
  Future<bool> canOpen(Uri url) async =>
      throw StateError('MissingPluginException(url_launcher)');

  @override
  Future<bool> openExternally(Uri url) async =>
      throw StateError('MissingPluginException(url_launcher)');
}

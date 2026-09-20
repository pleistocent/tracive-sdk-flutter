// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// A runnable example for package:tracive_sdk.
//
// WHAT THIS DEMONSTRATES, and why each part is here:
//
//   * `TraciveClient` built in OAuth mode with **no API key**, because the
//     surface has no parameter for one.
//   * `TraciveQuery` folding: the key sent to the server is shown next to the
//     raw input, so the grammar is visible rather than described.
//   * The cache: the fake backend's call counter is on screen, so a cache
//     hit is visibly *not* a call. Change `Source` and watch it stop moving.
//   * The `disclaimer` is rendered on every result. The contract says surface
//     it in any UI built on the SDK, so this UI surfaces it.
//   * Typed errors, triggered on demand rather than described.
//
// THREE FLAVORS (lib/flavor.dart). `demo`, the default, answers every call
// in-process from `DemoBackend`, so it runs on a fresh clone with nothing to
// reach and nothing to bill. `sandbox` and `production` are the real
// integration: the default transport, the encrypted on-disk cache, and the
// OAuth round trip through the Tracive app.
//
// USING THIS AS YOUR OWN EXPERIMENT GROUND? Everything you have to supply is
// marked `TODO(partner)`: `grep -rn "TODO(partner)" example`.

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

// Everything this app needs comes through the public barrel — which is the
// point of an example: it is written against the surface an integrator has,
// not against the package's internals.
import 'package:tracive_sdk/tracive_sdk.dart';

import 'demo_backend.dart';
import 'flavor.dart';

Future<void> main() async {
  // Nothing is installed here on purpose. The SDK already folds every query
  // through full Unicode NFC (`UnormNormalizer`), so an integrator has nothing
  // to configure to get a key that matches the server's. The seam exists for
  // the app that has measured the fold as too slow and knows its identifiers
  // are ASCII; see `doc/integration.md` before taking it.
  WidgetsFlutterBinding.ensureInitialized();
  final flavor = ExampleFlavor.current;
  runApp(
    TraciveExampleApp(
      flavor: flavor,
      // Opened before the first frame: it is asynchronous, and the client
      // takes its cache at construction.
      cache: flavor.isLive ? await openTraciveCache() : null,
    ),
  );
}

/// The example application.
class TraciveExampleApp extends StatelessWidget {
  /// Creates the app. [cache] is required for a live [flavor].
  const TraciveExampleApp({
    super.key,
    this.flavor = ExampleFlavor.demo,
    this.cache,
  });

  final ExampleFlavor flavor;

  final CheckCache? cache;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Tracive SDK example',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F6FEB)),
          useMaterial3: true,
        ),
        home: CheckScreen(flavor: flavor, cache: cache),
      );
}

/// The one screen: enter an identifier, check it, read the result.
class CheckScreen extends StatefulWidget {
  /// Creates the screen.
  const CheckScreen({super.key, required this.flavor, this.cache});

  final ExampleFlavor flavor;

  final CheckCache? cache;

  @override
  State<CheckScreen> createState() => _CheckScreenState();
}

class _CheckScreenState extends State<CheckScreen> {
  final TextEditingController _input = TextEditingController(
    text: '+62 812-3456-7891',
  );

  /// Only the demo has one; the live flavors talk to the real API.
  DemoBackend? _backend;
  late final TraciveClient _client;
  StreamSubscription<Uri>? _links;

  Source _source = Source.cacheFirst;
  Detail _detail = Detail.minimal;

  bool _busy = false;
  bool _authorized = false;
  CheckResult? _result;
  Object? _error;
  String? _foldedKey;

  @override
  void initState() {
    super.initState();
    final flavor = widget.flavor;
    // Note what is absent: there is no apiKey parameter, in any mode. The SDK
    // authenticates with OAuth + PKCE so no long-lived secret ships inside the
    // binary.
    final mode = TraciveMode.oauth(
      // TODO(partner): your own stable id for this user — an account id or a
      // UUID you store. Required, never blank, and never a phone number or an
      // email.
      partnerUserId: 'partner-user-1',
      clientId: flavor.clientId,
      redirectUri: flavor.redirectUri,
      // Named, not typed. A scope name is only ever validated by the
      // authorization server, and it rejects the whole consent request when
      // it does not recognise one — so a typo is not a narrower grant, it is
      // an integration that cannot authorize at all.
      // TODO(partner): the narrowest set your integration needs.
      scopes: <String>[TraciveScopes.scammerCheck],
    );

    final environment = flavor.environment;
    if (environment != null) {
      // The real integration. `installUrl` — where a user without the Tracive
      // app is sent — is not passed: it defaults to the install page every
      // Tracive SDK opens. Pass one only if Tracive has issued you another.
      _client = TraciveClient(
        mode: mode,
        environment: environment,
        cache: widget.cache!,
      );
      // Every incoming link goes to the SDK, which answers null for anything
      // that is not its own redirect. The stream also carries the link that
      // cold-started the app, which is how a flow survives the OS killing
      // this process while the user was in the Tracive app.
      _links = AppLinks().uriLinkStream.listen(_onLink);
      unawaited(
        _client.isAuthorized.then((authorized) {
          if (mounted) setState(() => _authorized = authorized);
        }),
      );
    } else {
      final backend = DemoBackend();
      _backend = backend;
      _client = TraciveClient(
        mode: mode,
        // An in-process fake in place of the HTTP transport, so the demo runs
        // with no server. The same seam is how you widget-test your own screen.
        transport: backend,
        // In memory so the demo runs on any platform, desktop and web
        // included, with no plugin. The live flavors use `openTraciveCache()`.
        cache: CheckCache.inMemory(),
        // Pre-seeded so the demo starts signed in; the live flavors get here
        // through `authorize()`. See `doc/oauth.md`.
        tokenStore: InMemoryTokenStore(
          tokens: const TraciveTokens(
            accessToken: 'demo-access-token',
            refreshToken: 'demo-refresh-token',
            grantedScopes: <String>[TraciveScopes.scammerCheck],
          ),
        ),
      );
      _authorized = true;
    }
  }

  @override
  void dispose() {
    unawaited(_links?.cancel());
    _client.close();
    _input.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _foldedKey = null;
    });

    try {
      // Validation happens here, before anything leaves the device: a key that
      // could not match is never sent, because a miss is billed.
      final query = TraciveQuery.phone(_input.text);
      // TODO(partner): pass an idempotencyKey — one per logical check, reused
      // only to retry that same check. Without one a 5xx or a timeout cannot be
      // retried safely, because a blind retry risks being charged twice.
      final result = await _client.checkScammer(
        query,
        source: _source,
        detail: _detail,
        locale: 'id',
      );
      if (!mounted) return;
      setState(() {
        _foldedKey = query.searchQueryIndex;
        _result = result;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearCache() async {
    await _client.cache.clear();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Cache cleared — the next check costs a credit.'),
      ),
    );
  }

  void _armFailure(int status, String code) {
    _backend!.failNextCall = (status: status, code: code);
    _say('Next call will fail with $status $code.');
  }

  void _say(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// Opens the consent screen and returns; the answer arrives at [_onLink].
  Future<void> _authorize() async {
    final start = await _client.authorize();
    if (!mounted) return;
    _say(switch (start) {
      null => 'Consent screen opened. Finish it in the Tracive app.',
      AuthAppNotInstalled() =>
        'Install the Tracive app first — the install page has been opened.',
      AuthFailed(:final error) => error.message,
      // authorize() returns nothing else; handleCallback does.
      _ => 'Unexpected result from authorize(): $start',
    });
  }

  Future<void> _onLink(Uri uri) async {
    final result = await _client.handleCallback(uri);
    // TODO(partner): null means not a Tracive redirect. Route it to whatever
    // else in your app handles deep links, instead of dropping it.
    if (result == null || !mounted) return;
    setState(() => _authorized = result is AuthAuthorized);
    _say(switch (result) {
      AuthAuthorized(:final grantedScopes) =>
        'Authorized. Scopes granted: ${grantedScopes.join(", ")}',
      // Only reachable for a confidential client; this example is public.
      // TODO(partner): a confidential client forwards the code and verifier
      // over TLS to its own backend, which completes the exchange.
      AuthCodeReceived() =>
        'Authorization code received. Forward it to your backend.',
      AuthDenied() => 'You declined the request.',
      AuthFailed(:final error) => error.message,
      AuthAppNotInstalled() => 'The Tracive app is not installed.',
    });
  }

  Future<void> _signOut() async {
    await _client.signOut();
    if (!mounted) return;
    setState(() {
      _authorized = false;
      _result = null;
    });
    _say('Signed out. The grant and the cached verdicts are gone.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tracive SDK example'),
        backgroundColor: theme.colorScheme.inversePrimary,
      ),
      // Scaffold does not inset its body for MediaQuery.padding — only an appBar or a
      // bottomNavigationBar makes it do that, and there is no bottom bar here. Without this the
      // last card sits permanently under the Android gesture pill and the iPhone home indicator,
      // and scrolling cannot recover it because the viewport already extends behind them.
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _StatusBanner(flavor: widget.flavor),
            const SizedBox(height: 16),
            if (widget.flavor.isLive) ...<Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton.tonal(
                    onPressed: _authorized ? null : _authorize,
                    child: Text(_authorized ? 'Authorized' : 'Authorize'),
                  ),
                  OutlinedButton(
                    onPressed: _authorized ? _signOut : null,
                    child: const Text('Sign out'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _input,
              decoration: const InputDecoration(
                labelText: 'Phone number (E.164)',
                helperText: 'Spaces and dashes are folded away by the grammar.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            _SourcePicker(
              value: _source,
              onChanged: (value) => setState(() => _source = value),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Full detail'),
              subtitle: const Text(
                'detail=full adds chronologies and comments — and is never cached.',
              ),
              value: _detail == Detail.full,
              onChanged: (on) =>
                  setState(() => _detail = on ? Detail.full : Detail.minimal),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _check,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search),
              label: const Text('Check'),
            ),
            const SizedBox(height: 12),
            if (_backend case final backend?) ...<Widget>[
              _CallCounter(backend: backend),
              const SizedBox(height: 12),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton(
                  onPressed: _clearCache,
                  child: const Text('Clear cache'),
                ),
                if (_backend != null) ...<Widget>[
                  OutlinedButton(
                    onPressed: () =>
                        _armFailure(402, 'insufficient_user_credits'),
                    child: const Text('Simulate 402'),
                  ),
                  OutlinedButton(
                    onPressed: () => _armFailure(429, 'rate_limited'),
                    child: const Text('Simulate 429'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 24),
            if (_error != null) _ErrorCard(error: _error!),
            if (_result != null)
              _ResultCard(result: _result!, foldedKey: _foldedKey!),
          ],
        ),
      ),
    );
  }
}

/// Says plainly what this app is talking to, so a demo answer is never
/// mistaken for a real one and sandbox is never mistaken for production.
class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.flavor});

  final ExampleFlavor flavor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final environment = flavor.environment;
    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              environment == null
                  ? Icons.science_outlined
                  : Icons.cloud_outlined,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                environment == null
                    ? 'Demo flavor. Every response below comes from an '
                        'in-process fake (DemoBackend); nothing here opens a '
                        'socket. Run with --flavor sandbox or --flavor '
                        'production for the real API.'
                    : '${environment.name} · ${environment.baseUrl}\n'
                        'Every check below is a real call to this environment.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The `Source` selector — the control that makes the cache observable.
class _SourcePicker extends StatelessWidget {
  const _SourcePicker({required this.value, required this.onChanged});

  final Source value;
  final ValueChanged<Source> onChanged;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Source', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<Source>(
            segments: const <ButtonSegment<Source>>[
              ButtonSegment<Source>(
                value: Source.cacheFirst,
                label: Text('cacheFirst'),
              ),
              ButtonSegment<Source>(
                  value: Source.server, label: Text('server')),
              ButtonSegment<Source>(
                value: Source.serverFirst,
                label: Text('serverFirst'),
              ),
              ButtonSegment<Source>(value: Source.cache, label: Text('cache')),
            ],
            selected: <Source>{value},
            onSelectionChanged: (selection) => onChanged(selection.first),
          ),
        ],
      );
}

/// How many calls actually reached the fake backend.
///
/// This is the whole point of the cache made visible: check the same number
/// twice with `cacheFirst` and this does not move the second time.
class _CallCounter extends StatelessWidget {
  const _CallCounter({required this.backend});

  final DemoBackend backend;

  @override
  Widget build(BuildContext context) => Row(
        children: <Widget>[
          const Icon(Icons.cloud_outlined, size: 18),
          const SizedBox(width: 8),
          Text(
            'Backend calls this session: ${backend.callCount}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      );
}

/// Renders a [CheckResult], including the fields a UI is required to show.
class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result, required this.foldedKey});

  final CheckResult result;
  final String foldedKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                _TierChip(tier: result.riskTier),
                const Spacer(),
                Chip(
                  avatar: Icon(
                    result.origin == Origin.cache
                        ? Icons.sd_storage_outlined
                        : Icons.cloud_download_outlined,
                    size: 18,
                  ),
                  label: Text(result.origin.wireValue),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SelectableText(
              'Folded key sent: $foldedKey',
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
            const Divider(height: 24),
            _Row(label: 'Found', value: '${result.found}'),
            _Row(label: 'Reports', value: '${result.reportTotal}'),
            _Row(label: 'Credible', value: '${result.credibleReports}'),
            _Row(label: 'Ambiguous', value: '${result.ambiguousReports}'),
            _Row(
                label: 'Related scammers',
                value: '${result.relatedScammerCount}'),
            if (result.tags.isNotEmpty)
              _Row(label: 'Tags', value: result.tags.join(', ')),
            if (result.fraudAmount.isNotEmpty)
              _Row(
                label: 'Reported loss',
                value: result.fraudAmount.entries
                    .map((e) => '${e.key} ${e.value.toStringAsFixed(0)}')
                    .join(', '),
              ),
            _Row(label: 'Fetched at', value: '${result.fetchedAt.toUtc()}'),
            if (result.checkId != null)
              _Row(label: 'Check id', value: result.checkId!),

            // detail=full content. Present only when asked for, and never
            // written to the cache — ask for it again after a cache hit
            // and you will see it is gone.
            if (result.topChronologies != null) ...<Widget>[
              const Divider(height: 24),
              Text('Chronologies', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              for (final entry in result.topChronologies!)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '• ${entry.chronology} (risk ${entry.riskLevel})',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
            if (result.comments != null) ...<Widget>[
              Text('Comments', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              for (final comment in result.comments!)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '• ${comment.text} (${comment.date})',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],

            // Surface this in any UI built on the SDK. Not optional.
            if (result.disclaimer != null) ...<Widget>[
              const Divider(height: 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(Icons.info_outline, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      result.disclaimer!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The risk tier, coloured. `NONE` is deliberately not green: the SDK reports
/// an absence of reports, which is not the same as a verdict of "safe".
class _TierChip extends StatelessWidget {
  const _TierChip({required this.tier});

  final RiskTier tier;

  @override
  Widget build(BuildContext context) {
    final (Color colour, String label) = switch (tier) {
      RiskTier.high => (Colors.red.shade700, 'HIGH RISK'),
      RiskTier.elevated => (Colors.deepOrange.shade600, 'ELEVATED'),
      RiskTier.caution => (Colors.amber.shade800, 'CAUTION'),
      RiskTier.none => (Colors.blueGrey.shade600, 'NO REPORTS'),
    };
    return Chip(
      backgroundColor: colour,
      label: Text(
        label,
        style:
            const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// Renders a thrown [TraciveException] as the typed thing it is.
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (String title, String detail) = switch (error) {
      TraciveQueryException(:final reason) => (
          'Invalid input',
          'Rejected before any call was made, because a miss is billed. '
              'Reason: $reason',
        ),
      // TODO(partner): send the user into your own top-up flow here.
      TraciveInsufficientCreditsException() => (
          'Out of credits',
          'Handle the 402 — do not call credits() before every check.',
        ),
      TraciveRateLimitedException(:final retryAfter) => (
          'Rate limited',
          'Retry after: ${retryAfter ?? "unspecified"}',
        ),
      TraciveCacheMissException() => (
          'Cache miss',
          'source: Source.cache found no live entry. This is an error, never a '
              'silent empty result that would read as "not a scammer".',
        ),
      TraciveNotImplementedException(:final message) => (
          'Not implemented',
          message,
        ),
      TraciveException(:final message) => (
          error.runtimeType.toString(),
          message,
        ),
      _ => ('Unexpected error', '$error'),
    };

    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(detail, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// One label/value line.
class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 150,
              child: Text(label, style: Theme.of(context).textTheme.bodySmall),
            ),
            Expanded(
              child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
            ),
          ],
        ),
      );
}

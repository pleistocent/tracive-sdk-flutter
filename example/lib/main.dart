// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
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
// NO NETWORK. Every call is answered in-process by `DemoBackend`, injected as
// the client's `transport`. There is no `api.tracive.id` to reach: the Open API
// is not live yet. That is the honest state of phase 1, and this app is written
// so that running it teaches the SDK rather than a connection error.

import 'package:flutter/material.dart';

// Everything this app needs comes through the public barrel — which is the
// point of an example: it is written against the surface an integrator has,
// not against the package's internals.
import 'package:tracive_sdk/tracive_sdk.dart';

import 'demo_backend.dart';

void main() {
  // Nothing is installed here on purpose. The SDK already folds every query
  // through full Unicode NFC (`UnormNormalizer`), so an integrator has nothing
  // to configure to get a key that matches the server's. The seam exists for
  // the app that has measured the fold as too slow and knows its identifiers
  // are ASCII; see `doc/integration.md` before taking it.
  runApp(const TraciveExampleApp());
}

/// The example application.
class TraciveExampleApp extends StatelessWidget {
  /// Creates the app.
  const TraciveExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Tracive SDK example',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F6FEB)),
          useMaterial3: true,
        ),
        home: const CheckScreen(),
      );
}

/// The one screen: enter an identifier, check it, read the result.
class CheckScreen extends StatefulWidget {
  /// Creates the screen.
  const CheckScreen({super.key});

  @override
  State<CheckScreen> createState() => _CheckScreenState();
}

class _CheckScreenState extends State<CheckScreen> {
  final TextEditingController _input = TextEditingController(
    text: '+62 812-3456-7891',
  );

  late final DemoBackend _backend;
  late final TraciveClient _client;

  Source _source = Source.cacheFirst;
  Detail _detail = Detail.minimal;

  bool _busy = false;
  CheckResult? _result;
  Object? _error;
  String? _foldedKey;

  @override
  void initState() {
    super.initState();
    _backend = DemoBackend();
    _client = TraciveClient(
      // Note what is absent: there is no apiKey parameter, in any mode. The
      // SDK authenticates with OAuth + PKCE so no long-lived secret ships
      // inside the binary.
      mode: TraciveMode.oauth(
        partnerUserId: 'partner-user-1',
        clientId: 'demo-client',
        // An https App Link / Universal Link, not a custom scheme, and that is
        // not a stylistic choice. A custom scheme (`tracive-demo://callback`)
        // is claimed first-come on both platforms: any other app on the device
        // can register the same one and receive the authorization code. An
        // App Link is bound to a host you control by
        // `/.well-known/assetlinks.json` (Android) or the
        // apple-app-site-association file (iOS), so it cannot be claimed by
        // somebody else. `SECURITY.md` says the same, and this file is what
        // integrators copy.
        redirectUri: 'https://example.tracive.id/oauth/callback',
        // Named, not typed. A scope name is only ever validated by the
        // authorization server, and it rejects the whole consent request when
        // it does not recognise one — so a typo is not a narrower grant, it is
        // an integration that cannot authorize at all.
        scopes: <String>[TraciveScopes.scammerCheck],
      ),
      // `installUrl` — where a user without the Tracive app is sent — is not
      // passed here, and a real app does not pass it either: it defaults to
      // the same install page every Tracive SDK opens. Pass one only if
      // Tracive has issued you a different link.
      transport: _backend,
      // A real app would pass `await openTraciveCache()` — SQLCipher on disk,
      // key in Keystore/Keychain. In-memory here so the example runs on any
      // platform, including desktop and web, with no plugin.
      cache: CheckCache.inMemory(),
      // Pre-seeded so the example starts signed in. A real app gets here by
      // calling `client.authorize()` and handling the redirect; that flow needs
      // the Tracive app installed and a registered redirect URI, neither of
      // which exists in a demo. See `doc/oauth.md` for the real thing.
      tokenStore: InMemoryTokenStore(
        tokens: const TraciveTokens(
          accessToken: 'demo-access-token',
          refreshToken: 'demo-refresh-token',
          grantedScopes: <String>[TraciveScopes.scammerCheck],
        ),
      ),
    );
  }

  @override
  void dispose() {
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
    _backend.failNextCall = (status: status, code: code);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Next call will fail with $status $code.')),
    );
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
            const _StatusBanner(),
            const SizedBox(height: 16),
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
            _CallCounter(backend: _backend),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton(
                  onPressed: _clearCache,
                  child: const Text('Clear cache'),
                ),
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

/// Says plainly what this app is talking to. phase 1 has no live backend, and a
/// demo that hid that would be teaching the wrong thing.
class _StatusBanner extends StatelessWidget {
  const _StatusBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.science_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'phase 1: OAuth mode only, and the Tracive Open API is not live '
                'yet. Every response below comes from an in-process fake '
                '(DemoBackend). Nothing here opens a socket.',
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
            if (result.cacheTtlSeconds != null)
              _Row(
                label: 'Server cache TTL',
                value: '${result.cacheTtlSeconds}s',
              ),
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

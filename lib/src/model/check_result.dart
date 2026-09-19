// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'billing.dart';
import 'chronology.dart';
import 'collection_equality.dart';
import 'comment.dart';
import 'json.dart';
import 'origin.dart';
import 'risk_tier.dart';

/// The answer to a scammer check.
///
/// Two fields are stamped by the SDK rather than sent by the server: [origin]
/// (cache or network) and [fetchedAt] (when the underlying data was fetched
/// from the server — on a cache hit that is the *original* fetch, not now).
///
/// Surface [disclaimer] in any UI built on this SDK. It is not decoration:
/// these are user reports, not adjudicated findings.
class CheckResult {
  /// Creates a result. Normally decoded with [CheckResult.fromJson].
  CheckResult({
    required this.found,
    required this.riskTier,
    required this.origin,
    required this.fetchedAt,
    this.checkId,
    this.reportTotal = 0,
    this.credibleReports = 0,
    this.ambiguousReports = 0,
    this.firstReportOn,
    this.lastReportOn,
    Map<String, double> fraudAmount = const <String, double>{},
    List<String> tags = const <String>[],
    this.relatedScammerCount = 0,
    this.topChronologies,
    this.comments,
    this.billing,
    this.cacheTtlSeconds,
    this.disclaimer,
  })  : fraudAmount = Map<String, double>.unmodifiable(fraudAmount),
        tags = List<String>.unmodifiable(tags);

  /// Decodes a `POST /scammer-checks` response body.
  ///
  /// Unknown fields are ignored and a field of an unexpected type degrades to
  /// its default rather than throwing (forward compatibility).
  ///
  /// [origin] and [fetchedAt] override anything in [json]; they fall back to
  /// the JSON (so a cached record round-trips) and finally to
  /// `Origin.server` / `DateTime.now()`.
  factory CheckResult.fromJson(
    Map<String, Object?> json, {
    Origin? origin,
    DateTime? fetchedAt,
  }) {
    final chronologies = asJsonMapList(json['topChronologies']);
    final commentMaps = asJsonMapList(json['comments']);
    final billingJson = asJsonMap(json['billing']);
    return CheckResult(
      checkId: asString(json['checkId']),
      found: asBool(json['found']),
      riskTier: RiskTier.fromWire(json['riskTier']),
      reportTotal: asInt(json['reportTotal']),
      credibleReports: asInt(json['credibleReports']),
      ambiguousReports: asInt(json['ambiguousReports']),
      firstReportOn: asUtcDateTime(json['firstReportOn']),
      lastReportOn: asUtcDateTime(json['lastReportOn']),
      fraudAmount: asAmountMap(json['fraudAmount']),
      tags: asStringList(json['tags']),
      relatedScammerCount: asInt(json['relatedScammerCount']),
      topChronologies:
          chronologies?.map(Chronology.fromJson).toList(growable: false),
      comments: commentMaps?.map(Comment.fromJson).toList(growable: false),
      billing: billingJson == null ? null : Billing.fromJson(billingJson),
      cacheTtlSeconds: asIntOrNull(json['cacheTtlSeconds']),
      disclaimer: asString(json['disclaimer']),
      origin: origin ?? Origin.fromWire(json['origin']),
      fetchedAt: fetchedAt ??
          asUtcDateTime(json['fetchedAt']) ??
          DateTime.now().toUtc(),
    );
  }

  /// Server-assigned id of this check. `null` on a cache hit — nothing was
  /// checked, so nothing was assigned.
  final String? checkId;

  /// Whether the identifier is on record at all.
  final bool found;

  /// How dangerous it looks.
  final RiskTier riskTier;

  /// Total reports behind [riskTier].
  final int reportTotal;

  /// Reports the server considers credible.
  final int credibleReports;

  /// Reports the server considers ambiguous.
  final int ambiguousReports;

  /// Earliest report, in UTC.
  final DateTime? firstReportOn;

  /// Most recent report, in UTC.
  final DateTime? lastReportOn;

  /// Reported loss per currency code, e.g. `{'IDR': 4500000.0}`. Unmodifiable.
  final Map<String, double> fraudAmount;

  /// Server-assigned labels. Unmodifiable.
  final List<String> tags;

  /// How many other flagged entities are linked to this one.
  ///
  /// A count, never a list: returning the linked identifiers would leak
  /// third parties' data.
  final int relatedScammerCount;

  /// Narratives — `detail = full` only. `null` means "not requested"; `[]`
  /// means "requested, none returned".
  final List<Chronology>? topChronologies;

  /// Comments — `detail = full` only, same `null` versus `[]` distinction.
  final List<Comment>? comments;

  /// What this call cost. `null` on a cache hit (a cache hit costs nothing).
  final Billing? billing;

  /// Server-driven TTL override, in seconds.
  ///
  /// This **overrides** the tier default and is the fleet-wide
  /// invalidation lever — honour it.
  final int? cacheTtlSeconds;

  /// Legal/UX disclaimer. **Surface this in any UI built on the SDK.**
  final String? disclaimer;

  /// Cache or network.
  final Origin origin;

  /// When the underlying data was fetched from the server, in UTC. On a cache
  /// hit this is the original fetch time, which is what TTL is measured from.
  final DateTime fetchedAt;

  /// [cacheTtlSeconds] as a [Duration], when the server sent one.
  Duration? get serverTtl =>
      cacheTtlSeconds == null ? null : Duration(seconds: cacheTtlSeconds!);

  /// Whether this result carries `detail = full` content.
  bool get hasFullDetail => topChronologies != null || comments != null;

  /// Whether this result was served without touching the network.
  bool get isFromCache => origin == Origin.cache;

  /// The subset of this result that is safe to cache.
  ///
  /// Drops the content that only a full-detail answer carries
  /// ([topChronologies], [comments]) and the two single-use fields ([billing],
  /// [checkId]).
  ///
  /// [disclaimer] and [tags] are **kept**, and that is only sound because of a
  /// rule enforced one layer up: `TraciveClient` caches an answer only when the
  /// request was `detail: minimal`, and a minimal request carries no `locale`
  /// at all. Every cached row therefore holds the one language the server
  /// returns when it is not told which to use, and the cache key can stay the
  /// query alone.
  ///
  /// **If a future version ever caches a full-detail or localized answer, the
  /// cache key must become `(query, detail, locale)` first** — otherwise an
  /// Indonesian answer is served to an English caller, in the one string this
  /// SDK asks every integrator to put on screen.
  CheckResult cacheable() => CheckResult(
        checkId: null,
        found: found,
        riskTier: riskTier,
        reportTotal: reportTotal,
        credibleReports: credibleReports,
        ambiguousReports: ambiguousReports,
        firstReportOn: firstReportOn,
        lastReportOn: lastReportOn,
        fraudAmount: fraudAmount,
        tags: tags,
        relatedScammerCount: relatedScammerCount,
        topChronologies: null,
        comments: null,
        billing: null,
        cacheTtlSeconds: cacheTtlSeconds,
        disclaimer: disclaimer,
        origin: Origin.cache,
        fetchedAt: fetchedAt,
      );

  /// This result reduced to what may be kept against a transaction.
  ///
  /// A transaction record is read back under the transaction it was filed for
  /// and never under another request, so almost everything survives —
  /// including the fields [cacheable] drops for reasons that do not apply here.
  /// [checkId] and [billing] describe one call, which is exactly what this
  /// record is; keeping them is what lets a support agent reconcile the charge
  /// and a UI say whether that transfer spent a credit. [origin] and
  /// [fetchedAt] are kept as they are, not restamped, because the record is a
  /// statement about a past moment: a second transfer to an account already
  /// checked was served from the cache, spent nothing, and should say so.
  ///
  /// [topChronologies] and [comments] go, and that is the one deliberate loss.
  /// They are other people's accounts of being defrauded, written in prose; a
  /// record lives for months rather than hours, and nothing on a
  /// transaction-detail screen shows them.
  CheckResult transactionRecord() => CheckResult(
        checkId: checkId,
        found: found,
        riskTier: riskTier,
        reportTotal: reportTotal,
        credibleReports: credibleReports,
        ambiguousReports: ambiguousReports,
        firstReportOn: firstReportOn,
        lastReportOn: lastReportOn,
        fraudAmount: fraudAmount,
        tags: tags,
        relatedScammerCount: relatedScammerCount,
        topChronologies: null,
        comments: null,
        billing: billing,
        cacheTtlSeconds: cacheTtlSeconds,
        disclaimer: disclaimer,
        origin: origin,
        fetchedAt: fetchedAt,
      );

  /// Copy with replacements.
  ///
  /// Only replaces the fields you name: passing `null` for a field means "leave
  /// it alone", not "clear it". Use [cacheable] for the one case where fields
  /// must actually be cleared.
  CheckResult copyWith({
    String? checkId,
    bool? found,
    RiskTier? riskTier,
    int? reportTotal,
    int? credibleReports,
    int? ambiguousReports,
    DateTime? firstReportOn,
    DateTime? lastReportOn,
    Map<String, double>? fraudAmount,
    List<String>? tags,
    int? relatedScammerCount,
    List<Chronology>? topChronologies,
    List<Comment>? comments,
    Billing? billing,
    int? cacheTtlSeconds,
    String? disclaimer,
    Origin? origin,
    DateTime? fetchedAt,
  }) =>
      CheckResult(
        checkId: checkId ?? this.checkId,
        found: found ?? this.found,
        riskTier: riskTier ?? this.riskTier,
        reportTotal: reportTotal ?? this.reportTotal,
        credibleReports: credibleReports ?? this.credibleReports,
        ambiguousReports: ambiguousReports ?? this.ambiguousReports,
        firstReportOn: firstReportOn ?? this.firstReportOn,
        lastReportOn: lastReportOn ?? this.lastReportOn,
        fraudAmount: fraudAmount ?? this.fraudAmount,
        tags: tags ?? this.tags,
        relatedScammerCount: relatedScammerCount ?? this.relatedScammerCount,
        topChronologies: topChronologies ?? this.topChronologies,
        comments: comments ?? this.comments,
        billing: billing ?? this.billing,
        cacheTtlSeconds: cacheTtlSeconds ?? this.cacheTtlSeconds,
        disclaimer: disclaimer ?? this.disclaimer,
        origin: origin ?? this.origin,
        fetchedAt: fetchedAt ?? this.fetchedAt,
      );

  /// Wire form, plus the two SDK-stamped fields ([origin], [fetchedAt]) so a
  /// cached record can round-trip through [CheckResult.fromJson].
  Map<String, Object?> toJson() => <String, Object?>{
        if (checkId != null) 'checkId': checkId,
        'found': found,
        'riskTier': riskTier.wireValue,
        'reportTotal': reportTotal,
        'credibleReports': credibleReports,
        'ambiguousReports': ambiguousReports,
        if (firstReportOn != null) 'firstReportOn': toIso8601Utc(firstReportOn),
        if (lastReportOn != null) 'lastReportOn': toIso8601Utc(lastReportOn),
        'fraudAmount': fraudAmount,
        'tags': tags,
        'relatedScammerCount': relatedScammerCount,
        if (topChronologies != null)
          'topChronologies': <Object?>[
            for (final item in topChronologies!) item.toJson(),
          ],
        if (comments != null)
          'comments': <Object?>[for (final item in comments!) item.toJson()],
        if (billing != null) 'billing': billing!.toJson(),
        if (cacheTtlSeconds != null) 'cacheTtlSeconds': cacheTtlSeconds,
        if (disclaimer != null) 'disclaimer': disclaimer,
        'origin': origin.wireValue,
        'fetchedAt': toIso8601Utc(fetchedAt),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CheckResult &&
          other.checkId == checkId &&
          other.found == found &&
          other.riskTier == riskTier &&
          other.reportTotal == reportTotal &&
          other.credibleReports == credibleReports &&
          other.ambiguousReports == ambiguousReports &&
          other.firstReportOn == firstReportOn &&
          other.lastReportOn == lastReportOn &&
          mapEquals(other.fraudAmount, fraudAmount) &&
          listEquals(other.tags, tags) &&
          other.relatedScammerCount == relatedScammerCount &&
          listEquals(other.topChronologies, topChronologies) &&
          listEquals(other.comments, comments) &&
          other.billing == billing &&
          other.cacheTtlSeconds == cacheTtlSeconds &&
          other.disclaimer == disclaimer &&
          other.origin == origin &&
          other.fetchedAt == fetchedAt;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        checkId,
        found,
        riskTier,
        reportTotal,
        credibleReports,
        ambiguousReports,
        firstReportOn,
        lastReportOn,
        mapHash(fraudAmount),
        listHash(tags),
        relatedScammerCount,
        listHash(topChronologies),
        listHash(comments),
        billing,
        cacheTtlSeconds,
        disclaimer,
        origin,
        fetchedAt,
      ]);

  /// Counts and tiers only — narrative text and comments are summarised by
  /// length, never printed.
  @override
  String toString() => 'CheckResult(found: $found, riskTier: ${riskTier.name}, '
      'reportTotal: $reportTotal, credibleReports: $credibleReports, '
      'ambiguousReports: $ambiguousReports, '
      'relatedScammerCount: $relatedScammerCount, origin: ${origin.name}, '
      'fetchedAt: $fetchedAt, '
      'topChronologies: ${topChronologies?.length}, '
      'comments: ${comments?.length})';
}

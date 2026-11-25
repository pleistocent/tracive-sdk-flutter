// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'json.dart';

/// The business sizes a QRIS declares, as `QrisDetails.criteria` carries them.
///
/// Constants rather than an enum, as `QueryRejectionReason` is: a size this
/// build does not know must still decode, as the string it is.
abstract final class QrisCriteria {
  /// Micro business.
  static const String umi = 'UMI';

  /// Small business.
  static const String uke = 'UKE';

  /// Medium business.
  static const String ume = 'UME';

  /// Large business.
  static const String ube = 'UBE';

  /// Every size this build knows.
  static const List<String> values = <String>[umi, uke, ume, ube];
}

/// What Tracive knows about the merchant behind a QRIS hit.
///
/// Every field is optional: the server sends what it read from the reported
/// QR and nothing else. The PAN never comes back.
class QrisDetails {
  /// Creates the details. Normally decoded with [QrisDetails.fromJson].
  const QrisDetails({
    this.merchantName,
    this.city,
    this.criteria,
    this.acquirer,
  });

  /// Decodes a `qris` object. Unknown fields are ignored.
  factory QrisDetails.fromJson(Map<String, Object?> json) => QrisDetails(
        merchantName: asString(json['merchantName']),
        city: asString(json['city']),
        criteria: asString(json['criteria']),
        acquirer: asString(json['acquirer']),
      );

  /// The merchant name printed in the QR.
  final String? merchantName;

  /// The merchant city printed in the QR.
  final String? city;

  /// One of [QrisCriteria]'s values. A `String`, so a size this build does not
  /// know is kept as sent instead of failing the whole check.
  final String? criteria;

  /// The acquirer's reverse-domain id, e.g. `ID.DANA.WWW`.
  final String? acquirer;

  /// Wire form.
  Map<String, Object?> toJson() => <String, Object?>{
        if (merchantName != null) 'merchantName': merchantName,
        if (city != null) 'city': city,
        if (criteria != null) 'criteria': criteria,
        if (acquirer != null) 'acquirer': acquirer,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QrisDetails &&
          other.merchantName == merchantName &&
          other.city == city &&
          other.criteria == criteria &&
          other.acquirer == acquirer;

  @override
  int get hashCode => Object.hash(merchantName, city, criteria, acquirer);

  /// The name is summarised by length: a micro business is often named after
  /// its owner.
  @override
  String toString() => 'QrisDetails(criteria: $criteria, acquirer: $acquirer, '
      'merchantName: ${merchantName?.length} chars, city: $city)';
}

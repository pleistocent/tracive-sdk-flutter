// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'json.dart';

/// The reported party's own answer to the reports, e.g. a QRIS merchant's.
///
/// Show it below the warning, verbatim and untranslated, whenever a result
/// carries one.
class RightOfReply {
  /// Creates a reply. Normally decoded with [RightOfReply.fromJson].
  const RightOfReply({required this.text, required this.language});

  /// Decodes a `rightOfReply` object. Unknown fields are ignored.
  factory RightOfReply.fromJson(Map<String, Object?> json) => RightOfReply(
        text: asStringOr(json['text'], ''),
        language: asStringOr(json['language'], ''),
      );

  /// The reply, exactly as written.
  final String text;

  /// The language [text] is written in, e.g. `id`.
  final String language;

  /// Wire form.
  Map<String, Object?> toJson() => <String, Object?>{
        'text': text,
        'language': language,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RightOfReply && other.text == text && other.language == language;

  @override
  int get hashCode => Object.hash(text, language);

  /// Redacted: free text routinely contains identifiers.
  @override
  String toString() =>
      'RightOfReply(language: $language, text: ${text.length} chars)';
}

// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'dart:typed_data';

/// A receipt screenshot or PDF to prefill Tracive's report form with.
///
/// Nothing is checked here. `TraciveClient.openReportForm` checks every
/// attachment, in order, before anything is written or opened, and reports the
/// first one that fails as a `ReportFormFailed` naming its index.
///
/// PRIVACY: the bytes are the user's receipt. [toString] prints the type and
/// the size only.
final class ReportAttachment {
  const ReportAttachment._(this.mimeType, this.bytes);

  /// An image, declared as one of `image/jpeg` (or `image/jpg`), `image/png`,
  /// `image/webp`, `image/heic`, `image/heif` or `image/bmp`, case-insensitive.
  ///
  /// The bytes must really be that type: a PNG label on JPEG bytes is refused
  /// as `ReportFormContentMismatch`, because the Tracive app checks the bytes
  /// again and would drop the file. GIF is refused. Images have no size cap of
  /// their own; the app compresses them.
  factory ReportAttachment.image(Uint8List bytes, String mimeType) =>
      ReportAttachment._(mimeType, bytes);

  /// A PDF, strictly under 1 MiB (1,048,576 bytes is refused).
  factory ReportAttachment.pdf(Uint8List bytes) =>
      ReportAttachment._('application/pdf', bytes);

  /// The type as the caller declared it, before normalisation.
  final String mimeType;

  /// The file's contents.
  final Uint8List bytes;

  @override
  String toString() => 'ReportAttachment($mimeType, ${bytes.length} bytes)';
}

# tracive_sdk_extended

Lets a user report a scammer from inside your app, and check that report's status. Use Tracive's
native form, or your own Flutter UI on the same calls.

The compression, upload and screens are Tracive's native SDKs. This package presents them and holds
them for Dart, so a report behaves the same as in a native app.

## Requirements

| | |
|---|---|
| Flutter | 3.27 or newer, with `tracive_sdk` |
| Android | minSdk 24, compileSdk 36, Android Gradle Plugin 8.9.1, Gradle 8.11.1, Kotlin 2.2, JDK 17, each or newer |
| iOS | iOS 15 or newer, through CocoaPods |
| Tracive | The user has an account, and a grant with `report.create` |

An app from an older `flutter create` sits under these. Raise `com.android.application` and
`org.jetbrains.kotlin.android` in `android/settings.gradle`, and the Gradle version in
`android/gradle/wrapper/gradle-wrapper.properties`.

**Android API 24 and 25 need core library desugaring**, because the screens read `java.time`:

```kotlin
android {
    compileOptions { isCoreLibraryDesugaringEnabled = true }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
```

**iOS** fetches `TraciveReportCore.xcframework` during `pod install` and verifies its SHA-256. For a
local build of it, set `TRACIVE_EXTENDED_XCFRAMEWORK` to its path and run `pod install` again.
`LSApplicationQueriesSchemes` needs `tracive` for `openInTracive`, as `tracive_sdk` already asks.

## Connect it

Add the scopes to the client you already have, and pass it in. Tokens stay with `tracive_sdk`, which
keeps doing the refresh:

```dart
final client = TraciveClient(
  mode: TraciveMode.oauth(
    clientId: 'your-client-id',
    redirectUri: 'https://your.app/oauth/callback',
    partnerUserId: 'your-stable-user-id',
    scopes: const [TraciveReportScopes.create, TraciveReportScopes.read],
  ),
);

final reports = TraciveReports(client: client);
```

If your backend keeps the tokens, answer for them yourself. A refresh token rotates and a reused one
revokes the grant, so refresh only when `stale` asks for it:

```dart
final reports = TraciveReports.withTokens(
  environment: TraciveEnvironment.production,
  accessToken: (stale) => myBackend.traciveToken(stale),
);
```

Call `reports.dispose()` when you are done with it.

## Tracive's form

```dart
final outcome = await TraciveReportForm.present(
  reports,
  prefill: ReportPrefill.forQuery(query, incidentDate: date, title: 'Fake seller'),
  theme: const TraciveReportTheme(primaryColor: Color(0xFF00695C), cornerRadius: 16),
);

switch (outcome) {
  case ReportFormSubmitted(:final reportId, :final status):
    // Keep reportId with your transaction: reports cannot be listed.
  case ReportFormNeedsConsent():
    // Run your authorize flow with the scope added, then open it again.
  case ReportFormUserCancelled():
    break;
}
```

The user writes the chronology, so it cannot be prefilled. Closing the form cancels an upload in
progress.

## Your own UI

```dart
final requirements = await reports.requirements();
final evidence = await reports.prepare(bytes, mimeType: 'image/png');

final draft = ReportDraft.forQuery(
  query: query,
  title: title,
  chronology: chronology,
  incidentDate: date,
  evidence: [evidence],
  acceptedTerms: requirements.terms,
);

if (draft.problems(requirements.limits).isEmpty) {
  final result = await reports.submit(draft, onProgress: (fraction) {});
}
```

- Show a link to each of `requirements.terms` next to your Send button, and pass only what you
  showed as `acceptedTerms`.
- The chronology must be the user's own words.
- **Keep one draft per form, across retries.** Its idempotency key is what stops a retry from filing
  twice. After `ReportFailed`, call `submit` again with the same draft: finished uploads are skipped.
  `cancelSubmit(draft)` stops a running upload, and the draft can be sent again.
- `prepare` compresses to AVIF, under 200 KB. The bytes stay on the native side from then on, and
  `PreparedEvidence` is a handle to them. They are released when the report is filed, when you call
  `evidence.dispose()`, and when you call `reports.dispose()`. Call `evidence.dispose()` if the user
  removes a file.

## Status

```dart
await TraciveReportStatus.present(reports, reportId, theme: theme);
final status = await reports.status(reportId);
await reports.openInTracive(reportId); // Where a revision is made.
```

Status needs a grant with `report.read`. It says what stage a report is in and never what a review
concluded. A report answers for 30 days.

## Errors

Calls throw `TraciveReportException`, with a `code` and, for the daily cap, `retryAfterSeconds`.
`submit` answers a sealed `SubmitResult` instead: `ReportSubmitted`, `ReportNeedsConsent` or
`ReportFailed`. `ReportErrorCode.needsConsent` and `ReportNeedsConsent` both mean the same thing: run
your authorize flow with the scope added, and call again.

## Example

[`example/`](example) runs all of this, with no account if you want: see its README.

## Licences

The native core embeds AVIF components that ship inside your app. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

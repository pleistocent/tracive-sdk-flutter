# tracive_sdk_extended example

Tracive's form, your own UI and the status screen, in Tracive's sandbox:

```
flutter run --dart-define=TRACIVE_CLIENT_ID=<your sandbox client id>
```

To try everything with no account, no Tracive app and no network, start a stand-in for the Tracive
API inside the app, on 127.0.0.1, with a made-up grant:

```
flutter run --dart-define=TRACIVE_EXAMPLE_LOCAL=true
```

Every call still crosses the bridge into the native core. The stand-in checks nothing: it exists so
the screens and the bridge can be seen working.

`integration_test/bridge_test.dart` drives the real native core on a device against the same
stand-in:

```
flutter test integration_test/bridge_test.dart -d <device>
```

## Another host

Anything other than sandbox stays out of this repository, in a JSON file git ignores:

```
flutter run --dart-define-from-file=tracive_overrides.json
```

```json
{
  "TRACIVE_API_BASE_URL": "https://api.example.com/v1",
  "TRACIVE_AUTHORIZE_URL": "https://example.com/oauth/authorize",
  "TRACIVE_CLIENT_ID": "your client id",
  "TRACIVE_REDIRECT_SCHEME": "your-scheme",
  "TRACIVE_APP_SCHEME": "the Tracive build's scheme"
}
```

An API host does not serve the authorize page, so `TRACIVE_API_BASE_URL` needs
`TRACIVE_AUTHORIZE_URL`. The app-presence check still looks for the production Tracive app on such a
host. The token store is not keyed by host, so uninstall the app when you switch.

## Against an unreleased version

An unreleased version is not on Maven Central or GitHub Releases yet, so build its native parts
first, from a checkout of `tracive-sdk-kotlin`:

```
./gradlew :tracive-sdk-extended:publishToMavenLocal
./gradlew :tracive-sdk-extended-ui:publishToMavenLocal -x :tracive-sdk-extended-ui:javaDocReleaseGeneration
./gradlew :tracive-sdk-extended:assembleTraciveReportCoreReleaseXCFramework
export TRACIVE_EXTENDED_XCFRAMEWORK=$PWD/tracive-sdk-extended/build/XCFrameworks/release/TraciveReportCore.xcframework
```

Then add `mavenLocal()` to the repositories in `android/build.gradle.kts`, limited to the Tracive
group with a `content` filter, and leave it out of the commit.

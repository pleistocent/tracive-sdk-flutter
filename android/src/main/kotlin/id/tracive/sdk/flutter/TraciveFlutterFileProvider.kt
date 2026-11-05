package id.tracive.sdk.flutter

import androidx.core.content.FileProvider

/**
 * Empty on purpose. A manifest entry naming androidx's own FileProvider collides in the manifest
 * merger with the host app's; a subclass gives this SDK a provider of its own.
 */
class TraciveFlutterFileProvider : FileProvider()

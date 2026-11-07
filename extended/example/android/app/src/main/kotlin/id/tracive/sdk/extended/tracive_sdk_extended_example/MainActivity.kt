package id.tracive.sdk.extended.tracive_sdk_extended_example

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    // The local stand-in is on this device's own loopback, which a device proxy cannot reach.
    System.setProperty("http.nonProxyHosts", "127.0.0.1")
    super.onCreate(savedInstanceState)
  }
}

package id.tracive.sdk.flutter

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The Android steps of `openReportForm`. Dart validates and encodes the package and decides what
 * happens next; this class performs one step per call and reports the outcome.
 *
 * Error codes are the SDK's reason tokens and carry no message: nothing here may echo the
 * identifier, the link or the package.
 */
class TraciveSdkPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {

  private var channel: MethodChannel? = null
  private var context: Context? = null
  private var activity: Activity? = null
  private var io: ExecutorService? = null
  private val main = Handler(Looper.getMainLooper())

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    io = Executors.newSingleThreadExecutor()
    channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
    io?.shutdown()
    io = null
    context = null
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
  }

  override fun onDetachedFromActivityForConfigChanges() {
    activity = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    activity = binding.activity
  }

  override fun onDetachedFromActivity() {
    activity = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    val context = context ?: return result.error("unexpected", null, null)
    try {
      when (call.method) {
        "handOver" -> handOver(context, call, result)
        "isInstalled" -> result.success(isInstalled(context, call.requireString("androidPackage")))
        "openLink" -> openLink(context, call, result)
        else -> result.notImplemented()
      }
    } catch (_: IllegalArgumentException) {
      result.error("unexpected", null, null)
    }
  }

  private fun handOver(context: Context, call: MethodCall, result: MethodChannel.Result) {
    val targetPackage = call.requireString("androidPackage")
    val extension = call.requireString("fileExtension")
    val mimeType = call.requireString("mimeType")
    val bytes = call.argument<ByteArray>("package") ?: throw IllegalArgumentException("no package")
    val store = ReportPackageStore(context.cacheDir)
    val executor = io ?: return result.error("unexpected", null, null)

    // Up to 20 MiB: written off the main thread, then back to it to start the activity.
    executor.execute {
      val file =
        try {
          store.replaceWith(bytes, extension)
        } catch (_: IOException) {
          main.post { result.error("write_failed", null, null) }
          return@execute
        } catch (_: IllegalArgumentException) {
          main.post { result.error("write_failed", null, null) }
          return@execute
        }
      main.post { start(context, store, file, targetPackage, mimeType, result) }
    }
  }

  private fun start(
    context: Context,
    store: ReportPackageStore,
    file: File,
    targetPackage: String,
    mimeType: String,
    result: MethodChannel.Result,
  ) {
    val uri =
      try {
        FileProvider.getUriForFile(context, "${context.packageName}$AUTHORITY_SUFFIX", file)
      } catch (_: IllegalArgumentException) {
        store.clear()
        return result.error("provider_unavailable", null, null)
      }
    val intent =
      Intent(Intent.ACTION_VIEW)
        .setDataAndType(uri, mimeType)
        .setPackage(targetPackage)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)

    // An app too old to take a package has no activity for this type. That is the signal for the
    // link fallback, so it is an outcome, not an error.
    @Suppress("DEPRECATION")
    if (context.packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY) == null) {
      store.clear()
      return result.success(mapOf("outcome" to "notAccepted"))
    }
    try {
      launch(context, intent)
      result.success(mapOf("outcome" to "started"))
    } catch (_: ActivityNotFoundException) {
      result.error("activity_not_found", null, null)
    } catch (_: SecurityException) {
      result.error("activity_not_found", null, null)
    }
  }

  private fun openLink(context: Context, call: MethodCall, result: MethodChannel.Result) {
    // Explicit package: any app can claim a custom scheme, and this link carries the identifier.
    val intent =
      Intent(Intent.ACTION_VIEW, Uri.parse(call.requireString("link")))
        .setPackage(call.requireString("androidPackage"))
    try {
      launch(context, intent)
      result.success(true)
    } catch (_: ActivityNotFoundException) {
      result.error("activity_not_found", null, null)
    } catch (_: SecurityException) {
      result.error("activity_not_found", null, null)
    }
  }

  private fun launch(context: Context, intent: Intent) {
    val activity = activity
    if (activity != null) {
      activity.startActivity(intent)
    } else {
      context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
  }

  /**
   * Needs package visibility on API 30+: the SDK's manifest grants it for the production and
   * sandbox builds; any other target needs a `<queries><package>` entry in the host's own manifest.
   */
  @Suppress("DEPRECATION")
  private fun isInstalled(context: Context, targetPackage: String): Boolean =
    try {
      context.packageManager.getPackageInfo(targetPackage, 0)
      true
    } catch (_: PackageManager.NameNotFoundException) {
      false
    }

  private fun MethodCall.requireString(name: String): String =
    argument<String>(name) ?: throw IllegalArgumentException("missing $name")

  companion object {
    private const val CHANNEL = "tracive_sdk/report_form"

    /** Must match `android:authorities` in this module's manifest. */
    const val AUTHORITY_SUFFIX = ".tracive-flutter-files"
  }
}

package id.tracive.sdk.extended.flutter

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import id.tracive.sdk.extended.AccessTokenProvider
import id.tracive.sdk.extended.PreparedEvidence
import id.tracive.sdk.extended.ReportDraft
import id.tracive.sdk.extended.ReportErrorCode
import id.tracive.sdk.extended.ReportLimits
import id.tracive.sdk.extended.ReportProgressListener
import id.tracive.sdk.extended.ReportRequirements
import id.tracive.sdk.extended.RequiredTerm
import id.tracive.sdk.extended.SubmitResult
import id.tracive.sdk.extended.TraciveReportException
import id.tracive.sdk.extended.TraciveReports
import id.tracive.sdk.extended.ui.ReportFormOutcome
import id.tracive.sdk.extended.ui.ReportFormRequest
import id.tracive.sdk.extended.ui.ReportPrefill
import id.tracive.sdk.extended.ui.ReportPrefillAttachment
import id.tracive.sdk.extended.ui.ReportStatusOutcome
import id.tracive.sdk.extended.ui.ReportStatusRequest
import id.tracive.sdk.extended.ui.TraciveReportForm
import id.tracive.sdk.extended.ui.TraciveReportScreens
import id.tracive.sdk.extended.ui.TraciveReportStatus
import id.tracive.sdk.extended.ui.TraciveReportTheme
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.datetime.LocalDate

private const val CHANNEL = "tracive_sdk_extended/reports"
private const val REQUEST_FORM = 0x7452
private const val REQUEST_STATUS = 0x7453
private const val CANCELLED = "CANCELLED"

private class Instance(val reports: TraciveReports) {
  val evidence = mutableMapOf<Int, PreparedEvidence>()
  val calls = mutableSetOf<Job>()
  val submissions = mutableMapOf<String, Job>()
}

/**
 * Holds the native core for Dart. Everything here runs on the main thread, which is where a
 * MethodChannel must be used, so the maps need no lock. The core moves its own heavy work off it.
 */
class TraciveSdkExtendedPlugin :
  FlutterPlugin,
  MethodChannel.MethodCallHandler,
  ActivityAware,
  PluginRegistry.ActivityResultListener {

  private class OpenScreen(val requestCode: Int, val result: MethodChannel.Result)

  private var channel: MethodChannel? = null
  private var scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private var activityBinding: ActivityPluginBinding? = null
  private var openScreen: OpenScreen? = null
  private val instances = mutableMapOf<Int, Instance>()
  private val tokenWaiters = mutableSetOf<CancellableContinuation<String>>()
  private var nextHandle = 1
  private val main = Handler(Looper.getMainLooper())

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
    scope.cancel()
    // A form can outlive the engine under it, and nothing would ever answer these.
    tokenWaiters.toList().forEach { it.resumeWithException(engineGone()) }
    tokenWaiters.clear()
    instances.values.forEach { it.reports.close() }
    instances.clear()
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activityBinding = binding
    binding.addActivityResultListener(this)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    activityBinding?.removeActivityResultListener(this)
    activityBinding = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    onAttachedToActivity(binding)
  }

  override fun onDetachedFromActivity() {
    activityBinding?.removeActivityResultListener(this)
    activityBinding = null
    // No result can arrive now, and Dart would wait on it forever.
    openScreen?.let {
      openScreen = null
      it.result.success(
        if (it.requestCode == REQUEST_FORM) mapOf("outcome" to "cancelled") else "closed"
      )
    }
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    try {
      if (call.method == "create") return create(call, result)
      val instance =
        instances[call.require<Int>("reports")]
          ?: return result.error(CANCELLED, "This TraciveReports was disposed.", null)
      when (call.method) {
        "dispose" -> dispose(call.require("reports"), instance, result)
        "requirements" ->
          instance.launchCall(result) { result.success(instance.reports.requirements().toWire()) }
        "prepare" -> prepare(call, instance, result)
        "releaseEvidence" -> {
          instance.evidence.remove(call.require<Int>("evidence"))
          result.success(null)
        }
        "submit" -> submit(call, instance, result)
        "cancelSubmit" -> {
          instance.submissions[call.require<String>("key")]?.cancel()
          result.success(null)
        }
        "status" -> {
          val reportId = call.require<String>("reportId")
          instance.launchCall(result) { result.success(instance.reports.status(reportId).name) }
        }
        "openInTracive" -> result.success(instance.reports.openInTracive(call.require("reportId")))
        "presentForm" -> presentForm(call, instance, result)
        "presentStatus" -> presentStatus(call, instance, result)
        else -> result.notImplemented()
      }
    } catch (failure: Exception) {
      result.fail(failure)
    }
  }

  private fun create(call: MethodCall, result: MethodChannel.Result) {
    val handle = nextHandle++
    val reports =
      TraciveReports(
        baseUrl = call.require("baseUrl"),
        appUrlScheme = call.require("appUrlScheme"),
        accessToken = DartTokens(handle),
      )
    instances[handle] = Instance(reports)
    result.success(handle)
  }

  private fun dispose(handle: Int, instance: Instance, result: MethodChannel.Result) {
    instances.remove(handle)
    instance.calls.toList().forEach { it.cancel() }
    instance.reports.close()
    result.success(null)
  }

  private fun prepare(call: MethodCall, instance: Instance, result: MethodChannel.Result) {
    val bytes = call.require<ByteArray>("bytes")
    val mimeType = call.require<String>("mimeType")
    instance.launchCall(result) {
      val prepared = instance.reports.prepare(bytes, mimeType)
      val handle = nextHandle++
      instance.evidence[handle] = prepared
      result.success(
        mapOf(
          "evidence" to handle,
          "mimeType" to prepared.mimeType,
          "byteCount" to prepared.bytes.size,
        )
      )
    }
  }

  private fun submit(call: MethodCall, instance: Instance, result: MethodChannel.Result) {
    val key = call.require<String>("key")
    val draft =
      ReportDraft(
        identifiers = call.require("identifiers"),
        title = call.require("title"),
        chronology = call.require("chronology"),
        comment = call.argument("comment"),
        incidentDate = call.require("incidentDate"),
        evidence = call.require<List<Int>>("evidence").map { instance.heldEvidence(it) },
        acceptedTerms = call.require<List<Map<String, String>>>("terms").map(::requiredTerm),
        language = call.argument("language"),
        idempotencyKey = key,
      )
    val progress = ReportProgressListener { fraction ->
      main.post {
        channel?.invokeMethod("progress", mapOf("key" to key, "fraction" to fraction.toDouble()))
      }
    }
    val job =
      instance.launchCall(result) {
        try {
          when (val outcome = instance.reports.submit(draft, progress)) {
            is SubmitResult.Submitted ->
              result.success(
                mapOf(
                  "outcome" to "submitted",
                  "reportId" to outcome.reportId,
                  "status" to outcome.status.name,
                )
              )
            SubmitResult.NeedsConsent -> result.success(mapOf("outcome" to "needsConsent"))
            is SubmitResult.Failed -> result.fail(outcome.error)
          }
        } finally {
          instance.submissions.remove(key)
        }
      }
    if (job.isActive) instance.submissions[key] = job
  }

  private fun presentForm(call: MethodCall, instance: Instance, result: MethodChannel.Result) {
    val activity = startingScreen(result) ?: return
    TraciveReportScreens.configure(instance.reports)
    val request =
      ReportFormRequest(
        ReportPrefill(
          identifiers = call.require("identifiers"),
          incidentDate = call.argument<String>("incidentDate")?.let(LocalDate::parse),
          title = call.argument("title"),
          attachments =
            call.require<List<Map<String, Any>>>("attachments").map {
              ReportPrefillAttachment(it["bytes"] as ByteArray, it["mimeType"] as String)
            },
        ),
        call.theme(),
      )
    val intent = TraciveReportForm.Contract().createIntent(activity, request)
    openScreen = OpenScreen(REQUEST_FORM, result)
    activity.startActivityForResult(intent, REQUEST_FORM)
  }

  private fun presentStatus(call: MethodCall, instance: Instance, result: MethodChannel.Result) {
    val activity = startingScreen(result) ?: return
    TraciveReportScreens.configure(instance.reports)
    val request = ReportStatusRequest(call.require("reportId"), call.theme())
    val intent = TraciveReportStatus.Contract().createIntent(activity, request)
    openScreen = OpenScreen(REQUEST_STATUS, result)
    activity.startActivityForResult(intent, REQUEST_STATUS)
  }

  private fun startingScreen(result: MethodChannel.Result): Activity? {
    val activity = activityBinding?.activity
    when {
      activity == null -> result.error("SERVER", "There is no Activity to open it from.", null)
      openScreen != null -> result.error("SERVER", "A Tracive screen is already open.", null)
    }
    return activity.takeIf { openScreen == null }
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    val screen = openScreen?.takeIf { it.requestCode == requestCode } ?: return false
    openScreen = null
    when (requestCode) {
      REQUEST_FORM ->
        screen.result.success(TraciveReportForm.Contract().parseResult(resultCode, data).toWire())
      REQUEST_STATUS ->
        screen.result.success(TraciveReportStatus.Contract().parseResult(resultCode, data).toWire())
    }
    return true
  }

  private fun Instance.launchCall(
    result: MethodChannel.Result,
    block: suspend CoroutineScope.() -> Unit,
  ): Job {
    val job = scope.launch {
      try {
        block()
      } catch (failure: Exception) {
        result.fail(failure)
        if (failure is CancellationException) throw failure
      }
    }
    if (job.isActive) {
      calls += job
      job.invokeOnCompletion { main.post { calls -= job } }
    }
    return job
  }

  /** Native never refreshes: a rotating refresh token has one owner, the base SDK in Dart. */
  private inner class DartTokens(private val handle: Int) : AccessTokenProvider {
    override suspend fun accessToken(stale: String?): String =
      withContext(Dispatchers.Main.immediate) {
        val channel = channel ?: throw engineGone()
        suspendCancellableCoroutine { waiter ->
          tokenWaiters += waiter
          waiter.invokeOnCancellation { main.post { tokenWaiters -= waiter } }
          channel.invokeMethod(
            "accessToken",
            mapOf("reports" to handle, "stale" to stale),
            object : MethodChannel.Result {
              override fun success(value: Any?) {
                tokenWaiters -= waiter
                val token = value as? String
                if (token != null) waiter.resume(token) else waiter.resumeWithException(noAnswer())
              }

              override fun error(code: String, message: String?, details: Any?) {
                tokenWaiters -= waiter
                waiter.resumeWithException(reportException(code, message, details))
              }

              override fun notImplemented() {
                tokenWaiters -= waiter
                waiter.resumeWithException(noAnswer())
              }
            },
          )
        }
      }
  }
}

private fun Instance.heldEvidence(handle: Int): PreparedEvidence =
  evidence[handle]
    ?: throw TraciveReportException(
      ReportErrorCode.ATTACHMENT_INVALID,
      "The evidence was released.",
    )

private fun <T> MethodCall.require(name: String): T =
  requireNotNull(argument<T>(name)) { "Missing argument: $name" }

private fun MethodCall.theme() =
  TraciveReportTheme(
    primaryColor = argument<Number>("primaryColor")?.toLong()?.toInt(),
    cornerRadius = argument("cornerRadius"),
  )

private fun requiredTerm(term: Map<String, String>) =
  RequiredTerm(
    id = term.getValue("id"),
    version = term.getValue("version"),
    url = term.getValue("url"),
  )

private fun engineGone() =
  TraciveReportException(ReportErrorCode.SERVER, "The Flutter engine has stopped.")

private fun noAnswer() = TraciveReportException(ReportErrorCode.SERVER, "The token call failed.")

private fun reportException(code: String, message: String?, details: Any?): TraciveReportException {
  val extras = details as? Map<*, *>
  return TraciveReportException(
    ReportErrorCode.entries.firstOrNull { it.name == code } ?: ReportErrorCode.SERVER,
    message ?: code,
    httpStatus = (extras?.get("httpStatus") as? Number)?.toInt(),
    retryAfterSeconds = (extras?.get("retryAfterSeconds") as? Number)?.toLong(),
  )
}

private fun MethodChannel.Result.fail(failure: Throwable) {
  when (failure) {
    is TraciveReportException ->
      error(
        failure.code.name,
        failure.message,
        mapOf("httpStatus" to failure.httpStatus, "retryAfterSeconds" to failure.retryAfterSeconds),
      )
    is CancellationException -> error(CANCELLED, "The call was cancelled.", null)
    else -> error(ReportErrorCode.SERVER.name, "The call failed.", null)
  }
}

private fun ReportRequirements.toWire() =
  mapOf(
    "enabled" to enabled,
    "remainingToday" to remainingToday,
    "limits" to limits.toWire(),
    "terms" to terms.map { mapOf("id" to it.id, "version" to it.version, "url" to it.url) },
  )

private fun ReportLimits.toWire() =
  mapOf(
    "titleMaxLength" to titleMaxLength,
    "chronologyMinLength" to chronologyMinLength,
    "chronologyMaxLength" to chronologyMaxLength,
    "commentMaxLength" to commentMaxLength,
    "maxIdentifiers" to maxIdentifiers,
    "attachmentsPerIdentifier" to attachmentsPerIdentifier,
    "extraAttachmentsWithPhone" to extraAttachmentsWithPhone,
    "maxAttachmentBytes" to maxAttachmentBytes,
    "attachmentTypes" to attachmentTypes,
  )

private fun ReportFormOutcome.toWire(): Map<String, Any> =
  when (this) {
    is ReportFormOutcome.Submitted ->
      mapOf("outcome" to "submitted", "reportId" to reportId, "status" to status.name)
    ReportFormOutcome.NeedsConsent -> mapOf("outcome" to "needsConsent")
    ReportFormOutcome.Cancelled -> mapOf("outcome" to "cancelled")
  }

private fun ReportStatusOutcome.toWire(): String =
  when (this) {
    ReportStatusOutcome.Closed -> "closed"
    ReportStatusOutcome.NeedsConsent -> "needsConsent"
  }

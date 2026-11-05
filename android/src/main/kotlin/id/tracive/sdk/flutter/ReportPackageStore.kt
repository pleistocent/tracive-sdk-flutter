package id.tracive.sdk.flutter

import java.io.File
import java.io.IOException

/**
 * The one folder the SDK's FileProvider serves: `<cacheDir>/tracive-sdk/report/`.
 *
 * It holds at most one package. Whatever an earlier call left behind is deleted before the next one
 * is written, because the receiving app's read grant may outlive the call and nothing else ever
 * tells the SDK that the receiver is done with the file.
 */
internal class ReportPackageStore(cacheDir: File) {

  val directory: File = File(cacheDir, DIRECTORY)

  @Throws(IOException::class)
  fun replaceWith(bytes: ByteArray, extension: String): File {
    require(EXTENSION.matches(extension)) { "invalid file extension" }
    clear()
    if (!directory.mkdirs() && !directory.isDirectory) {
      throw IOException("cannot create the report folder")
    }
    return File(directory, "report.$extension").apply { writeBytes(bytes) }
  }

  fun clear() {
    directory.deleteRecursively()
  }

  companion object {
    /** Must match `path` in `res/xml/tracive_sdk_flutter_report_paths.xml`. */
    const val DIRECTORY = "tracive-sdk/report"

    private val EXTENSION = Regex("[A-Za-z0-9]+")
  }
}

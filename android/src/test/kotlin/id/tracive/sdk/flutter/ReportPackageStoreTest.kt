package id.tracive.sdk.flutter

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ReportPackageStoreTest {

  private lateinit var cacheDir: File

  @Before
  fun setUp() {
    cacheDir = Files.createTempDirectory("tracive-store-test").toFile()
  }

  @After
  fun tearDown() {
    cacheDir.deleteRecursively()
  }

  @Test
  fun writesThePackageIntoTheServedFolder() {
    val file = ReportPackageStore(cacheDir).replaceWith(byteArrayOf(1, 2, 3), "tracivereport")

    assertEquals(File(cacheDir, "tracive-sdk/report/report.tracivereport"), file)
    assertArrayEquals(byteArrayOf(1, 2, 3), file.readBytes())
  }

  @Test
  fun deletesWhatAnEarlierCallLeftBeforeWritingTheNextOne() {
    val store = ReportPackageStore(cacheDir)
    val first = store.replaceWith(byteArrayOf(1), "tracivesandboxreport")
    val stray = File(store.directory, "left-over.bin").apply { writeBytes(byteArrayOf(9)) }

    val second = store.replaceWith(byteArrayOf(2), "tracivereport")

    assertFalse(first.exists())
    assertFalse(stray.exists())
    assertEquals(listOf(second), store.directory.listFiles()!!.toList())
  }

  @Test
  fun leavesTheRestOfTheCacheAlone() {
    val hostFile = File(cacheDir, "host-app.db").apply { writeBytes(byteArrayOf(7)) }
    val store = ReportPackageStore(cacheDir)

    store.replaceWith(byteArrayOf(1), "tracivereport")
    store.clear()

    assertTrue(hostFile.exists())
    assertFalse(store.directory.exists())
  }

  @Test
  fun refusesAnExtensionThatCouldLeaveTheFolder() {
    assertThrows(IllegalArgumentException::class.java) {
      ReportPackageStore(cacheDir).replaceWith(byteArrayOf(1), "../escape")
    }
  }
}

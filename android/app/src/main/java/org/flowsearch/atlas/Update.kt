// SPDX-License-Identifier: MPL-2.0
package org.flowsearch.atlas

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.SystemUpdate
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/** The newest version on the download page (version.json). */
data class Release(val code: Int, val name: String, val address: String, val sha256: String, val notes: String)

object Updater {
    private const val PAGE = "https://mesh.flowsearch.org/app/"

    private fun open(address: String) = (URL(address).openConnection() as HttpURLConnection).apply {
        connectTimeout = 15_000
        readTimeout = 60_000
        setRequestProperty("User-Agent", "Atlas-Android")
        if (responseCode != 200) throw java.io.IOException("HTTP $responseCode")
    }

    suspend fun newest(): Release = withContext(Dispatchers.IO) {
        // the number at the end: no old copy from a cache on the way
        val c = open(PAGE + "version.json?t=" + System.currentTimeMillis())
        val o = JSONObject(c.inputStream.bufferedReader().use { it.readText() })
        Release(o.getInt("versionCode"), o.getString("versionName"), PAGE + o.getString("file"), o.getString("sha256"), o.optString("notes"))
    }

    /** loads the new app into the cache and checks that it is exactly the published file */
    suspend fun download(context: Context, release: Release, progress: (Float) -> Unit): File = withContext(Dispatchers.IO) {
        val file = File(context.cacheDir, "Atlas-update.apk")
        val c = open(release.address)
        val length = c.contentLength.toLong()
        val digest = MessageDigest.getInstance("SHA-256")
        c.inputStream.use { input ->
            file.outputStream().use { out ->
                val part = ByteArray(1 shl 16)
                var done = 0L
                var shown = 0L
                while (true) {
                    val n = input.read(part)
                    if (n < 0) break
                    out.write(part, 0, n)
                    digest.update(part, 0, n)
                    done += n
                    if (length > 0 && done - shown > length / 200) {
                        shown = done
                        progress(done.toFloat() / length)
                    }
                }
            }
        }
        val sum = digest.digest().joinToString("") { "%02x".format(it) }
        if (!sum.equals(release.sha256, ignoreCase = true)) {
            file.delete()
            throw java.io.IOException("the file is not the published one")
        }
        file
    }

    /** hands the file to Android, which asks the user and installs it (it accepts only the same signing key) */
    suspend fun install(context: Context, file: File) = withContext(Dispatchers.IO) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(context.packageName)
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            session.openWrite("atlas", 0, file.length()).use { out ->
                file.inputStream().use { it.copyTo(out) }
                session.fsync(out)
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            val answer = PendingIntent.getBroadcast(context, id, Intent(context, InstallReceiver::class.java), flags)
            session.commit(answer.intentSender)
        }
    }
}

/** What Android says about the installation. */
class InstallReceiver : BroadcastReceiver() {
    @Suppress("DEPRECATION")
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            // show Android's "do you want to update?" screen
            intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)?.let { context.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        } else if (status != PackageInstaller.STATUS_SUCCESS && status != PackageInstaller.STATUS_FAILURE_ABORTED) {
            val why = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "unknown reason"
            Toast.makeText(context, "The update could not be installed: $why", Toast.LENGTH_LONG).show()
        }
    }
}

/** The part of the settings that looks for a new version and installs it. */
@Composable
fun UpdateSetting() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf("Version ${BuildConfig.VERSION_NAME}") }
    var found by remember { mutableStateOf<Release?>(null) }
    var busy by remember { mutableStateOf(false) }
    var progress by remember { mutableStateOf<Float?>(null) }

    fun check() = scope.launch {
        busy = true
        text = "Looking for a new version…"
        runCatching { Updater.newest() }.onSuccess {
            found = it.takeIf { r -> r.code > BuildConfig.VERSION_CODE }
            text = if (found == null) "Version ${BuildConfig.VERSION_NAME} is the newest." else "Version ${it.name} is ready. ${it.notes}"
        }.onFailure { text = "Could not look for updates. Check your connection." }
        busy = false
    }

    fun update(release: Release) {
        if (!context.packageManager.canRequestPackageInstalls()) {
            text = "Allow Atlas to install apps, then come back and tap Update again."
            context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}")))
            return
        }
        scope.launch {
            busy = true
            progress = 0f
            text = "Downloading version ${release.name}…"
            runCatching {
                val file = Updater.download(context, release) { progress = it }
                text = "Installing…"
                progress = null
                Updater.install(context, file)
            }.onSuccess { text = "Confirm the update on the screen that opens." }
                .onFailure { text = "The update failed: ${it.message}" }
            progress = null
            busy = false
        }
    }

    Column {
        ListItem(
            headlineContent = { Text("App update") }, supportingContent = { Text(text) },
            leadingContent = { Icon(Icons.Filled.SystemUpdate, null) },
            trailingContent = {
                val release = found
                Button(onClick = { if (release != null) update(release) else check() }, enabled = !busy) {
                    Text(if (release != null) "Update" else "Check")
                }
            },
        )
        progress?.let { LinearProgressIndicator(progress = { it }, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)) }
    }
}

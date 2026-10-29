package com.spatialbridge.android.diagnostics

import android.content.Context
import android.content.Intent
import android.os.Build
import com.spatialbridge.android.BuildConfig
import com.spatialbridge.android.settings.AppSettings
import com.spatialbridge.android.settings.TransferOutcome
import com.spatialbridge.android.settings.TransferRecord

/**
 * A redacted, human-readable diagnostics summary. It contains app/OS versions, settings and outcome
 * counts by error code. It never contains filenames, file contents, peer IDs, names, addresses or secrets.
 */
object Diagnostics {
    data class Environment(val appVersion: String, val build: Int, val osRelease: String, val sdk: Int, val model: String)

    fun currentEnvironment() = Environment(
        BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE, Build.VERSION.RELEASE ?: "?", Build.VERSION.SDK_INT,
        "${Build.MANUFACTURER} ${Build.MODEL}",
    )

    fun report(env: Environment, settings: AppSettings, pairedCount: Int, history: List<TransferRecord>): String = buildString {
        appendLine("Drager diagnostics")
        appendLine("app=${env.appVersion} (${env.build}) platform=android os=${env.osRelease} sdk=${env.sdk} device=${env.model}")
        appendLine("paired=$pairedCount placement=${settings.layout.placement.raw} offset=${"%.2f".format(settings.layout.alignmentOffset)} mirrored=${settings.layout.mirrored}")
        appendLine("sensitivity=${"%.1f".format(settings.gestureSensitivity)} keepHistory=${settings.keepHistory}")
        val byOutcome = TransferOutcome.entries.associateWith { o -> history.count { it.outcome == o } }
        appendLine("transfers=" + byOutcome.entries.joinToString(" ") { "${it.key.name.lowercase()}=${it.value}" })
        val codes = history.mapNotNull { it.errorCode?.wire }.groupingBy { it }.eachCount().toSortedMap()
        appendLine("errors=" + if (codes.isEmpty()) "none" else codes.entries.joinToString(" ") { "${it.key}=${it.value}" })
    }

    fun shareIntent(context: Context, text: String): Intent {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, "Drager diagnostics")
            putExtra(Intent.EXTRA_TEXT, text)
        }
        return Intent.createChooser(send, "Share Diagnostics").also {
            if (context !is android.app.Activity) it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
    }
}

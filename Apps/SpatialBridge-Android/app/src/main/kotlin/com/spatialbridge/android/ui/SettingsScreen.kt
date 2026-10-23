package com.spatialbridge.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.MedicalServices
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.spatialbridge.android.AppModel
import com.spatialbridge.android.BuildConfig
import com.spatialbridge.android.diagnostics.Diagnostics
import com.spatialbridge.android.model.ErrorCopy
import com.spatialbridge.android.platform.ManualEndpoint
import com.spatialbridge.android.settings.TransferOutcome
import java.text.DateFormat
import java.util.Date
import kotlin.math.roundToInt

/** Paired computers, gesture sensitivity, calibration, history, diagnostics and reset. */
@Composable
fun SettingsScreen(model: AppModel, onPair: () -> Unit, onCalibrate: () -> Unit) {
    val settings by model.settings.collectAsStateWithLifecycle()
    val trusted by model.trustedPeers.collectAsStateWithLifecycle()
    val history by model.history.collectAsStateWithLifecycle()
    var confirmReset by rememberSaveable { mutableStateOf(false) }
    val context = LocalContext.current
    val preferredID = settings.preferredPeerID ?: trusted.firstOrNull()?.peerID

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Tokens.gutter).testTag("settings.form"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Header("Paired computers")
        if (trusted.isEmpty()) Text("No paired computers", color = MaterialTheme.colorScheme.onSurfaceVariant)
        trusted.forEach { peer ->
            Row(Modifier.fillMaxWidth().heightIn(min = Tokens.minTouch).testTag("settings.peer.${peer.peerID}"), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(platformIcon(peer.platform), platformName(peer.platform), tint = MaterialTheme.colorScheme.primary)
                Column(Modifier.weight(1f)) {
                    Text(peer.displayName)
                    Text(fingerprint(peer.peerID), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                val preferred = peer.peerID == preferredID
                IconButton(onClick = { model.setPreferred(peer.peerID) }, enabled = !preferred, modifier = Modifier.testTag("settings.prefer")) {
                    Icon(if (preferred) Icons.Filled.Star else Icons.Filled.StarBorder, contentDescription = if (preferred) "Preferred" else "Make preferred")
                }
                TextButton(onClick = { model.unpair(peer.peerID) }, modifier = Modifier.testTag("settings.unpair")) { Text("Unpair", color = MaterialTheme.colorScheme.error) }
            }
        }
        TextButton(onClick = onPair, modifier = Modifier.testTag("settings.pair")) {
            Icon(Icons.Filled.Add, null, Modifier.size(18.dp)); Text("  Pair Another Computer")
        }
        Footnote("Unpair on the computer too to remove trust on both sides.")
        HorizontalDivider()

        Header("Gesture")
        val sensitivity = settings.gestureSensitivity
        Row { Text("Sensitivity", Modifier.weight(1f)); Text(sensitivityLabel(sensitivity), color = MaterialTheme.colorScheme.onSurfaceVariant) }
        Slider(
            value = sensitivity.toFloat(),
            onValueChange = { v -> model.settingsStore.update { it.copy(gestureSensitivity = (v * 10).roundToInt() / 10.0) } },
            valueRange = 0.5f..2.0f, steps = 14,
            modifier = Modifier.testTag("settings.sensitivity").semantics { stateDescription = sensitivityLabel(sensitivity) },
        )
        Footnote("Needs a flick of ${model.gestureConfiguration.effectiveVelocityThreshold.roundToInt()} dp/s toward the edge.")
        SensitivityPreview(model)
        TextButton(onClick = onCalibrate, modifier = Modifier.testTag("settings.calibration")) {
            Text("Calibration  "); Icon(Icons.AutoMirrored.Filled.ArrowForward, null, Modifier.size(18.dp))
        }
        HorizontalDivider()

        Header("History")
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Keep transfer history", Modifier.weight(1f))
            Switch(settings.keepHistory, onCheckedChange = model::setKeepHistory, modifier = Modifier.testTag("settings.keepHistory"))
        }
        TextButton(onClick = model::clearHistory, enabled = history.isNotEmpty()) { Text("Clear History") }
        Footnote("Only names, sizes and outcomes are kept, on this device. Logs never include filenames.")
        HorizontalDivider()

        Header("Diagnostics")
        TextButton(
            onClick = {
                val report = Diagnostics.report(Diagnostics.currentEnvironment(), settings, trusted.size, history)
                context.startActivity(Diagnostics.shareIntent(context, report))
            },
            modifier = Modifier.testTag("settings.diagnostics"),
        ) { Icon(Icons.Filled.MedicalServices, null, Modifier.size(18.dp)); Text("  Prepare Diagnostics…") }
        Footnote("Diagnostics are scrubbed of filenames, device names, addresses and keys.")
        Text("Version ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})", style = MaterialTheme.typography.labelSmall)

        if (BuildConfig.DEBUG) {
            HorizontalDivider()
            Header("Debug")
            ManualEndpointField(settings.manualEndpoint) { value -> model.settingsStore.update { it.copy(manualEndpoint = value) } }
        }

        HorizontalDivider()
        TextButton(onClick = { confirmReset = true }, modifier = Modifier.testTag("settings.reset")) {
            Text("Reset Spatial Bridge", color = MaterialTheme.colorScheme.error)
        }
    }

    if (confirmReset) {
        AlertDialog(
            onDismissRequest = { confirmReset = false },
            title = { Text("Reset Spatial Bridge?") },
            text = { Text("This unpairs every computer, clears history and restores default settings.") },
            confirmButton = {
                TextButton(onClick = { confirmReset = false; model.resetEverything() }, modifier = Modifier.testTag("settings.reset.confirm")) {
                    Text("Unpair All and Reset", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { confirmReset = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun Header(text: String) = Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)

@Composable
private fun Footnote(text: String) = Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

private fun sensitivityLabel(value: Double) = when {
    value < 0.8 -> "Firm"
    value < 1.3 -> "Normal"
    else -> "Easy"
}

/** Live preview of the current threshold: flick the chip to see whether it fires. */
@Composable
private fun SensitivityPreview(model: AppModel) {
    val settings by model.settings.collectAsStateWithLifecycle()
    var result by remember { mutableStateOf("Flick to test") }
    ThrowSurface(
        edge = settings.layout.exitEdge,
        configuration = model.gestureConfiguration,
        engines = model.gestureEngines,
        enabled = true,
        onFire = { result = "Fired at ${it.outwardVelocity.roundToInt()} dp/s" },
        modifier = Modifier.fillMaxWidth().height(180.dp),
    ) {
        Text(result, style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(12.dp))
    }
}

/** Debug builds only: connect to `host:port` directly, e.g. `10.0.2.2:PORT` from the emulator. */
@Composable
private fun ManualEndpointField(current: String?, onChange: (String?) -> Unit) {
    var text by rememberSaveable { mutableStateOf(current.orEmpty()) }
    val valid = text.isBlank() || ManualEndpoint.parse(text) != null
    OutlinedTextField(
        value = text,
        onValueChange = {
            text = it
            if (it.isBlank()) onChange(null) else if (ManualEndpoint.parse(it) != null) onChange(it.trim())
        },
        label = { Text("Manual endpoint (host:port)") },
        placeholder = { Text("${ManualEndpoint.EMULATOR_HOST}:52000") },
        isError = !valid,
        supportingText = { Text(if (valid) "Bypasses discovery. Debug builds only." else "Use host:port") },
        singleLine = true,
        modifier = Modifier.fillMaxWidth().testTag("settings.manualEndpoint"),
    )
}

/** Metadata-only transfer history. The UI may show names; logs never do. */
@Composable
fun HistoryScreen(model: AppModel) {
    val history by model.history.collectAsStateWithLifecycle()
    if (history.isEmpty()) {
        StateMessage(Icons.Filled.History, "No transfers yet", "Files you send appear here.", Modifier.padding(Tokens.gutter).testTag("history.empty"))
        return
    }
    val formatter = remember { DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT) }
    LazyColumn(Modifier.fillMaxSize().testTag("history.list"), contentPadding = androidx.compose.foundation.layout.PaddingValues(Tokens.gutter), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Row(Modifier.fillMaxWidth()) {
                Text("${history.size} transfers", Modifier.weight(1f).height(Tokens.minTouch).padding(top = 12.dp), style = MaterialTheme.typography.labelLarge)
                TextButton(onClick = model::clearHistory) { Text("Clear", color = MaterialTheme.colorScheme.error) }
            }
        }
        items(history) { record ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                when (record.outcome) {
                    TransferOutcome.COMPLETED -> Icon(Icons.Filled.CheckCircle, "Saved", tint = successColor())
                    TransferOutcome.FAILED -> Icon(Icons.Filled.Error, "Failed", tint = MaterialTheme.colorScheme.error)
                    TransferOutcome.CANCELLED -> Icon(Icons.Filled.Cancel, "Cancelled", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Column(Modifier.weight(1f)) {
                    Text(record.filename, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
                    Text("${record.peerName} · ${formatBytes(record.byteCount)} · ${formatter.format(Date(record.atMillis))}",
                        style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    record.errorCode?.let { Text(ErrorCopy.message(it), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error) }
                }
            }
        }
    }
}

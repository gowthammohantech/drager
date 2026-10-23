package com.spatialbridge.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.WifiTethering
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.spatialbridge.android.model.TransferPhase
import com.spatialbridge.android.model.TransferUi

/**
 * Connecting / Offering / Sending / Saving / Saved / Failed / Cancelled. Progress is bytes the receiver
 * acknowledged; "Saved" appears only after COMMITTED (see [TransferUi.isSuccess]).
 */
@Composable
fun TransferStatusCard(ui: TransferUi, onCancel: () -> Unit, onRetry: () -> Unit, onDismiss: () -> Unit) {
    SectionCard(Modifier.testTag("transfer.status").semantics { liveRegion = LiveRegionMode.Polite }) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            when {
                ui.isSuccess -> Icon(Icons.Filled.CheckCircle, null, tint = successColor(), modifier = Modifier.size(28.dp))
                ui.phase == TransferPhase.FAILED -> Icon(Icons.Filled.Error, null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(28.dp))
                ui.phase == TransferPhase.CANCELLED -> Icon(Icons.Filled.Cancel, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(28.dp))
                ui.phase == TransferPhase.CONNECTING -> Icon(Icons.Filled.WifiTethering, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(28.dp))
                else -> CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
            }
            Column(Modifier.weight(1f)) {
                Text(ui.title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.testTag(if (ui.isSuccess) "transfer.success" else "transfer.title"))
                Text(ui.subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            when {
                ui.phase.isActive && ui.phase != TransferPhase.AWAITING_COMMIT ->
                    OutlinedButton(onClick = onCancel, modifier = Modifier.testTag("transfer.cancel")) { Text("Cancel") }
                ui.phase == TransferPhase.FAILED || ui.phase == TransferPhase.CANCELLED -> Row {
                    Button(onClick = onRetry, modifier = Modifier.testTag("transfer.retry")) { Text("Retry") }
                    IconButton(onClick = onDismiss, modifier = Modifier.testTag("transfer.dismiss")) { Icon(Icons.Filled.Close, contentDescription = "Dismiss") }
                }
                ui.isSuccess -> IconButton(onClick = onDismiss, modifier = Modifier.testTag("transfer.dismiss")) { Icon(Icons.Filled.Close, contentDescription = "Dismiss") }
                else -> Spacer(Modifier.size(0.dp))
            }
        }
        if (ui.phase.showsProgress) {
            val percent = (ui.fraction * 100).toInt()
            LinearProgressIndicator(
                progress = { ui.fraction },
                modifier = Modifier.fillMaxWidth().testTag("transfer.progress").semantics { stateDescription = "$percent percent" },
            )
            if (ui.phase == TransferPhase.SENDING) {
                Text("${formatBytes(ui.sentBytes)} of ${formatBytes(ui.totalBytes)}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (ui.phase == TransferPhase.FAILED && ui.error != null) {
            ErrorBanner(ui.error, Modifier.testTag("transfer.error"))
        }
    }
}

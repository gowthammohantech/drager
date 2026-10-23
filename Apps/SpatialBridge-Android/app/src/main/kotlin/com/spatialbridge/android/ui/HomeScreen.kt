package com.spatialbridge.android.ui

import android.graphics.BitmapFactory
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.spatialbridge.android.AppModel
import com.spatialbridge.android.content.StagedItem
import com.spatialbridge.android.model.displayName
import com.spatialbridge.android.settings.TransferOutcome
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Main screen: computer status, pickers, the staged item on the throw surface and recent transfers. */
@Composable
fun HomeScreen(model: AppModel, onPair: () -> Unit) {
    val staged by model.staged.collectAsStateWithLifecycle()
    val importing by model.importing.collectAsStateWithLifecycle()
    val importError by model.importError.collectAsStateWithLifecycle()
    val settings by model.settings.collectAsStateWithLifecycle()

    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri?.let(model::import)
    }
    val documentPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let(model::import)
    }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Tokens.gutter),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        StatusCard(model, onPair)
        val item = staged
        if (item != null) {
            SendStage(model, item)
        } else {
            SectionCard(Modifier.testTag("home.empty")) {
                StateMessage(
                    Icons.Filled.PhotoLibrary, "Choose something to send",
                    "Pick photos or files, then flick them toward the ${settings.layout.exitEdge.displayName.lowercase()} edge.",
                )
            }
        }
        if (importing) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically, modifier = Modifier.testTag("home.importing")) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                Text("Preparing your file…", style = MaterialTheme.typography.bodySmall)
            }
        }
        importError?.let { ErrorBanner(it, Modifier.testTag("home.importError")) }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedButton(
                onClick = { photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)) },
                modifier = Modifier.weight(1f).heightIn(min = Tokens.minTouch).testTag("home.photos"),
            ) {
                Icon(Icons.Filled.Photo, null, Modifier.size(18.dp)); Text("  Photos")
            }
            OutlinedButton(
                onClick = { documentPicker.launch(arrayOf("*/*")) },
                modifier = Modifier.weight(1f).heightIn(min = Tokens.minTouch).testTag("home.files"),
            ) {
                Icon(Icons.Filled.Folder, null, Modifier.size(18.dp)); Text("  Files")
            }
        }
        RecentTransfers(model)
    }
}

@Composable
private fun StatusCard(model: AppModel, onPair: () -> Unit) {
    val trusted by model.trustedPeers.collectAsStateWithLifecycle()
    val settings by model.settings.collectAsStateWithLifecycle()
    val peer = trusted.firstOrNull { it.peerID == settings.preferredPeerID } ?: trusted.firstOrNull()
    SectionCard(Modifier.testTag("home.status")) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(platformIcon(peer?.platform), null, tint = if (peer != null) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(36.dp))
            Column(Modifier.weight(1f)) {
                Text(peer?.displayName ?: "No computer paired", style = MaterialTheme.typography.titleMedium, modifier = Modifier.testTag("home.peerName"))
                Text(
                    if (peer != null) "Paired · on this network" else "Pair your Mac or Windows PC to start",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        if (peer == null) PrimaryButton("Pair a Computer", Modifier.testTag("home.pair"), Icons.Filled.Add, onClick = onPair)
    }
}

@Composable
private fun SendStage(model: AppModel, item: StagedItem) {
    val settings by model.settings.collectAsStateWithLifecycle()
    val transfer by model.transferUi.collectAsStateWithLifecycle()
    val trusted by model.trustedPeers.collectAsStateWithLifecycle()
    val peerName = (trusted.firstOrNull { it.peerID == settings.preferredPeerID } ?: trusted.firstOrNull())?.displayName
    val canSend = trusted.isNotEmpty() && !transfer.phase.isActive
    val edge = settings.layout.exitEdge.displayName.lowercase()

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        ThrowSurface(
            edge = settings.layout.exitEdge,
            configuration = model.gestureConfiguration,
            engines = model.gestureEngines,
            enabled = canSend,
            onFire = { model.send(it) },
            modifier = Modifier.fillMaxWidth().height(360.dp).testTag("home.throwSurface").semantics {
                contentDescription = "${item.displayName}. Flick toward the $edge edge to send, or use the Send button."
                customActions = listOf(CustomAccessibilityAction("Send to computer") { model.send(null); true })
            },
        ) { ItemCard(item) }

        if (transfer.phase != com.spatialbridge.android.model.TransferPhase.IDLE) {
            TransferStatusCard(transfer, onCancel = model::cancelTransfer, onRetry = model::retry, onDismiss = model::dismissTransfer)
        }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Button(
                onClick = { model.send(null) },
                enabled = canSend,
                modifier = Modifier.weight(1f).heightIn(min = Tokens.minTouch).testTag("home.send"),
            ) {
                Icon(Icons.AutoMirrored.Filled.Send, null, Modifier.size(18.dp))
                Text("  Send to ${peerName ?: "computer"}")
            }
            IconButton(onClick = model::clearStaged, enabled = !transfer.phase.isActive, modifier = Modifier.testTag("home.clear")) {
                Icon(Icons.Filled.Close, contentDescription = "Remove item")
            }
        }
    }
}

@Composable
private fun ItemCard(item: StagedItem) {
    val thumbnail by produceState<ImageBitmap?>(null, item.id) {
        if (item.isImage) value = withContext(Dispatchers.IO) { decodeThumbnail(item.file.path) }
    }
    Column(
        Modifier.width(196.dp).background(MaterialTheme.colorScheme.surface, RoundedCornerShape(20.dp)).padding(8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(Modifier.size(180.dp, 200.dp).clip(RoundedCornerShape(14.dp)).background(MaterialTheme.colorScheme.surfaceVariant), contentAlignment = Alignment.Center) {
            val bitmap = thumbnail
            if (bitmap != null) {
                Image(bitmap, null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            } else {
                Icon(
                    when {
                        item.isImage -> Icons.Filled.Photo
                        item.isVideo -> Icons.Filled.Videocam
                        else -> Icons.AutoMirrored.Filled.InsertDriveFile
                    },
                    null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Text(item.displayName, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.MiddleEllipsis, modifier = Modifier.testTag("item.name"))
        Text(formatBytes(item.file.byteCount), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun decodeThumbnail(path: String): ImageBitmap? = runCatching {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(path, bounds)
    var sample = 1
    while (bounds.outWidth / (sample * 2) >= 400 && bounds.outHeight / (sample * 2) >= 400) sample *= 2
    BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
}.getOrNull()

@Composable
private fun RecentTransfers(model: AppModel) {
    val history by model.history.collectAsStateWithLifecycle()
    if (history.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.testTag("home.recent")) {
        Text("Recent", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
        history.take(3).forEach { record ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                val ok = record.outcome == TransferOutcome.COMPLETED
                Icon(if (ok) Icons.Filled.CheckCircle else Icons.Filled.Error, null, tint = if (ok) successColor() else Tokens.warning, modifier = Modifier.size(18.dp))
                Text(record.filename, maxLines = 1, overflow = TextOverflow.MiddleEllipsis, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                Text(record.peerName, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

package com.spatialbridge.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.spatialbridge.android.AppModel
import com.spatialbridge.android.PairingSheetState
import com.spatialbridge.core.PairingState

@Composable
fun PairingSheetHost(model: AppModel, onPairedDone: () -> Unit = {}) {
    val sheet by model.pairingSheet.collectAsStateWithLifecycle()
    sheet?.let { PairingSheet(model, it, onPairedDone) }
}

/** Code comparison and pairing progress (FR-107). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PairingSheet(model: AppModel, sheet: PairingSheetState, onPairedDone: () -> Unit) {
    val done = {
        model.dismissPairing()
        onPairedDone()
    }
    val busy = sheet.state is PairingState.Connecting || sheet.state is PairingState.WaitingForPeer
    val currentBusy by rememberUpdatedState(busy)
    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = true,
        confirmValueChange = { it != SheetValue.Hidden || !currentBusy },
    )
    val lastCode = remember { mutableStateOf("") }
    (sheet.state as? PairingState.CompareCode)?.let { lastCode.value = it.code }
    ModalBottomSheet(
        onDismissRequest = {
            when (sheet.state) {
                is PairingState.Paired -> done()
                is PairingState.Failed -> model.dismissPairing()
                else -> model.cancelPairing()
            }
        },
        sheetState = sheetState,
        modifier = Modifier.testTag("pairing.sheet"),
    ) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 24.dp).navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            when (val state = sheet.state) {
                PairingState.Idle, PairingState.Connecting -> {
                    Spacer(Modifier.height(24.dp))
                    CircularProgressIndicator()
                    Text("Connecting to ${sheet.peerName}…", style = MaterialTheme.typography.titleMedium)
                    TextButton(onClick = model::cancelPairing, modifier = Modifier.testTag("pairing.cancel")) { Text("Cancel") }
                }
                is PairingState.CompareCode -> CodeComparison(model, state.peerName, state.code, waiting = false)
                // Keep showing the code the user confirmed while the computer decides.
                PairingState.WaitingForPeer -> CodeComparison(model, sheet.peerName, lastCode.value, waiting = true)
                is PairingState.Paired -> {
                    Icon(Icons.Filled.Verified, null, tint = successColor(), modifier = Modifier.size(64.dp))
                    Text("Paired with ${sheet.peerName}", style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center,
                        modifier = Modifier.testTag("pairing.success"))
                    Text("You can now throw files to this computer.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    PrimaryButton("Done", Modifier.testTag("pairing.done"), onClick = done)
                }
                is PairingState.Failed -> {
                    Icon(Icons.Filled.Cancel, null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(64.dp))
                    Text("Pairing didn't complete", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.testTag("pairing.failed"))
                    ErrorBanner(state.code)
                    PrimaryButton("OK", Modifier.testTag("pairing.ok"), onClick = model::dismissPairing)
                }
            }
        }
    }
}

@Composable
private fun CodeComparison(model: AppModel, peerName: String, code: String, waiting: Boolean) {
    val shown = code
    Text(
        "Does this code match the one on your computer?",
        style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center,
    )
    Text(
        formatCode(shown),
        fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, fontSize = 48.sp, letterSpacing = 4.sp,
        modifier = Modifier
            .background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(16.dp))
            .padding(horizontal = 24.dp, vertical = 16.dp)
            .testTag("pairing.code")
            .semantics { contentDescription = "Code " + shown.toList().joinToString(" ") },
    )
    Text(peerName, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (waiting) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }.testTag("pairing.waiting"),
        ) {
            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            Text("Waiting for you to confirm on $peerName…", style = MaterialTheme.typography.bodyMedium)
        }
        TextButton(onClick = model::cancelPairing) { Text("Cancel") }
    } else {
        PrimaryButton("Codes Match", Modifier.testTag("pairing.match"), Icons.Filled.Check) { model.answerPairing(true) }
        TextButton(
            onClick = { model.answerPairing(false) },
            modifier = Modifier.fillMaxWidth().heightIn(min = Tokens.minTouch).testTag("pairing.mismatch"),
        ) { Text("They Don't Match", color = MaterialTheme.colorScheme.error) }
    }
}

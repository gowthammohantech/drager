package com.spatialbridge.android.ui

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.VpnLock
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.filled.WifiTethering
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.spatialbridge.android.AppModel
import com.spatialbridge.android.platform.TxtRecordParser
import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.DiscoveredPeer

/** Computers on the network: paired ones and ones accepting pairing (BR-02). */
@Composable
fun DiscoveryScreen(model: AppModel) {
    val peers by model.peers.collectAsStateWithLifecycle()
    val denied by model.localNetworkDenied.collectAsStateWithLifecycle()
    var troubleshooting by rememberSaveable { mutableStateOf(false) }
    val context = LocalContext.current
    val pairable = peers.filter { it.pairingAvailable && !it.isTrusted }
    val trusted = peers.filter { it.isTrusted }

    LazyColumn(
        Modifier.fillMaxSize().testTag("discover.list"),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(Tokens.gutter),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (denied) {
            item {
                ErrorBanner(BridgeErrorCode.LOCAL_NETWORK_DENIED, Modifier.testTag("discover.permissionDenied")) {
                    TextButton(onClick = {
                        context.startActivity(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)),
                        )
                    }) { Text("Open Settings") }
                }
            }
        }
        item { SectionHeader("Nearby computers") }
        if (pairable.isEmpty()) {
            item {
                Row(Modifier.fillMaxWidth().padding(vertical = 8.dp).testTag("discover.searching"), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
                    Column {
                        Text("Looking for computers…")
                        Text(
                            "Open Drager on your Mac or Windows PC and keep both devices on the same Wi-Fi.",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        } else {
            items(pairable, key = { "p-" + it.peerID }) { peer ->
                PeerRow(
                    peer = peer,
                    subtitle = "${platformName(peer.platform).replaceFirstChar { it.uppercase() }} · Ready to pair",
                    trailing = "Pair",
                    modifier = Modifier.testTag("discover.peer.${peer.peerID}"),
                    onClick = { model.pair(peer) },
                )
            }
        }
        item {
            TextButton(onClick = { troubleshooting = true }, modifier = Modifier.testTag("discover.troubleshoot")) { Text("Can't find your computer?") }
        }
        if (trusted.isNotEmpty()) {
            item { SectionHeader("Paired") }
            items(trusted, key = { "t-" + it.peerID }) { peer ->
                PeerRow(peer = peer, subtitle = "Paired · nearby", trailing = null, trustedBadge = true)
            }
        }
    }
    if (troubleshooting) TroubleshootingDialog { troubleshooting = false }
}

@Composable
private fun SectionHeader(text: String) {
    Text(text, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(top = 8.dp))
}

@Composable
fun PeerRow(
    peer: DiscoveredPeer,
    subtitle: String,
    trailing: String?,
    modifier: Modifier = Modifier,
    trustedBadge: Boolean = false,
    onClick: (() -> Unit)? = null,
) {
    val clickable = if (onClick != null) {
        Modifier.clickable(role = Role.Button, onClickLabel = "Start pairing. You'll compare a code on both screens.", onClick = onClick)
    } else Modifier
    SectionCard(modifier.then(clickable)) {
        Row(Modifier.fillMaxWidth().heightIn(min = Tokens.minTouch), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(platformIcon(peer.platform), contentDescription = platformName(peer.platform), tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(32.dp))
            Column(Modifier.weight(1f)) {
                Text(peer.displayName, fontWeight = FontWeight.Medium)
                Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (trustedBadge) Icon(Icons.Filled.Verified, contentDescription = "Paired", tint = successColor())
            if (trailing != null) Text(trailing, color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
fun TroubleshootingDialog(onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = onDismiss, modifier = Modifier.testTag("troubleshoot.done")) { Text("Done") } },
        title = { Text("Troubleshooting") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                ExplainerRow(Icons.Filled.Computer, "Open the computer app", "Drager must be running on your Mac or Windows PC with Available turned on.")
                ExplainerRow(Icons.Filled.Wifi, "Same Wi-Fi", "Both devices need to be on the same Wi-Fi network. Guest networks often block devices from seeing each other.")
                ExplainerRow(Icons.Filled.Security, "Private network on Windows", "On Windows, set this Wi-Fi network to Private (Settings › Network & internet › Wi-Fi › your network) and allow Drager through the firewall.")
                ExplainerRow(Icons.Filled.VpnLock, "VPNs and firewalls", "Some VPNs and router settings block local discovery. Try pausing the VPN.")
                ExplainerRow(Icons.Filled.WifiTethering, "Nearby devices permission", "On Android: Settings › Apps › Drager › Permissions › Nearby devices. On Mac: System Settings › Privacy & Security › Local Network.")
                Text("Service: ${TxtRecordParser.SERVICE_TYPE}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp))
            }
        },
    )
}

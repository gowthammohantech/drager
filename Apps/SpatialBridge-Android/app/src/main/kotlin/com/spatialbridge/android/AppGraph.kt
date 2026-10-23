package com.spatialbridge.android

import android.content.Context
import android.os.Build
import android.provider.Settings
import androidx.core.content.edit
import com.spatialbridge.android.diagnostics.BridgeLog
import com.spatialbridge.android.platform.KeystoreSecretStore
import com.spatialbridge.android.platform.ManualEndpoint
import com.spatialbridge.android.platform.ManualTarget
import com.spatialbridge.android.platform.NsdPeerDiscovery
import com.spatialbridge.android.platform.NsdSink
import com.spatialbridge.android.platform.PeerBrowser
import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.model.TrustedPeer
import com.spatialbridge.core.net.Endpoint
import com.spatialbridge.core.service.DiscoveryState
import com.spatialbridge.core.service.LocatedPeer
import com.spatialbridge.core.service.PeerLocator
import com.spatialbridge.core.service.ResolvedPeerLocator
import com.spatialbridge.core.service.ResolvedService
import com.spatialbridge.core.service.SenderService
import com.spatialbridge.core.service.ServiceRole
import com.spatialbridge.core.store.FileTrustedPeerStore
import com.spatialbridge.core.store.IdentityStore
import com.spatialbridge.core.store.PairSecretStore
import com.spatialbridge.core.store.SecretStore
import com.spatialbridge.core.store.TrustedPeerStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import java.io.File

/** [FileTrustedPeerStore] with its file I/O moved to [Dispatchers.IO] (callers may be on the main thread). */
class AppTrustedPeerStore(file: File) : TrustedPeerStore {
    private val inner = FileTrustedPeerStore(file)
    override suspend fun all() = withContext(Dispatchers.IO) { inner.all() }
    override suspend fun upsert(peer: TrustedPeer) = withContext(Dispatchers.IO) { inner.upsert(peer) }
    override suspend fun remove(peerID: String) = withContext(Dispatchers.IO) { inner.remove(peerID) }
    override suspend fun markSeen(peerID: String, atMillis: Long) = withContext(Dispatchers.IO) { inner.markSeen(peerID, atMillis) }
}

/**
 * The locator the app gives [SenderService]: core's [ResolvedPeerLocator] fed by NSD, plus the
 * debug manual endpoint. A manual entry is keyed by its address until pairing reveals the peer ID;
 * that ID is remembered per address so a restarted app can reconnect to the same receiver.
 */
class AppPeerLocator(
    private val manualPeerIDs: ManualPeerMemory,
    /** Builds the NSD browser that reports into this locator; null disables NSD (tests). */
    browser: ((NsdSink) -> PeerBrowser)? = null,
) : PeerLocator, NsdSink {
    private val inner = ResolvedPeerLocator(onStart = ::startNsd, onStop = ::stopNsd)
    private val nsd = browser?.invoke(this)
    @Volatile private var manual: ManualTarget? = null
    @Volatile private var manualID: String? = null

    override val peers: StateFlow<List<LocatedPeer>> get() = inner.peers
    override val state: StateFlow<DiscoveryState> get() = inner.state

    override fun endpoint(id: String, role: ServiceRole): Endpoint? = inner.endpoint(id, role)
    override fun start() = inner.start()
    override fun stop() = inner.stop()

    override fun didPair(id: String, peerID: String) {
        val target = manual
        if (target != null && id == manualID) {
            manualPeerIDs.remember(target, peerID)
            manualID = peerID
        }
        inner.didPair(id, peerID)
    }

    /** Sets or clears the debug manual endpoint. */
    fun setManual(target: ManualTarget?) {
        manualID?.let(inner::removeManual)
        manual = target
        manualID = null
        if (target == null) return
        val id = manualPeerIDs.peerID(target) ?: target.locatorID
        manualID = id
        inner.addManual(id, "Manual (${target.host})", target.pairing, target.session)
        // A manual entry needs no multicast, so an NSD failure must not block connecting to it.
        if (inner.state.value is DiscoveryState.Waiting) inner.setState(DiscoveryState.Browsing)
    }

    private fun startNsd() = nsd?.start() ?: Unit
    private fun stopNsd() = nsd?.stop() ?: Unit

    // NsdSink

    override fun resolved(service: ResolvedService) = inner.upsert(service)
    override fun lost(instanceName: String) = inner.lost(instanceName)
    override fun failed(code: BridgeErrorCode) {
        if (manual != null) {
            BridgeLog.warn("Discovery unavailable (${code.wire}); using the manual endpoint")
            return
        }
        inner.setState(DiscoveryState.Waiting(code))
    }
}

/** Debug only: which peer ID a manual address paired as. Public metadata, so plain preferences. */
interface ManualPeerMemory {
    fun peerID(target: ManualTarget): String?
    fun remember(target: ManualTarget, peerID: String)
    fun clear()
}

class SharedPreferencesManualPeerMemory(context: Context) : ManualPeerMemory {
    private val prefs = context.getSharedPreferences("debug.manualPeers", Context.MODE_PRIVATE)
    private fun key(t: ManualTarget) = "${t.host}:${t.session.port}"
    override fun peerID(target: ManualTarget) = prefs.getString(key(target), null)
    override fun remember(target: ManualTarget, peerID: String) = prefs.edit { putString(key(target), peerID) }
    override fun clear() = prefs.edit { clear() }
}

class InMemoryManualPeerMemory : ManualPeerMemory {
    private val map = HashMap<String, String>()
    @Synchronized override fun peerID(target: ManualTarget) = map["${target.host}:${target.session.port}"]
    @Synchronized override fun remember(target: ManualTarget, peerID: String) { map["${target.host}:${target.session.port}"] = peerID }
    @Synchronized override fun clear() = map.clear()
}

/**
 * The production dependency graph: identity and pair keys in [KeystoreSecretStore], trusted peers in
 * a JSON file in no-backup app storage, and [SenderService] over [AppPeerLocator]. Owned by the
 * ViewModel so a transfer outlives configuration changes; [close] tears it down.
 */
class AppGraph(
    context: Context,
    val secrets: SecretStore = KeystoreSecretStore(context),
    trustedPeerFile: File = File(context.noBackupFilesDir, "trusted-peers.json"),
    manualPeerMemory: ManualPeerMemory = SharedPreferencesManualPeerMemory(context),
    nsdEnabled: Boolean = true,
    val manualEndpointsAllowed: Boolean = BuildConfig.DEBUG,
) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val trustedPeers: TrustedPeerStore = AppTrustedPeerStore(trustedPeerFile)
    val locator = AppPeerLocator(manualPeerMemory, if (nsdEnabled) { sink -> NsdPeerDiscovery(context, sink) } else null)
    private val identityStore = IdentityStore(secrets)
    private val identity = identityStore.loadOrCreate()
    val sender = SenderService(
        identity = identity,
        device = SenderService.deviceInfo(identity, deviceName(context), Build.MODEL ?: "Android"),
        pairSecrets = PairSecretStore(secrets),
        trustedPeerStore = trustedPeers,
        locator = locator,
        scope = scope,
    )

    /** Applies the settings value; ignored (and cleared) unless manual endpoints are allowed. */
    fun applyManualEndpoint(text: String?) {
        locator.setManual(if (manualEndpointsAllowed) ManualEndpoint.parse(text) else null)
    }

    fun close() {
        locator.stop()
        scope.cancel()
    }

    private companion object {
        fun deviceName(context: Context): String =
            runCatching { Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) }.getOrNull()
                ?.takeIf { it.isNotBlank() } ?: Build.MODEL ?: "Android"
    }
}

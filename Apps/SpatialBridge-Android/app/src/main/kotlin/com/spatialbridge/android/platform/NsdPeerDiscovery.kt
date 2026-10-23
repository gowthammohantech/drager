package com.spatialbridge.android.platform

import android.annotation.SuppressLint
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import androidx.annotation.RequiresApi
import com.spatialbridge.android.diagnostics.BridgeLog
import com.spatialbridge.core.BridgeErrorCode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Browses `_spatialbridge._tcp` with NsdManager and merges each receiver's session and pairing
 * instances by `pid`. Holds a Wi-Fi multicast lock while browsing. Not wired yet: XP2a feeds
 * [peers] into core's SenderService.
 */
class NsdPeerDiscovery(
    context: Context,
    private val trustedPeerIDs: () -> Set<String>,
    private val ownPeerID: String? = null,
) {
    private val app = context.applicationContext
    private val nsd = app.getSystemService(NsdManager::class.java)
    private val wifi = app.getSystemService(WifiManager::class.java)
    private val connectivity = app.getSystemService(ConnectivityManager::class.java)
    private val executor = Executors.newSingleThreadExecutor()

    private val _peers = MutableStateFlow<List<ResolvedPeer>>(emptyList())
    val peers: StateFlow<List<ResolvedPeer>> = _peers.asStateFlow()
    private val _error = MutableStateFlow<BridgeErrorCode?>(null)
    val error: StateFlow<BridgeErrorCode?> = _error.asStateFlow()

    private val resolved = ConcurrentHashMap<String, ServiceInstance>()
    private val callbacks = ConcurrentHashMap<String, Any>()
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var listener: NsdManager.DiscoveryListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    @Synchronized
    fun start() {
        if (listener != null) return
        _error.value = null
        if (!hasLocalNetwork()) {
            _error.value = BridgeErrorCode.LOCAL_NETWORK_DENIED
            return
        }
        try {
            multicastLock = wifi?.createMulticastLock("spatialbridge-nsd")?.apply {
                setReferenceCounted(false)
                acquire()
            }
            val l = discoveryListener()
            listener = l
            nsd.discoverServices(TxtRecordParser.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
        } catch (e: SecurityException) {
            // Missing NEARBY_WIFI_DEVICES / local-network permission.
            BridgeLog.warn("Discovery denied: ${e.javaClass.simpleName}")
            fail(BridgeErrorCode.LOCAL_NETWORK_DENIED)
        } catch (e: IllegalArgumentException) {
            BridgeLog.warn("Discovery rejected: ${e.javaClass.simpleName}")
            fail(BridgeErrorCode.LOCAL_NETWORK_DENIED)
        }
    }

    @Synchronized
    fun stop() {
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        if (Build.VERSION.SDK_INT >= 34) {
            callbacks.values.forEach { cb -> runCatching { nsd.unregisterServiceInfoCallback(cb as NsdManager.ServiceInfoCallback) } }
        }
        callbacks.clear()
        synchronized(pending) { pending.clear(); resolving = false }
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
    }

    /** Re-evaluates trust after pairing or unpairing without re-browsing. */
    fun refreshTrust() = publish()

    private fun fail(code: BridgeErrorCode) {
        _error.value = code
        stop()
    }

    private fun hasLocalNetwork(): Boolean {
        val caps = connectivity?.getNetworkCapabilities(connectivity.activeNetwork) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
    }

    private fun discoveryListener() = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(serviceType: String) = Unit
        override fun onDiscoveryStopped(serviceType: String) = Unit
        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            BridgeLog.warn("NSD start failed ($errorCode)")
            synchronized(this@NsdPeerDiscovery) { listener = null }
            fail(BridgeErrorCode.LOCAL_NETWORK_DENIED)
        }
        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        override fun onServiceFound(info: NsdServiceInfo) {
            if (Build.VERSION.SDK_INT >= 34) watch(info) else enqueueResolve(info)
        }
        override fun onServiceLost(info: NsdServiceInfo) {
            val name = info.serviceName
            resolved.remove(name)
            if (Build.VERSION.SDK_INT >= 34) {
                (callbacks.remove(name) as? NsdManager.ServiceInfoCallback)?.let { runCatching { nsd.unregisterServiceInfoCallback(it) } }
            }
            publish()
        }
    }

    // API 34+: a live callback per instance also delivers TXT and address updates.
    @RequiresApi(34)
    private fun watch(info: NsdServiceInfo) {
        val name = info.serviceName
        if (callbacks.containsKey(name)) return
        val cb = object : NsdManager.ServiceInfoCallback {
            override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) { callbacks.remove(name) }
            override fun onServiceUpdated(serviceInfo: NsdServiceInfo) {
                val host = serviceInfo.hostAddresses.firstOrNull()?.hostAddress
                record(serviceInfo, host)
            }
            override fun onServiceLost() { resolved.remove(name); publish() }
            override fun onServiceInfoCallbackUnregistered() = Unit
        }
        callbacks[name] = cb
        runCatching { nsd.registerServiceInfoCallback(info, executor, cb) }.onFailure { callbacks.remove(name) }
    }

    // Below API 34 NsdManager allows one resolve at a time, so resolve serially.
    private fun enqueueResolve(info: NsdServiceInfo) {
        synchronized(pending) {
            pending.addLast(info)
            if (resolving) return
            resolving = true
        }
        resolveNext()
    }

    @Suppress("DEPRECATION")
    private fun resolveNext() {
        val next = synchronized(pending) {
            val n = pending.removeFirstOrNull()
            if (n == null) resolving = false
            n
        } ?: return
        nsd.resolveService(next, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) { resolveNext() }
            @SuppressLint("NewApi")
            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                record(serviceInfo, serviceInfo.host?.hostAddress)
                resolveNext()
            }
        })
    }

    private fun record(info: NsdServiceInfo, host: String?) {
        val txt = TxtRecordParser.parse(info.attributes.orEmpty())
        resolved[info.serviceName] = ServiceInstance(info.serviceName, host, info.port, txt)
        publish()
    }

    private fun publish() {
        _peers.value = PeerMerger.merge(resolved.values.toList(), trustedPeerIDs(), ownPeerID)
    }
}

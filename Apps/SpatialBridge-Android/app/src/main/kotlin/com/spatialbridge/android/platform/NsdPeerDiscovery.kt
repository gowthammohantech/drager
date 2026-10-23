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
import com.spatialbridge.core.service.ResolvedService
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/** Where resolved instances go: core's `ResolvedPeerLocator` merges them by TXT `pid`. */
interface NsdSink {
    fun resolved(service: ResolvedService)
    fun lost(instanceName: String)

    /** E001 when browsing is impossible (no Wi-Fi/Ethernet, permission denied, NSD refused). */
    fun failed(code: BridgeErrorCode)
}

/** Starts and stops a network browser that reports into an [NsdSink]. */
interface PeerBrowser {
    fun start()
    fun stop()
}

/**
 * Browses `_spatialbridge._tcp` with NsdManager and reports each resolved instance to [sink].
 * Holds a Wi-Fi multicast lock while browsing. Never logs names, addresses or TXT values.
 */
class NsdPeerDiscovery(
    context: Context,
    private val sink: NsdSink,
) : PeerBrowser {
    private val app = context.applicationContext
    private val nsd = app.getSystemService(NsdManager::class.java)
    private val wifi = app.getSystemService(WifiManager::class.java)
    private val connectivity = app.getSystemService(ConnectivityManager::class.java)
    private val executor = Executors.newSingleThreadExecutor()

    private val callbacks = ConcurrentHashMap<String, Any>()
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var listener: NsdManager.DiscoveryListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    @Synchronized
    override fun start() {
        if (listener != null) return
        if (!hasLocalNetwork()) {
            sink.failed(BridgeErrorCode.LOCAL_NETWORK_DENIED)
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
    override fun stop() {
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

    private fun fail(code: BridgeErrorCode) {
        stop()
        sink.failed(code)
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
            if (Build.VERSION.SDK_INT >= 34) {
                (callbacks.remove(name) as? NsdManager.ServiceInfoCallback)?.let { runCatching { nsd.unregisterServiceInfoCallback(it) } }
            }
            sink.lost(name)
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
            override fun onServiceLost() = sink.lost(name)
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
        TxtRecordParser.resolvedService(info.serviceName, host, info.port, txt)?.let(sink::resolved)
    }
}

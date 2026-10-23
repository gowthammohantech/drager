package com.spatialbridge.core.store

import com.spatialbridge.core.DevicePlatform
import com.spatialbridge.core.crypto.DeviceIdentity
import com.spatialbridge.core.json.CanonicalJson
import com.spatialbridge.core.model.BridgeProtocol
import com.spatialbridge.core.model.PeerIDs
import com.spatialbridge.core.model.TrustedPeer
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Base64

/** Keychain-like storage for small secrets. The app implements it with Android Keystore. Never log values. */
interface SecretStore {
    fun read(key: String): ByteArray?
    fun write(key: String, value: ByteArray)
    fun delete(key: String)

    /** Keys starting with [prefix]. Optional: only used to enumerate pair keys. */
    fun keys(prefix: String): List<String> = emptyList()

    /** Removes every secret (identity and pair keys). */
    fun deleteAll() {
        delete(BridgeProtocol.SecretKey.IDENTITY_SEED)
        keys(BridgeProtocol.SecretKey.PAIR_PSK_PREFIX).forEach(::delete)
    }
}

/** Public metadata of paired receivers, most recently paired first. */
interface TrustedPeerStore {
    suspend fun all(): List<TrustedPeer>
    suspend fun get(peerID: String): TrustedPeer? = all().firstOrNull { it.peerID == peerID }
    suspend fun upsert(peer: TrustedPeer)
    suspend fun remove(peerID: String)
    suspend fun markSeen(peerID: String, atMillis: Long = System.currentTimeMillis())
}

class InMemorySecretStore : SecretStore {
    private val storage = HashMap<String, ByteArray>()
    @Synchronized override fun read(key: String) = storage[key]?.copyOf()
    @Synchronized override fun write(key: String, value: ByteArray) { storage[key] = value.copyOf() }
    @Synchronized override fun deleteAll() = storage.clear()
    @Synchronized override fun delete(key: String) { storage.remove(key) }
    @Synchronized override fun keys(prefix: String) = storage.keys.filter { it.startsWith(prefix) }.sorted()
}

/** Test-only, **unencrypted** `secrets.json` (base64 values), the same layout as the Swift harness. */
class FileSecretStore(private val file: File) : SecretStore {
    private fun load(): MutableMap<String, String> {
        if (!file.isFile) return mutableMapOf()
        val root = CanonicalJson.parse(file.readBytes()) as? JsonObject ?: return mutableMapOf()
        return root.mapValues { it.value.jsonPrimitive.content }.toMutableMap()
    }

    private fun save(values: Map<String, String>) = atomicWrite(file, CanonicalJson.encode(values))

    @Synchronized override fun read(key: String) = load()[key]?.let { Base64.getDecoder().decode(it) }
    @Synchronized override fun write(key: String, value: ByteArray) = save(load().apply { put(key, Base64.getEncoder().encodeToString(value)) })
    @Synchronized override fun delete(key: String) = save(load().apply { remove(key) })
    @Synchronized override fun keys(prefix: String) = load().keys.filter { it.startsWith(prefix) }.sorted()
}

class InMemoryTrustedPeerStore : TrustedPeerStore {
    private val lock = Mutex()
    private val peers = ArrayList<TrustedPeer>()

    override suspend fun all() = lock.withLock { peers.sortedByDescending { it.pairedAtMillis } }
    override suspend fun upsert(peer: TrustedPeer) = lock.withLock {
        peers.removeAll { it.peerID == peer.peerID }
        peers += peer
    }
    override suspend fun remove(peerID: String) = lock.withLock { peers.removeAll { it.peerID == peerID }; Unit }
    override suspend fun markSeen(peerID: String, atMillis: Long) = lock.withLock {
        val index = peers.indexOfFirst { it.peerID == peerID }
        if (index >= 0) peers[index] = peers[index].copy(lastSeenAtMillis = atMillis)
    }
}

/** JSON file of trusted peers (`trusted-peers.json`). Public metadata only, so plain JSON is fine. */
class FileTrustedPeerStore(private val file: File) : TrustedPeerStore {
    private val lock = Mutex()

    private fun load(): MutableList<TrustedPeer> {
        if (!file.isFile) return mutableListOf()
        return CanonicalJson.parse(file.readBytes()).jsonArray.map { element ->
            val o = element.jsonObject
            TrustedPeer(
                peerID = o.getValue("peerID").jsonPrimitive.content,
                displayName = o.getValue("displayName").jsonPrimitive.content,
                platform = DevicePlatform(o.getValue("platform").jsonPrimitive.content),
                model = o.getValue("model").jsonPrimitive.content,
                signingPublicKey = Base64.getDecoder().decode(o.getValue("signingPublicKey").jsonPrimitive.content),
                pairedAtMillis = o.getValue("pairedAt").jsonPrimitive.longOrNull ?: 0,
                lastSeenAtMillis = o["lastSeenAt"]?.jsonPrimitive?.longOrNull,
            )
        }.toMutableList()
    }

    private fun save(peers: List<TrustedPeer>) = atomicWrite(
        file,
        CanonicalJson.encode(
            peers.map {
                mapOf(
                    "peerID" to it.peerID, "displayName" to it.displayName, "platform" to it.platform.raw, "model" to it.model,
                    "signingPublicKey" to it.signingPublicKey, "pairedAt" to it.pairedAtMillis, "lastSeenAt" to it.lastSeenAtMillis,
                )
            },
        ),
    )

    override suspend fun all() = lock.withLock { load().sortedByDescending { it.pairedAtMillis } }
    override suspend fun upsert(peer: TrustedPeer) = lock.withLock {
        save(load().filter { it.peerID != peer.peerID } + peer)
    }
    override suspend fun remove(peerID: String) = lock.withLock { save(load().filter { it.peerID != peerID }) }
    override suspend fun markSeen(peerID: String, atMillis: Long) = lock.withLock {
        save(load().map { if (it.peerID == peerID) it.copy(lastSeenAtMillis = atMillis) else it })
    }
}

private fun atomicWrite(file: File, bytes: ByteArray) {
    file.parentFile?.mkdirs()
    val temp = File(file.parentFile, ".${file.name}.tmp")
    temp.writeBytes(bytes)
    Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
}

/** Loads or creates the device identity seed. */
class IdentityStore(private val secrets: SecretStore) {
    fun loadOrCreate(): DeviceIdentity {
        secrets.read(BridgeProtocol.SecretKey.IDENTITY_SEED)?.takeIf { it.size == 32 }?.let { return DeviceIdentity(it) }
        val identity = DeviceIdentity.generate()
        secrets.write(BridgeProtocol.SecretKey.IDENTITY_SEED, identity.exportSeed())
        return identity
    }

    fun resetAll() = secrets.deleteAll()
}

/** Per-pair TLS PSKs, keyed `pair.psk.<peerID>`. */
class PairSecretStore(private val secrets: SecretStore) {
    fun psk(peerID: String): ByteArray? = secrets.read(BridgeProtocol.SecretKey.pairPsk(peerID))

    fun store(psk: ByteArray, peerID: String) {
        require(psk.size == 32) { "PSK must be 32 bytes" }
        secrets.write(BridgeProtocol.SecretKey.pairPsk(peerID), psk)
    }

    fun remove(peerID: String) = secrets.delete(BridgeProtocol.SecretKey.pairPsk(peerID))

    fun pairedPeers(): List<String> = secrets.keys(BridgeProtocol.SecretKey.PAIR_PSK_PREFIX)
        .map { it.removePrefix(BridgeProtocol.SecretKey.PAIR_PSK_PREFIX) }
        .filter(PeerIDs::isValid)
}

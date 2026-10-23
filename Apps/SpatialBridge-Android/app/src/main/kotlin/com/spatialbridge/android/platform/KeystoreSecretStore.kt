package com.spatialbridge.android.platform

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Same key names as Swift `BridgeProtocol.SecretKey`. */
object SecretKeys {
    const val IDENTITY_SEED = "identity.ed25519.seed"
    private const val PAIR_PSK_PREFIX = "pair.psk."
    fun pairPSK(peerID: String) = PAIR_PSK_PREFIX + peerID
}

interface SecretStore {
    fun read(key: String): ByteArray?
    fun write(key: String, value: ByteArray)
    fun delete(key: String)
    fun deleteAll()
}

/**
 * Wraps secrets (identity seed, pair PSKs) with a non-exportable AES-256-GCM key in AndroidKeyStore
 * and keeps the ciphertext in app-private files (`noBackupFilesDir/secrets`). Never logs values.
 * File layout: `iv(12) | ciphertext+tag`, the key name bound as AAD so files can't be swapped.
 */
class KeystoreSecretStore(context: Context) : SecretStore {
    private val dir = File(context.noBackupFilesDir, "secrets").apply { mkdirs() }

    @Synchronized
    override fun read(key: String): ByteArray? {
        val file = fileFor(key)
        if (!file.exists()) return null
        val blob = file.readBytes()
        if (blob.size <= IV_BYTES) return null
        return runCatching {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, masterKey(), GCMParameterSpec(TAG_BITS, blob, 0, IV_BYTES))
            cipher.updateAAD(key.encodeToByteArray())
            cipher.doFinal(blob, IV_BYTES, blob.size - IV_BYTES)
        }.getOrNull()
    }

    @Synchronized
    override fun write(key: String, value: ByteArray) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, masterKey()) // Keystore picks a random IV.
        cipher.updateAAD(key.encodeToByteArray())
        val sealed = cipher.iv + cipher.doFinal(value)
        val tmp = File(dir, fileFor(key).name + ".tmp")
        tmp.writeBytes(sealed)
        if (!tmp.renameTo(fileFor(key))) {
            tmp.delete()
            error("secret write failed")
        }
    }

    @Synchronized
    override fun delete(key: String) { fileFor(key).delete() }

    @Synchronized
    override fun deleteAll() {
        dir.listFiles()?.forEach { it.delete() }
        runCatching { keyStore().deleteEntry(ALIAS) }
    }

    /** Key names may contain peer IDs; hash them so the directory listing reveals nothing. */
    private fun fileFor(key: String): File {
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(key.encodeToByteArray())
        return File(dir, digest.joinToString("") { "%02x".format(it) })
    }

    private fun keyStore() = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private fun masterKey(): SecretKey {
        (keyStore().getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "spatialbridge.secrets.v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val TAG_BITS = 128
    }
}

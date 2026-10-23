package com.spatialbridge.android.platform

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.spatialbridge.core.store.SecretStore
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Wraps secrets (identity seed, pair PSKs) with a non-exportable AES-256-GCM key in AndroidKeyStore
 * and keeps the ciphertext in app-private files (`noBackupFilesDir/secrets`). Never logs values.
 * File layout: `iv(12) | ciphertext+tag`, the key name bound as AAD so files can't be swapped.
 * Implements core's [SecretStore] (key names from `BridgeProtocol.SecretKey`). File names are hashed,
 * so [keys] can't enumerate; [deleteAll] removes the directory and the wrapping key instead.
 * [directory] and [alias] exist so instrumented tests can use an isolated store.
 */
class KeystoreSecretStore(
    context: Context,
    directory: String = "secrets",
    private val alias: String = DEFAULT_ALIAS,
) : SecretStore {
    private val dir = File(context.noBackupFilesDir, directory).apply { mkdirs() }

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
        runCatching { keyStore().deleteEntry(alias) }
    }

    /** Key names may contain peer IDs; hash them so the directory listing reveals nothing. */
    private fun fileFor(key: String): File {
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(key.encodeToByteArray())
        return File(dir, digest.joinToString("") { "%02x".format(it) })
    }

    private fun keyStore() = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private fun masterKey(): SecretKey {
        (keyStore().getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
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
        const val DEFAULT_ALIAS = "spatialbridge.secrets.v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val TAG_BITS = 128
    }
}

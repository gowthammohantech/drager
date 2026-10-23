package com.spatialbridge.android.settings

import android.content.Context
import androidx.core.content.edit
import com.spatialbridge.core.BridgeErrorCode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

enum class TransferOutcome { COMPLETED, FAILED, CANCELLED }

/** Metadata only: name (shown in UI, never logged), size, outcome, peer and time. No content. */
data class TransferRecord(
    val filename: String,
    val byteCount: Long,
    val peerName: String,
    val outcome: TransferOutcome,
    val errorCode: BridgeErrorCode?,
    val atMillis: Long,
)

interface HistoryStore {
    val records: StateFlow<List<TransferRecord>>
    fun add(record: TransferRecord)
    fun clear()
}

class InMemoryHistoryStore : HistoryStore {
    private val state = MutableStateFlow<List<TransferRecord>>(emptyList())
    override val records: StateFlow<List<TransferRecord>> = state.asStateFlow()
    override fun add(record: TransferRecord) { state.value = (listOf(record) + state.value).take(MAX) }
    override fun clear() { state.value = emptyList() }

    companion object { const val MAX = 100 }
}

class SharedPreferencesHistoryStore(context: Context) : HistoryStore {
    private val prefs = context.getSharedPreferences("history", Context.MODE_PRIVATE)
    private val state = MutableStateFlow(load())
    override val records: StateFlow<List<TransferRecord>> = state.asStateFlow()

    override fun add(record: TransferRecord) {
        state.value = (listOf(record) + state.value).take(InMemoryHistoryStore.MAX)
        save()
    }

    override fun clear() {
        state.value = emptyList()
        prefs.edit { remove(KEY) }
    }

    private fun save() {
        val array = JSONArray()
        state.value.forEach { r ->
            array.put(
                JSONObject()
                    .put("name", r.filename).put("bytes", r.byteCount).put("peer", r.peerName)
                    .put("outcome", r.outcome.name).put("code", r.errorCode?.wire ?: "").put("at", r.atMillis),
            )
        }
        prefs.edit { putString(KEY, array.toString()) }
    }

    private fun load(): List<TransferRecord> = runCatching {
        val array = JSONArray(prefs.getString(KEY, "[]"))
        (0 until array.length()).map { i ->
            val o = array.getJSONObject(i)
            TransferRecord(
                o.getString("name"), o.getLong("bytes"), o.getString("peer"),
                TransferOutcome.valueOf(o.getString("outcome")),
                BridgeErrorCode.entries.firstOrNull { it.wire == o.optString("code") },
                o.getLong("at"),
            )
        }
    }.getOrDefault(emptyList())

    private companion object { const val KEY = "records" }
}

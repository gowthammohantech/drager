package com.spatialbridge.core.vectors

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DynamicTest
import java.io.File

/** Loads `Conformance/vectors/<name>.json` from the repo root passed as `sb.repoRoot`. */
object Vectors {
    val repoRoot: File = File(System.getProperty("sb.repoRoot") ?: "../../..")

    fun cases(kind: String): List<JsonObject> {
        val file = File(repoRoot, "Conformance/vectors/$kind.json")
        assertTrue(file.isFile, "missing vector file ${file.path}")
        val root = Json.parseToJsonElement(file.readText()).jsonObject
        return root.getValue("cases").jsonArray.map { it.jsonObject }
    }

    fun tests(kind: String, filter: (JsonObject) -> Boolean = { true }, body: (JsonObject) -> Unit): List<DynamicTest> =
        cases(kind).filter(filter).map { case -> DynamicTest.dynamicTest(case.str("name")) { body(case) } }
}

fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content
fun JsonObject.strOrNull(key: String): String? = this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content
fun JsonObject.obj(key: String): JsonObject = getValue(key).jsonObject
fun JsonObject.bool(key: String): Boolean = this[key]?.jsonPrimitive?.content == "true"
fun JsonObject.has(key: String): Boolean = this[key] != null && this[key] !is JsonNull
fun JsonElement.num(): String = (this as JsonPrimitive).content

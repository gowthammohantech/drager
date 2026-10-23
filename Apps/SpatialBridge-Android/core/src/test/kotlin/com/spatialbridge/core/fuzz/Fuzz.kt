package com.spatialbridge.core.fuzz

import kotlin.random.Random

/**
 * Deterministic, seeded fuzz loop for the normal test run (no extra tooling).
 *
 * - `SB_FUZZ_ITERATIONS` sets the iteration count per target (default [DEFAULT_ITERATIONS], sized
 *   for CI; run locally with `SB_FUZZ_ITERATIONS=20000`).
 * - `SB_FUZZ_SEED` changes the base seed. Every iteration uses its own `Random(seed, target, i)`, so a
 *   failure message names exactly the input to replay.
 * - Every single input must finish within [MAX_CASE_MILLIS] (bounded time).
 */
object Fuzz {
    const val DEFAULT_ITERATIONS = 2_000
    const val MAX_CASE_MILLIS = 2_000L

    val iterations: Int = (System.getenv("SB_FUZZ_ITERATIONS") ?: System.getProperty("sb.fuzzIterations"))
        ?.toIntOrNull()?.coerceAtLeast(1) ?: DEFAULT_ITERATIONS

    val seed: Long = System.getenv("SB_FUZZ_SEED")?.toLongOrNull() ?: 0x5B_F022_2026L

    /** Runs [body] [count] times; returns the number of iterations run. */
    fun run(target: String, count: Int = iterations, body: (rng: Random, iteration: Int) -> Unit): Int {
        val base = seed xor target.hashCode().toLong().shl(17)
        var slowest = 0L
        for (i in 0 until count) {
            val rng = Random(base + i * 0x9E37_79B9L)
            val start = System.nanoTime()
            try {
                body(rng, i)
            } catch (e: Throwable) {
                throw AssertionError("fuzz $target failed at iteration $i (SB_FUZZ_SEED=$seed): $e", e)
            }
            val millis = (System.nanoTime() - start) / 1_000_000
            if (millis > slowest) slowest = millis
            if (millis > MAX_CASE_MILLIS) throw AssertionError("fuzz $target iteration $i took $millis ms (> $MAX_CASE_MILLIS)")
        }
        println("fuzz $target: $count iterations, slowest case $slowest ms")
        return count
    }

    fun bytes(rng: Random, max: Int): ByteArray = rng.nextBytes(rng.nextInt(max + 1))

    fun <T> pick(rng: Random, items: List<T>): T = items[rng.nextInt(items.size)]
}

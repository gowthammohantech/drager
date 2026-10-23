package com.spatialbridge.core.gesture

import com.spatialbridge.core.Edge
import com.spatialbridge.core.ExitGesture
import com.spatialbridge.core.model.isHorizontal
import com.spatialbridge.core.model.outwardNormal
import kotlin.math.hypot
import kotlin.math.roundToLong

/** Gesture thresholds (PRD §5), mirroring `GestureConfiguration`. Distances in points/dp, times in seconds. */
data class GestureConfiguration(
    val edgeZoneInset: Double = 24.0,
    val minimumOutwardVelocity: Double = 500.0,
    val minimumTravel: Double = 60.0,
    val velocityWindow: Double = 0.09,
    val minimumSamples: Int = 3,
    val sensitivity: Double = 1.0,
    val projectionTime: Double = 0.08,
) {
    val effectiveMinimumSamples: Int get() = maxOf(2, minimumSamples)
    val effectiveSensitivity: Double get() = sensitivity.coerceIn(0.5, 2.0)
    val effectiveVelocityThreshold: Double get() = minimumOutwardVelocity / effectiveSensitivity

    companion object {
        val DEFAULT = GestureConfiguration()
    }
}

/**
 * A touch sample in canvas-local, top-left-origin coordinates (dp are treated as points);
 * [timestamp] in seconds. Only differences matter, so `MotionEvent.eventTime / 1000.0` works.
 */
data class GestureSample(val x: Double, val y: Double, val timestamp: Double) {
    companion object {
        fun fromDp(xDp: Float, yDp: Float, eventTimeMillis: Long) = GestureSample(xDp.toDouble(), yDp.toDouble(), eventTimeMillis / 1000.0)
    }
}

data class Velocity(val dx: Double, val dy: Double) {
    val magnitude: Double get() = hypot(dx, dy)
    fun component(normal: Pair<Double, Double>): Double = dx * normal.first + dy * normal.second

    companion object {
        val ZERO = Velocity(0.0, 0.0)
    }
}

/** Least-squares velocity over a sliding window; a two-point estimate below [minimumSamples]. */
class VelocityEstimator(val window: Double, minimumSamples: Int) {
    val minimumSamples: Int = maxOf(2, minimumSamples)
    private val samples = ArrayDeque<GestureSample>()

    fun reset() = samples.clear()

    fun add(sample: GestureSample) {
        samples.lastOrNull()?.let { if (sample.timestamp < it.timestamp) return }
        samples.addLast(sample)
        val cutoff = sample.timestamp - window
        while (samples.size > 2 && samples.first().timestamp < cutoff) samples.removeFirst()
        while (samples.size > 64) samples.removeFirst()
    }

    val sampleCount: Int get() = samples.size

    val velocity: Velocity
        get() {
            if (samples.size < 2) return Velocity.ZERO
            val first = samples.first()
            val last = samples.last()
            val elapsed = last.timestamp - first.timestamp
            if (elapsed <= 0) return Velocity.ZERO
            if (samples.size < minimumSamples) return Velocity((last.x - first.x) / elapsed, (last.y - first.y) / elapsed)

            val n = samples.size.toDouble()
            val t0 = first.timestamp
            var sumT = 0.0; var sumX = 0.0; var sumY = 0.0; var sumTT = 0.0; var sumTX = 0.0; var sumTY = 0.0
            for (s in samples) {
                val t = s.timestamp - t0
                sumT += t; sumX += s.x; sumY += s.y
                sumTT += t * t; sumTX += t * s.x; sumTY += t * s.y
            }
            val denominator = n * sumTT - sumT * sumT
            if (denominator <= 1e-12) return Velocity((last.x - first.x) / elapsed, (last.y - first.y) / elapsed)
            return Velocity((n * sumTX - sumT * sumX) / denominator, (n * sumTY - sumT * sumY) / denominator)
        }
}

enum class GestureRejection { NOT_IN_EDGE_ZONE, TOO_SLOW, TOO_SHORT, WRONG_DIRECTION, NOT_TRACKING }

sealed interface GesturePhase {
    data object Idle : GesturePhase
    data object Tracking : GesturePhase
    data object Armed : GesturePhase
    data object Fired : GesturePhase
    data object Cancelled : GesturePhase
    data class Rejected(val reason: GestureRejection) : GesturePhase
}

data class GestureUpdate(
    val phase: GesturePhase,
    val velocity: Velocity,
    val outwardVelocity: Double,
    val distanceToEdge: Double,
    val travelDistance: Double,
    val normalizedPosition: Double,
    /** True exactly on the sample that armed the gesture. */
    val didArm: Boolean,
)

data class Bounds(val x: Double, val y: Double, val width: Double, val height: Double) {
    val minX get() = x
    val minY get() = y
    val maxX get() = x + width
    val maxY get() = y + height
}

/**
 * Port of Swift's `SpatialGestureEngine`: idle → tracking → armed → fired | cancelled | rejected.
 * Emits at most one [ExitGesture] per drag.
 */
class SpatialGestureEngine(
    val configuration: GestureConfiguration = GestureConfiguration.DEFAULT,
    var bounds: Bounds,
    var targetEdge: Edge,
    /** Wall-clock time stamped into the gesture. Swift uses the sample timestamp; pass a clock when samples use uptime. */
    private val firedAtMillis: (GestureSample) -> Long = { (it.timestamp * 1000).roundToLong() },
) {
    var phase: GesturePhase = GesturePhase.Idle
        private set
    private val estimator = VelocityEstimator(configuration.velocityWindow, configuration.effectiveMinimumSamples)
    private var latest: GestureSample? = null
    private var travel = 0.0
    private var hasFired = false

    fun begin(sample: GestureSample): GestureUpdate {
        reset()
        phase = GesturePhase.Tracking
        latest = sample
        estimator.add(sample)
        return makeUpdate(false)
    }

    fun update(sample: GestureSample): GestureUpdate {
        if (phase != GesturePhase.Tracking && phase != GesturePhase.Armed) return makeUpdate(false)
        latest?.let { travel += hypot(sample.x - it.x, sample.y - it.y) }
        latest = sample
        estimator.add(sample)

        var didArm = false
        val inZone = distanceToEdge(sample.x, sample.y) <= configuration.edgeZoneInset
        val outward = estimator.velocity.component(targetEdge.outwardNormal)
        if (inZone && outward > 0) {
            if (phase == GesturePhase.Tracking) didArm = true
            phase = GesturePhase.Armed
        } else if (phase == GesturePhase.Armed && !inZone) {
            phase = GesturePhase.Tracking
        }
        return makeUpdate(didArm)
    }

    /** Ends the drag; returns a gesture exactly once if the release qualifies. */
    fun end(sample: GestureSample): ExitGesture? {
        if ((phase != GesturePhase.Tracking && phase != GesturePhase.Armed) || hasFired) {
            if (phase == GesturePhase.Idle || phase == GesturePhase.Cancelled) phase = GesturePhase.Rejected(GestureRejection.NOT_TRACKING)
            return null
        }
        latest?.let { travel += hypot(sample.x - it.x, sample.y - it.y) }
        latest = sample
        estimator.add(sample)

        val velocity = estimator.velocity
        val outward = velocity.component(targetEdge.outwardNormal)
        val distance = distanceToEdge(sample.x, sample.y)
        val projectedX = sample.x + velocity.dx * configuration.projectionTime
        val projectedY = sample.y + velocity.dy * configuration.projectionTime
        val crossesEdge = distance <= configuration.edgeZoneInset || isBeyondEdge(projectedX, projectedY)

        val rejection = when {
            outward <= 0 -> GestureRejection.WRONG_DIRECTION
            !crossesEdge -> GestureRejection.NOT_IN_EDGE_ZONE
            travel < configuration.minimumTravel -> GestureRejection.TOO_SHORT
            outward < configuration.effectiveVelocityThreshold -> GestureRejection.TOO_SLOW
            else -> null
        }
        if (rejection != null) {
            phase = GesturePhase.Rejected(rejection)
            return null
        }
        hasFired = true
        phase = GesturePhase.Fired
        return ExitGesture(
            edge = targetEdge,
            normalizedPosition = normalizedPosition(sample.x, sample.y),
            outwardVelocity = maxOf(outward, 0.0),
            travelDistance = maxOf(travel, 0.0),
            firedAtMillis = firedAtMillis(sample),
        )
    }

    fun cancel() {
        reset()
        phase = GesturePhase.Cancelled
    }

    fun reset() {
        phase = GesturePhase.Idle
        estimator.reset()
        latest = null
        travel = 0.0
        hasFired = false
    }

    fun distanceToEdge(x: Double, y: Double): Double = when (targetEdge) {
        Edge.TOP -> maxOf(0.0, y - bounds.minY)
        Edge.BOTTOM -> maxOf(0.0, bounds.maxY - y)
        Edge.LEFT -> maxOf(0.0, x - bounds.minX)
        Edge.RIGHT -> maxOf(0.0, bounds.maxX - x)
    }

    fun isBeyondEdge(x: Double, y: Double): Boolean = when (targetEdge) {
        Edge.TOP -> y < bounds.minY
        Edge.BOTTOM -> y > bounds.maxY
        Edge.LEFT -> x < bounds.minX
        Edge.RIGHT -> x > bounds.maxX
    }

    fun normalizedPosition(x: Double, y: Double): Double {
        val value = if (targetEdge.isHorizontal) {
            if (bounds.width > 0) (x - bounds.minX) / bounds.width else 0.5
        } else {
            if (bounds.height > 0) (y - bounds.minY) / bounds.height else 0.5
        }
        return value.coerceIn(0.0, 1.0)
    }

    private fun makeUpdate(didArm: Boolean): GestureUpdate {
        val velocity = estimator.velocity
        val x = latest?.x ?: 0.0
        val y = latest?.y ?: 0.0
        return GestureUpdate(
            phase = phase,
            velocity = velocity,
            outwardVelocity = velocity.component(targetEdge.outwardNormal),
            distanceToEdge = distanceToEdge(x, y),
            travelDistance = travel,
            normalizedPosition = normalizedPosition(x, y),
            didArm = didArm,
        )
    }
}

/** A recorded or synthesized drag, for tests and calibration. */
data class GestureTrace(val name: String, val bounds: Bounds, val targetEdge: Edge, val samples: List<GestureSample>, val expectedToFire: Boolean) {
    data class Result(val gesture: ExitGesture?, val finalPhase: GesturePhase, val armedCount: Int)

    fun run(configuration: GestureConfiguration = GestureConfiguration.DEFAULT): Result {
        val engine = SpatialGestureEngine(configuration, bounds, targetEdge)
        val first = samples.firstOrNull() ?: return Result(null, GesturePhase.Idle, 0)
        var armed = 0
        engine.begin(first)
        for (sample in samples.drop(1).dropLast(1)) if (engine.update(sample).didArm) armed++
        val gesture = engine.end(if (samples.size > 1) samples.last() else first)
        return Result(gesture, engine.phase, armed)
    }

    companion object {
        fun linear(
            name: String,
            bounds: Bounds,
            targetEdge: Edge,
            fromX: Double, fromY: Double,
            toX: Double, toY: Double,
            duration: Double,
            sampleInterval: Double = 1.0 / 120.0,
            startTime: Double = 1_700_000_000.0,
            expectedToFire: Boolean,
        ): GestureTrace {
            val steps = maxOf(2, Math.round(duration / sampleInterval).toInt())
            val samples = (0..steps).map { i ->
                val t = i.toDouble() / steps
                GestureSample(fromX + (toX - fromX) * t, fromY + (toY - fromY) * t, startTime + duration * t)
            }
            return GestureTrace(name, bounds, targetEdge, samples, expectedToFire)
        }
    }
}

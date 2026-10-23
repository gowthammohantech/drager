package com.spatialbridge.android.model

import com.spatialbridge.core.Edge

/** Where the phone sits relative to the computer (ADR-004). */
enum class PhonePlacement(val raw: String) {
    BELOW("below"), ABOVE("above"), LEFT("left"), RIGHT("right");

    /** The phone edge the user flicks toward. */
    val exitEdge: Edge get() = when (this) {
        BELOW -> Edge.TOP
        ABOVE -> Edge.BOTTOM
        LEFT -> Edge.RIGHT
        RIGHT -> Edge.LEFT
    }

    /** The computer edge the file appears to arrive from. */
    val arrivalEdge: Edge get() = when (this) {
        BELOW -> Edge.BOTTOM
        ABOVE -> Edge.TOP
        LEFT -> Edge.LEFT
        RIGHT -> Edge.RIGHT
    }

    val displayName: String get() = when (this) {
        BELOW -> "Below the computer"
        ABOVE -> "Above the computer"
        LEFT -> "Left of the computer"
        RIGHT -> "Right of the computer"
    }

    companion object {
        fun fromRaw(raw: String?): PhonePlacement = entries.firstOrNull { it.raw == raw } ?: BELOW
    }
}

val Edge.displayName: String get() = when (this) {
    Edge.TOP -> "Top"
    Edge.BOTTOM -> "Bottom"
    Edge.LEFT -> "Left"
    Edge.RIGHT -> "Right"
}

/** True for top/bottom: the along-edge axis is x. */
val Edge.isHorizontal: Boolean get() = this == Edge.TOP || this == Edge.BOTTOM

data class SpatialLayout(
    val placement: PhonePlacement = PhonePlacement.BELOW,
    /** -0.5…0.5, shifts where files appear along the computer's edge. */
    val alignmentOffset: Double = 0.0,
    val mirrored: Boolean = false,
) {
    val exitEdge: Edge get() = placement.exitEdge
    val arrivalEdge: Edge get() = placement.arrivalEdge

    /** Phone-side calibration applied before sending, as `CoordinateMapper.mapNormalizedPosition` does. */
    fun mapNormalizedPosition(position: Double): Double {
        var p = position.coerceIn(0.0, 1.0)
        if (mirrored) p = 1 - p
        p += alignmentOffset.coerceIn(-0.5, 0.5)
        return p.coerceIn(0.0, 1.0)
    }
}

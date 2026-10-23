package com.spatialbridge.android.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.spatialbridge.android.AppModel
import com.spatialbridge.android.model.PhonePlacement
import com.spatialbridge.android.model.SpatialLayout
import com.spatialbridge.android.model.displayName
import com.spatialbridge.core.Edge
import kotlin.math.roundToInt

/**
 * Spatial calibration (ADR-004): where the phone sits relative to the computer, alignment nudge and
 * mirroring. Persisted through [com.spatialbridge.android.settings.SettingsStore] (SharedPreferences).
 */
@Composable
fun CalibrationScreen(model: AppModel) {
    val settings by model.settings.collectAsStateWithLifecycle()
    val layout = settings.layout
    fun set(transform: (SpatialLayout) -> SpatialLayout) = model.settingsStore.update { it.copy(layout = transform(it.layout)) }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Tokens.gutter), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        ArrangementDiagram(layout, Modifier.fillMaxWidth().height(220.dp))
        Text("Your phone is…", style = MaterialTheme.typography.titleSmall)
        Column(Modifier.selectableGroup().testTag("calibration.placement")) {
            PhonePlacement.entries.forEach { placement ->
                Row(
                    Modifier.fillMaxWidth().heightIn(min = Tokens.minTouch)
                        .selectable(selected = layout.placement == placement, role = Role.RadioButton) { set { it.copy(placement = placement) } }
                        .testTag("calibration.placement.${placement.raw}"),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RadioButton(selected = layout.placement == placement, onClick = null)
                    Text(placement.displayName, Modifier.padding(start = 12.dp))
                }
            }
        }
        Text(
            "You'll flick toward the ${layout.exitEdge.displayName.lowercase()} edge of your phone, and files arrive from the ${layout.arrivalEdge.displayName.lowercase()} edge of your computer.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text("Fine-tune", style = MaterialTheme.typography.titleSmall)
        Text("Alignment", style = MaterialTheme.typography.bodyMedium)
        val percent = (layout.alignmentOffset * 100).roundToInt()
        Slider(
            value = layout.alignmentOffset.toFloat(),
            onValueChange = { v -> set { it.copy(alignmentOffset = (v * 20).roundToInt() / 20.0) } },
            valueRange = -0.5f..0.5f,
            steps = 19,
            modifier = Modifier.testTag("calibration.offset").semantics { stateDescription = (if (percent > 0) "+" else "") + "$percent%" },
        )
        Row(Modifier.fillMaxWidth().heightIn(min = Tokens.minTouch), verticalAlignment = Alignment.CenterVertically) {
            Text("Mirror direction", Modifier.weight(1f))
            Switch(checked = layout.mirrored, onCheckedChange = { m -> set { it.copy(mirrored = m) } }, modifier = Modifier.testTag("calibration.mirror"))
        }
        Text(
            "Shift where files appear along the computer's edge. This is your preference; Spatial Bridge doesn't sense where your devices physically are.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** Schematic of the computer display and the phone's position, with the arrival edge highlighted. */
@Composable
private fun ArrangementDiagram(layout: SpatialLayout, modifier: Modifier) {
    val outline = MaterialTheme.colorScheme.outline
    val tint = MaterialTheme.colorScheme.primary
    Canvas(
        modifier.semantics {
            contentDescription = "Phone ${layout.placement.displayName.lowercase()}; files arrive from the ${layout.arrivalEdge.displayName.lowercase()} edge of the computer"
        },
    ) {
        val unit = 1.dp.toPx()
        val screen = Rect(Offset(size.width / 2 - 80 * unit, size.height / 2 - 52 * unit), Size(160 * unit, 104 * unit))
        drawRoundRect(outline, screen.topLeft, screen.size, CornerRadius(10 * unit), style = Stroke(2 * unit))
        val inset = 10 * unit
        val (a, b) = when (layout.arrivalEdge) {
            Edge.TOP -> Offset(screen.left + inset, screen.top) to Offset(screen.right - inset, screen.top)
            Edge.BOTTOM -> Offset(screen.left + inset, screen.bottom) to Offset(screen.right - inset, screen.bottom)
            Edge.LEFT -> Offset(screen.left, screen.top + inset) to Offset(screen.left, screen.bottom - inset)
            Edge.RIGHT -> Offset(screen.right, screen.top + inset) to Offset(screen.right, screen.bottom - inset)
        }
        drawLine(tint, a, b, 4 * unit, StrokeCap.Round)

        val w = 36 * unit; val h = 64 * unit; val gap = 18 * unit
        val horizontal = layout.placement == PhonePlacement.LEFT || layout.placement == PhonePlacement.RIGHT
        val shift = (layout.alignmentOffset * if (horizontal) screen.height else screen.width).toFloat()
        val phone = when (layout.placement) {
            PhonePlacement.BELOW -> Offset(screen.center.x - w / 2 + shift, screen.bottom + gap)
            PhonePlacement.ABOVE -> Offset(screen.center.x - w / 2 + shift, screen.top - gap - h)
            PhonePlacement.LEFT -> Offset(screen.left - gap - w, screen.center.y - h / 2 + shift)
            PhonePlacement.RIGHT -> Offset(screen.right + gap, screen.center.y - h / 2 + shift)
        }
        drawRoundRect(tint.copy(alpha = 0.15f), phone, Size(w, h), CornerRadius(8 * unit))
        drawRoundRect(tint, phone, Size(w, h), CornerRadius(8 * unit), style = Stroke(2 * unit))
        val c = Offset(phone.x + w / 2, phone.y + h / 2)
        val dir = when (layout.exitEdge) {
            Edge.TOP -> Offset(0f, -1f)
            Edge.BOTTOM -> Offset(0f, 1f)
            Edge.LEFT -> Offset(-1f, 0f)
            Edge.RIGHT -> Offset(1f, 0f)
        }
        drawLine(tint, c - dir * (10 * unit), c + dir * (10 * unit), 3 * unit, StrokeCap.Round)
    }
}

package com.spatialbridge.android.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

object Tokens {
    val success = Color(0xFF2E7D32)
    val successDark = Color(0xFF81C784)
    val warning = Color(0xFFF57C00)
    val minTouch = 48.dp
    val gutter = 16.dp
}

private val Light = lightColorScheme(primary = Color(0xFF3D5AFE), secondary = Color(0xFF5C6BC0))
private val Dark = darkColorScheme(primary = Color(0xFF8C9EFF), secondary = Color(0xFF9FA8DA))

@Composable
fun SpatialBridgeTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val scheme = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> Dark
        else -> Light
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

@Composable
fun successColor(): Color = if (isSystemInDarkTheme()) Tokens.successDark else Tokens.success

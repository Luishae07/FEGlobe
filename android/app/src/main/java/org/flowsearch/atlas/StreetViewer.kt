// SPDX-License-Identifier: MPL-2.0
package org.flowsearch.atlas

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.opengl.GLUtils
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.launch
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.math.max
import kotlin.math.min

/** Draws a round (360°) photo as seen from its middle: one picture over the whole screen, each point looked up in the photo. */
private class Round : GLSurfaceView.Renderer {
    @Volatile var yaw = 0f
    @Volatile var pitch = 0f
    @Volatile var wide = 1.3f // the angle of view, in radians
    @Volatile var next: Bitmap? = null
    private var program = 0
    private var texture = 0
    private var ratio = 1f
    private var ready = false
    private var shown: Bitmap? = null
    private val corners = ByteBuffer.allocateDirect(32).order(ByteOrder.nativeOrder()).asFloatBuffer()
        .apply { put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)); position(0) }

    private fun shader(kind: Int, code: String) = GLES20.glCreateShader(kind).also { GLES20.glShaderSource(it, code); GLES20.glCompileShader(it) }

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        val vertex = shader(GLES20.GL_VERTEX_SHADER, "attribute vec2 p; varying vec2 v; void main() { v = p; gl_Position = vec4(p, 0.0, 1.0); }")
        val fragment = shader(GLES20.GL_FRAGMENT_SHADER, """
            precision highp float;
            varying vec2 v; uniform sampler2D photo; uniform float yaw, pitch, wide, ratio;
            void main() {
              float t = tan(wide / 2.0);
              vec3 d = normalize(vec3(v.x * t * min(ratio, 1.6), v.y * t * min(ratio, 1.6) / ratio, 1.0));
              d = vec3(d.x, d.y * cos(pitch) + d.z * sin(pitch), d.z * cos(pitch) - d.y * sin(pitch));
              d = vec3(d.x * cos(yaw) + d.z * sin(yaw), d.y, d.z * cos(yaw) - d.x * sin(yaw));
              vec2 at = vec2(atan(d.x, d.z) / 6.2831853 + 0.5, 0.5 - asin(clamp(d.y, -1.0, 1.0)) / 3.1415927);
              gl_FragColor = texture2D(photo, at);
            }""")
        program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vertex)
        GLES20.glAttachShader(program, fragment)
        GLES20.glLinkProgram(program)
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        texture = ids[0]
        ready = false
        if (next == null) next = shown // the screen was recreated: put the photo back
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        GLES20.glViewport(0, 0, width, height)
        ratio = width.toFloat() / max(1, height)
    }

    override fun onDrawFrame(gl: GL10?) {
        next?.let { bitmap ->
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
            for ((name, value) in listOf(GLES20.GL_TEXTURE_MIN_FILTER to GLES20.GL_LINEAR, GLES20.GL_TEXTURE_MAG_FILTER to GLES20.GL_LINEAR,
                GLES20.GL_TEXTURE_WRAP_S to GLES20.GL_CLAMP_TO_EDGE, GLES20.GL_TEXTURE_WRAP_T to GLES20.GL_CLAMP_TO_EDGE))
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, name, value)
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
            shown = bitmap
            next = null
            ready = true
        }
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        if (!ready) return
        GLES20.glUseProgram(program)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "yaw"), yaw)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "pitch"), pitch)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "wide"), wide)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "ratio"), ratio)
        val p = GLES20.glGetAttribLocation(program, "p")
        GLES20.glEnableVertexAttribArray(p)
        GLES20.glVertexAttribPointer(p, 2, GLES20.GL_FLOAT, false, 0, corners)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }
}

/** drag to look around, two fingers to come closer */
private class RoundView(context: Context) : GLSurfaceView(context) {
    val round = Round()
    private var x = 0f
    private var y = 0f
    private val pinch = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(d: ScaleGestureDetector): Boolean {
            round.wide = min(1.9f, max(0.5f, round.wide / d.scaleFactor))
            requestRender()
            return true
        }
    })

    init {
        setEGLContextClientVersion(2)
        setRenderer(round)
        renderMode = RENDERMODE_WHEN_DIRTY
    }

    @Suppress("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        pinch.onTouchEvent(e)
        if (e.actionMasked == MotionEvent.ACTION_MOVE && e.pointerCount == 1 && !pinch.isInProgress) {
            val step = round.wide / max(1, height) * 1.4f
            round.yaw -= (e.x - x) * step
            round.pitch = min(1.45f, max(-1.45f, round.pitch + (e.y - y) * step))
            requestRender()
        }
        x = e.x
        y = e.y
        return true
    }
}

/** The photo of a street, full screen, with steps along the street. */
@Composable
fun StreetViewer(first: StreetPicture, close: () -> Unit) {
    var picture by remember { mutableStateOf(first) }
    var photo by remember { mutableStateOf<Bitmap?>(null) }
    var failed by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    BackHandler { close() }
    LaunchedEffect(picture.address) {
        failed = false
        photo = null
        photo = runCatching {
            val data = Panoramax.bytes(picture.image)
            BitmapFactory.decodeByteArray(data, 0, data.size)
        }.getOrNull()
        failed = photo == null
    }
    fun step(address: String?) {
        if (address != null) scope.launch { runCatching { Panoramax.load(address) }.getOrNull()?.let { picture = it } }
    }
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        val shown = photo
        if (picture.full) {
            AndroidView(factory = { RoundView(it) }, modifier = Modifier.fillMaxSize(), update = { view ->
                if (shown != null) {
                    view.round.next = shown
                    view.requestRender()
                }
            })
        } else if (shown != null) {
            var scale by remember(picture.address) { mutableFloatStateOf(1f) }
            var move by remember(picture.address) { mutableStateOf(androidx.compose.ui.geometry.Offset.Zero) }
            Image(shown.asImageBitmap(), "Street photo", contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize().pointerInput(picture.address) {
                    detectTransformGestures { _, pan, zoom, _ ->
                        scale = min(6f, max(1f, scale * zoom))
                        move = if (scale == 1f) androidx.compose.ui.geometry.Offset.Zero else move + pan
                    }
                }.graphicsLayer(scaleX = scale, scaleY = scale, translationX = move.x, translationY = move.y))
        }
        if (shown == null) {
            if (failed) Text("The photo could not be loaded.", color = Color.White, modifier = Modifier.align(Alignment.Center))
            else CircularProgressIndicator(Modifier.align(Alignment.Center))
        }
        FilledTonalIconButton(onClick = close, modifier = Modifier.statusBarsPadding().padding(12.dp)) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back to the map")
        }
        Column(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Row(horizontalArrangement = Arrangement.spacedBy(28.dp)) {
                FilledIconButton(onClick = { step(picture.next) }, enabled = picture.next != null, modifier = Modifier.size(60.dp)) {
                    Icon(Icons.Filled.KeyboardArrowUp, "Step forward", Modifier.size(36.dp))
                }
                FilledIconButton(onClick = { step(picture.previous) }, enabled = picture.previous != null, modifier = Modifier.size(60.dp)) {
                    Icon(Icons.Filled.KeyboardArrowDown, "Step back", Modifier.size(36.dp))
                }
            }
            Text("${picture.date} · ${picture.author} · Panoramax · ${picture.licence}", color = Color.White, style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(top = 10.dp).background(Color(0x99000000)).padding(horizontal = 8.dp, vertical = 3.dp))
        }
    }
}

package com.example.voidfm

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodChannel

class AudioFocusManager(private val context: Context) {

    companion object {
        private const val TAG = "AudioFocusManager"
    }

    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var focusRequest: AudioFocusRequest? = null
    private var flutterResultCallback: MethodChannel.Result? = null

    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        when (focusChange) {
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                Log.w(TAG, "Unexpected audio focus loss: $focusChange")
                // Flutter 側に通知（必要に応じて EventChannel を使う拡張が可能）
            }
            else -> Unit
        }
    }

    fun requestDuck(duckVolume: Double, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()

            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(attrs)
                .setWillPauseWhenDucked(false)
                .setOnAudioFocusChangeListener(focusChangeListener)
                .build()

            focusRequest = request
            val res = audioManager.requestAudioFocus(request)
            if (res == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                result.success(null)
            } else {
                result.error("FOCUS_DENIED", "AudioFocus request denied", null)
            }
        } else {
            @Suppress("DEPRECATION")
            val res = audioManager.requestAudioFocus(
                focusChangeListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
            )
            if (res == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                result.success(null)
            } else {
                result.error("FOCUS_DENIED", "AudioFocus request denied", null)
            }
        }
    }

    fun abandonFocus(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            focusRequest = null
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(focusChangeListener)
        }
        result.success(null)
    }
}

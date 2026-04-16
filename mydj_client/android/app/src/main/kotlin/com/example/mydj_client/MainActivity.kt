package com.example.voidfm

import android.content.ComponentName
import android.content.Intent
import android.media.MediaMetadata
import android.media.session.MediaSessionManager
import android.os.Build
import android.provider.Settings
import android.text.TextUtils
import androidx.appcompat.app.AlertDialog
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val NOTIFICATION_CHANNEL = "com.example.voidfm/notification"
        private const val NEXT_TRACK_CHANNEL   = "com.example.voidfm/next_track"
        private const val TRACK_ENDING_CHANNEL = "com.example.voidfm/track_ending"
        private const val AUDIO_FOCUS_CHANNEL  = "com.example.voidfm/audio_focus"
        private const val MEDIA_SESSION_CHANNEL = "com.example.voidfm/media_session"
    }

    private lateinit var audioFocusManager: AudioFocusManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        audioFocusManager = AudioFocusManager(this)

        // ── EventChannel: 現在トラック変更 → Flutter ──────────────────────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIFICATION_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    MyNotificationListener.eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    MyNotificationListener.eventSink = null
                }
            })

        // ── EventChannel: 次トラック更新 → Flutter ────────────────────────────
        // MyNotificationListener の MediaController.Callback が
        // extractNextTrack() を実行するたびにこちらへ流れる
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, NEXT_TRACK_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    MyNotificationListener.nextTrackSink = events
                }
                override fun onCancel(arguments: Any?) {
                    MyNotificationListener.nextTrackSink = null
                }
            })

        // ── EventChannel: 現在曲の終端直前イベント → Flutter ──────────────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, TRACK_ENDING_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    MyNotificationListener.trackEndingSink = events
                }
                override fun onCancel(arguments: Any?) {
                    MyNotificationListener.trackEndingSink = null
                }
            })

        // ── MethodChannel: AudioFocus ダッキング制御（互換性のため残す）────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_FOCUS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestDuck" -> audioFocusManager.requestDuck(
                        call.argument<Double>("duckVolume") ?: 0.3, result)
                    "abandonFocus" -> audioFocusManager.abandonFocus(result)
                    else -> result.notImplemented()
                }
            }

        // ── MethodChannel: メディアコントロール + トラック情報 ────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_SESSION_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCurrentTrack" -> result.success(getCurrentTrack())
                    "skipToNext"      -> {
                        MyNotificationListener.markUserSkip()
                        sendMediaCommand("next")
                        result.success(null)
                    }
                    "skipToPrevious"  -> {
                        MyNotificationListener.markUserSkip()
                        sendMediaCommand("previous")
                        result.success(null)
                    }
                    "play"            -> {
                        // Flutter が明示的に再開するとき hold をクリアしてから play
                        MyNotificationListener.holdPlayback = false
                        // 100ms の遅延でメディアセッションの状態を安定化させる
                        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                            android.util.Log.d("MainActivity", "play command executing (100ms delayed)")
                            sendMediaCommand("play")
                        }, 100)
                        result.success(null)
                    }
                    "pause"           -> { sendMediaCommand("pause");    result.success(null) }
                    "setDjActive"     -> {
                        val active = call.argument<Boolean>("active") ?: false
                        MyNotificationListener.djActive = active
                        if (!active) MyNotificationListener.holdPlayback = false
                        result.success(null)
                    }
                    "setDjHoldPlayback" -> {
                        MyNotificationListener.holdPlayback =
                            call.argument<Boolean>("hold") ?: false
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** MediaSessionManager から現在アクティブなセッションのトラック情報を返す */
    private fun getCurrentTrack(): Map<String, Any?>? {
        if (!isNotificationListenerEnabled()) return null
        return try {
            val manager = getSystemService(MEDIA_SESSION_SERVICE) as MediaSessionManager
            val cn = ComponentName(this, MyNotificationListener::class.java)
            val sessions = manager.getActiveSessions(cn)

            val activePkg = MyNotificationListener.activeMediaPackage
            val ordered = if (activePkg != null) {
                val preferred = sessions.filter { it.packageName == activePkg }
                val others = sessions.filter { it.packageName != activePkg }
                preferred + others
            } else {
                sessions
            }

            for (controller in ordered) {
                if (controller.packageName in MyNotificationListener.BLOCKED_PACKAGES) continue
                val meta = controller.metadata ?: continue
                val title  = meta.getString(MediaMetadata.METADATA_KEY_TITLE) ?: continue
                val artist = meta.getString(MediaMetadata.METADATA_KEY_ARTIST)
                    ?: meta.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: continue
                val album  = meta.getString(MediaMetadata.METADATA_KEY_ALBUM)
                val artBitmap = meta.getBitmap(MediaMetadata.METADATA_KEY_ART)
                    ?: meta.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
                val artBytes = artBitmap?.let {
                    val out = java.io.ByteArrayOutputStream()
                    it.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, out)
                    out.toByteArray()
                }
                return mutableMapOf<String, Any?>(
                    "title"   to title,
                    "artist"  to artist,
                    "album"   to album,
                    "package" to controller.packageName,
                ).also { if (artBytes != null) it["albumArt"] = artBytes }
            }
            null
        } catch (e: Exception) { null }
    }

    private fun sendMediaCommand(command: String) {
        try {
            val manager = getSystemService(MEDIA_SESSION_SERVICE) as MediaSessionManager
            val cn = ComponentName(this, MyNotificationListener::class.java)
            val sessions = manager.getActiveSessions(cn)
            val activePkg = MyNotificationListener.activeMediaPackage

            val controls = sessions
                .firstOrNull {
                    activePkg != null &&
                    it.packageName == activePkg &&
                    it.packageName !in MyNotificationListener.BLOCKED_PACKAGES
                }
                ?.transportControls
                ?: sessions.firstOrNull { it.packageName !in MyNotificationListener.BLOCKED_PACKAGES }
                ?.transportControls

            if (controls != null) {
                android.util.Log.d("MainActivity", "sendMediaCommand: $command via TransportControls")
                when (command) {
                    "next"     -> controls.skipToNext()
                    "previous" -> controls.skipToPrevious()
                    "play"     -> controls.play()
                    "pause"    -> controls.pause()
                }
            } else {
                android.util.Log.d("MainActivity", "sendMediaCommand: $command via KeyEvent")
                val keyCode = when (command) {
                    "next"     -> android.view.KeyEvent.KEYCODE_MEDIA_NEXT
                    "previous" -> android.view.KeyEvent.KEYCODE_MEDIA_PREVIOUS
                    "play"     -> android.view.KeyEvent.KEYCODE_MEDIA_PLAY
                    "pause"    -> android.view.KeyEvent.KEYCODE_MEDIA_PAUSE
                    else       -> return
                }
                val am = getSystemService(AUDIO_SERVICE) as android.media.AudioManager
                am.dispatchMediaKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, keyCode))
                am.dispatchMediaKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, keyCode))
            }
        } catch (e: Exception) {
            android.util.Log.w("MainActivity", "sendMediaCommand($command) failed: ${e.message}")
        }
    }

    override fun onResume() {
        super.onResume()
        if (!isNotificationListenerEnabled()) showNotificationAccessDialog()
    }

    private fun isNotificationListenerEnabled(): Boolean {
        val flat = Settings.Secure.getString(
            contentResolver, "enabled_notification_listeners") ?: return false
        val cn = ComponentName(this, MyNotificationListener::class.java)
        return flat.split(":").any { TextUtils.equals(it, cn.flattenToString()) }
    }

    private fun showNotificationAccessDialog() {
        AlertDialog.Builder(this)
            .setTitle("通知へのアクセスが必要です")
            .setMessage("VoidFM が楽曲情報を取得するには通知へのアクセス許可が必要です。設定画面を開きますか？")
            .setPositiveButton("設定を開く") { _, _ ->
                startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            }
            .setNegativeButton("後で") { dialog, _ -> dialog.dismiss() }
            .show()
    }
}

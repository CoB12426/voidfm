package com.example.voidfm

import android.app.Notification
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.io.ByteArrayOutputStream

/**
 * メディア通知を監視し、再生中トラックと次トラックの情報を Flutter に送る。
 *
 * ─ 送信チャンネル ─
 *   com.example.mydj/notification : 現在トラック変更イベント (Map)
 *   com.example.mydj/next_track   : キューから取得した次トラック更新イベント (Map)
 *
 * ─ 次トラック取得ロジック ─
 *   MediaController.Callback を登録し、
 *   onMetadataChanged / onPlaybackStateChanged / onQueueChanged で
 *   extractNextTrack() を実行して PlaybackEventBus (nextTrackSink) へ流す。
 */
class MyNotificationListener : NotificationListenerService() {

    companion object {
        private const val TAG = "MyNotifListener"
        private const val USER_SKIP_GUARD_MS = 2500L
        private const val PRE_END_PAUSE_MS = 500L
        private const val PRE_END_MONITOR_INTERVAL_MS = 20L

        /** 現在トラック用 EventSink（com.example.mydj/notification） */
        var eventSink: EventChannel.EventSink? = null

        /** 次トラック用 EventSink（com.example.mydj/next_track） */
        var nextTrackSink: EventChannel.EventSink? = null

        /** 現在曲の終端直前イベント用 EventSink（com.example.voidfm/track_ending） */
        var trackEndingSink: EventChannel.EventSink? = null

        /**
         * true のとき、トラック変更を検知した瞬間に MediaController.pause() を実行する。
         * Flutter 側の MethodChannel 往復を待たずに即座に一時停止するための最適化。
         * Flutter の DJ サービスが有効なときに true にセットされる。
         */
        @Volatile
        var djActive: Boolean = false

        /**
         * true の間は、外部プレイヤーが勝手に再開しても即 pause して
         * DJ トーク再生中の重なりを防ぐ。
         * Flutter から setDjHoldPlayback(true/false) でセット/クリアされる。
         * また 'play' コマンド受信時にも自動クリアされる。
         */
        @Volatile
        var holdPlayback: Boolean = false

        /** 現在アクティブとみなすメディアアプリの package 名 */
        @Volatile
        var activeMediaPackage: String? = null

        /** ユーザー手動スキップ直後に自動 pause を抑止する期限 (elapsedRealtime ms) */
        @Volatile
        private var userSkipGuardUntilMs: Long = 0L

        fun markUserSkip() {
            userSkipGuardUntilMs = SystemClock.elapsedRealtime() + USER_SKIP_GUARD_MS
            holdPlayback = false  // void talk中でもスキップなら即座に新曲を再生させる
            Log.d(TAG, "user skip guard enabled for ${USER_SKIP_GUARD_MS}ms")
        }

        private fun isUserSkipGuardActive(): Boolean {
            return SystemClock.elapsedRealtime() < userSkipGuardUntilMs
        }

        private var lastTitle: String? = null
        private var lastArtist: String? = null
        private var lastHadArt: Boolean = false

        /**
         * 音楽以外のメディアアプリ（動画ストリーミング等）を除外するブロックリスト。
         */
        val BLOCKED_PACKAGES = setOf(
            "com.google.android.youtube",
            "com.google.android.youtube.tv",
            "com.netflix.mediaclient",
            "com.amazon.avod.thirdpartyclient",
            "com.disney.disneyplus",
            "com.google.android.videos",
            "com.hulu.plus",
            "com.twitch.android.viewer",
            "tv.abema.abema",
            "jp.abematv.android",
            "com.nicovideo.nicoandroid",
            "tv.tver.android",
            "jp.unext.mediaclient",
            "com.dena.abema",
            "com.ted.android",
        )
    }

    // 現在アクティブな MediaController とそのコールバック
    private var activeController: MediaController? = null
    private var controllerCallback: MediaController.Callback? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var preEndMonitor: Runnable? = null

    // ── 通知受信 ──────────────────────────────────────────────────────────────

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        sbn ?: return
        if (sbn.packageName in BLOCKED_PACKAGES) return

        activeMediaPackage = sbn.packageName

        // MediaSession.Token 経由でメタデータ取得（高精度）
        val token: MediaSession.Token? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            @Suppress("DEPRECATION")
            sbn.notification?.extras?.get(Notification.EXTRA_MEDIA_SESSION) as? MediaSession.Token
        } else null

        if (token != null) {
            try {
                val controller = MediaController(applicationContext, token)

                // セッションが変わった場合のみコールバックを付け替える
                if (activeController?.sessionToken != token) {
                    attachControllerCallback(controller, sbn.packageName)
                }

                val meta = controller.metadata
                if (meta != null) {
                    val title  = meta.getString(MediaMetadata.METADATA_KEY_TITLE)
                    val artist = meta.getString(MediaMetadata.METADATA_KEY_ARTIST)
                        ?: meta.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
                    val album  = meta.getString(MediaMetadata.METADATA_KEY_ALBUM)
                    val art    = meta.getBitmap(MediaMetadata.METADATA_KEY_ART)
                        ?: meta.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)

                    if (!title.isNullOrBlank() && !artist.isNullOrBlank()) {
                        sendIfChanged(title, artist, album, art, sbn.packageName)
                        sendNextTrack(controller)
                        return
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "MediaController failed: ${e.message}")
            }
        }

        // フォールバック: 通知 extras からタイトル/アーティスト取得
        val extras = sbn.notification?.extras ?: return
        if (!extras.containsKey(Notification.EXTRA_MEDIA_SESSION) &&
            sbn.notification?.category != Notification.CATEGORY_TRANSPORT) return

        val title  = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
            ?: extras.getCharSequence("android.title")?.toString() ?: return
        val artist = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
            ?: extras.getCharSequence("android.text")?.toString() ?: return
        val album  = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()

        sendIfChanged(title, artist, album, null, sbn.packageName)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {}

    // ── MediaController.Callback ──────────────────────────────────────────────

    /**
     * 指定 MediaController にコールバックを登録し、
     * メタデータ / 再生状態 / キュー変化を監視する。
     */
    private fun attachControllerCallback(controller: MediaController, packageName: String) {
        // 前のコールバックを解除
        controllerCallback?.let { activeController?.unregisterCallback(it) }
        preEndMonitor?.let { mainHandler.removeCallbacks(it) }
        preEndMonitor = null
        activeMediaPackage = packageName

        val callback = object : MediaController.Callback() {
            // キューの現在位置を追跡してトラック切り替えを早期検出する
            private var lastActiveQueueItemId: Long = MediaSession.QueueItem.UNKNOWN_ID.toLong()
            private var currentDurationMs: Long = -1L
            private var latestPlaybackState: PlaybackState? = null
            private var preEndPauseSentForTrack = false

            private fun maybePauseBeforeTrackEnd() {
                if (!djActive || isUserSkipGuardActive() || preEndPauseSentForTrack) return

                val state = latestPlaybackState ?: return
                if (state.state != PlaybackState.STATE_PLAYING) return
                if (holdPlayback) return

                val duration = currentDurationMs
                if (duration <= 0L) return

                val pos = estimatePositionMs(state)
                val remaining = duration - pos
                if (remaining > PRE_END_PAUSE_MS) return

                preEndPauseSentForTrack = true
                holdPlayback = true  // 次曲の自動再生を即時ブロック（Flutter往復不要）
                controller.transportControls.pause()
                sendTrackEndingSoon(remaining)
                Log.d(TAG, "djActive: pre-end pause fired (remaining=${remaining}ms)")
            }

            private fun schedulePreEndMonitorIfNeeded() {
                if (!djActive) return
                if (isUserSkipGuardActive()) return
                val state = latestPlaybackState ?: return
                if (state.state != PlaybackState.STATE_PLAYING) return
                if (holdPlayback) return
                if (currentDurationMs <= 0L) return

                if (preEndMonitor == null) {
                    preEndMonitor = object : Runnable {
                        override fun run() {
                            maybePauseBeforeTrackEnd()
                            val latest = latestPlaybackState
                            val keepRunning = latest != null &&
                                latest.state == PlaybackState.STATE_PLAYING &&
                                djActive &&
                                !isUserSkipGuardActive() &&
                                !holdPlayback &&
                                currentDurationMs > 0L &&
                                !preEndPauseSentForTrack

                            if (keepRunning) {
                                mainHandler.postDelayed(this, PRE_END_MONITOR_INTERVAL_MS)
                            }
                        }
                    }
                }

                mainHandler.removeCallbacks(preEndMonitor!!)
                mainHandler.post(preEndMonitor!!)
            }

            /** 曲が変わったとき（タイトル・アーティスト変化） */
            override fun onMetadataChanged(metadata: MediaMetadata?) {
                metadata ?: return
                val title  = metadata.getString(MediaMetadata.METADATA_KEY_TITLE) ?: return
                val artist = metadata.getString(MediaMetadata.METADATA_KEY_ARTIST)
                    ?: metadata.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: return
                val album  = metadata.getString(MediaMetadata.METADATA_KEY_ALBUM)
                val art    = metadata.getBitmap(MediaMetadata.METADATA_KEY_ART)
                    ?: metadata.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)

                // メタデータ更新は同一曲でも頻繁に発生するため、
                // 「実際に曲が変わった時」だけ自動一時停止する。
                val isTrackChanged = (title != lastTitle) || (artist != lastArtist)
                if (isTrackChanged) {
                    preEndPauseSentForTrack = false
                }

                currentDurationMs = metadata.getLong(MediaMetadata.METADATA_KEY_DURATION)

                if (isTrackChanged && isUserSkipGuardActive()) {
                    Log.d(TAG, "skip guard: suppress auto-pause on metadata change")
                }

                sendIfChanged(title, artist, album, art, packageName)
                sendNextTrack(controller)
                schedulePreEndMonitorIfNeeded()
            }

            /** 再生位置や activeQueueItemId が変わったとき */
            override fun onPlaybackStateChanged(state: PlaybackState?) {
                latestPlaybackState = state
                val currentQueueId = state?.activeQueueItemId
                    ?: MediaSession.QueueItem.UNKNOWN_ID.toLong()

                if (djActive && state?.state == PlaybackState.STATE_PLAYING) {
                    if (isUserSkipGuardActive()) {
                        // ユーザースキップ中は自動 pause を行わない
                        sendNextTrack(controller)
                        if (currentQueueId != MediaSession.QueueItem.UNKNOWN_ID.toLong()) {
                            lastActiveQueueItemId = currentQueueId
                        }
                        return
                    }

                    // 曲開始時の即時ポーズは行わない（終端直前介入方式へ移行）
                    if (holdPlayback) {
                        // DJ トーク再生中: 音楽が勝手に再開しないよう抑止
                        controller.transportControls.pause()
                        Log.d(TAG, "djActive: forced pause (holdPlayback=true)")
                    }
                }

                // キュー位置を更新（UNKNOWN は信頼できないので有効値のみ）
                if (currentQueueId != MediaSession.QueueItem.UNKNOWN_ID.toLong()) {
                    lastActiveQueueItemId = currentQueueId
                }

                sendNextTrack(controller)
                schedulePreEndMonitorIfNeeded()
            }

            /** キューの内容が変わったとき */
            override fun onQueueChanged(queue: MutableList<MediaSession.QueueItem>?) {
                sendNextTrack(controller)
            }

            override fun onSessionDestroyed() {
                Log.d(TAG, "MediaSession destroyed (pkg=$packageName)")
                if (activeMediaPackage == packageName) activeMediaPackage = null
                preEndMonitor?.let { mainHandler.removeCallbacks(it) }
                preEndMonitor = null
                activeController = null
                controllerCallback = null
            }
        }

        controller.registerCallback(callback, mainHandler)
        activeController = controller
        controllerCallback = callback
        Log.d(TAG, "Attached MediaController callback for $packageName")
    }

    // ── トラック情報送信 ───────────────────────────────────────────────────────

    private fun estimatePositionMs(state: PlaybackState): Long {
        val base = state.position
        val speed = state.playbackSpeed
        if (speed <= 0f) return base

        val lastUpdate = state.lastPositionUpdateTime
        if (lastUpdate <= 0L) return base

        val delta = SystemClock.elapsedRealtime() - lastUpdate
        if (delta <= 0L) return base

        return base + (delta * speed).toLong()
    }

    private fun sendTrackEndingSoon(remainingMs: Long) {
        val map = mutableMapOf<String, Any>(
            "remaining_ms" to remainingMs.coerceAtLeast(0L)
        )
        mainHandler.post { trackEndingSink?.success(map) }
    }

    /** 現在トラックが変わった場合のみ Flutter へ送信 */
    fun sendIfChanged(
        title: String,
        artist: String,
        album: String?,
        artBitmap: Bitmap?,
        packageName: String,
    ) {
        val hasArt = artBitmap != null
        val sameTrack = (title == lastTitle && artist == lastArtist)

        // 同一曲でも、最初はアートなし→後からアートありで届くことがある。
        // このときは再送して Flutter 側の表示を更新する。
        if (sameTrack && !(hasArt && !lastHadArt)) return

        lastTitle  = title
        lastArtist = artist
        lastHadArt = hasArt

        Log.d(TAG, "Track changed [$packageName]: $artist – $title")

        val artBytes = artBitmap?.let {
            val out = ByteArrayOutputStream()
            it.compress(Bitmap.CompressFormat.JPEG, 85, out)
            out.toByteArray()
        }

        val map = mutableMapOf<String, Any?>(
            "title"   to title,
            "artist"  to artist,
            "album"   to album,
            "package" to packageName,
        )
        if (artBytes != null) map["albumArt"] = artBytes

        mainHandler.post { eventSink?.success(map) }
    }

    /**
     * MediaController のキューから次トラックを取得して Flutter へ送信。
     * キュー未対応アプリ (YouTube Music 等) では何もしない。
     */
    private fun sendNextTrack(controller: MediaController) {
        val next = extractNextTrack(controller) ?: return
        mainHandler.post { nextTrackSink?.success(next) }
    }

    /**
     * queue と playbackState.activeQueueItemId を使って現在曲の位置を特定し、
     * 次の QueueItem と（あれば）その次の QueueItem を Map に変換して返す。
     *
     * 返す Map のキー:
     *   title / artist / album          : 次の曲（song_next）
     *   next_title / next_artist / next_album : 次の次の曲（song_after_next）— 存在する場合のみ
     */
    private fun extractNextTrack(controller: MediaController): Map<String, Any?>? {
        val queue = controller.queue
        if (queue.isNullOrEmpty() || queue.size < 2) return null

        val activeId = controller.playbackState?.activeQueueItemId
            ?: MediaSession.QueueItem.UNKNOWN_ID.toLong()

        val currentIndex = if (activeId != MediaSession.QueueItem.UNKNOWN_ID.toLong()) {
            queue.indexOfFirst { it.queueId == activeId }
        } else {
            // activeQueueItemId が不明なアプリ向けフォールバック:
            // 現在メタデータ(タイトル/アーティスト)とキュー項目を突き合わせる。
            val meta = controller.metadata
            val metaTitle = meta?.getString(MediaMetadata.METADATA_KEY_TITLE)
            val metaArtist = meta?.getString(MediaMetadata.METADATA_KEY_ARTIST)
                ?: meta?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)

            if (!metaTitle.isNullOrBlank() && !metaArtist.isNullOrBlank()) {
                queue.indexOfFirst {
                    val d = it.description
                    val qt = d.title?.toString()
                    val qa = d.subtitle?.toString() ?: d.description?.toString()
                    qt == metaTitle && qa == metaArtist
                }
            } else {
                -1
            }
        }

        if (currentIndex < 0) return null
        val nextIndex = currentIndex + 1
        if (nextIndex >= queue.size) return null

        val desc   = queue[nextIndex].description
        val title  = desc.title?.toString()?.trim() ?: return null
        val artist = desc.subtitle?.toString()
            ?: desc.description?.toString()
            ?: return null
        val artistTrimmed = artist.trim()

        if (title.isBlank() || artistTrimmed.isBlank()) return null

        Log.d(TAG, "extractNextTrack: $artistTrimmed – $title (index=$nextIndex/${queue.size - 1})")

        return mutableMapOf(
            "title"  to title,
            "artist" to artistTrimmed,
            "album"  to desc.description?.toString(),
        )
    }
}

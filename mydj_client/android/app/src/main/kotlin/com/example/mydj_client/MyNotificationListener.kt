package com.example.voidfm

import android.app.Notification
import android.graphics.Bitmap
import android.media.AudioManager
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
        private const val PRE_END_FADE_START_MS = 5000L
        private const val PRE_END_PAUSE_MS = 3500L
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

        /**
         * true の間は sendIfChanged() がトラック変更通知を Flutter へ送らずバッファリングする。
         * maybePauseBeforeTrackEnd() で true にセットされ、Flutter が void talk 完了後に
         * clearPreEndPending MethodChannel を呼ぶことでクリアされる。
         * これにより「void talk 開始前に次曲通知が届く」競合状態を解消する。
         */
        @Volatile
        var preEndPending: Boolean = false

        /** preEndPending 中にバッファリングされたトラック変更通知 */
        @Volatile
        var bufferedTrackChange: Map<String, Any?>? = null

        /** 現在アクティブとみなすメディアアプリの package 名 */
        @Volatile
        var activeMediaPackage: String? = null

        /**
         * フェードアウト開始前に保存した STREAM_MUSIC の音量。
         * -1 は「未保存」。フェード完了・一時停止時に元に戻し、-1 にリセットする。
         */
        @Volatile
        var savedMusicVolume: Int = -1

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
        private var trackEventSequence: Long = 0L

        private fun nextTrackEventId(): Long {
            trackEventSequence += 1L
            return trackEventSequence
        }

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
                // 30秒未満の短い曲（ジングル等）では終端一時停止（DJトーク介入）を行わない
                if (duration <= 30000L) return

                val pos = estimatePositionMs(state)
                val remaining = duration - pos

                if (remaining > PRE_END_FADE_START_MS) return

                val am = this@MyNotificationListener.getSystemService(AUDIO_SERVICE) as AudioManager

                if (remaining > PRE_END_PAUSE_MS) {
                    // フェードゾーン (5秒前〜3.5秒前): 音量を線形に下げる
                    if (savedMusicVolume < 0) {
                        savedMusicVolume = am.getStreamVolume(AudioManager.STREAM_MUSIC)
                    }
                    val fadeRange = (PRE_END_FADE_START_MS - PRE_END_PAUSE_MS).toFloat()
                    val progress = ((remaining - PRE_END_PAUSE_MS) / fadeRange).coerceIn(0f, 1f)
                    val targetVol = (savedMusicVolume * progress).toInt().coerceAtLeast(0)
                    am.setStreamVolume(AudioManager.STREAM_MUSIC, targetVol, 0)
                    return
                }

                // 3.5秒前に到達 → 一時停止してトークへ移行
                preEndPauseSentForTrack = true
                preEndPending = true  // Flutter が void talk を完了するまでトラック変更通知をバッファリング
                holdPlayback = true  // 次曲の自動再生を即時ブロック（Flutter往復不要）
                // 音量をフェード前の値に戻してからポーズ（Talk がすぐ全音量で再生できる）
                val restored = savedMusicVolume
                savedMusicVolume = -1
                if (restored >= 0) {
                    am.setStreamVolume(AudioManager.STREAM_MUSIC, restored, 0)
                }
                controller.transportControls.pause()
                sendTrackEndingSoon(remaining, duration, pos, packageName)
                Log.d(TAG, "djActive: pre-end fade+pause fired (remaining=${remaining}ms, restoredVol=${restored})")
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
                currentDurationMs = metadata.getLong(MediaMetadata.METADATA_KEY_DURATION)

                if (isTrackChanged) {
                    preEndPauseSentForTrack = false
                    // フェード中にトラックが変わった場合は音量を即座に復元する
                    val saved = savedMusicVolume
                    if (saved >= 0) {
                        savedMusicVolume = -1
                        val am = this@MyNotificationListener.getSystemService(AUDIO_SERVICE) as AudioManager
                        am.setStreamVolume(AudioManager.STREAM_MUSIC, saved, 0)
                    }
                    // DJモードON時に自然に曲が切り替わった場合、VoidTalkとの音声被りを防ぐため即座に一時停止しブロックする。
                    // 30秒未満の短い曲の場合は、ギャップレス再生対策による強制一時停止を行わない。
                    if (djActive && !isUserSkipGuardActive() && !holdPlayback && currentDurationMs > 30000L) {
                        holdPlayback = true
                        controller.transportControls.pause()
                        Log.d(TAG, "djActive: paused immediately on metadata track change (duration=$currentDurationMs)")
                    }
                }

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

    private fun sendTrackEndingSoon(
        remainingMs: Long,
        durationMs: Long,
        positionMs: Long,
        packageName: String,
    ) {
        val map = mutableMapOf<String, Any>(
            "event_id" to nextTrackEventId(),
            "remaining_ms" to remainingMs.coerceAtLeast(0L),
            "duration_ms" to durationMs.coerceAtLeast(0L),
            "position_ms" to positionMs.coerceAtLeast(0L),
            "package" to packageName,
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

        // void talk 完了前に次曲通知が届く競合を防ぐため、バッファリングする
        if (preEndPending && djActive) {
            Log.d(TAG, "preEndPending: buffering track change $artist – $title")
            bufferedTrackChange = map
            return
        }

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

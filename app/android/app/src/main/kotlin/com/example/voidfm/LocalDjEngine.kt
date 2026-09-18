package com.example.voidfm

import android.app.Activity
import android.content.Intent
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.SamplerConfig
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import java.io.BufferedInputStream
import java.io.File

/** App-private model and speech pipeline. Only the model/TTS assets stay local; talk generation mirrors the host's prompt. */
class LocalDjEngine(private val activity: Activity) {
    private val modelFile get() = File(activity.filesDir, "gemma-4-e2b-it.litertlm")
    private val ttsDir get() = File(activity.filesDir, "supertonic3")
    private var engine: Engine? = null
    private var pendingPicker: MethodChannel.Result? = null
    private var generation = 0
    private val pipeline = Mutex()
    private val modelMutex = Mutex()
    private val recentBits = ArrayDeque<String>()

    fun hasModel() = modelFile.isFile && modelFile.length() > 0
    fun hasTtsModel() = ttsFiles.all { File(ttsDir, it).isFile && File(ttsDir, it).length() > 0 }
    fun ttsModelPath(): String = ttsDir.absolutePath
    fun isReady() = engine != null && hasTtsModel()
    fun isModelLoaded() = engine != null

    fun pickModel(result: MethodChannel.Result) {
        if (pendingPicker != null) {
            result.error("BUSY", "Model picker already open", null)
            return
        }
        pendingPicker = result
        openPicker(PICK_MODEL)
    }

    fun pickTtsModel(result: MethodChannel.Result) {
        if (pendingPicker != null) {
            result.error("BUSY", "Model picker already open", null)
            return
        }
        pendingPicker = result
        openPicker(PICK_TTS)
    }

    private fun openPicker(requestCode: Int) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        activity.startActivityForResult(intent, requestCode)
    }

    suspend fun onPicked(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_MODEL && requestCode != PICK_TTS) return false
        val callback = pendingPicker
        pendingPicker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            callback?.success(false)
            return true
        }
        try {
            if (requestCode == PICK_TTS) {
                withContext(Dispatchers.IO) { importTtsArchive(uri) }
            } else {
                pipeline.withLock {
                    closeModel()
                    withContext(Dispatchers.IO) {
                        val temporary = File(activity.filesDir, "gemma-4-e2b-it.partial.litertlm")
                        val backup = File(activity.filesDir, "gemma-4-e2b-it.backup.litertlm")
                        try {
                            activity.contentResolver.openInputStream(uri)?.use { input ->
                                temporary.outputStream().use { input.copyTo(it) }
                            } ?: error("Cannot open selected model")
                            check(temporary.length() > 1_000_000) { "Selected model is too small" }
                            val magic = ByteArray(8)
                            temporary.inputStream().use { check(it.read(magic) == 8) }
                            check(String(magic, Charsets.US_ASCII) == "LITERTLM") {
                                "Select the Gemma 4 E2B instruction-tuned .litertlm model"
                            }
                            backup.delete()
                            if (modelFile.exists()) check(modelFile.renameTo(backup)) { "Cannot back up old model" }
                            if (!temporary.renameTo(modelFile)) {
                                if (backup.exists()) backup.renameTo(modelFile)
                                error("Could not save model")
                            }
                            backup.delete()
                        } finally {
                            temporary.delete()
                        }
                    }
                }
            }
            callback?.success(true)
        } catch (e: Exception) {
            callback?.error("MODEL_IMPORT", e.message, null)
        }
        return true
    }

    private fun importTtsArchive(uri: android.net.Uri) {
        val staging = File(activity.filesDir, "supertonic3.staging")
        val backup = File(activity.filesDir, "supertonic3.backup")
        if (!ttsDir.exists() && backup.exists()) backup.renameTo(ttsDir)
        staging.deleteRecursively()
        check(staging.mkdir()) { "Cannot create model directory" }
        try {
            val input = activity.contentResolver.openInputStream(uri)
                ?: error("Cannot open Supertonic archive")
            input.use { source ->
                TarArchiveInputStream(BZip2CompressorInputStream(BufferedInputStream(source))).use { tar ->
                    var total = 0L
                    while (true) {
                        val entry = tar.nextEntry ?: break
                        if (!entry.isFile || entry.name.split('/').contains("..")) continue
                        val name = entry.name.substringAfterLast('/')
                        if (name !in ttsFiles) continue
                        total += entry.size
                        check(total <= 1_000_000_000L) { "Supertonic archive is too large" }
                        val target = File(staging, name)
                        check(!target.exists()) { "Duplicate Supertonic file: $name" }
                        target.outputStream().use { tar.copyTo(it) }
                    }
                }
            }
            check(ttsFiles.all { File(staging, it).isFile && File(staging, it).length() > 0 }) {
                "This is not the official Supertonic 3 archive"
            }
            backup.deleteRecursively()
            if (ttsDir.exists()) check(ttsDir.renameTo(backup)) { "Cannot replace old TTS model" }
            if (!staging.renameTo(ttsDir)) {
                if (backup.exists()) backup.renameTo(ttsDir)
                error("Cannot install Supertonic model")
            }
            backup.deleteRecursively()
        } finally {
            staging.deleteRecursively()
        }
    }

    suspend fun initialize() {
        check(hasModel()) { "Select a Gemma 4 E2B .litertlm model in Settings" }
        modelMutex.withLock {
            if (engine == null) {
                engine = withContext(Dispatchers.IO) {
                    // GPU is preferred on phones; CPU keeps unsupported GPUs usable.
                    try {
                        createEngine(Backend.GPU())
                    } catch (gpuError: Exception) {
                        android.util.Log.w("LocalDjEngine", "GPU initialization failed; trying CPU", gpuError)
                        createEngine(Backend.CPU())
                    }
                }
            }
        }
    }

    private fun createEngine(backend: Backend): Engine {
        val candidate = Engine(
            EngineConfig(
                modelPath = modelFile.absolutePath,
                backend = backend,
                maxNumTokens = 1024,
                cacheDir = activity.cacheDir.absolutePath,
            )
        )
        try {
            candidate.initialize()
            return candidate
        } catch (error: Exception) {
            candidate.close()
            throw error
        }
    }

    suspend fun generate(args: Map<*, *>): Map<String, Any> = pipeline.withLock {
        initialize()
        val token = ++generation
        val next = trackOf(args["next"] as? Map<*, *> ?: error("Missing next track"))
        val previous = (args["previous"] as? Map<*, *>)?.let { trackOf(it) }
        val prefs = args["preferences"] as? Map<*, *> ?: emptyMap<String, Any>()
        val history = (args["history"] as? List<*>)
            ?.filterIsInstance<Map<*, *>>()
            ?.map { trackOf(it) }
            ?: emptyList()

        val prompt = buildPrompt(next, previous, prefs, history)

        val raw = withContext(Dispatchers.IO) {
            val loaded = engine ?: error("Model unavailable")
            loaded.createConversation(
                ConversationConfig(
                    samplerConfig = SamplerConfig(topK = 20, topP = 0.9, temperature = 0.7),
                    maxOutputToken = 220,
                )
            ).use { conversation ->
                conversation.sendMessage(prompt).contents.contents
                    .filterIsInstance<Content.Text>()
                    .joinToString("") { it.text }
            }
        }
        check(token == generation) { "Generation cancelled" }
        val script = raw.substringBefore("<turn|>").trim().trim('"', '「', '」')
        mapOf("script" to script)
    }

    suspend fun stationId(): Map<String, Any> = pipeline.withLock {
        val script = stationPhrases.random()
        mapOf("script" to script)
    }

    private data class Track(val title: String, val artist: String, val album: String?)

    private fun trackOf(map: Map<*, *>) = Track(
        title = map["title"] as? String ?: "",
        artist = map["artist"] as? String ?: "",
        album = map["album"] as? String,
    )

    private fun trackLabel(t: Track): String {
        var base = "\"${t.title}\" by ${t.artist}"
        if (!t.album.isNullOrBlank()) base += " (from ${t.album})"
        return base
    }

    // ------------------------------------------------------------------
    // パーソナリティ定義（host 版 prompt_builder.py と同一構成）
    // ------------------------------------------------------------------
    private data class Personality(
        val persona: String,
        val style: String,
        val jokeRate: Double,
        val houseRules: String,
    )

    private val personalities = mapOf(
        "standard" to Personality(
            persona = "a warm music radio DJ",
            style = "Natural, present, and easy to follow. Speak in plain conversational sentences, like you are riding " +
                "the last seconds of a segue. Keep the listener's focus on the song coming up.",
            jokeRate = 0.30,
            houseRules = "- Sound live and relaxed: one clear thought, no essay shape.\n" +
                "- Use everyday radio phrasing, not polished copy or big metaphors.\n" +
                "- Make the next track feel like the reason you opened the mic.",
        ),
        "energetic" to Personality(
            persona = "an upbeat drive-time music radio DJ",
            style = "Bright, punchy, and rhythmic. Keep the pace moving with short spoken lines, but stay warm and human. " +
                "Hype the track without sounding like an ad.",
            jokeRate = 0.25,
            houseRules = "- Open with momentum, like the music is already pushing you forward.\n" +
                "- Keep sentences short enough to say cleanly over a bed.\n" +
                "- Sell the next track with feeling, not shouting.",
        ),
        "chill" to Personality(
            persona = "a mellow late-night music radio DJ",
            style = "Soft, unhurried, and intimate. Speak like the studio lights are low and the listener is close by. " +
                "Small dry humor is fine, but keep it simple.",
            jokeRate = 0.25,
            houseRules = "- Let the air breathe, but do not drift into a monologue.\n" +
                "- Use small observations, not elaborate stories.\n" +
                "- Ease into the next track like it belongs in the room.",
        ),
        "intellectual" to Personality(
            persona = "a thoughtful music radio DJ",
            style = "Smart but conversational. Offer one simple musical or cultural note when it fits, then get back to " +
                "the feeling of the next track. Never lecture.",
            jokeRate = 0.15,
            houseRules = "- One insight is enough; make it sound spoken, not written.\n" +
                "- If you mention a music fact, keep it true, brief, and relevant.\n" +
                "- Land on the next track before the thought gets academic.",
        ),
        "comedian" to Personality(
            persona = "a funny music radio DJ",
            style = "Light, quick, and playful. Use easy radio jokes, small self-deprecation, or one odd observation. " +
                "The joke should feel tossed off on-air, not like a stand-up routine.",
            jokeRate = 0.70,
            houseRules = "- Keep the joke simple enough to understand while half-listening.\n" +
                "- Use one funny image or aside, then move on.\n" +
                "- The track intro is still the payoff; do not bury the song under the bit.",
        ),
    )

    private fun personalityFor(name: String?): Personality =
        personalities[name] ?: personalities.getValue("standard")

    // ------------------------------------------------------------------
    // 長さ指示（host 版と同一の語数目安）
    // ------------------------------------------------------------------
    private val lengthInstructions = mapOf(
        "short" to "LENGTH: Aim for 18–30 words. One quick DJ beat, then the track.",
        "medium" to "LENGTH: Aim for 35–60 words. Two quick beats max — a light opener and a clean track intro.",
        "long" to "LENGTH: Aim for 70–100 words. Still radio-tight: open, add one detail, land the track intro.",
    )

    private fun lengthInstructionFor(talkLength: String?) =
        lengthInstructions[talkLength] ?: lengthInstructions.getValue("medium")

    // ------------------------------------------------------------------
    // 雑談・番組ビット（host 版 _AIRBREAK_BITS と同一の重み・内容）
    // ------------------------------------------------------------------
    private data class Bit(val weight: Int, val name: String, val instruction: String)

    private val airbreakBits = listOf(
        Bit(14, "song hype intro",
            "Build genuine anticipation for the next track like a DJ who loves it. Mention one simple thing " +
                "the listener can feel right away: the groove, hook, mood, or first impression."),
        Bit(10, "music bridge",
            "Make a natural bridge from the previous track to the next: shared mood, contrast, tempo, or energy. " +
                "Sound like you curated the segue on purpose."),
        Bit(8, "listener ritual",
            "Imagine a tiny listening ritual: headphones settling in, a late train window, a desk lamp, a kitchen counter, " +
                "or someone queueing up one more song. Keep it specific and brief."),
        Bit(8, "fictional listener message",
            "Pretend a listener sent a strange but believable message. Keep it brief, playful, and radio-natural."),
        Bit(8, "fake station business",
            "Invent a quick VoidFM station announcement, fake sponsor tease, lost-and-found note, or studio mishap. " +
                "Make it obviously fictional, then move on."),
        Bit(7, "sound detail",
            "Start from one concrete sound detail: a bassline, hi-hat, guitar texture, synth color, vocal entrance, " +
                "or silence before the drop. Use it to point into the next track."),
        Bit(7, "studio snapshot",
            "Give one quick image from the imaginary studio: meters bouncing, coffee going cold, cables behaving, " +
                "a sticky note on the console, or the playlist screen blinking. Keep it fresh."),
        Bit(6, "micro-rant",
            "Do a harmless one-sentence rant about a trivial, less-obvious annoyance: overpacked keyrings, mystery remote buttons, " +
                "too many browser tabs, tiny hotel soaps, or unreadable appliance icons."),
        Bit(6, "absurd local bulletin",
            "Give a tiny fictional local bulletin or public-service aside in one sentence, then move on like it was normal. " +
                "Avoid nearby-animal bits unless the idea is genuinely novel."),
        Bit(6, "personal anecdote",
            "Share a one-sentence DJ anecdote or confession that feels human, light, and a little funny."),
        Bit(5, "record-shelf note",
            "Make a small record-shelf or playlist-curator observation: sequencing, contrast, a title that catches the eye, " +
                "or the pleasure of finding the right next song."),
        Bit(5, "mini scene",
            "Paint a tiny scene in one sentence: neon on wet pavement, laundry spinning, elevator lights, a quiet hallway, " +
                "a convenience-store glow, or a room settling down."),
        Bit(4, "playful question",
            "Ask the listener a playful, low-stakes question or challenge, then immediately turn it toward the next track."),
        Bit(4, "unexpected comparison",
            "Use one simple, surprising comparison that is easy to understand while half-listening. Do not get poetic or dense."),
        Bit(3, "listener interaction",
            "Talk directly to the listener with a playful question or challenge, without requiring an answer."),
        Bit(2, "local color",
            "You may use the time of day as local color, but avoid saying it is a perfect time for music."),
    )

    private fun pickAirbreakBit(): Bit {
        val choices = airbreakBits.filter { it.name !in recentBits }.ifEmpty { airbreakBits }
        val total = choices.sumOf { it.weight }
        var roll = (1..total).random()
        for (bit in choices) {
            roll -= bit.weight
            if (roll <= 0) {
                recentBits.addLast(bit.name)
                while (recentBits.size > 4) recentBits.removeFirst()
                return bit
            }
        }
        val bit = choices.first()
        recentBits.addLast(bit.name)
        while (recentBits.size > 4) recentBits.removeFirst()
        return bit
    }

    private fun jokeHint(personality: Personality): String {
        if (Math.random() >= personality.jokeRate) return ""
        return listOf(
            "Include a quick off-topic joke or dry one-liner, then get back to the music.",
            "Add one funny radio-studio observation, like a small equipment mishap or odd listener note.",
            "Slip in a casual aside that sounds improvised, not written.",
        ).random()
    }

    // ------------------------------------------------------------------
    // コンテキスト（時刻） host 版 _get_context と同一のロジック
    // ------------------------------------------------------------------
    private fun buildContext(): String {
        val calendar = java.util.Calendar.getInstance()
        val hour = calendar.get(java.util.Calendar.HOUR_OF_DAY)
        val timeLabel = when {
            hour in 5..11 -> "morning"
            hour in 12..16 -> "afternoon"
            hour in 17..20 -> "evening"
            else -> "night"
        }
        val timeStr = java.text.SimpleDateFormat("h:mm a", java.util.Locale.US).format(calendar.time)
        val dateStr = java.text.SimpleDateFormat("MMMM d (EEEE)", java.util.Locale.US).format(calendar.time)

        val includeExactTime = Math.random() < 0.20
        val includeDate = Math.random() < 0.10

        val parts = mutableListOf(timeLabel)
        if (includeExactTime) parts.add(timeStr)
        if (includeDate) parts.add(dateStr)

        return "[Live context — let this inform your TONE silently; do NOT mention the time/date " +
            "unless the selected bit explicitly calls for local color: ${parts.joinToString(", ")}]"
    }

    // ------------------------------------------------------------------
    // プロンプト構築（host 版 build_prompt/_build のポート）
    // ------------------------------------------------------------------
    private fun buildPrompt(
        next: Track,
        previous: Track?,
        prefs: Map<*, *>,
        trackHistory: List<Track>,
    ): String {
        val personality = personalityFor(prefs["personality"] as? String)
        val lengthInstruction = lengthInstructionFor(prefs["talk_length"] as? String)
        val djName = (prefs["dj_name"] as? String)?.trim().orEmpty()
        val username = (prefs["username"] as? String)?.trim().orEmpty()
        val customPrompt = (prefs["custom_prompt"] as? String)?.trim().orEmpty()

        val context = buildContext()

        val nameLine = if (djName.isNotEmpty()) "Your DJ name is \"$djName\".\n" else ""
        val usernameLine = if (username.isNotEmpty() && Math.random() < 0.60)
            "The listener's name is \"$username\". Give them a natural shoutout if it feels right.\n"
        else ""
        val customLine = if (customPrompt.isNotEmpty()) "\n[Custom instructions: $customPrompt]" else ""

        val prevKey = previous?.let { it.title to it.artist }
        val filteredHistory = trackHistory.filter { (it.title to it.artist) != prevKey }
        val historyLine = if (filteredHistory.isEmpty()) "" else
            "■ Recently played (oldest first): " +
                filteredHistory.takeLast(4).joinToString(" → ") { trackLabel(it) } + "\n"

        val prevLine = if (previous != null) "■ Previous track (just ended): ${trackLabel(previous)}\n" else ""
        val sameTrack = previous != null && previous.title == next.title && previous.artist == next.artist
        val nextLine = if (sameTrack)
            "■ Next track (about to play): Another track from the queue\n"
        else
            "■ Next track (about to play): ${trackLabel(next)}\n"

        val bit = pickAirbreakBit()

        val structure = when {
            previous != null && !sameTrack ->
                "Structure the airbreak as one flowing live-radio moment:\n" +
                    "1. Open with the selected bit — this is the main flavor.\n" +
                    "2. Mention the previous track only if it helps the flow; otherwise skip it.\n" +
                    "3. Land the plane by introducing the next track naturally. " +
                    "If the bit is 'song hype intro', steps 1 and 3 can merge — spend the whole airbreak selling the next track."
            previous != null && sameTrack ->
                "Structure the airbreak as one flowing live-radio moment:\n" +
                    "1. Open with the selected bit — this is the main flavor.\n" +
                    "2. Avoid naming the same song twice.\n" +
                    "3. Tease that another track is coming next, without naming a song title."
            else ->
                "Structure the airbreak as one flowing live-radio moment:\n" +
                    "1. Open with the selected bit — this is the main flavor.\n" +
                    "2. Introduce the next track naturally near the end. " +
                    "If the bit is 'song hype intro', spend the whole airbreak building anticipation for the next track."
        }

        val joke = jokeHint(personality)
        val jokeLine = if (joke.isNotEmpty()) "\n[Extra instruction: $joke]" else ""

        val guidelines = "## ROLE & TASK\n" +
            "You are ${personality.persona}.\n" +
            "${personality.style}\n\n" +
            "The music is currently paused. Deliver the airbreak in natural English.\n" +
            "Think of a real music radio station with a light fictional edge: alive, warm, occasionally funny, " +
            "but always easy to follow between songs.\n\n" +
            "## PERFORMANCE STYLE\n" +
            "${personality.houseRules}\n\n" +
            "## CRITICAL RULES\n" +
            "- Station Name: The station is 'VoidFM'. Never invent or use another station name.\n" +
            "- Endless Stream: This is a continuous 24/7 radio program. Never use sign-offs, goodbyes, 'wrap up', or suggest the show is ending.\n" +
            "- Immersion: The listener is already tuned in. Do NOT open with any greeting — no 'Good morning', 'Good evening', 'Hey there', 'Hi everyone', or 'Welcome to VoidFM'. Dive straight into the talk.\n" +
            "- Identity: Do NOT introduce yourself ('This is [DJ name]') unless it feels exceptionally natural in the moment.\n" +
            "- DJ flow: This is a spoken break between songs. Keep it rhythmic, clear, and easy to understand on first listen.\n" +
            "- Off-topic is okay in small doses: You may mention fictional station life, fake listener messages, tiny complaints, food, traffic, gadgets, urban myths, or absurd local news.\n" +
            "- Variety: Do not keep returning to app updates, self-checkout machines, nearby animals, vending machines, or the same tiny-complaint pattern unless the selected bit explicitly makes it fresh.\n" +
            "- Music remains the anchor: Do not make every talk a song review, but make the next-track intro feel intentional, not pasted on.\n" +
            "- Simplicity: Prefer plain words, one main image, and clean transitions. Avoid dense analogies or clever paragraphs.\n" +
            "- Time restraint: Usually do NOT mention the time or date. Never default to 'perfect time for music'. Use it only when the selected bit asks for local color.\n" +
            "- Continuity: Speak only about the current moment context. Do not mention yesterday or tomorrow.\n" +
            "- Safety: Keep jokes playful, fictional, and non-hateful. No slurs, explicit sexual content, real-person defamation, or instructions for wrongdoing.\n" +
            "- Professionalism: Always complete your sentences fully. Never cut off mid-thought.\n\n" +
            "## OUTPUT FORMAT\n" +
            "Output ONLY the spoken words for the text-to-speech engine. No quotes, no preamble, no meta-text."

        return "$context\n\n" +
            "$guidelines\n\n" +
            "$nameLine$usernameLine" +
            historyLine +
            prevLine +
            nextLine +
            "\n## SELECTED AIRBREAK BIT\n" +
            "${bit.name}: ${bit.instruction}\n" +
            "\n$structure" +
            "$jokeLine\n\n" +
            "$lengthInstruction" +
            customLine
    }

    companion object {
        const val PICK_MODEL = 4918
        const val PICK_TTS = 4919
        private val ttsFiles = setOf(
            "duration_predictor.int8.onnx", "text_encoder.int8.onnx",
            "vector_estimator.int8.onnx", "vocoder.int8.onnx",
            "tts.json", "unicode_indexer.bin", "voice.bin", "LICENSE"
        )
        private val stationPhrases = listOf(
            "VoidFM.",
            "You're listening to VoidFM.",
            "This is VoidFM.",
            "VoidFM — your personal radio.",
            "VoidFM. Music, always.",
            "You're tuned in to VoidFM.",
            "VoidFM. Let the music play.",
            "VoidFM. This is your station.",
        )
    }

    fun cancel() { generation++ }

    /** Frees the Gemma engine once any in-flight generation has finished. */
    suspend fun unload() = pipeline.withLock { modelMutex.withLock { closeModel() } }
    fun closeModel() { cancel(); engine?.close(); engine = null }
    fun close() { closeModel() }
}

package com.jhomlala.better_player.cmcd

/**
 * Per-playback-session CMCD state (CTA-5004).
 */
internal class CmcdSession(
    var sessionId: String,
    contentId: String,
    var isLive: Boolean,
) {
    var contentId: String = contentId
        private set

    /** True until first successful play / stream attach. */
    @Volatile
    var startup: Boolean = true

    /** Set while rebuffering with an attached stream; cleared on recovery. */
    @Volatile
    var bufferStarvation: Boolean = false

    fun updateContentId(next: String) {
        val id = next.trim()
        if (id.isEmpty() || id == contentId) return
        contentId = id
        startup = true
        bufferStarvation = false
    }

    fun markStarted() {
        startup = false
    }

    fun setRebuffering(rebuffering: Boolean) {
        bufferStarvation = rebuffering
    }
}

internal data class CmcdRuntimeConfig(
    val enabled: Boolean,
    val mode: String,
    val sessionId: String,
    val contentId: String,
    val isLive: Boolean,
) {
    val isActive: Boolean
        get() = enabled && (mode == "query" || mode == "header")

    companion object {
        @Suppress("UNCHECKED_CAST")
        fun fromMap(raw: Map<String, Any?>?): CmcdRuntimeConfig? {
            if (raw == null) return null
            val enabled = when (val e = raw["enabled"]) {
                is Boolean -> e
                is Number -> e.toInt() != 0
                else -> false
            }
            val mode = (raw["mode"] as? String)?.trim()?.lowercase() ?: "none"
            val sid = (raw["sessionId"] as? String)?.trim().orEmpty()
            val cid = (raw["contentId"] as? String)?.trim().orEmpty()
            val isLive = when (val live = raw["isLive"]) {
                is Boolean -> live
                is Number -> live.toInt() != 0
                else -> false
            }
            if (!enabled || (mode != "query" && mode != "header")) return null
            if (sid.isEmpty()) return null
            return CmcdRuntimeConfig(enabled, mode, sid, cid, isLive)
        }
    }
}

internal data class CmcdMetrics(
    val encodedBitrateKbps: Int? = null,
    val topBitrateKbps: Int? = null,
    val throughputKbps: Int? = null,
    val bufferLengthMs: Long? = null,
    val playbackRate: Float = 1f,
    val objectType: String = "o",
    val streamingFormat: String = "h",
)

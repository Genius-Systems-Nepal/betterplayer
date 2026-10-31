package com.jhomlala.better_player

import android.annotation.SuppressLint
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.util.Log
import android.view.Surface
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.lifecycle.Observer
import androidx.work.Data
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.google.ads.interactivemedia.v3.api.AdEvent
import com.google.android.exoplayer2.*
import com.google.android.exoplayer2.analytics.AnalyticsListener
import com.google.android.exoplayer2.audio.AudioAttributes
import com.google.android.exoplayer2.drm.*
import com.google.android.exoplayer2.ext.ima.ImaAdsLoader
import com.google.android.exoplayer2.ext.mediasession.MediaSessionConnector
import com.google.android.exoplayer2.ext.rtmp.RtmpDataSource
import com.google.android.exoplayer2.extractor.DefaultExtractorsFactory
import com.google.android.exoplayer2.mediacodec.MediaCodecSelector
import com.google.android.exoplayer2.source.*
import com.google.android.exoplayer2.source.dash.DashChunkSource
import com.google.android.exoplayer2.source.dash.DashMediaSource
import com.google.android.exoplayer2.source.dash.DefaultDashChunkSource
import com.google.android.exoplayer2.source.hls.HlsMediaSource
import com.google.android.exoplayer2.source.smoothstreaming.DefaultSsChunkSource
import com.google.android.exoplayer2.source.smoothstreaming.SsMediaSource
import com.google.android.exoplayer2.trackselection.AdaptiveTrackSelection
import com.google.android.exoplayer2.trackselection.DefaultTrackSelector
import com.google.android.exoplayer2.trackselection.TrackSelectionOverrides
import com.google.android.exoplayer2.ui.PlayerNotificationManager
import com.google.android.exoplayer2.ui.PlayerNotificationManager.BitmapCallback
import com.google.android.exoplayer2.ui.PlayerNotificationManager.MediaDescriptionAdapter
import com.google.android.exoplayer2.ui.DefaultTrackNameProvider
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DefaultBandwidthMeter
import com.google.android.exoplayer2.upstream.DefaultDataSource
import com.google.android.exoplayer2.upstream.DefaultDataSourceFactory
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource
import com.google.android.exoplayer2.util.Util
import com.jhomlala.better_player.DataSourceUtils.getDataSourceFactory
import com.jhomlala.better_player.DataSourceUtils.getUserAgent
import com.jhomlala.better_player.DataSourceUtils.isHTTP
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.EventChannel.EventSink
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry.SurfaceTextureEntry
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.*
import kotlin.math.max
import kotlin.math.min
import com.google.android.exoplayer2.analytics.AnalyticsListener.EventTime
import com.jhomlala.better_player.cmcd.CmcdDataSource
import com.jhomlala.better_player.cmcd.CmcdMetrics
import com.jhomlala.better_player.cmcd.CmcdRuntimeConfig
import com.jhomlala.better_player.cmcd.CmcdSession
import com.quanteec.plugin.settings.QuanteecConfig
import com.quanteec.quanteecexoplugin2_17.QuanteecBaseDataSource
import com.quanteec.quanteecexoplugin2_17.exoplayer.QuanteecBandwidthMeters
import com.quanteec.quanteecexoplugin2_17.exoplayer.QuanteecExoCore
import java.util.concurrent.atomic.AtomicReference

internal class BetterPlayer(
    context: Context,
    private val eventChannel: EventChannel,
    private val textureEntry: SurfaceTextureEntry,
    customDefaultLoadControl: CustomDefaultLoadControl?,
    result: MethodChannel.Result,
    act: Activity,
    quanteecConfigData: Map<String, Any?>?
) {
    private val exoPlayer: ExoPlayer?
    private val eventSink = QueuingEventSink()

    /// Low initial estimate so Auto ABR starts on a low rung, then upshifts.
    private val bandwidthMeter: DefaultBandwidthMeter =
        DefaultBandwidthMeter.Builder(context)
            .setInitialBitrateEstimate(ABR_INITIAL_BITRATE_ESTIMATE)
            .build()
    private val trackSelector: DefaultTrackSelector = DefaultTrackSelector(
        context,
        AdaptiveTrackSelection.Factory(
            /* minDurationForQualityIncreaseMs */ 10_000,
            /* maxDurationForQualityDecreaseMs */ 25_000,
            /* minDurationToRetainAfterDiscardMs */ 25_000,
            /* bandwidthFraction */ 0.7f
        )
    )
    private val loadControl: LoadControl
    private var isInitialized = false
    private var surface: Surface? = null
    private var key: String? = null
    private var playerNotificationManager: PlayerNotificationManager? = null
    private var refreshHandler: Handler? = null
    private var refreshRunnable: Runnable? = null
    private var exoPlayerEventListener: Player.Listener? = null
    private var bitmap: Bitmap? = null
    private var mediaSession: MediaSessionCompat? = null
    /// Kept so PiP / MediaSession rebuilds still show Now Playing title & art.
    private var notificationTitle: String? = null
    private var notificationAuthor: String? = null
    private var notificationImageUrl: String? = null
    private var drmSessionManager: DrmSessionManager? = null
    private val workManager: WorkManager
    private val workerObserverMap: HashMap<UUID, Observer<WorkInfo?>>
    private val customDefaultLoadControl: CustomDefaultLoadControl =
        customDefaultLoadControl ?: CustomDefaultLoadControl()
    private var lastSendBufferedPosition = 0L

    /// Silent DRM session recreate when OEM KEY_EXPIRED cannot renew in-place.
    private val mainHandler = Handler(Looper.getMainLooper())
    private var drmAppContext: Context? = null
    private var drmMediaUri: Uri? = null
    private var drmLicenseUrl: String? = null
    private var drmToken: String? = null
    private var drmHeadersCached: Map<String, String>? = null
    private var drmIsDash: Boolean = false
    private var drmAdsUri: Uri? = null
    private var drmFormatHint: String? = null
    private var drmCacheKey: String? = null
    private var drmUserAgent: String? = null
    private var drmHttpHeaders: Map<String, String>? = null
    private var drmDataSourceFactory: DataSource.Factory? = null
    private var isSilentDrmRelicensing = false
    private var silentDrmRelicenseCount = 0
    private var lastSilentDrmRelicenseAtMs = 0L
    private var behindLiveWindowRecoverCount = 0
    private var lastBehindLiveWindowRecoverAtMs = 0L
    private var decoderFailureRecoverCount = 0
    private var lastDecoderFailureRecoverAtMs = 0L

    /// nerdstat
    var startNerdStat = false
    var nerdStatHelper: NerdStatHelper? = null

    /// Ads
    private val activity = act
    private val adsLayout = FrameLayout(act)
    private var isAdPlay = false

    var quanteecConfig: QuanteecConfig? = null
    var quanteecCore: QuanteecExoCore? = null

    private val cmcdSessionRef = AtomicReference<CmcdSession?>(null)
    private val cmcdConfigRef = AtomicReference<CmcdRuntimeConfig?>(null)

    init {
        val loadBuilder = DefaultLoadControl.Builder()
        loadBuilder.setBufferDurationsMs(
            this.customDefaultLoadControl.minBufferMs,
            this.customDefaultLoadControl.maxBufferMs,
            this.customDefaultLoadControl.bufferForPlaybackMs,
            this.customDefaultLoadControl.bufferForPlaybackAfterRebufferMs
        )
        loadControl = loadBuilder.build()
        surface = Surface(textureEntry.surfaceTexture())

        val adsLoader =
            ImaAdsLoader.Builder(context).setAdEventListener { adEvent ->
                if (adEvent.type == AdEvent.AdEventType.AD_BREAK_ENDED
                    || adEvent.type == AdEvent.AdEventType.COMPLETED || adEvent.type == AdEvent.AdEventType.SKIPPED
                ) {
                    isAdPlay = false
                    isInitialized = false
                    removeAdsView()
                } else if (adEvent.type == AdEvent.AdEventType.STARTED || adEvent.type == AdEvent.AdEventType.LOADED) {
                    isAdPlay = true
                } else if (adEvent.type == AdEvent.AdEventType.AD_BREAK_FETCH_ERROR) {
                    isAdPlay = false
                    isInitialized = false
                    removeAdsView()
                }
            }.setAdErrorListener { adError ->
                isInitialized = false
                removeAdsView()
            }.build()
        val dataSourceFactory: DataSource.Factory = DefaultDataSourceFactory(context, "Livetv")

        val renderersFactory = DefaultRenderersFactory(context)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF)
            .setMediaCodecSelector { mimeType, _, requiresTunnelingDecoder ->
                MediaCodecSelector.DEFAULT.getDecoderInfos(
                    mimeType,
                    false,
                    requiresTunnelingDecoder
                )
            }

        if (quanteecConfigData != null) {
            /// Need to reelase quanteec before creating new instance
            releaseQuanteec()

            val videoId = quanteecConfigData?.get("videoId") as? String ?: ""
            val quanteecKey = quanteecConfigData?.get("quanteecKey") as? String ?: ""

            quanteecConfig = QuanteecConfig.Builder(quanteecKey).setVideoID(videoId).build()
            quanteecCore = QuanteecExoCore(context, quanteecConfig!!)

            val quanteecDataSourceFactory = QuanteecBaseDataSource.Factory(quanteecCore!!)
            val quanteecBandwidthMeters = QuanteecBandwidthMeters.Builder(context).build()

            val mediaSourceFactory: MediaSourceFactory =
                DefaultMediaSourceFactory(quanteecDataSourceFactory)
                    .setAdsLoaderProvider { unusedAdTagUri: MediaItem.AdsConfiguration? -> adsLoader }
                    .setAdViewProvider {
                        val statusBarHeight =
                            Math.ceil((25 * context.resources.displayMetrics.density).toDouble())
                                .toInt()

                        val width = activity.resources.displayMetrics.widthPixels
                        val height =
                            (activity.resources.displayMetrics.widthPixels / 1.7777777778).toInt() + statusBarHeight
                        val lp: FrameLayout.LayoutParams =
                            FrameLayout.LayoutParams(width, height)
                        adsLayout.layoutParams = lp
                        val view = activity.findViewById(android.R.id.content) as ViewGroup
                        view.addView(adsLayout)
                        adsLayout.bringToFront()
                        adsLayout
                    }

            exoPlayer = ExoPlayer.Builder(context, renderersFactory)
                .setTrackSelector(trackSelector)
                .setLoadControl(loadControl)
                .setMediaSourceFactory(mediaSourceFactory)
                .setBandwidthMeter(
                    quanteecBandwidthMeters
                ).build()
        } else {
            val mediaSourceFactory: MediaSourceFactory =
                DefaultMediaSourceFactory(dataSourceFactory)
                    .setAdsLoaderProvider { unusedAdTagUri: MediaItem.AdsConfiguration? -> adsLoader }
                    .setAdViewProvider {
                        val statusBarHeight =
                            Math.ceil((25 * context.resources.displayMetrics.density).toDouble())
                                .toInt()

                        val width = activity.resources.displayMetrics.widthPixels
                        val height =
                            (activity.resources.displayMetrics.widthPixels / 1.7777777778).toInt() + statusBarHeight
                        val lp: FrameLayout.LayoutParams =
                            FrameLayout.LayoutParams(width, height)
                        adsLayout.layoutParams = lp
                        val view = activity.findViewById(android.R.id.content) as ViewGroup
                        view.addView(adsLayout)
                        adsLayout.bringToFront()
                        adsLayout
                    }

            exoPlayer = ExoPlayer.Builder(context, renderersFactory)
                .setTrackSelector(trackSelector)
                .setLoadControl(loadControl)
                .setMediaSourceFactory(mediaSourceFactory)
                .setBandwidthMeter(bandwidthMeter)
                .build()
        }

        adsLoader.setPlayer(exoPlayer)
        workManager = WorkManager.getInstance(context)
        workerObserverMap = HashMap()
        nerdStatHelper = NerdStatHelper(
            exoPlayer,
            TextView(context),
            eventSink,
            exoPlayer.getCurrentTrackSelections(),
            DefaultTrackNameProvider(context.getResources()),
            context
        )
        setupVideoPlayer(eventChannel, textureEntry, result)
    }

    fun removeAdsView() {
        val view = activity.findViewById(android.R.id.content) as ViewGroup
        if (adsLayout != null) {
            isAdPlay = false
            view.removeView(adsLayout)
        }
    }

    fun isAdPlaying(): Boolean {
        return isAdPlay
    }

    fun contentDuration(): Long {
        return exoPlayer!!.duration
    }

    fun contentPosition(): Long {
        return exoPlayer!!.contentPosition
    }

    fun setDataSource(
        context: Context,
        key: String?,
        dataSource: String?,
        adsLink: String?,
        formatHint: String?,
        result: MethodChannel.Result,
        headers: Map<String, String>?,
        useCache: Boolean?,
        maxCacheSize: Long,
        maxCacheFileSize: Long,
        overriddenDuration: Long,
        licenseUrl: String?,
        drmHeaders: Map<String, String>?,
        extraParams: Map<String, String>?,
        cacheKey: String?,
        clearKey: String?,
        cmcdConfigMap: Map<String, Any?>? = null,
    ) {
        this.key = key
        isInitialized = false
        silentDrmRelicenseCount = 0
        lastSilentDrmRelicenseAtMs = 0L
        isSilentDrmRelicensing = false
        behindLiveWindowRecoverCount = 0
        lastBehindLiveWindowRecoverAtMs = 0L
        configureCmcd(cmcdConfigMap)
        var adsUri: Uri? = null
        val uri = Uri.parse(dataSource)
        if (adsLink != null && !adsLink.isEmpty()) {
            adsUri = Uri.parse(adsLink)
        }
        var dataSourceFactory: DataSource.Factory?
        val userAgent = getUserAgent(headers)

        val drmTokenValue: String? = extraParams
            ?.get("drm_token")
            ?.trim()
            ?.takeIf { it.isNotEmpty() && !it.equals("null", ignoreCase = true) }

        if (uri.toString().contains("rtmp")) {
            dataSourceFactory = buildRtmp()
        } else if (isHTTP(uri)) {
            dataSourceFactory = getDataSourceFactory(userAgent, headers)
            dataSourceFactory = maybeWrapCmcd(dataSourceFactory)
            if (useCache == true && maxCacheSize > 0 && maxCacheFileSize > 0) {
                dataSourceFactory = CacheDataSourceFactory(
                    context,
                    maxCacheSize,
                    maxCacheFileSize,
                    dataSourceFactory
                )
            }
        } else {
            dataSourceFactory = DefaultDataSource.Factory(context)
        }

        val contentType = Util.inferContentType(uri, null)
        val hasLicense = !licenseUrl.isNullOrEmpty()
        drmAppContext = context
        drmMediaUri = uri
        drmLicenseUrl = licenseUrl
        drmToken = drmTokenValue
        drmHeadersCached = drmHeaders
        drmIsDash = hasLicense && contentType == C.TYPE_DASH
        drmAdsUri = adsUri
        drmFormatHint = formatHint
        drmCacheKey = cacheKey
        drmUserAgent = userAgent
        drmHttpHeaders = headers
        drmDataSourceFactory = dataSourceFactory

        if (hasLicense) {
            prepareDrmPlayback(/* fromSilentRelicense= */ false)
        } else if (clearKey != null && clearKey.isNotEmpty()) {
            drmSessionManager = if (Util.SDK_INT < 18) {
                Log.e(TAG, "Protected content not supported on API levels below 18")
                null
            } else {
                DefaultDrmSessionManager.Builder()
                    .setUuidAndExoMediaDrmProvider(
                        C.CLEARKEY_UUID,
                        FrameworkMediaDrm.DEFAULT_PROVIDER
                    ).build(LocalMediaDrmCallback(clearKey.toByteArray()))
            }
            buildMediaSource(uri, adsUri, dataSourceFactory, formatHint, cacheKey, context)
            exoPlayer?.prepare()
            exoPlayer?.playWhenReady = true
        } else {
            drmSessionManager = null
            buildMediaSource(uri, adsUri, dataSourceFactory, formatHint, cacheKey, context)
            exoPlayer?.prepare()
            exoPlayer?.playWhenReady = true
        }

        exoPlayer?.let {
            quanteecCore?.setPlayer(it);
        }
        result.success(null)
    }

    private fun buildWidevineDrmSessionManager(licenseUrl: String): DrmSessionManager? {
        if (Util.SDK_INT < 18) {
            Log.e(TAG, "Protected content not supported on API levels below 18")
            return null
        }
        val httpMediaDrmCallback =
            HttpMediaDrmCallback(
                licenseUrl,
                /* forceDefaultLicenseUrl= */ true,
                DefaultHttpDataSource.Factory()
            )
        drmHeadersCached?.forEach { (drmKey, drmValue) ->
            httpMediaDrmCallback.setKeyRequestProperty(drmKey, drmValue)
        }
        val drmSchemeUuid = Util.getDrmUuid("widevine") ?: return null
        return DefaultDrmSessionManager.Builder()
            .setUuidAndExoMediaDrmProvider(drmSchemeUuid) { uuid: UUID? ->
                try {
                    KeyExpiredRemappingExoMediaDrm.createWidevineL3(uuid!!) {
                        requestSilentDrmRelicense("keyExpired")
                    }
                } catch (e: UnsupportedDrmException) {
                    DummyExoMediaDrm()
                }
            }
            .setMultiSession(true)
            .build(httpMediaDrmCallback)
    }

    private fun prepareDrmPlayback(fromSilentRelicense: Boolean) {
        val uri = drmMediaUri ?: return
        val licenseUrl = drmLicenseUrl?.takeIf { it.isNotEmpty() } ?: return
        val context = drmAppContext ?: return

        if (drmIsDash) {
            val mediaFactory = maybeWrapCmcd(DefaultHttpDataSource.Factory())
            val drmMediaSource = DrmHelper().buildDrmMediaSource(
                uri,
                context,
                drmToken,
                drmHeadersCached,
                licenseUrl,
                mediaDataSourceFactory = mediaFactory,
            ) {
                requestSilentDrmRelicense("keyExpired")
            }
            exoPlayer?.setMediaSource(drmMediaSource)
        } else {
            drmSessionManager = buildWidevineDrmSessionManager(licenseUrl)
            val factory = drmDataSourceFactory ?: maybeWrapCmcd(DefaultDataSource.Factory(context))
            buildMediaSource(uri, drmAdsUri, factory, drmFormatHint, drmCacheKey, context)
        }
        if (fromSilentRelicense) {
            // Avoid re-firing Flutter "initialized" during silent session recreate.
            isInitialized = true
        }
        exoPlayer?.prepare()
        exoPlayer?.playWhenReady = true
    }

    private fun requestSilentDrmRelicense(reason: String): Boolean {
        if (drmLicenseUrl.isNullOrEmpty() || drmMediaUri == null) return false
        val now = SystemClock.elapsedRealtime()
        if (isSilentDrmRelicensing) return true
        if (now - lastSilentDrmRelicenseAtMs < SILENT_DRM_RELICENSE_DEBOUNCE_MS) return true
        if (silentDrmRelicenseCount >= MAX_SILENT_DRM_RELICENSES) {
            Log.w(TAG, "Silent DRM relicense exhausted after $silentDrmRelicenseCount attempts")
            return false
        }
        isSilentDrmRelicensing = true
        silentDrmRelicenseCount++
        lastSilentDrmRelicenseAtMs = now
        Log.i(TAG, "Silent DRM relicense ($reason) attempt=$silentDrmRelicenseCount")
        mainHandler.post {
            try {
                prepareDrmPlayback(/* fromSilentRelicense= */ true)
            } catch (e: Exception) {
                Log.e(TAG, "Silent DRM relicense failed", e)
            } finally {
                isSilentDrmRelicensing = false
            }
        }
        return true
    }

    /** HLS/DASH live: playlist moved on; seek to live edge instead of fatal Retry. */
    private fun isBehindLiveWindow(error: PlaybackException): Boolean {
        if (error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW) {
            return true
        }
        var cause: Throwable? = error.cause
        while (cause != null) {
            if (cause is BehindLiveWindowException) return true
            val text = "${cause.javaClass.name} ${cause.message}"
            if (text.contains("BehindLiveWindowException")) return true
            cause = cause.cause
        }
        return false
    }

    private fun recoverBehindLiveWindow(): Boolean {
        val now = SystemClock.elapsedRealtime()
        if (now - lastBehindLiveWindowRecoverAtMs < BEHIND_LIVE_WINDOW_RECOVER_DEBOUNCE_MS) {
            Log.i(TAG, "BehindLiveWindow recovery debounced")
            return true
        }
        if (behindLiveWindowRecoverCount >= MAX_BEHIND_LIVE_WINDOW_RECOVERIES) {
            Log.w(
                TAG,
                "BehindLiveWindow recovery exhausted after $behindLiveWindowRecoverCount attempts"
            )
            return false
        }
        behindLiveWindowRecoverCount++
        lastBehindLiveWindowRecoverAtMs = now
        Log.i(
            TAG,
            "BehindLiveWindow recovery attempt=$behindLiveWindowRecoverCount — seekToDefaultPosition + prepare"
        )
        return try {
            exoPlayer?.seekToDefaultPosition()
            exoPlayer?.prepare()
            exoPlayer?.playWhenReady = true
            true
        } catch (e: Exception) {
            Log.e(TAG, "BehindLiveWindow recovery failed", e)
            false
        }
    }

    /**
     * MediaCodec TIMED_OUT / decoder failures leave ExoPlayer paused with a dead
     * OMX decoder. Flutter only sees VideoError and may not recreate codecs via
     * setupDataSource alone. stop()+prepare() forces renderer recreation.
     */
    private fun isDecoderFailure(error: PlaybackException): Boolean {
        if (error.errorCode == PlaybackException.ERROR_CODE_DECODING_FAILED ||
            error.errorCode == PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES ||
            error.errorCode == PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED
        ) {
            return true
        }
        var cause: Throwable? = error.cause
        while (cause != null) {
            val text = "${cause.javaClass.name} ${cause.message}"
            if (text.contains("MediaCodecVideoDecoderException") ||
                text.contains("MediaCodecDecoderException") ||
                text.contains("MediaCodecAudioDecoderException") ||
                text.contains("Decoder failed") ||
                text.contains("CodecException") ||
                text.contains("OMX.")
            ) {
                return true
            }
            cause = cause.cause
        }
        return false
    }

    private fun recoverDecoderFailure(): Boolean {
        val now = SystemClock.elapsedRealtime()
        if (now - lastDecoderFailureRecoverAtMs < DECODER_FAILURE_RECOVER_DEBOUNCE_MS) {
            Log.i(TAG, "DecoderFailure recovery debounced")
            return true
        }
        if (decoderFailureRecoverCount >= MAX_DECODER_FAILURE_RECOVERIES) {
            Log.w(
                TAG,
                "DecoderFailure recovery exhausted after $decoderFailureRecoverCount attempts"
            )
            return false
        }
        decoderFailureRecoverCount++
        lastDecoderFailureRecoverAtMs = now
        val position = exoPlayer?.currentPosition ?: 0L
        val live = exoPlayer?.isCurrentMediaItemLive == true
        Log.i(
            TAG,
            "DecoderFailure recovery attempt=$decoderFailureRecoverCount live=$live position=$position — stop + prepare"
        )
        return try {
            // stop() releases failed codecs; prepare() rebuilds renderers on the same media source.
            exoPlayer?.stop()
            exoPlayer?.prepare()
            if (live) {
                exoPlayer?.seekToDefaultPosition()
            } else if (position > 0L) {
                exoPlayer?.seekTo(position)
            }
            exoPlayer?.playWhenReady = true
            true
        } catch (e: Exception) {
            Log.e(TAG, "DecoderFailure recovery failed", e)
            false
        }
    }

    private fun isDrmLicenseFailure(error: PlaybackException): Boolean {
        if (error.errorCode == PlaybackException.ERROR_CODE_DRM_UNSPECIFIED ||
            error.errorCode == PlaybackException.ERROR_CODE_DRM_LICENSE_EXPIRED ||
            error.errorCode == PlaybackException.ERROR_CODE_DRM_SYSTEM_ERROR ||
            error.errorCode == PlaybackException.ERROR_CODE_DRM_LICENSE_ACQUISITION_FAILED ||
            error.errorCode == PlaybackException.ERROR_CODE_DRM_CONTENT_ERROR ||
            error.errorCode == PlaybackException.ERROR_CODE_DRM_DISALLOWED_OPERATION
        ) {
            return true
        }
        var cause: Throwable? = error
        while (cause != null) {
            val text = "${cause.javaClass.name} ${cause.message}"
            if (text.contains("ERROR_DRM_NO_LICENSE") ||
                text.contains("ERROR_DRM_UNKNOWN") ||
                text.contains("MediaDrmStateException") ||
                text.contains("Crypto key not available") ||
                text.contains("Failed to get key request")
            ) {
                return true
            }
            cause = cause.cause
        }
        return false
    }

    private fun buildRtmp(): DataSource.Factory {
        return RtmpDataSource.Factory()
    }

    fun setupPlayerNotification(
        context: Context, title: String, author: String?,
        imageUrl: String?, notificationChannelName: String?,
        activityName: String
    ) {
        notificationTitle = title.trim().ifEmpty { null }
        notificationAuthor = null
        notificationImageUrl = imageUrl?.trim()?.ifEmpty { null }
        bitmap = null

        val displayTitle = notificationTitle ?: title
        val artworkUrl = notificationImageUrl

        val mediaDescriptionAdapter: MediaDescriptionAdapter = object : MediaDescriptionAdapter {
            override fun getCurrentContentTitle(player: Player): String {
                return displayTitle
            }

            @SuppressLint("UnspecifiedImmutableFlag")
            override fun createCurrentContentIntent(player: Player): PendingIntent? {
                val packageName = context.applicationContext.packageName
                val notificationIntent = Intent()
                notificationIntent.setClassName(
                    packageName,
                    "$packageName.$activityName"
                )
                notificationIntent.flags = (Intent.FLAG_ACTIVITY_CLEAR_TOP
                        or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                return PendingIntent.getActivity(
                    context, 0,
                    notificationIntent,
                    PendingIntent.FLAG_IMMUTABLE
                )
            }

            override fun getCurrentContentText(player: Player): String? {
                // Hide author/subtitle line on the media notification.
                return null
            }

            override fun getCurrentLargeIcon(
                player: Player,
                callback: BitmapCallback
            ): Bitmap? {
                if (artworkUrl.isNullOrBlank()) {
                    return null
                }
                if (bitmap != null) {
                    return bitmap
                }
                val imageWorkRequest = OneTimeWorkRequest.Builder(ImageWorker::class.java)
                    .addTag(artworkUrl)
                    .setInputData(
                        Data.Builder()
                            .putString(BetterPlayerPlugin.URL_PARAMETER, artworkUrl)
                            .build()
                    )
                    .build()
                workManager.enqueue(imageWorkRequest)
                val workInfoObserver = Observer { workInfo: WorkInfo? ->
                    try {
                        if (workInfo != null) {
                            val state = workInfo.state
                            if (state == WorkInfo.State.SUCCEEDED) {
                                val outputData = workInfo.outputData
                                val filePath =
                                    outputData.getString(BetterPlayerPlugin.FILE_PATH_PARAMETER)
                                //Bitmap here is already processed and it's very small, so it won't
                                //break anything.
                                bitmap = BitmapFactory.decodeFile(filePath)
                                bitmap?.let { loaded ->
                                    callback.onBitmap(loaded)
                                    updateMediaSessionMetadata()
                                }
                            }
                            if (state == WorkInfo.State.SUCCEEDED || state == WorkInfo.State.CANCELLED || state == WorkInfo.State.FAILED) {
                                val uuid = imageWorkRequest.id
                                val observer = workerObserverMap.remove(uuid)
                                if (observer != null) {
                                    workManager.getWorkInfoByIdLiveData(uuid)
                                        .removeObserver(observer)
                                }
                            }
                        }
                    } catch (exception: Exception) {
                        Log.e(TAG, "Image select error: $exception")
                    }
                }
                val workerUuid = imageWorkRequest.id
                workManager.getWorkInfoByIdLiveData(workerUuid)
                    .observeForever(workInfoObserver)
                workerObserverMap[workerUuid] = workInfoObserver
                return null
            }
        }
        var playerNotificationChannelName = notificationChannelName
        if (notificationChannelName == null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val importance = NotificationManager.IMPORTANCE_LOW
                val channel = NotificationChannel(
                    DEFAULT_NOTIFICATION_CHANNEL,
                    DEFAULT_NOTIFICATION_CHANNEL, importance
                )
                channel.description = DEFAULT_NOTIFICATION_CHANNEL
                val notificationManager = context.getSystemService(
                    NotificationManager::class.java
                )
                notificationManager.createNotificationChannel(channel)
                playerNotificationChannelName = DEFAULT_NOTIFICATION_CHANNEL
            }
        }

        // ExoPlayer 2.17 registers notification receivers without export flags;
        // Android 13+ crashes unless we wrap the context (Quanteec pins 2.17).
        val notificationContext = SafeReceiverContext(context.applicationContext)
        playerNotificationManager = PlayerNotificationManager.Builder(
            notificationContext, NOTIFICATION_ID,
            playerNotificationChannelName!!
        ).setMediaDescriptionAdapter(mediaDescriptionAdapter).build()

        playerNotificationManager?.apply {

            exoPlayer?.let {
                setPlayer(ForwardingPlayer(exoPlayer))
                setUseNextAction(false)
                setUsePreviousAction(false)
                setUseStopAction(false)
            }

            setupMediaSession(context)?.let {
                setMediaSessionToken(it.sessionToken)
            }
        }
        updateMediaSessionMetadata()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            refreshHandler = Handler(Looper.getMainLooper())
            refreshRunnable = Runnable {
                val playbackState: PlaybackStateCompat = if (exoPlayer?.isPlaying == true) {
                    PlaybackStateCompat.Builder()
                        .setActions(PlaybackStateCompat.ACTION_SEEK_TO)
                        .setState(PlaybackStateCompat.STATE_PLAYING, position, 1.0f)
                        .build()
                } else {
                    PlaybackStateCompat.Builder()
                        .setActions(PlaybackStateCompat.ACTION_SEEK_TO)
                        .setState(PlaybackStateCompat.STATE_PAUSED, position, 1.0f)
                        .build()
                }
                mediaSession?.setPlaybackState(playbackState)
                refreshHandler?.postDelayed(refreshRunnable!!, 1000)
            }
            refreshHandler?.postDelayed(refreshRunnable!!, 0)
        }
        exoPlayerEventListener = object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                // Keep title/artwork — duration-only metadata was wiping Now Playing to "Unknown".
                updateMediaSessionMetadata()
            }
        }
        exoPlayerEventListener?.let { exoPlayerEventListener ->
            exoPlayer?.addListener(exoPlayerEventListener)
        }
        exoPlayer?.seekTo(0)
    }

    /** Build Now Playing metadata for MediaSession / MediaSessionConnector. */
    private fun buildNowPlayingMetadata(): MediaMetadataCompat? {
        val title = notificationTitle
        if (title.isNullOrBlank()) return null
        val builder = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
            .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_TITLE, title)
            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, getDuration())
        val art = bitmap
        if (art != null) {
            builder.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, art)
            builder.putBitmap(MediaMetadataCompat.METADATA_KEY_DISPLAY_ICON, art)
        } else {
            val artUrl = notificationImageUrl
            if (!artUrl.isNullOrBlank()) {
                builder.putString(MediaMetadataCompat.METADATA_KEY_ALBUM_ART_URI, artUrl)
                builder.putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_ICON_URI, artUrl)
            }
        }
        return builder.build()
    }

    /** Push title / author / artwork into MediaSession (system shade + lock screen). */
    private fun updateMediaSessionMetadata() {
        val session = mediaSession ?: return
        val metadata = buildNowPlayingMetadata() ?: return
        session.setMetadata(metadata)
    }

    fun disposeRemoteNotifications() {
        exoPlayerEventListener?.let { exoPlayerEventListener ->
            exoPlayer?.removeListener(exoPlayerEventListener)
        }
        if (refreshHandler != null) {
            refreshHandler?.removeCallbacksAndMessages(null)
            refreshHandler = null
            refreshRunnable = null
        }
        if (playerNotificationManager != null) {
            playerNotificationManager?.setPlayer(null)
        }
        bitmap = null
        notificationTitle = null
        notificationAuthor = null
        notificationImageUrl = null
    }

    private fun buildMediaSource(
        uri: Uri,
        adsUri: Uri?,
        mediaDataSourceFactory: DataSource.Factory,
        formatHint: String?,
        cacheKey: String?,
        context: Context
    ) {
//        val type: Int
        @C.ContentType val type: Int = Util.inferContentType(uri, null)

//        if (formatHint == null) {
//            var lastPathSegment = uri.lastPathSegment
//            if (lastPathSegment == null) {
//                lastPathSegment = ""
//            }
//            type = Util.inferContentType(lastPathSegment)
//        } else {
//            type = when (formatHint) {
//                FORMAT_SS -> C.TYPE_SS
//                FORMAT_DASH -> C.TYPE_DASH
//                FORMAT_HLS -> C.TYPE_HLS
//                FORMAT_OTHER -> C.TYPE_OTHER
//                else -> -1
//            }
//        }
        val mediaItemBuilder = MediaItem.Builder()
        mediaItemBuilder.setUri(uri)
        if (adsUri != null) {
//            val adsConfiguration: MediaItem.AdsConfiguration = MediaItem.AdsConfiguration(adsUri)
            mediaItemBuilder.setAdTagUri(adsUri)
        }
        if (cacheKey != null && cacheKey.isNotEmpty()) {
            mediaItemBuilder.setCustomCacheKey(cacheKey)
        }
        val mediaItem = mediaItemBuilder.build()
        var drmSessionManagerProvider: DrmSessionManagerProvider? = null
        drmSessionManager?.let { drmSessionManager ->
            drmSessionManagerProvider = DrmSessionManagerProvider { drmSessionManager }
        }
        val mediaSource = when (type) {
            C.TYPE_SS -> SsMediaSource.Factory(
                DefaultSsChunkSource.Factory(mediaDataSourceFactory),
                DefaultDataSource.Factory(context, mediaDataSourceFactory)
            )
                .setDrmSessionManagerProvider(drmSessionManagerProvider)
                .createMediaSource(mediaItem)

            C.TYPE_DASH -> DashMediaSource.Factory(
                DefaultDashChunkSource.Factory(mediaDataSourceFactory),
                DefaultDataSource.Factory(context, mediaDataSourceFactory)
            )
                .setDrmSessionManagerProvider(drmSessionManagerProvider)
                .createMediaSource(mediaItem)

            C.TYPE_HLS -> HlsMediaSource.Factory(mediaDataSourceFactory)
                .setDrmSessionManagerProvider(drmSessionManagerProvider)
                .createMediaSource(mediaItem)

            C.TYPE_OTHER -> ProgressiveMediaSource.Factory(
                mediaDataSourceFactory,
                DefaultExtractorsFactory()
            )
                .setDrmSessionManagerProvider(drmSessionManagerProvider)
                .createMediaSource(mediaItem)

            else -> {
                throw IllegalStateException("Unsupported type: $type")
            }
        }

        // Only setMediaSource — setMediaItem would rebuild via the player’s default
        // MediaSourceFactory and drop the CMCD-wrapped DataSource.Factory.
        exoPlayer?.setMediaSource(mediaSource)
        exoPlayer?.playWhenReady = true
        exoPlayer?.let {
            quanteecCore?.setPlayer(it);
        }
    }

    private fun setupVideoPlayer(
        eventChannel: EventChannel, textureEntry: SurfaceTextureEntry, result: MethodChannel.Result
    ) {
        eventChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(o: Any?, sink: EventSink) {
                    eventSink.setDelegate(sink)
                }

                override fun onCancel(o: Any?) {
                    eventSink.setDelegate(null)
                }
            })
        exoPlayer?.setVideoSurface(surface)
        setAudioAttributes(exoPlayer, true)
        exoPlayer?.addAnalyticsListener(object : AnalyticsListener {
            override fun onBandwidthEstimate(
                eventTime: EventTime,
                totalLoadTimeMs: Int,
                totalBytesLoaded: Long,
                bitrateEstimate: Long
            ) {
                sendBitrate(bitrateEstimate)
            }
        })
        exoPlayer?.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_BUFFERING -> {
                        if (isInitialized) {
                            cmcdSessionRef.get()?.setRebuffering(true)
                        }
                        sendBufferingUpdate(true)
                        val event: MutableMap<String, Any> = HashMap()
                        event["event"] = "bufferingStart"
                        eventSink.success(event)
                    }

                    Player.STATE_READY -> {
                        // Successful playback — allow future MediaCodec recoveries.
                        decoderFailureRecoverCount = 0
                        cmcdSessionRef.get()?.let { session ->
                            session.setRebuffering(false)
                            session.markStarted()
                        }
                        if (!isInitialized) {
                            isInitialized = true
                            sendInitialized()
                        }
                        val event: MutableMap<String, Any> = HashMap()
                        event["event"] = "bufferingEnd"
                        eventSink.success(event)
                    }

                    Player.STATE_ENDED -> {
                        val event: MutableMap<String, Any?> = HashMap()
                        event["event"] = "completed"
                        event["key"] = key
                        eventSink.success(event)
                    }

                    Player.STATE_IDLE -> {
                        //no-op
                    }
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                if (isDrmLicenseFailure(error) && requestSilentDrmRelicense("playerError")) {
                    // Fresh DRM session recreate — do not surface error/loader to Flutter.
                    return
                }
                if (isBehindLiveWindow(error) && recoverBehindLiveWindow()) {
                    // Seek to live edge + re-prepare — do not surface Retry to Flutter.
                    return
                }
                if (isDecoderFailure(error) && recoverDecoderFailure()) {
                    // MediaCodec TIMED_OUT / OMX decoder dead — recreate renderers, keep playing.
                    return
                }
                eventSink.error("VideoError", "Video player had error $error", "${error.errorCode}")
            }
        })
        val reply: MutableMap<String, Any> = HashMap()
        reply["textureId"] = textureEntry.id()
        result.success(reply)
    }

    fun sendBufferingUpdate(isFromBufferingStart: Boolean) {
        val bufferedPosition = exoPlayer?.bufferedPosition ?: 0L
        if (isFromBufferingStart || bufferedPosition != lastSendBufferedPosition) {
            val event: MutableMap<String, Any> = HashMap()
            event["event"] = "bufferingUpdate"
            val range: List<Number?> = listOf(0, bufferedPosition)
            // iOS supports a list of buffered ranges, so here is a list with a single range.
            event["values"] = listOf(range)
            eventSink.success(event)
            lastSendBufferedPosition = bufferedPosition
        }
    }

    fun sendBitrate(bitrate: Long) {
        val event: MutableMap<String, Any> = HashMap()
        event["event"] = "bitrateUpdate"
        event["values"] = bitrate
        eventSink.success(event)
    }

    @Suppress("DEPRECATION")
    private fun setAudioAttributes(exoPlayer: ExoPlayer?, mixWithOthers: Boolean) {
        val audioComponent = exoPlayer?.audioComponent ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            audioComponent.setAudioAttributes(
                AudioAttributes.Builder().setContentType(C.CONTENT_TYPE_MOVIE).build(),
                !mixWithOthers
            )
        } else {
            audioComponent.setAudioAttributes(
                AudioAttributes.Builder().setContentType(C.CONTENT_TYPE_MUSIC).build(),
                !mixWithOthers
            )
        }
    }

    fun play() {
        exoPlayer?.playWhenReady = true
    }

    fun pause() {
        exoPlayer?.playWhenReady = false
    }

    fun setLooping(value: Boolean) {
        exoPlayer?.repeatMode = if (value) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF
    }

    fun setVolume(value: Double) {
        val bracketedValue = max(0.0, min(1.0, value))
            .toFloat()
        exoPlayer?.volume = bracketedValue
    }

    fun setSpeed(value: Double) {
        val bracketedValue = value.toFloat()
        val playbackParameters = PlaybackParameters(bracketedValue)
        exoPlayer?.playbackParameters = playbackParameters
    }

    fun setTrackParameters(width: Int, height: Int, bitrate: Int) {
        val parametersBuilder = trackSelector.buildUponParameters()
        if (width != 0 && height != 0) {
            parametersBuilder.setMaxVideoSize(width, height)
        }
        if (bitrate != 0) {
            parametersBuilder.setMaxVideoBitrate(bitrate)
        }
        if (width == 0 && height == 0 && bitrate == 0) {
            parametersBuilder.clearVideoSizeConstraints()
            parametersBuilder.setMaxVideoBitrate(Int.MAX_VALUE)
        }
        trackSelector.setParameters(parametersBuilder)
    }

    fun seekTo(location: Int) {
        exoPlayer?.seekTo(location.toLong())
    }

    val position: Long
        get() = exoPlayer?.currentPosition ?: 0L

    val absolutePosition: Long
        get() {
            val timeline = exoPlayer?.currentTimeline
            timeline?.let {
                if (!timeline.isEmpty) {
                    val windowStartTimeMs =
                        timeline.getWindow(0, Timeline.Window()).windowStartTimeMs
                    val pos = exoPlayer?.currentPosition ?: 0L
                    return windowStartTimeMs + pos
                }
            }
            return exoPlayer?.currentPosition ?: 0L
        }

    private fun sendInitialized() {
        if (isInitialized) {
            val event: MutableMap<String, Any?> = HashMap()
            event["event"] = "initialized"
            event["key"] = key
            event["duration"] = getDuration()
            if (exoPlayer?.videoFormat != null) {
                val videoFormat = exoPlayer.videoFormat
                var width = videoFormat?.width
                var height = videoFormat?.height
                val rotationDegrees = videoFormat?.rotationDegrees
                // Switch the width/height if video was taken in portrait mode
                if (rotationDegrees == 90 || rotationDegrees == 270) {
                    width = exoPlayer.videoFormat?.height
                    height = exoPlayer.videoFormat?.width
                }
                event["width"] = width
                event["height"] = height
            }
            eventSink.success(event)
        }
    }

    private fun getDuration(): Long = exoPlayer?.duration ?: 0L

    /**
     * Create media session which will be used in notifications, pip mode.
     *
     * @param context                - android context
     * @return - configured MediaSession instance
     */
    @SuppressLint("InlinedApi")
    fun setupMediaSession(context: Context?): MediaSessionCompat? {
        mediaSession?.release()
        context?.let {

            val mediaButtonIntent = Intent(Intent.ACTION_MEDIA_BUTTON)
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                0, mediaButtonIntent,
                PendingIntent.FLAG_IMMUTABLE
            )
            val mediaSession = MediaSessionCompat(context, TAG, null, pendingIntent)
            mediaSession.setCallback(object : MediaSessionCompat.Callback() {
                override fun onSeekTo(pos: Long) {
                    sendSeekToEvent(pos)
                    super.onSeekTo(pos)
                }
            })
            mediaSession.isActive = true
            val mediaSessionConnector = MediaSessionConnector(mediaSession)
            // Prefer our Now Playing fields over ExoPlayer MediaItem (empty → "Unknown").
            mediaSessionConnector.setMediaMetadataProvider {
                buildNowPlayingMetadata()
                    ?: MediaMetadataCompat.Builder()
                        .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, getDuration())
                        .build()
            }
            mediaSessionConnector.setPlayer(exoPlayer)
            this.mediaSession = mediaSession
            // PiP recreates the session — re-apply Now Playing so OEMs do not show "Unknown".
            updateMediaSessionMetadata()
            return mediaSession
        }
        return null

    }

    fun onPictureInPictureStatusChanged(inPip: Boolean) {
        if (inPip) {
            // Background/release OEMs often show a blank first PiP frame until a
            // resize (user double-tap). Rebind the video surface immediately.
            refreshVideoSurfaceForPip()
        }
        val event: MutableMap<String, Any> = HashMap()
        event["event"] = if (inPip) "pipStart" else "pipStop"
        eventSink.success(event)
    }

    /**
     * Re-attach ExoPlayer to the Flutter [SurfaceTexture] so the first PiP
     * composite shows video (release / mini→background enter race on some devices).
     */
    fun refreshVideoSurfaceForPip() {
        try {
            val player = exoPlayer ?: return
            val texture = textureEntry.surfaceTexture()
            val video = player.videoSize
            val metrics = activity.resources.displayMetrics
            // Prefer decoded size; fall back to display so mini→PiP is not stuck
            // on a tiny buffer from the clipped mini layout.
            val bufW = when {
                video.width > 0 -> video.width
                else -> metrics.widthPixels
            }
            val bufH = when {
                video.height > 0 -> video.height
                else -> metrics.heightPixels
            }
            if (bufW > 0 && bufH > 0) {
                texture.setDefaultBufferSize(bufW, bufH)
            }
            val nextSurface = surface?.takeIf { it.isValid } ?: Surface(texture).also {
                surface?.release()
                surface = it
            }
            player.setVideoSurface(null)
            player.setVideoSurface(nextSurface)
            if (!player.playWhenReady) {
                player.playWhenReady = true
            }
        } catch (e: Exception) {
            Log.w(TAG, "refreshVideoSurfaceForPip failed: ${e.message}")
        }
    }

    fun disposeMediaSession() {
        if (mediaSession != null) {
            mediaSession?.release()
        }
        mediaSession = null
    }

    private fun sendEvent(eventType: String) {
        val event: MutableMap<String, Any> = HashMap()
        event["event"] = eventType
        eventSink.success(event)
    }

    fun setAudioTrack(name: String, index: Int) {
        try {
            val mappedTrackInfo = trackSelector.currentMappedTrackInfo
            if (mappedTrackInfo != null) {
                for (rendererIndex in 0 until mappedTrackInfo.rendererCount) {
                    if (mappedTrackInfo.getRendererType(rendererIndex) != C.TRACK_TYPE_AUDIO) {
                        continue
                    }
                    val trackGroupArray = mappedTrackInfo.getTrackGroups(rendererIndex)
                    var hasElementWithoutLabel = false
                    var hasStrangeAudioTrack = false
                    for (groupIndex in 0 until trackGroupArray.length) {
                        val group = trackGroupArray[groupIndex]
                        for (groupElementIndex in 0 until group.length) {
                            val format = group.getFormat(groupElementIndex)
                            if (format.label == null) {
                                hasElementWithoutLabel = true
                            }
                            if (format.id != null && format.id == "1/15") {
                                hasStrangeAudioTrack = true
                            }
                        }
                    }
                    for (groupIndex in 0 until trackGroupArray.length) {
                        val group = trackGroupArray[groupIndex]
                        for (groupElementIndex in 0 until group.length) {
                            val label = group.getFormat(groupElementIndex).label
                            if (name == label && index == groupIndex) {
                                setAudioTrack(rendererIndex, groupIndex, groupElementIndex)
                                return
                            }

                            ///Fallback option
                            if (!hasStrangeAudioTrack && hasElementWithoutLabel && index == groupIndex) {
                                setAudioTrack(rendererIndex, groupIndex, groupElementIndex)
                                return
                            }
                            ///Fallback option
                            if (hasStrangeAudioTrack && name == label) {
                                setAudioTrack(rendererIndex, groupIndex, groupElementIndex)
                                return
                            }
                        }
                    }
                }
            }
        } catch (exception: Exception) {
            Log.e(TAG, "setAudioTrack failed$exception")
        }
    }

    private fun setAudioTrack(rendererIndex: Int, groupIndex: Int, groupElementIndex: Int) {
        val mappedTrackInfo = trackSelector.currentMappedTrackInfo
        if (mappedTrackInfo != null) {
            val builder = trackSelector.parameters.buildUpon()
                .setRendererDisabled(rendererIndex, false)
                .setTrackSelectionOverrides(
                    TrackSelectionOverrides.Builder().addOverride(
                        TrackSelectionOverrides.TrackSelectionOverride(
                            mappedTrackInfo.getTrackGroups(
                                rendererIndex
                            ).get(groupIndex)
                        )
                    ).build()
                )

            trackSelector.setParameters(builder)
        }
    }

    private fun sendSeekToEvent(positionMs: Long) {
        exoPlayer?.seekTo(positionMs)
        val event: MutableMap<String, Any> = HashMap()
        event["event"] = "seek"
        event["position"] = positionMs
        eventSink.success(event)
    }

    fun setMixWithOthers(mixWithOthers: Boolean) {
        setAudioAttributes(exoPlayer, mixWithOthers)
    }

    fun dispose() {
        releaseQuanteec()
        clearCmcd()
        disposeMediaSession()
        disposeRemoteNotifications()
        if (isInitialized) {
            exoPlayer?.stop()
        }
        textureEntry.release()
        eventChannel.setStreamHandler(null)
        surface?.release()
        exoPlayer?.release()
    }

    private fun configureCmcd(raw: Map<String, Any?>?) {
        val config = CmcdRuntimeConfig.fromMap(raw)
        cmcdConfigRef.set(config)
        if (config == null) {
            cmcdSessionRef.set(null)
            Log.d(TAG_CMCD, "disabled (missing/invalid config)")
            return
        }
        CmcdDataSource.resetLogCount()
        val existing = cmcdSessionRef.get()
        if (existing == null || existing.sessionId != config.sessionId) {
            cmcdSessionRef.set(
                CmcdSession(config.sessionId, config.contentId, config.isLive)
            )
            Log.d(
                TAG_CMCD,
                "session start mode=${config.mode} sid=${config.sessionId} " +
                        "cid=${config.contentId} isLive=${config.isLive}"
            )
        } else {
            existing.isLive = config.isLive
            existing.updateContentId(config.contentId)
            Log.d(
                TAG_CMCD,
                "session update mode=${config.mode} sid=${config.sessionId} " +
                        "cid=${config.contentId} isLive=${config.isLive}"
            )
        }
    }

    private fun clearCmcd() {
        cmcdConfigRef.set(null)
        cmcdSessionRef.set(null)
    }

    private fun maybeWrapCmcd(factory: DataSource.Factory): DataSource.Factory {
        val config = cmcdConfigRef.get()
        if (config == null || !config.isActive) {
            Log.d(TAG_CMCD, "wrap skipped (inactive)")
            return factory
        }
        // Quanteec replaces the media source factory at create-time; CMCD must not stack with it.
        if (quanteecCore != null) {
            Log.d(TAG_CMCD, "wrap skipped (quanteec active)")
            return factory
        }
        Log.d(TAG_CMCD, "DataSource wrapped mode=${config.mode}")
        return CmcdDataSource.Factory(
            factory,
            cmcdSessionRef,
            cmcdConfigRef,
            ::snapshotCmcdMetrics,
            { drmLicenseUrl },
        )
    }

    private fun snapshotCmcdMetrics(): CmcdMetrics {
        val player = exoPlayer
        var encodedKbps: Int? = null
        var topKbps: Int? = null
        try {
            val format = player?.videoFormat
            if (format != null && format.bitrate != Format.NO_VALUE) {
                encodedKbps = (format.bitrate / 1000).coerceAtLeast(0)
            }
            val groups = player?.currentTrackGroups
            if (groups != null) {
                var maxBr = 0
                for (i in 0 until groups.length) {
                    val group = groups[i]
                    for (j in 0 until group.length) {
                        val br = group.getFormat(j).bitrate
                        if (br != Format.NO_VALUE && br > maxBr) maxBr = br
                    }
                }
                if (maxBr > 0) topKbps = maxBr / 1000
            }
        } catch (_: Exception) {
        }
        val throughput = try {
            val estimate = bandwidthMeter.bitrateEstimate
            if (estimate > 0) (estimate / 1000).toInt() else null
        } catch (_: Exception) {
            null
        }
        val bufferMs = try {
            val p = player ?: return CmcdMetrics(
                encodedBitrateKbps = encodedKbps,
                topBitrateKbps = topKbps,
                throughputKbps = throughput,
            )
            val buffered = p.bufferedPosition
            val current = p.currentPosition
            if (buffered >= current) buffered - current else null
        } catch (_: Exception) {
            null
        }
        val rate = try {
            player?.playbackParameters?.speed ?: 1f
        } catch (_: Exception) {
            1f
        }
        return CmcdMetrics(
            encodedBitrateKbps = encodedKbps,
            topBitrateKbps = topKbps,
            throughputKbps = throughput,
            bufferLengthMs = bufferMs,
            playbackRate = rate,
        )
    }

    fun releaseQuanteec() {
        try {
            quanteecCore?.release()
            quanteecCore = null
        } catch (_: Exception) {}
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other == null || javaClass != other.javaClass) return false
        val that = other as BetterPlayer
        if (if (exoPlayer != null) exoPlayer != that.exoPlayer else that.exoPlayer != null) return false
        return if (surface != null) surface == that.surface else that.surface == null
    }

    override fun hashCode(): Int {
        var result = exoPlayer?.hashCode() ?: 0
        result = 31 * result + if (surface != null) surface.hashCode() else 0
        return result
    }

    companion object {
        private const val TAG = "BetterPlayer"
        private const val TAG_CMCD = "CMCD"
        private const val FORMAT_SS = "ss"
        private const val FORMAT_DASH = "dash"
        private const val FORMAT_HLS = "hls"
        private const val FORMAT_OTHER = "other"
        private const val DEFAULT_NOTIFICATION_CHANNEL = "BETTER_PLAYER_NOTIFICATION"
        private const val NOTIFICATION_ID = 20772077

        /** ~300 kbps — prefer lowest viable ladder rung at startup. */
        private const val ABR_INITIAL_BITRATE_ESTIMATE = 300_000L

        /** Debounce OEM KEY_EXPIRED storms while a recreate is in flight. */
        private const val SILENT_DRM_RELICENSE_DEBOUNCE_MS = 1500L

        /** Enough for multi-hour live with ~2 min rental windows. */
        private const val MAX_SILENT_DRM_RELICENSES = 120

        private const val BEHIND_LIVE_WINDOW_RECOVER_DEBOUNCE_MS = 1500L
        private const val MAX_BEHIND_LIVE_WINDOW_RECOVERIES = 20

        private const val DECODER_FAILURE_RECOVER_DEBOUNCE_MS = 1500L
        private const val MAX_DECODER_FAILURE_RECOVERIES = 5

        //Clear cache without accessing BetterPlayerCache.
        fun clearCache(context: Context?, result: MethodChannel.Result) {
            try {
                context?.let { context ->
                    val file = File(context.cacheDir, "betterPlayerCache")
                    deleteDirectory(file)
                }
                result.success(null)
            } catch (exception: Exception) {
                Log.e(TAG, exception.toString())
                result.error("", "", "")
            }
        }

        private fun deleteDirectory(file: File) {
            if (file.isDirectory) {
                val entries = file.listFiles()
                if (entries != null) {
                    for (entry in entries) {
                        deleteDirectory(entry)
                    }
                }
            }
            if (!file.delete()) {
                Log.e(TAG, "Failed to delete cache dir.")
            }
        }

        //Start pre cache of video. Invoke work manager job and start caching in background.
        fun preCache(
            context: Context?, dataSource: String?, preCacheSize: Long,
            maxCacheSize: Long, maxCacheFileSize: Long, headers: Map<String, String?>,
            cacheKey: String?, result: MethodChannel.Result
        ) {
            val dataBuilder = Data.Builder()
                .putString(BetterPlayerPlugin.URL_PARAMETER, dataSource)
                .putLong(BetterPlayerPlugin.PRE_CACHE_SIZE_PARAMETER, preCacheSize)
                .putLong(BetterPlayerPlugin.MAX_CACHE_SIZE_PARAMETER, maxCacheSize)
                .putLong(BetterPlayerPlugin.MAX_CACHE_FILE_SIZE_PARAMETER, maxCacheFileSize)
            if (cacheKey != null) {
                dataBuilder.putString(BetterPlayerPlugin.CACHE_KEY_PARAMETER, cacheKey)
            }
            for (headerKey in headers.keys) {
                dataBuilder.putString(
                    BetterPlayerPlugin.HEADER_PARAMETER + headerKey,
                    headers[headerKey]
                )
            }
            if (dataSource != null && context != null) {
                val cacheWorkRequest = OneTimeWorkRequest.Builder(CacheWorker::class.java)
                    .addTag(dataSource)
                    .setInputData(dataBuilder.build()).build()
                WorkManager.getInstance(context).enqueue(cacheWorkRequest)
            }
            result.success(null)
        }

        //Stop pre cache of video with given url. If there's no work manager job for given url, then
        //it will be ignored.
        fun stopPreCache(context: Context?, url: String?, result: MethodChannel.Result) {
            if (url != null && context != null) {
                WorkManager.getInstance(context).cancelAllWorkByTag(url)
            }
            result.success(null)
        }
    }

}
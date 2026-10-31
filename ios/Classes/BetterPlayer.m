// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "BetterPlayer.h"
#import <UIKit/UIKit.h>
#import <better_player/better_player-Swift.h>

static void* timeRangeContext = &timeRangeContext;
static void* statusContext = &statusContext;
static void* playbackLikelyToKeepUpContext = &playbackLikelyToKeepUpContext;
static void* playbackBufferEmptyContext = &playbackBufferEmptyContext;
static void* playbackBufferFullContext = &playbackBufferFullContext;
static void* presentationSizeContext = &presentationSizeContext;
static void *timeControlStatusContext = &timeControlStatusContext;

static NSString* BetterPlayerNormalizeDrmToken(NSString* token) {
    if (![token isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString* normalizedToken = [token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (normalizedToken.length == 0) {
        return nil;
    }
    if ([normalizedToken caseInsensitiveCompare:@"null"] == NSOrderedSame) {
        return nil;
    }
    return normalizedToken;
}

static NSString* BetterPlayerNormalizeNonEmptyString(NSString* value) {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString* normalizedValue = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return normalizedValue.length > 0 ? normalizedValue : nil;
}

static BOOL BetterPlayerIsRemoteCertificateUrl(NSString* certificateUrl) {
    NSString* lowerCertificateUrl = [certificateUrl lowercaseString];
    return [lowerCertificateUrl hasPrefix:@"http://"] || [lowerCertificateUrl hasPrefix:@"https://"];
}

static NSString* BetterPlayerCertificateUrlPreview(NSString* certificateUrl) {
    if (certificateUrl.length == 0) {
        return @"(empty)";
    }
    if (BetterPlayerIsRemoteCertificateUrl(certificateUrl)) {
        return certificateUrl;
    }
    const NSUInteger previewLength = MIN((NSUInteger)32, certificateUrl.length);
    return [NSString stringWithFormat:@"%@... (%lu chars, inline base64)",
            [certificateUrl substringToIndex:previewLength],
            (unsigned long)certificateUrl.length];
}


#if TARGET_OS_IOS
void (^__strong _Nonnull _restoreUserInterfaceForPIPStopCompletionHandler)(BOOL);
API_AVAILABLE(ios(9.0))
AVPictureInPictureController *_pipController;
#endif

/** ~300 kbps startup peak so Auto ABR begins on a low rung, then unlocks. */
static const double kAbrStartupPeakBitRate = 300000.0;
/** Silent live-edge recovery when AVPlayer falls behind / stalls on live HLS. */
static const NSInteger kMaxLiveEdgeRecoveries = 20;

@implementation BetterPlayer {
    NSTimer *nerdStatTimer;
    BetterPlayerVuDrmAssetsLoaderDelegate *_vuDrmAssetsloaderDelegate;
    BOOL nerdStatActive;
    double lastBitRate;
    /// YES while PiP should keep playing across app background (same as in-app).
    BOOL _pipDesiredPlaying;
    BOOL _appInBackground;
    /// YES between willStop and cleanup — ignore teardown pause events.
    BOOL _pipStopping;
    /// User expanded PiP back into the app (restore UI), not dismissed with X.
    BOOL _pipExpandingToApp;
    /// Resume in-app playback after PiP stop when expanding while playing.
    BOOL _pipResumeAfterStop;
    /// YES after Auto (0x0x0) until buffer is healthy and peak cap is cleared.
    BOOL _autoAbrPendingUnlock;
    NSInteger _liveEdgeRecoverCount;
    NSTimeInterval _lastLiveEdgeRecoverAt;
    /// Set once we observe indefinite duration (live HLS/DASH).
    BOOL _isLiveStream;
}

- (instancetype)initWithFrame:(CGRect)frame dictQuanteecConfig:(NSDictionary * _Nullable)dictQuanteecConfig {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _isInitialized = false;
    _isPlaying = false;
    _disposed = false;
    _pipDesiredPlaying = false;
    _appInBackground = false;
    _pipStopping = false;
    _pipExpandingToApp = false;
    _pipResumeAfterStop = false;
    _player = [[AVPlayer alloc] init];

    //TODO: handle quanteec when package available
    /*if (dictQuanteecConfig) {
        [QuanteecHelper setupWithPlayer:_player dictQuanteecConfig: dictQuanteecConfig];
    }*/

    BetterPlayerView *playerView = [[BetterPlayerView alloc] initWithFrame:CGRectZero];
    playerView.player = _player;
    _thisView = playerView;

    [self setUpAdsLoader];
//    _adTagUrlOrAdsResponse = @"https://ap-south-1-prod.ads.expresswifi.com/ads/video?h=720&w=600&api_key=BHPGAIUBVG4QIJIA&apid=3412547012154583&tag=app-10001-0002&skip=5";
    _isAdTagUrl = TRUE;
    _contentPlayhead = [[IMAAVPlayerContentPlayhead alloc] initWithAVPlayer:_player];
//    [self requestAds];

    _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    ///Fix for loading large videos
    if (@available(iOS 10.0, *)) {
        _player.automaticallyWaitsToMinimizeStalling = false;
    }

    self._observersAdded = false;
#if TARGET_OS_IOS
    [self registerAppLifecycleObservers];
#endif
    _liveEdgeRecoverCount = 0;
    _lastLiveEdgeRecoverAt = 0;
    _isLiveStream = NO;
    return self;
}

#if TARGET_OS_IOS
- (void)registerAppLifecycleObservers {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    // removeObserver:self also clears these; re-add after player item observer churn.
    [center removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
    [center removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
    [center removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    if (@available(iOS 11.0, *)) {
        [center removeObserver:self name:UIScreenCapturedDidChangeNotification object:nil];
    }
    [center addObserver:self
               selector:@selector(applicationWillResignActive:)
                   name:UIApplicationWillResignActiveNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationDidEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
    if (@available(iOS 11.0, *)) {
        [center addObserver:self
                   selector:@selector(screenCaptureDidChange:)
                       name:UIScreenCapturedDidChangeNotification
                     object:nil];
        // Arm immediately if capture already active (e.g. mid-session).
        if (UIScreen.mainScreen.isCaptured) {
            [self forcePauseForScreenCapture];
        }
    }
}

/// Stop playback and system PiP when the screen is recorded/mirrored (no FLAG_SECURE on iOS).
- (void)forcePauseForScreenCapture {
    if (_disposed) {
        return;
    }
    _pipDesiredPlaying = NO;
    _pipExpandingToApp = NO;
    _pipResumeAfterStop = NO;
    _isPlaying = false;
    if (@available(iOS 9.0, *)) {
        if (_pipController != nil && [_pipController isPictureInPictureActive]) {
            self._pictureInPicture = NO;
            [_pipController stopPictureInPicture];
        }
    }
    if (_player != nil) {
        [_player pause];
    }
    if (_eventSink != nil) {
        _eventSink(@{@"event" : @"pause"});
    }
}

- (void)screenCaptureDidChange:(NSNotification *)notification {
    if (@available(iOS 11.0, *)) {
        if (UIScreen.mainScreen.isCaptured) {
            [self forcePauseForScreenCapture];
        }
        // Capture ended: leave paused — user must resume.
    }
}
#endif

/// Live when duration is indefinite, or we previously observed a live item this session.
- (BOOL)isLikelyLiveItem:(AVPlayerItem *)item {
    if (_isLiveStream) return YES;
    if (item == nil) return NO;
    if (CMTIME_IS_INDEFINITE(item.duration)) {
        _isLiveStream = YES;
        return YES;
    }
    return NO;
}

/// AVPlayer is advancing frames (may still report playbackBufferEmpty with stalling disabled).
- (BOOL)isActivelyPlaying {
    if (@available
    (iOS
    10.0, *)) {
        return _player.timeControlStatus == AVPlayerTimeControlStatusPlaying;
    }
    return _player.rate > 0;
}

- (void)sendBufferingStart {
    if (_eventSink == nil) {
        return;
    }
    NSMutableDictionary *event = [@{@"event": @"bufferingStart"} mutableCopy];
    if (_key != nil) {
        event[@"key"] = _key;
    }
    _eventSink(event);
}

- (void)sendBufferingEnd {
    if (_eventSink == nil) {
        return;
    }
    NSMutableDictionary *event = [@{@"event": @"bufferingEnd"} mutableCopy];
    if (_key != nil) {
        event[@"key"] = _key;
    }
    _eventSink(event);
}

/// Parity with Android STATE_READY → bufferingEnd after silent live-edge recovery.
- (void)notifyPlaybackResumedAfterRecovery {
    __weak BetterPlayer *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        BetterPlayer *strong = weakSelf;
        if (strong == nil || strong.disposed) {
            return;
        }
        if (strong->_isPlaying || [strong isActivelyPlaying]) {
            [strong sendBufferingEnd];
        }
    });
}

- (BOOL)recoverToLiveEdge:(NSString *)reason {
    AVPlayerItem *item = _player.currentItem;
    if (item == nil) return NO;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - _lastLiveEdgeRecoverAt < 1.5) {
        NSLog(@"[LiveEdge] recovery debounced (%@)", reason);
        return YES;
    }
    if (_liveEdgeRecoverCount >= kMaxLiveEdgeRecoveries) {
        NSLog(@"[LiveEdge] recovery exhausted after %ld attempts", (long) _liveEdgeRecoverCount);
        return NO;
    }

    _liveEdgeRecoverCount++;
    _lastLiveEdgeRecoverAt = now;
    _stalledCount = 0;
    _isStalledCheckStarted = false;
    NSLog(@"[LiveEdge] recovery attempt=%ld (%@)", (long) _liveEdgeRecoverCount, reason);

    // Failed items cannot seek reliably — rebuild from the same asset (keeps headers/DRM loader).
    if (item.status == AVPlayerItemStatusFailed) {
        AVAsset *asset = item.asset;
        if (asset == nil) return NO;
        AVPlayerItem *fresh = [AVPlayerItem playerItemWithAsset:asset];
        [self removeObservers];
        [_player replaceCurrentItemWithPlayerItem:fresh];
        [self addObservers:fresh];
        [self play];
        [self notifyPlaybackResumedAfterRecovery];
        return YES;
    }

    CMTime liveTime = kCMTimeInvalid;
    NSArray *ranges = item.seekableTimeRanges;
    if (ranges.count > 0) {
        CMTimeRange last = [[ranges lastObject] CMTimeRangeValue];
        liveTime = CMTimeRangeGetEnd(last);
    } else if (CMTIME_IS_INDEFINITE(item.duration) || _isLiveStream) {
        liveTime = kCMTimePositiveInfinity;
    }
    if (!CMTIME_IS_VALID(liveTime)) return NO;

    __weak BetterPlayer *weakSelf = self;
    [_player seekToTime:liveTime
        toleranceBefore:kCMTimeZero
         toleranceAfter:kCMTimeZero
      completionHandler:^(BOOL finished) {
          BetterPlayer *strong = weakSelf;
          if (strong == nil || strong.disposed) return;
          [strong play];
          [strong notifyPlaybackResumedAfterRecovery];
      }];
    return YES;
}

- (void)toggleNerdStat {
    if (nerdStatActive == TRUE) {
        [nerdStatTimer invalidate];
        nerdStatTimer = nil;
        nerdStatActive = FALSE;
    } else {
        nerdStatTimer = [NSTimer scheduledTimerWithTimeInterval: 2.0
                          target: self
                          selector:@selector(nerdStat:)
                          userInfo: nil repeats:YES];
        nerdStatActive = TRUE;
    }
}

- (void)nerdStat:(NSTimer *)timer {
    if (_eventSink == nil) {
        return;
    }
    NSString *data = [[[NerdStatHelper alloc] init] getNerdStatTextWithPlayer: _player];

    _eventSink(@{ @"event" : @"nerdStat", @"values" : data});
}

- (nonnull UIView *)view {
    return _thisView;
}

- (void)addObservers:(AVPlayerItem*)item {
    if (!self._observersAdded){
        [_player addObserver:self forKeyPath:@"rate" options:0 context:nil];
        if (@available
        (iOS
        10.0, *)) {
            [_player addObserver:self
                      forKeyPath:@"timeControlStatus"
                         options:NSKeyValueObservingOptionNew
                         context:timeControlStatusContext];
        }
        [item addObserver:self forKeyPath:@"loadedTimeRanges" options:0 context:timeRangeContext];
        [item addObserver:self forKeyPath:@"status" options:0 context:statusContext];
        [item addObserver:self forKeyPath:@"presentationSize" options:0 context:presentationSizeContext];
        [item addObserver:self
               forKeyPath:@"playbackLikelyToKeepUp"
                  options:0
                  context:playbackLikelyToKeepUpContext];
        [item addObserver:self
               forKeyPath:@"playbackBufferEmpty"
                  options:0
                  context:playbackBufferEmptyContext];
        [item addObserver:self
               forKeyPath:@"playbackBufferFull"
                  options:0
                  context:playbackBufferFullContext];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(itemDidPlayToEndTime:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification
                                                   object:item];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAVPlayerAccess:)
                                                     name:AVPlayerItemNewAccessLogEntryNotification
                                                   object:nil];
        self._observersAdded = true;
    }
}

- (void)handleAVPlayerAccess:(NSNotification *)notif {
    AVPlayerItemAccessLog *accessLog = [((AVPlayerItem *)notif.object) accessLog];
    AVPlayerItemAccessLogEvent *lastEvent = accessLog.events.lastObject;
    float lastEventNumber = lastEvent.indicatedBitrate;
    if (lastEventNumber != lastBitRate) {
        lastBitRate = lastEventNumber;
        if (_eventSink != nil) {
            _eventSink(@{@"event" : @"bitrateUpdate", @"values" : [NSNumber numberWithInt:(int)lastBitRate]});
        }
    }
    // Once AVPlayer reports a variant, lift the startup peak so ABR can upshift.
    if (_autoAbrPendingUnlock && lastEventNumber > 0) {
        [self unlockAutoAbrIfNeeded];
    }
}

- (void)unlockAutoAbrIfNeeded {
    if (!_autoAbrPendingUnlock) {
        return;
    }
    _autoAbrPendingUnlock = NO;
    if (_player.currentItem != nil) {
        _player.currentItem.preferredPeakBitRate = 0;
    }
}

- (void)clear {
    _isInitialized = false;
    _isPlaying = false;
    _pipDesiredPlaying = false;
    _disposed = false;
    _failedCount = 0;
    _key = nil;
    _adTagUrlOrAdsResponse = @"";
    _autoAbrPendingUnlock = NO;
    _liveEdgeRecoverCount = 0;
    _lastLiveEdgeRecoverAt = 0;
    _isLiveStream = NO;
    if (_player.currentItem == nil) {
        return;
    }

    if (_player.currentItem == nil) {
        return;
    }

    [self removeObservers];
    AVAsset* asset = [_player.currentItem asset];
    [asset cancelLoading];
}

- (void) removeObservers{
    if (self._observersAdded){
        [_player removeObserver:self forKeyPath:@"rate" context:nil];
        if (@available
        (iOS
        10.0, *)) {
            [_player removeObserver:self forKeyPath:@"timeControlStatus" context:timeControlStatusContext];
        }
        [[_player currentItem] removeObserver:self forKeyPath:@"status" context:statusContext];
        [[_player currentItem] removeObserver:self forKeyPath:@"presentationSize" context:presentationSizeContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"loadedTimeRanges"
                                      context:timeRangeContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"playbackLikelyToKeepUp"
                                      context:playbackLikelyToKeepUpContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"playbackBufferEmpty"
                                      context:playbackBufferEmptyContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"playbackBufferFull"
                                      context:playbackBufferFullContext];
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        self._observersAdded = false;
#if TARGET_OS_IOS
        [self registerAppLifecycleObservers];
#endif
    }
}

- (void)itemDidPlayToEndTime:(NSNotification*)notification {
    if (_isLooping) {
        AVPlayerItem* p = [notification object];
        [p seekToTime:kCMTimeZero completionHandler:nil];
    } else {
        if (_eventSink) {
            _eventSink(@{@"event" : @"completed", @"key" : _key});
            [ self removeObservers];

        }
    }
}


static inline CGFloat radiansToDegrees(CGFloat radians) {
    // Input range [-pi, pi] or [-180, 180]
    CGFloat degrees = GLKMathRadiansToDegrees((float)radians);
    if (degrees < 0) {
        // Convert -90 to 270 and -180 to 180
        return degrees + 360;
    }
    // Output degrees in between [0, 360[
    return degrees;
};

- (AVMutableVideoComposition*)getVideoCompositionWithTransform:(CGAffineTransform)transform
                                                     withAsset:(AVAsset*)asset
                                                withVideoTrack:(AVAssetTrack*)videoTrack {
    AVMutableVideoCompositionInstruction* instruction =
    [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, [asset duration]);
    AVMutableVideoCompositionLayerInstruction* layerInstruction =
    [AVMutableVideoCompositionLayerInstruction
     videoCompositionLayerInstructionWithAssetTrack:videoTrack];
    [layerInstruction setTransform:_preferredTransform atTime:kCMTimeZero];

    AVMutableVideoComposition* videoComposition = [AVMutableVideoComposition videoComposition];
    instruction.layerInstructions = @[ layerInstruction ];
    videoComposition.instructions = @[ instruction ];

    // If in portrait mode, switch the width and height of the video
    CGFloat width = videoTrack.naturalSize.width;
    CGFloat height = videoTrack.naturalSize.height;
    NSInteger rotationDegrees =
    (NSInteger)round(radiansToDegrees(atan2(_preferredTransform.b, _preferredTransform.a)));
    if (rotationDegrees == 90 || rotationDegrees == 270) {
        width = videoTrack.naturalSize.height;
        height = videoTrack.naturalSize.width;
    }
    videoComposition.renderSize = CGSizeMake(width, height);

    float nominalFrameRate = videoTrack.nominalFrameRate;
    int fps = 30;
    if (nominalFrameRate > 0) {
        fps = (int) ceil(nominalFrameRate);
    }
    videoComposition.frameDuration = CMTimeMake(1, fps);
    
    return videoComposition;
}

- (CGAffineTransform)fixTransform:(AVAssetTrack*)videoTrack {
  CGAffineTransform transform = videoTrack.preferredTransform;
  // TODO(@recastrodiaz): why do we need to do this? Why is the preferredTransform incorrect?
  // At least 2 user videos show a black screen when in portrait mode if we directly use the
  // videoTrack.preferredTransform Setting tx to the height of the video instead of 0, properly
  // displays the video https://github.com/flutter/flutter/issues/17606#issuecomment-413473181
  NSInteger rotationDegrees = (NSInteger)round(radiansToDegrees(atan2(transform.b, transform.a)));
  if (rotationDegrees == 90) {
    transform.tx = videoTrack.naturalSize.height;
    transform.ty = 0;
  } else if (rotationDegrees == 180) {
    transform.tx = videoTrack.naturalSize.width;
    transform.ty = videoTrack.naturalSize.height;
  } else if (rotationDegrees == 270) {
    transform.tx = 0;
    transform.ty = videoTrack.naturalSize.width;
  }
  return transform;
}

- (void)setDataSourceAsset:(NSString*)asset withKey:(NSString*)key withCertificateUrl:(NSString*)certificateUrl withLicenseUrl:(NSString*)licenseUrl cacheKey:(NSString*)cacheKey cacheManager:(CacheManager*)cacheManager overriddenDuration:(int) overriddenDuration withDrmToken: (NSString *)drmToken {
    NSString* path = [[NSBundle mainBundle] pathForResource:asset ofType:nil];
    return [self setDataSourceURL:[NSURL fileURLWithPath:path] withKey:key withCertificateUrl:certificateUrl withLicenseUrl:(NSString *) licenseUrl withHeaders:@{} withCache:false cacheKey:cacheKey cacheManager:cacheManager overriddenDuration:overriddenDuration videoExtension:nil adsUrl:@"" withDrmToken:drmToken cmcdConfig:nil];
}

- (void)setDataSourceURL:(NSURL *)url withKey:(NSString *)key withCertificateUrl:(NSString *)certificateUrl withLicenseUrl:(NSString *)licenseUrl withHeaders:(NSDictionary *)headers withCache:(BOOL)useCache cacheKey:(NSString *)cacheKey cacheManager:(CacheManager *)cacheManager overriddenDuration:(int)overriddenDuration videoExtension:(NSString *)videoExtension adsUrl:(NSString *)adsUrl withDrmToken:(NSString *)drmToken cmcdConfig:(NSDictionary * _Nullable)cmcdConfig {
    if (adsUrl != (id)[NSNull null]) {
        _adTagUrlOrAdsResponse = adsUrl;
        [self requestAds];
    }
    _overriddenDuration = 0;
    if (headers == [NSNull null] || headers == NULL){
        headers = @{};
    }

    // CMCD: iOS native HLS cannot tag per-segment requests; only initial URL / static headers.
    // Never attach CMCD to DRM license/key flows (handled by resource-loader delegates below).
    NSURL *mediaURL = url;
    NSDictionary *mediaHeaders = headers;
    @try {
        if ([CmcdHelper isActiveWithConfig:cmcdConfig]) {
            mediaURL = [CmcdHelper taggedURLFrom:url config:cmcdConfig];
            mediaHeaders = [CmcdHelper httpHeadersMerging:headers config:cmcdConfig url:mediaURL];
        }
    } @catch (NSException *exception) {
        mediaURL = url;
        mediaHeaders = headers;
    }
    
    AVPlayerItem* item;
    if (useCache){
        if (cacheKey == [NSNull null]){
            cacheKey = nil;
        }
        if (videoExtension == [NSNull null]){
            videoExtension = nil;
        }

        item = [cacheManager getCachingPlayerItemForNormalPlayback:mediaURL cacheKey:cacheKey videoExtension:videoExtension headers:mediaHeaders];
    } else {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:mediaURL
                                                options:@{@"AVURLAssetHTTPHeaderFieldsKey": mediaHeaders}];
        NSString* normalizedDrmToken = BetterPlayerNormalizeDrmToken(drmToken);
        NSString* normalizedCertificateUrl = BetterPlayerNormalizeNonEmptyString(certificateUrl);
        NSString* normalizedLicenseUrl = BetterPlayerNormalizeNonEmptyString(licenseUrl);
        // VuDRM handles token-based providers (e.g. Lionsgate) and inline-certificate providers (e.g. SonyLiv ExpressPlay).
        if (normalizedCertificateUrl != nil && normalizedLicenseUrl != nil &&
            (normalizedDrmToken != nil || !BetterPlayerIsRemoteCertificateUrl(normalizedCertificateUrl))) {
            BOOL isInlineCertificate = !BetterPlayerIsRemoteCertificateUrl(normalizedCertificateUrl);
            NSLog(@"[BetterPlayer-FairPlay] Using VuDRM delegate (inlineCertificate=%@, hasToken=%@)",
                  isInlineCertificate ? @"YES" : @"NO",
                  normalizedDrmToken != nil ? @"YES" : @"NO");
            NSLog(@"[BetterPlayer-FairPlay] certificateUrl=%@",
                  BetterPlayerCertificateUrlPreview(normalizedCertificateUrl));
            NSLog(@"[BetterPlayer-FairPlay] licenseUrl=%@", normalizedLicenseUrl);
            NSURL * licenseNSURL = [[NSURL alloc] initWithString: normalizedLicenseUrl];
            _vuDrmAssetsloaderDelegate = [[BetterPlayerVuDrmAssetsLoaderDelegate alloc]initWithCertificateURL:normalizedCertificateUrl licenseURL:licenseNSURL fairPlayToken:normalizedDrmToken];
            dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_DEFAULT, -1);
            dispatch_queue_t streamQueue = dispatch_queue_create("streamQueue", qos);
            [asset.resourceLoader setDelegate:_vuDrmAssetsloaderDelegate queue:streamQueue];
        } else if (normalizedCertificateUrl != nil && normalizedLicenseUrl != nil) {
            NSLog(@"[BetterPlayer-FairPlay] Using EzDRM delegate");
            NSLog(@"[BetterPlayer-FairPlay] certificateUrl=%@",
                  BetterPlayerCertificateUrlPreview(normalizedCertificateUrl));
            NSLog(@"[BetterPlayer-FairPlay] licenseUrl=%@", normalizedLicenseUrl);
            NSURL * certificateNSURL = [[NSURL alloc] initWithString: normalizedCertificateUrl];
            NSURL * licenseNSURL = [[NSURL alloc] initWithString: normalizedLicenseUrl];
            _loaderDelegate = [[BetterPlayerEzDrmAssetsLoaderDelegate alloc] init:certificateNSURL withLicenseURL:licenseNSURL];
            dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_DEFAULT, -1);
            dispatch_queue_t streamQueue = dispatch_queue_create("streamQueue", qos);
            [asset.resourceLoader setDelegate:_loaderDelegate queue:streamQueue];
        }
        item = [AVPlayerItem playerItemWithAsset:asset];
    }

    if (@available(iOS 10.0, *) && overriddenDuration > 0) {
        _overriddenDuration = overriddenDuration;
    }
    return [self setDataSourcePlayerItem:item withKey:key];
}

- (void)setDataSourcePlayerItem:(AVPlayerItem*)item withKey:(NSString*)key{
    _key = key;
    _stalledCount = 0;
    _liveEdgeRecoverCount = 0;
    _lastLiveEdgeRecoverAt = 0;
    _isLiveStream = NO;
    _isStalledCheckStarted = false;
    _playerRate = 1;
    [_player replaceCurrentItemWithPlayerItem:item];

    AVAsset* asset = [item asset];
    void (^assetCompletionHandler)(void) = ^{
        if ([asset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded) {
            NSArray* tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
            if ([tracks count] > 0) {
                AVAssetTrack* videoTrack = tracks[0];
                void (^trackCompletionHandler)(void) = ^{
                    if (self->_disposed) return;
                    if ([videoTrack statusOfValueForKey:@"preferredTransform"
                                                  error:nil] == AVKeyValueStatusLoaded) {
                        // Rotate the video by using a videoComposition and the preferredTransform
                        self->_preferredTransform = [self fixTransform:videoTrack];
                        // Note:
                        // https://developer.apple.com/documentation/avfoundation/avplayeritem/1388818-videocomposition
                        // Video composition can only be used with file-based media and is not supported for
                        // use with media served using HTTP Live Streaming.
                        AVMutableVideoComposition* videoComposition =
                        [self getVideoCompositionWithTransform:self->_preferredTransform
                                                     withAsset:asset
                                                withVideoTrack:videoTrack];
                        item.videoComposition = videoComposition;
                    }
                };
                [videoTrack loadValuesAsynchronouslyForKeys:@[ @"preferredTransform" ]
                                          completionHandler:trackCompletionHandler];
            }
        }
    };

    [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:assetCompletionHandler];
    [self addObservers:item];
}

-(void)handleStalled {
    if (_isStalledCheckStarted){
        return;
    }
   _isStalledCheckStarted = true;
    [self startStalledCheck];
}

-(void)startStalledCheck{
    if (_player.currentItem.playbackLikelyToKeepUp ||
        [self availableDuration] - CMTimeGetSeconds(_player.currentItem.currentTime) > 10.0) {
        [self play];
        // timeControlStatus may already be Playing (no KVO re-fire) — clear sticky loader.
        [self sendBufferingEnd];
    } else {
        _stalledCount++;
        if (_stalledCount > 60){
            // Live: jump to edge instead of surfacing Retry.
            if ([self isLikelyLiveItem:_player.currentItem] && [self recoverToLiveEdge:@"stalled"]) {
                return;
            }
            if (_eventSink != nil) {
                _eventSink([FlutterError
                        errorWithCode:@"VideoError"
                        message:@"Failed to load video: playback stalled"
                        details:nil]);
            }
            return;
        }
        [self performSelector:@selector(startStalledCheck) withObject:nil afterDelay:1];

    }
}

- (NSTimeInterval) availableDuration
{
    NSArray *loadedTimeRanges = [[_player currentItem] loadedTimeRanges];
    if (loadedTimeRanges.count > 0){
        CMTimeRange timeRange = [[loadedTimeRanges objectAtIndex:0] CMTimeRangeValue];
        Float64 startSeconds = CMTimeGetSeconds(timeRange.start);
        Float64 durationSeconds = CMTimeGetSeconds(timeRange.duration);
        NSTimeInterval result = startSeconds + durationSeconds;
        return result;
    } else {
        return 0;
    }

}

- (void)observeValueForKeyPath:(NSString*)path
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {

    if ([path isEqualToString:@"rate"]) {
        BOOL pipActive = NO;
        if (@available(iOS 10.0, *)) {
            pipActive = _pipController != nil && _pipController.pictureInPictureActive == YES;
            if (pipActive){
                if (_lastAvPlayerTimeControlStatus != [NSNull null] && _lastAvPlayerTimeControlStatus == _player.timeControlStatus){
                    return;
                }

                if (_player.timeControlStatus == AVPlayerTimeControlStatusPaused){
                    // Expanding PiP → in-app: ignore teardown pause (restore UI /
                    // willStop run around the same time as this rate change).
                    if (_pipExpandingToApp || (_pipStopping && _pipResumeAfterStop)) {
                        return;
                    }
                    // App background/inactive often forces AVPlayer pause before our
                    // lifecycle flag is set. Resume if PiP should keep playing.
                    UIApplicationState appState = [UIApplication sharedApplication].applicationState;
                    BOOL leavingForeground = _appInBackground || appState != UIApplicationStateActive;
                    if (_pipDesiredPlaying && leavingForeground) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self keepPipPlayingIfNeeded];
                        });
                        return;
                    }
                    _lastAvPlayerTimeControlStatus = _player.timeControlStatus;
                    _isPlaying = false;
                    _pipDesiredPlaying = false;
                    if (_eventSink != nil) {
                      _eventSink(@{@"event" : @"pause"});
                    }
                    return;

                }
                if (_player.timeControlStatus == AVPlayerTimeControlStatusPlaying){
                    _lastAvPlayerTimeControlStatus = _player.timeControlStatus;
                    _isPlaying = true;
                    _pipDesiredPlaying = true;
                    if (_eventSink != nil) {
                      _eventSink(@{@"event" : @"play"});
                    }
                    return;
                }
                return;
            }
        }

        // Do not treat intentional PiP pause as a stall.
        if (!pipActive &&
            _player.rate == 0 && //if player rate dropped to 0
            CMTIME_COMPARE_INLINE(_player.currentItem.currentTime, >, kCMTimeZero) && //if video was started
            CMTIME_COMPARE_INLINE(_player.currentItem.currentTime, <, _player.currentItem.duration) && //but not yet finished
            _isPlaying) { //instance variable to handle overall state (changed to YES when user triggers playback)
            [self handleStalled];
        }
    }

    if (context == timeRangeContext) {
        if (_eventSink != nil) {
            NSMutableArray<NSArray<NSNumber*>*>* values = [[NSMutableArray alloc] init];
            for (NSValue* rangeValue in [object loadedTimeRanges]) {
                CMTimeRange range = [rangeValue CMTimeRangeValue];
                int64_t start = [BetterPlayerTimeUtils FLTCMTimeToMillis:(range.start)];
                int64_t end = start + [BetterPlayerTimeUtils FLTCMTimeToMillis:(range.duration)];
                if (!CMTIME_IS_INVALID(_player.currentItem.forwardPlaybackEndTime)) {
                    int64_t endTime = [BetterPlayerTimeUtils FLTCMTimeToMillis:(_player.currentItem.forwardPlaybackEndTime)];
                    if (end > endTime){
                        end = endTime;
                    }
                }

                [values addObject:@[ @(start), @(end) ]];
            }
            _eventSink(@{@"event" : @"bufferingUpdate", @"values" : values, @"key" : _key});
        }
    }
    else if (context == presentationSizeContext){
        [self onReadyToPlay];
    }

    else if (context == statusContext) {
        AVPlayerItem* item = (AVPlayerItem*)object;
        switch (item.status) {
            case AVPlayerItemStatusFailed:
                NSLog(@"Failed to load video:");
                NSLog(@"%@", item.error.debugDescription);

                // Live HLS can fail when the playhead falls behind the sliding window.
                if ([self isLikelyLiveItem:item] && [self recoverToLiveEdge:@"itemFailed"]) {
                    break;
                }

                if (_eventSink != nil) {
                    NSString *errorMessage = [NSString stringWithFormat:@"Failed to load video: %@ | Debug: %@",
                                                                        [item.error localizedDescription],
                                                                        item.error.debugDescription ?: @"No debug details available"];

                    _eventSink([FlutterError
                            errorWithCode:@"VideoError"
                                  message:errorMessage
                                  details:nil]);
                }
                break;
            case AVPlayerItemStatusUnknown:
                break;
            case AVPlayerItemStatusReadyToPlay:
                [self onReadyToPlay];
                break;
        }
    } else if (context == timeControlStatusContext) {
        // Primary buffering signal: Playing clears Flutter loader; Waiting shows it.
        // Needed because automaticallyWaitsToMinimizeStalling=NO can play while
        // isPlaybackLikelyToKeepUp stays false (no bufferingEnd from item KVO).
        if (@available
        (iOS
        10.0, *)) {
            AVPlayerTimeControlStatus status = _player.timeControlStatus;
            if (status == AVPlayerTimeControlStatusPlaying) {
                [self unlockAutoAbrIfNeeded];
                [self sendBufferingEnd];
            } else if (status == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate) {
                [self sendBufferingStart];
            }
        }
    } else if (context == playbackLikelyToKeepUpContext) {
        if ([[_player currentItem] isPlaybackLikelyToKeepUp]) {
            [self unlockAutoAbrIfNeeded];
            [self updatePlayingState];
            [self sendBufferingEnd];
        }
    } else if (context == playbackBufferEmptyContext) {
        // With stalling minimization disabled, buffer can empty while frames still advance.
        // Do not sticky-start the Flutter loader over active playback.
        if ([self isActivelyPlaying]) {
            return;
        }
        [self sendBufferingStart];
    } else if (context == playbackBufferFullContext) {
        [self sendBufferingEnd];
    }
}

- (void)updatePlayingState {
    if (!_isInitialized || !_key) {
        return;
    }
    if (!self._observersAdded){
        [self addObservers:[_player currentItem]];
    }

    if (_isPlaying) {
        if (@available(iOS 10.0, *)) {
            [_player playImmediatelyAtRate:1.0];
            _player.rate = _playerRate;
        } else {
            [_player play];
            _player.rate = _playerRate;
        }
    } else {
        [_player pause];
    }
}

- (void)onReadyToPlay {
    if (_eventSink && !_isInitialized && _key) {
        if (!_player.currentItem) {
            return;
        }
        if (_player.status != AVPlayerStatusReadyToPlay) {
            return;
        }

        CGSize size = [_player currentItem].presentationSize;
        CGFloat width = size.width;
        CGFloat height = size.height;


        AVAsset *asset = _player.currentItem.asset;
        bool onlyAudio =  [[asset tracksWithMediaType:AVMediaTypeVideo] count] == 0;

        // The player has not yet initialized.
        if (!onlyAudio && height == CGSizeZero.height && width == CGSizeZero.width) {
            return;
        }
        const BOOL isLive = CMTIME_IS_INDEFINITE([_player currentItem].duration);
        if (isLive) {
            _isLiveStream = YES;
        }
        // The player may be initialized but still needs to determine the duration.
        if (isLive == false && [self duration] == 0) {
            return;
        }

        //Fix from https://github.com/flutter/flutter/issues/66413
        AVPlayerItemTrack *track = [self.player currentItem].tracks.firstObject;
        CGSize naturalSize = track.assetTrack.naturalSize;
        CGAffineTransform prefTrans = track.assetTrack.preferredTransform;
        CGSize realSize = CGSizeApplyAffineTransform(naturalSize, prefTrans);

        int64_t duration = [BetterPlayerTimeUtils FLTCMTimeToMillis:(_player.currentItem.asset.duration)];
        if (_overriddenDuration > 0 && duration > _overriddenDuration){
            _player.currentItem.forwardPlaybackEndTime = CMTimeMake(_overriddenDuration/1000, 1);
        }

        _isInitialized = true;
        [self updatePlayingState];
        _eventSink(@{
            @"event" : @"initialized",
            @"duration" : @([self duration]),
            @"width" : @(fabs(realSize.width) ? : width),
            @"height" : @(fabs(realSize.height) ? : height),
            @"key" : _key
        });
    }
}

- (void)play {
    //to stop play or pause when ad is playing
    if (_isAdsPlaying == TRUE) {
        return;
    }
#if TARGET_OS_IOS
    if (@available(iOS 11.0, *)) {
        // Do not start (or arm PiP) while screen capture is active.
        if (UIScreen.mainScreen.isCaptured) {
            [self forcePauseForScreenCapture];
            return;
        }
    }
#endif
    _stalledCount = 0;
    _isStalledCheckStarted = false;
    _isPlaying = true;
    _pipDesiredPlaying = true;
    [self updatePlayingState];
#if TARGET_OS_IOS
    // Arm automatic video PiP before the user leaves the app.
    [self ensurePipPreparedForAutomaticStart];
#endif
}

- (void)pause {
    //to stop play or pause when ad is playing
    if (_isAdsPlaying == TRUE) {
        return;
    }
#if TARGET_OS_IOS
    if (@available(iOS 11.0, *)) {
        if (UIScreen.mainScreen.isCaptured) {
            [self forcePauseForScreenCapture];
            return;
        }
    }
    // Flutter/engine often pauses on inactive. If we are leaving the app while
    // playback is desired, start/keep system PiP instead of falling back to
    // audio-only Dynamic Island / Now Playing.
    UIApplicationState appState = [UIApplication sharedApplication].applicationState;
    BOOL leavingForeground = _appInBackground || appState != UIApplicationStateActive;
    if (_pipDesiredPlaying && leavingForeground) {
        if ([self isPipActive]) {
            [self keepPipPlayingIfNeeded];
            return;
        }
        [self bindPipToInlinePlayerLayer];
        [self startPictureInPictureNow];
        if ([self isPipActive] || self._pictureInPicture) {
            return;
        }
    }
#endif
    _isPlaying = false;
    _pipDesiredPlaying = false;
    [self updatePlayingState];
}

- (int64_t)position {
    return [BetterPlayerTimeUtils FLTCMTimeToMillis:([_player currentTime])];
}

- (int64_t)absolutePosition {
    return [BetterPlayerTimeUtils FLTNSTimeIntervalToMillis:([[[_player currentItem] currentDate] timeIntervalSince1970])];
}

- (int64_t)duration {
    CMTime time;
    if (@available(iOS 13, *)) {
        time =  [[_player currentItem] duration];
    } else {
        time =  [[[_player currentItem] asset] duration];
    }
    if (!CMTIME_IS_INVALID(_player.currentItem.forwardPlaybackEndTime)) {
        time = [[_player currentItem] forwardPlaybackEndTime];
    }

    return [BetterPlayerTimeUtils FLTCMTimeToMillis:(time)];
}

- (void)seekTo:(int)location {
    ///When player is playing, pause video, seek to new position and start again. This will prevent issues with seekbar jumps.
    bool wasPlaying = _isPlaying;
    if (wasPlaying){
        [_player pause];
    }

    [_player seekToTime:CMTimeMake(location, 1000)
        toleranceBefore:kCMTimeZero
         toleranceAfter:kCMTimeZero
      completionHandler:^(BOOL finished){
        if (wasPlaying){
            _player.rate = _playerRate;
        }
    }];
}

- (void)setIsLooping:(bool)isLooping {
    _isLooping = isLooping;
}

- (void)setVolume:(double)volume {
    _player.volume = (float)((volume < 0.0) ? 0.0 : ((volume > 1.0) ? 1.0 : volume));
}

- (void)setSpeed:(double)speed result:(FlutterResult)result {
    if (speed == 1.0 || speed == 0.0) {
        _playerRate = 1;
        result(nil);
    } else if (speed < 0 || speed > 2.0) {
        result([FlutterError errorWithCode:@"unsupported_speed"
                                   message:@"Speed must be >= 0.0 and <= 2.0"
                                   details:nil]);
    } else {
        _playerRate = speed;
        result(nil);
    }

    if (_isPlaying){
        _player.rate = _playerRate;
    }
}


- (void)setTrackParameters:(int) width: (int) height: (int)bitrate {
    if (width == 0 && height == 0 && bitrate == 0) {
        // Auto: start with a low peak so playback begins on a low rung, then unlock.
        _autoAbrPendingUnlock = YES;
        _player.currentItem.preferredPeakBitRate = kAbrStartupPeakBitRate;
        if (@available
        (iOS
        11.0, *)) {
            _player.currentItem.preferredMaximumResolution = CGSizeZero;
        }
        return;
    }
    _autoAbrPendingUnlock = NO;
    _player.currentItem.preferredPeakBitRate = bitrate;
    if (@available(iOS 11.0, *)) {
        if (width == 0 && height == 0){
            _player.currentItem.preferredMaximumResolution = CGSizeZero;
        } else {
            _player.currentItem.preferredMaximumResolution = CGSizeMake(width, height);
        }
    }
}

- (void)setPictureInPicture:(BOOL)pictureInPicture
{
    self._pictureInPicture = pictureInPicture;
    if (@available(iOS 9.0, *)) {
        if (_pipController && self._pictureInPicture && ![_pipController isPictureInPictureActive]) {
            [self startPictureInPictureNow];
        } else if (_pipController && !self._pictureInPicture && [_pipController isPictureInPictureActive]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [_pipController stopPictureInPicture];
            });
        } else {
            // Fallback on earlier versions
        } }
}

- (void)setUpAdsLoader {
    if (_adsLoader == NULL) {
        _adsLoader = [[IMAAdsLoader alloc] initWithSettings: NULL];
    }
    _adsLoader.delegate = self;
}

- (void)requestAds {
    if ([_adTagUrlOrAdsResponse isEqual: @""]) {
        return;
    }
    // Create ad display container for ad rendering.
    IMAAdDisplayContainer *adDisplayContainer = [[IMAAdDisplayContainer alloc] initWithAdContainer:self.view viewController:NULL];
    // Create an ad request with our ad tag, display container, and optional user context.
    IMAAdsRequest *request;
    if (_isAdTagUrl) {
        request = [[IMAAdsRequest alloc] initWithAdTagUrl:_adTagUrlOrAdsResponse adDisplayContainer:adDisplayContainer contentPlayhead:_contentPlayhead userContext:NULL];
    } else {
        request = [[IMAAdsRequest alloc] initWithAdsResponse:_adTagUrlOrAdsResponse adDisplayContainer:adDisplayContainer contentPlayhead:_contentPlayhead userContext:NULL];
    }
    [_adsLoader requestAdsWithRequest:request];
}

- (void)adsLoader:(IMAAdsLoader *)loader adsLoadedWithData:(IMAAdsLoadedData *)adsLoadedData {
    _adsManager = adsLoadedData.adsManager;
    _adsManager.delegate = self;
    [_adsManager initializeWithAdsRenderingSettings: NULL];
}

- (void)adsLoader:(IMAAdsLoader *)loader failedWithErrorData:(IMAAdLoadingErrorData *)adErrorData {
    [_player play];
}

- (void)adsManager:(IMAAdsManager *)adsManager didReceiveAdEvent:(IMAAdEvent *)event {
    // Play each ad once it has been loaded
    if (event.type == kIMAAdEvent_LOADED) {
        [_adsManager start];
    }
}

- (void)adsManagerDidRequestContentPause:(IMAAdsManager *)adsManager {
    _eventSink(@{@"event" : @"adStarted"});
    [self pause];
    _isAdsPlaying = TRUE;
}

- (void)adsManagerDidRequestContentResume:(IMAAdsManager *)adsManager {
    _eventSink(@{@"event" : @"adEnded"});
    _isAdsPlaying = FALSE;
    [self play];
}

#if TARGET_OS_IOS
- (void)setRestoreUserInterfaceForPIPStopCompletionHandler:(BOOL)restore
{
    if (_restoreUserInterfaceForPIPStopCompletionHandler != NULL) {
        _restoreUserInterfaceForPIPStopCompletionHandler(restore);
        _restoreUserInterfaceForPIPStopCompletionHandler = NULL;
    }
}

- (BOOL)_isOverlayPipLayer:(AVPlayerLayer *)layer {
    return layer != nil && _thisView != nil && layer != _thisView.playerLayer;
}

- (void)_removeOverlayPipLayerIfNeeded {
    if ([self _isOverlayPipLayer:self._playerLayer]) {
        [self._playerLayer removeFromSuperlayer];
        self._playerLayer = nil;
    }
}

/// Bind PiP to the inline platform-view AVPlayerLayer (not a second root overlay).
/// Overlay layers caused duplicate video frames and broke mini → background PiP.
- (void)bindPipToInlinePlayerLayer {
    if (_disposed || !_player || !_thisView) {
        return;
    }
    [self _removeOverlayPipLayerIfNeeded];
    self._playerLayer = _thisView.playerLayer;
    if (self._playerLayer.player != _player) {
        self._playerLayer.player = _player;
    }
    [self setupPipController];
}

- (void)setupPipController {
    if (@available(iOS 9.0, *)) {
        // Playback category is required for PiP to continue in background.
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
        [[AVAudioSession sharedInstance] setActive: YES error: nil];
        [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
        if (!self._playerLayer || ![AVPictureInPictureController isPictureInPictureSupported]) {
            return;
        }
        // Controller is tied to one layer — recreate when the layer changes.
        if (_pipController != nil && _pipController.playerLayer != self._playerLayer) {
            _pipController.delegate = nil;
            _pipController = nil;
        }
        if (!_pipController) {
            _pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:self._playerLayer];
            _pipController.delegate = self;
        }
        if (@available(iOS 14.2, *)) {
            // YouTube-like: system starts video PiP when leaving the app.
            _pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
        }
    } else {
        // Fallback on earlier versions
    }
}

/// Arm automatic video PiP from the inline player (no duplicate overlay layer).
- (void)ensurePipPreparedForAutomaticStart {
    if (@available(iOS 9.0, *)) {
        if (_disposed || !_player) {
            return;
        }
        if (@available(iOS 11.0, *)) {
            if (UIScreen.mainScreen.isCaptured) {
                return;
            }
        }
        if (![AVPictureInPictureController isPictureInPictureSupported]) {
            return;
        }
        [self bindPipToInlinePlayerLayer];
    }
}

- (BOOL)isPipActive {
    if (@available(iOS 9.0, *)) {
        return _pipController != nil && _pipController.pictureInPictureActive == YES;
    }
    return NO;
}

/// Keep AVPlayer running while system PiP is active (background must not pause it).
- (void)keepPipPlayingIfNeeded {
    if (_disposed || !_pipDesiredPlaying || ![self isPipActive]) {
        return;
    }
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    _isPlaying = true;
    if (@available(iOS 10.0, *)) {
        [_player playImmediatelyAtRate:(_playerRate > 0 ? _playerRate : 1.0)];
    } else {
        [_player play];
        _player.rate = (_playerRate > 0 ? _playerRate : 1.0);
    }
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    _appInBackground = YES;
    if (@available(iOS 11.0, *)) {
        if (UIScreen.mainScreen.isCaptured) {
            [self forcePauseForScreenCapture];
            return;
        }
    }
    if (_pipDesiredPlaying && [self isPipActive]) {
        [self keepPipPlayingIfNeeded];
        return;
    }
    // Last chance before suspend: start video PiP from the inline layer
    // (Flutter inactive is often too late for a method-channel round-trip).
    if (_pipDesiredPlaying && _isPlaying) {
        [self bindPipToInlinePlayerLayer];
        [self startPictureInPictureNow];
    }
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    _appInBackground = YES;
    if (@available(iOS 11.0, *)) {
        if (UIScreen.mainScreen.isCaptured) {
            [self forcePauseForScreenCapture];
            return;
        }
    }
    if (_pipDesiredPlaying && [self isPipActive]) {
        [self keepPipPlayingIfNeeded];
    }
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    _appInBackground = NO;
    // Drop any leftover root overlay from older PiP paths (dual-frame bug).
    [self _removeOverlayPipLayerIfNeeded];
    if (_pipDesiredPlaying && [self isPipActive]) {
        [self keepPipPlayingIfNeeded];
    }
}

- (void) enablePictureInPicture: (CGRect) frame{
    // Frame is unused — PiP must use the inline platform-view layer. Creating a
    // second root AVPlayerLayer stacked a "big" video over the mini player.
    (void)frame;
    BOOL desiredPlaying = _pipDesiredPlaying || _isPlaying;
    if (desiredPlaying) {
        _pipDesiredPlaying = YES;
        _isPlaying = YES;
    }
    [self bindPipToInlinePlayerLayer];
    [self startPictureInPictureNow];
}

- (void)usePlayerLayer: (CGRect) frame
{
    (void)frame;
    [self enablePictureInPicture:CGRectZero];
}

- (void)startPictureInPictureNow {
    if (@available(iOS 9.0, *)) {
        if (@available(iOS 11.0, *)) {
            if (UIScreen.mainScreen.isCaptured) {
                [self forcePauseForScreenCapture];
                return;
            }
        }
        if (_pipController == nil) {
            [self bindPipToInlinePlayerLayer];
        }
        if (_pipController == nil) {
            return;
        }
        self._pictureInPicture = YES;
        if (!_pipController.isPictureInPictureActive) {
            if (_pipController.isPictureInPicturePossible) {
                [_pipController startPictureInPicture];
            } else {
                // Layer may need one layout pass before possible == YES.
                // _pipController is file-scope (not an ivar) — do not use self->.
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (_pipController != nil &&
                        !_pipController.isPictureInPictureActive &&
                        _pipController.isPictureInPicturePossible) {
                        [_pipController startPictureInPicture];
                    }
                });
            }
        }
    }
}

- (void)disablePictureInPicture
{
    [self disablePictureInPictureKeepIntent:NO];
}

- (void)disablePictureInPictureKeepIntent:(BOOL)keepIntent
{
    // Must pass NO to stop an active PiP session. Passing YES was a long-standing
    // bug that left system PiP running and blocked new playback handoff.
    BOOL resumeAfterStop = _pipResumeAfterStop;
    BOOL desiredPlaying = _pipDesiredPlaying || _isPlaying;
    _pipStopping = YES;
    [self setPictureInPicture:false];
    // Never remove the inline BetterPlayerView layer — only leftover overlays.
    [self _removeOverlayPipLayerIfNeeded];
    if (!keepIntent && _eventSink != nil) {
        _eventSink(@{@"event" : @"pipStop"});
    }
    if (resumeAfterStop) {
        // Expanding PiP → in-app: keep the same playing state.
        _isPlaying = YES;
        _pipDesiredPlaying = NO;
        if (@available(iOS 10.0, *)) {
            [_player playImmediatelyAtRate:(_playerRate > 0 ? _playerRate : 1.0)];
        } else {
            [_player play];
            _player.rate = (_playerRate > 0 ? _playerRate : 1.0);
        }
        if (_eventSink != nil) {
            _eventSink(@{@"event" : @"play"});
        }
    } else if (keepIntent) {
        _pipDesiredPlaying = desiredPlaying;
        _isPlaying = desiredPlaying;
    } else {
        _pipDesiredPlaying = NO;
    }
    _pipStopping = NO;
    _pipResumeAfterStop = NO;
    _pipExpandingToApp = NO;
}
#endif

#if TARGET_OS_IOS
- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController  API_AVAILABLE(ios(9.0)){
    [self disablePictureInPicture];
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController  API_AVAILABLE(ios(9.0)){
    if (_eventSink != nil) {
        _eventSink(@{@"event" : @"pipStart"});
    }
    // Entered PiP while playing — keep that state across app background.
    _pipDesiredPlaying = YES;
    _isPlaying = YES;
    _pipStopping = NO;
    _pipExpandingToApp = NO;
    _pipResumeAfterStop = NO;
    // Only nudge leftover overlay layers off-screen — never move the inline view.
    if ([self _isOverlayPipLayer:self._playerLayer]) {
        self._playerLayer.frame = CGRectMake(-3.0, -3.0, 1.0, 1.0);
    }
    [self keepPipPlayingIfNeeded];
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController  API_AVAILABLE(ios(9.0)){
    _pipStopping = YES;
    // Only resume in-app when the user expands PiP back (restore UI), not when
    // dismissing PiP with X or when Flutter ends the session for handoff.
    if (_pipExpandingToApp && (_pipDesiredPlaying || _isPlaying)) {
        _pipResumeAfterStop = YES;
    }
}

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {

}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
    [self _removeOverlayPipLayerIfNeeded];
    self._pictureInPicture = NO;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    _pipExpandingToApp = YES;
    // Capture play intent as early as possible (before teardown pause).
    if (_pipDesiredPlaying || _isPlaying) {
        _pipResumeAfterStop = YES;
    }
    [self setRestoreUserInterfaceForPIPStopCompletionHandler: true];
}

- (void) setAudioTrack:(NSString*) name index:(int) index{
    AVMediaSelectionGroup *audioSelectionGroup = [[[_player currentItem] asset] mediaSelectionGroupForMediaCharacteristic: AVMediaCharacteristicAudible];
    NSArray* options = audioSelectionGroup.options;


    for (int audioTrackIndex = 0; audioTrackIndex < [options count]; audioTrackIndex++) {
        AVMediaSelectionOption* option = [options objectAtIndex:audioTrackIndex];
        NSArray *metaDatas = [AVMetadataItem metadataItemsFromArray:option.commonMetadata withKey:@"title" keySpace:@"comn"];
        if (metaDatas.count > 0) {
            NSString *title = ((AVMetadataItem*)[metaDatas objectAtIndex:0]).stringValue;
            if ([name compare:title] == NSOrderedSame && audioTrackIndex == index ){
                [[_player currentItem] selectMediaOption:option inMediaSelectionGroup: audioSelectionGroup];
            }
        }

    }

}

- (void)setMixWithOthers:(bool)mixWithOthers {
  if (mixWithOthers) {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                     withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                           error:nil];
  } else {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
  }
}


#endif

- (FlutterError* _Nullable)onCancelWithArguments:(id _Nullable)arguments {
    _eventSink = nil;
    return nil;
}

- (FlutterError* _Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
    _eventSink = events;
    // TODO(@recastrodiaz): remove the line below when the race condition is resolved:
    // https://github.com/flutter/flutter/issues/21483
    // This line ensures the 'initialized' event is sent when the event
    // 'AVPlayerItemStatusReadyToPlay' fires before _eventSink is set (this function
    // onListenWithArguments is called)
    [self onReadyToPlay];
    return nil;
}

/// This method allows you to dispose without touching the event channel.  This
/// is useful for the case where the Engine is in the process of deconstruction
/// so the channel is going to die or is already dead.
- (void)disposeSansEventChannel {
    @try{
        [self clear];
    }
    @catch(NSException *exception) {
        NSLog(exception.debugDescription);
    }
}

- (void)dispose {
    [nerdStatTimer invalidate];
    nerdStatTimer = nil;
    [self pause];
    [self disposeSansEventChannel];
    [_eventChannel setStreamHandler:nil];
    [self disablePictureInPicture];
    [self setPictureInPicture:false];
    _disposed = true;
}

@end

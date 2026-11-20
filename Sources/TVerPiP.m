#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <stdio.h>

#ifndef TVERPIP_DIAGNOSTIC
#define TVERPIP_DIAGNOSTIC 0
#endif

static NSHashTable<AVPlayer *> *TVPlayers;
static NSHashTable<AVPlayerLayer *> *TVLayers;
static NSHashTable<MPRemoteCommand *> *TVCommands;
static NSMutableArray *TVPiPObjects;
static NSMapTable<AVPictureInPictureController *, AVPlayerLayer *> *TVControllerLayers;
static NSMapTable<AVPlayerLayer *, AVPlayerItem *> *TVRejectedItems;
static BOOL TVInstallingCommands;
static AVAudioEngine *TVSilentEngine;
static AVAudioPlayerNode *TVSilentNode;
static AVAudioPCMBuffer *TVSilentBuffer;
static NSString *TVLogPath;
static AVPlayerLayer *TVProtectedLayer;
static AVPictureInPictureController *TVArmedController;
static __weak AVPlayerItem *TVArmedItem;
static NSUInteger TVPiPAttempt;
static BOOL TVPiPTransitionInProgress;

@interface TVPiPObserver : NSObject <AVPictureInPictureControllerDelegate>
@end

static TVPiPObserver *TVObserver;

static void TVRetainPiPObject(id object) {
    if (!object)
        return;
    [TVPiPObjects addObject:object];
    while (TVPiPObjects.count > 24)
        [TVPiPObjects removeObjectAtIndex:0];
}

static void TVLog(NSString *format, ...);
static void TVStartBestController(BOOL useBackgroundProxy);
static void TVDisarmController(void);
static BOOL TVIsProgramLayer(AVPlayerLayer *layer);

static void TVLog(NSString *format, ...) {
    if (!TVERPIP_DIAGNOSTIC)
        return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[TVerPiP] %@", message);
    if (!TVLogPath)
        TVLogPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"TVerPiP.log"];
    FILE *file = fopen(TVLogPath.fileSystemRepresentation, "a");
    if (file) {
        fprintf(file, "%s\n", message.UTF8String);
        fclose(file);
    }
}

@implementation TVPiPObserver
- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)controller {
    TVLog(@"PiP will start controller=%p", controller);
}
- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)controller {
    TVLog(@"PiP did start controller=%p", controller);
    if (controller != TVArmedController ||
        [TVControllerLayers objectForKey:controller].player.currentItem != TVArmedItem) {
        [controller stopPictureInPicture];
        return;
    }
    TVPiPTransitionInProgress = YES;
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        dispatch_async(dispatch_get_main_queue(), ^{
          if (controller.pictureInPictureActive &&
              UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
              [controller stopPictureInPicture];
        });
    }
}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller
    failedToStartPictureInPictureWithError:(NSError *)error {
    TVLog(@"PiP failed controller=%p domain=%@ code=%ld", controller, error.domain,
          (long)error.code);
}
- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)controller {
    TVLog(@"PiP did stop controller=%p", controller);
    if (controller == TVArmedController)
        TVDisarmController();
    TVPiPTransitionInProgress = NO;
    TVProtectedLayer = nil;
}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    TVLog(@"PiP restore requested controller=%p", controller);
    completionHandler(YES);
}
@end

static void (*OrigPlayerPlay)(AVPlayer *, SEL);
static void (*OrigPlayerPause)(AVPlayer *, SEL);
static void (*OrigPlayerReplace)(AVPlayer *, SEL, AVPlayerItem *);
static void (*OrigLayerSetPlayer)(AVPlayerLayer *, SEL, AVPlayer *);
typedef id (*TVInitWithLayer)(id self __attribute__((ns_consumed)), SEL, AVPlayerLayer *)
    __attribute__((ns_returns_retained));
typedef id (*TVInitWithSource)(id self __attribute__((ns_consumed)), SEL,
                              AVPictureInPictureControllerContentSource *)
    __attribute__((ns_returns_retained));
static id (*OrigLayerInitPlayer)(id self __attribute__((ns_consumed)), SEL, AVPlayer *)
    __attribute__((ns_returns_retained));
static TVInitWithLayer OrigPiPInitLayer;
static TVInitWithSource OrigPiPInitSource;
static void (*OrigPiPStart)(id, SEL);
static void (*OrigPiPStop)(id, SEL);
static void (*OrigPiPSetActive)(id, SEL, BOOL);
static void (*OrigCommandSetEnabled)(MPRemoteCommand *, SEL, BOOL);
static void (*OrigCommandAddTargetAction)(MPRemoteCommand *, SEL, id, SEL);
static id (*OrigCommandAddHandler)(MPRemoteCommand *, SEL, id);
static void (*OrigCommandRemoveTarget)(MPRemoteCommand *, SEL, id);
static void (*OrigCommandRemoveTargetAction)(MPRemoteCommand *, SEL, id, SEL);

static void TVRememberPlayer(AVPlayer *player) {
    if (!player)
        return;
    @synchronized(TVPlayers) {
        [TVPlayers addObject:player];
    }
    TVLog(@"player remembered %p item=%d rate=%.2f", player, player.currentItem != nil,
          player.rate);
}

static void TVRememberLayer(AVPlayerLayer *layer) {
    if (!layer)
        return;
    @synchronized(TVLayers) {
        [TVLayers addObject:layer];
    }
    TVRememberPlayer(layer.player);
    TVLog(@"layer remembered %p player=%p ready=%d", layer, layer.player,
          layer.readyForDisplay);
}

static AVPlayer *TVCurrentPlayer(void) {
    NSArray<AVPlayer *> *players;
    @synchronized(TVPlayers) {
        players = TVPlayers.allObjects;
    }
    AVPlayer *best = nil;
    NSInteger bestScore = NSIntegerMin;
    for (AVPlayer *player in players) {
        NSInteger score = player.currentItem ? 100 : 0;
        if (player.rate != 0.0f)
            score += 200;
        if (@available(iOS 10.0, *)) {
            if (player.timeControlStatus == AVPlayerTimeControlStatusPlaying)
                score += 300;
            if (player.timeControlStatus == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate)
                score += 50;
        }
        if (score > bestScore) {
            best = player;
            bestScore = score;
        }
    }
    return best;
}

static void TVUpdateNowPlaying(AVPlayer *player) {
    if (!player)
        return;
    NSMutableDictionary *info = [MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo mutableCopy]
                                    ?: [NSMutableDictionary dictionary];
    Float64 elapsed = CMTimeGetSeconds(player.currentTime);
    Float64 duration = CMTimeGetSeconds(player.currentItem.duration);
    if (isfinite(elapsed) && elapsed >= 0)
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsed);
    if (isfinite(duration) && duration > 0)
        info[MPMediaItemPropertyPlaybackDuration] = @(duration);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(player.rate);
    info[MPNowPlayingInfoPropertyMediaType] = @(MPNowPlayingInfoMediaTypeVideo);
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = info;
    if (@available(iOS 13.0, *)) {
        MPNowPlayingInfoCenter.defaultCenter.playbackState =
            player.rate == 0 ? MPNowPlayingPlaybackStatePaused : MPNowPlayingPlaybackStatePlaying;
    }
}

static MPRemoteCommandHandlerStatus TVWithPlayer(void (^action)(AVPlayer *)) {
    AVPlayer *player = TVCurrentPlayer();
    if (!player)
        return MPRemoteCommandHandlerStatusNoSuchContent;
    dispatch_async(dispatch_get_main_queue(), ^{
      action(player);
      TVUpdateNowPlaying(player);
    });
    return MPRemoteCommandHandlerStatusSuccess;
}

static void TVSeek(AVPlayer *player, NSTimeInterval delta) {
    Float64 current = CMTimeGetSeconds(player.currentTime);
    Float64 duration = CMTimeGetSeconds(player.currentItem.duration);
    if (!isfinite(current))
        return;
    Float64 target = MAX(0, current + delta);
    if (isfinite(duration) && duration > 0)
        target = MIN(target, duration);
    [player seekToTime:CMTimeMakeWithSeconds(target, NSEC_PER_SEC)
        toleranceBefore:kCMTimeZero
         toleranceAfter:kCMTimeZero];
}

static void TVStartSilentKeepalive(void) {
    if (TVSilentEngine.running)
        return;
    if (!TVSilentEngine) {
        TVSilentEngine = [AVAudioEngine new];
        TVSilentNode = [AVAudioPlayerNode new];
        [TVSilentEngine attachNode:TVSilentNode];
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100
                                                                               channels:2];
        [TVSilentEngine connect:TVSilentNode to:TVSilentEngine.mainMixerNode format:format];
        TVSilentEngine.mainMixerNode.outputVolume = 0.0f;
        TVSilentBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:4096];
        TVSilentBuffer.frameLength = 4096;
    }
    [TVSilentNode scheduleBuffer:TVSilentBuffer
                          atTime:nil
                         options:AVAudioPlayerNodeBufferLoops
               completionHandler:nil];
    NSError *error = nil;
    [TVSilentEngine prepare];
    if ([TVSilentEngine startAndReturnError:&error]) {
        [TVSilentNode play];
        TVLog(@"silent keepalive started");
    } else {
        TVLog(@"silent keepalive failed: %@", error);
    }
}

static void TVStopSilentKeepalive(void) {
    [TVSilentNode stop];
    [TVSilentEngine stop];
}

static BOOL TVAnyPiPActive(void) {
    for (AVPictureInPictureController *controller in TVControllerLayers.keyEnumerator) {
        if (controller.pictureInPictureActive)
            return YES;
    }
    return NO;
}

static void TVScheduleKeepaliveSafetyTimeout(void) {
    NSUInteger attempt = TVPiPAttempt;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      if (attempt == TVPiPAttempt && !TVAnyPiPActive()) {
          TVLog(@"keepalive safety timeout: no active PiP");
          TVDisarmController();
          TVStopSilentKeepalive();
          TVPiPTransitionInProgress = NO;
          TVProtectedLayer = nil;
      }
    });
}

static BOOL TVIsProgramLayer(AVPlayerLayer *layer) {
    // The redesigned home screen also runs AVPlayer for promotional previews.
    // Older layouts do not expose the same player view controllers.
    static BOOL redesignedHome;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      redesignedHome =
          NSClassFromString(@"RebornHomeFeature.HeroInlineAdPlayerViewController") != Nil ||
          NSClassFromString(@"_TtC17RebornHomeFeature32HeroInlineAdPlayerViewController") != Nil;
    });
    if (!redesignedHome)
        return YES;

    UIView *view = nil;
    for (CALayer *ancestor = layer; ancestor; ancestor = ancestor.superlayer) {
        if (ancestor.hidden || ancestor.opacity <= 0.01)
            return NO;
        id delegate = ancestor.delegate;
        if (!view && [delegate isKindOfClass:UIView.class])
            view = delegate;
    }
    UIWindow *window = view.window;
    if (!window || !CGRectIntersectsRect([view convertRect:view.bounds toView:window], window.bounds))
        return NO;
    NSString *programOwner = nil;
    BOOL dedicatedScreen = NO;
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:UIViewController.class])
            continue;
        UIViewController *owner = (UIViewController *)responder;
        UINavigationController *navigation = owner.navigationController;
        NSUInteger stackIndex = [navigation.viewControllers indexOfObjectIdenticalTo:owner];
        if (navigation && stackIndex != NSNotFound) {
            if (navigation.topViewController != owner)
                return NO;
            if (stackIndex > 0)
                dedicatedScreen = YES;
        }
        if (owner.presentingViewController &&
            owner.presentingViewController.presentedViewController == owner)
            dedicatedScreen = YES;
        NSString *name = NSStringFromClass(responder.class);
        if ([name containsString:@"Hero"] || [name containsString:@"Preview"] ||
            [name containsString:@"RebornHomeFeature"])
            return NO;
        if ([name isEqualToString:@"PlayerUI.EpisodePlayerClientViewController"] ||
            [name isEqualToString:@"PlayerUI.EpisodePlayerHostViewController"] ||
            [name isEqualToString:@"PlayerUI.LiveTopPlayerViewController"] ||
            [name isEqualToString:@"_TtC8PlayerUI33EpisodePlayerClientViewController"] ||
            [name isEqualToString:@"_TtC8PlayerUI31EpisodePlayerHostViewController"] ||
            [name isEqualToString:@"_TtC8PlayerUI27LiveTopPlayerViewController"])
            programOwner = name;
    }
    if (programOwner)
        TVLog(@"PiP program layer=%p owner=%@ dedicated=%d", layer, programOwner, dedicatedScreen);
    return programOwner != nil && dedicatedScreen;
}

static BOOL TVCanStartForLayer(AVPlayerLayer *layer) {
    AVPlayer *player = layer.player;
    return layer.superlayer && layer.readyForDisplay && player.currentItem &&
           player.rate > 0 && player.timeControlStatus == AVPlayerTimeControlStatusPlaying &&
           TVIsProgramLayer(layer);
}

static NSInteger TVControllerScore(AVPictureInPictureController *controller) {
    AVPlayerLayer *layer = [TVControllerLayers objectForKey:controller];
    AVPlayer *player = layer.player;
    NSInteger score = 0;
    if (layer.superlayer)
        score += 10;
    if (layer.readyForDisplay)
        score += 20;
    if (player.currentItem)
        score += 30;
    if (player.rate > 0)
        score += 40;
    if (@available(iOS 10.0, *))
        if (player.timeControlStatus == AVPlayerTimeControlStatusPlaying)
            score += 50;
    return score;
}

static AVPlayerLayer *TVBestPlayerLayer(AVPlayer *target) {
    NSArray<AVPlayerLayer *> *layers;
    @synchronized(TVLayers) {
        layers = TVLayers.allObjects;
    }
    AVPlayerLayer *best = nil;
    NSInteger bestScore = NSIntegerMin;
    for (AVPlayerLayer *layer in layers) {
        AVPlayer *player = layer.player;
        if ((target && player != target) || !TVCanStartForLayer(layer))
            continue;
        NSInteger score = 0;
        if (layer.superlayer)
            score += 10;
        if (layer.readyForDisplay)
            score += 20;
        if (player.currentItem)
            score += 30;
        if (player.rate > 0)
            score += 40;
        if (player == target && player)
            score += 200;
        if (score > bestScore) {
            best = layer;
            bestScore = score;
        }
        TVLog(@"layer candidate=%p player=%p score=%ld", layer, player, (long)score);
    }
    TVLog(@"best layer=%p score=%ld", best, (long)bestScore);
    return bestScore >= 50 ? best : nil;
}

static void TVRegisterController(AVPictureInPictureController *controller, AVPlayerLayer *layer) {
    if (!controller || !layer)
        return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
          TVRegisterController(controller, layer);
        });
        return;
    }
    if ([TVControllerLayers objectForKey:controller] == layer)
        return;
    [TVControllerLayers setObject:layer forKey:controller];
    TVRetainPiPObject(layer);
    TVRetainPiPObject(controller);
}

static void TVEnsureController(AVPlayerLayer *layer, AVPlayer *player, AVPlayerItem *item) {
    if (!layer || !item || layer.player != player || player.currentItem != item ||
        !TVCanStartForLayer(layer) || item.status != AVPlayerItemStatusReadyToPlay ||
        ![AVPictureInPictureController isPictureInPictureSupported] ||
        [TVRejectedItems objectForKey:layer] == item)
        return;
    for (AVPictureInPictureController *controller in TVControllerLayers.keyEnumerator) {
        if ([TVControllerLayers objectForKey:controller] == layer)
            return;
    }
    AVPictureInPictureController *created;
    @try {
        created = [[AVPictureInPictureController alloc] initWithPlayerLayer:layer];
    } @catch (NSException *exception) {
        // Keep inline playback available and do not retry the same item on this layer.
        [TVRejectedItems setObject:item forKey:layer];
        TVLog(@"PiP initialization exception name=%@ layer=%p player=%p item=%p",
              exception.name, layer, player, item);
        return;
    }
    if (!created)
        return;
    created.delegate = TVObserver;
    TVRegisterController(created, layer);
    TVLog(@"created PiP controller=%p layer=%p possible=%d", created, layer,
          created.pictureInPicturePossible);
}

static void TVScheduleController(AVPlayerLayer *layer, AVPlayer *player, AVPlayerItem *item,
                                 NSUInteger retries) {
    if (!player || !item)
        return;
    __weak AVPlayerLayer *expectedLayer = layer;
    __weak AVPlayer *expectedPlayer = player;
    __weak AVPlayerItem *expectedItem = item;
    BOOL hasExpectedLayer = layer != nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
      AVPlayer *player = expectedPlayer;
      AVPlayerItem *item = expectedItem;
      if (!item || player.currentItem != item ||
          UIApplication.sharedApplication.applicationState == UIApplicationStateBackground)
          return;
      AVPlayerLayer *layer = hasExpectedLayer ? expectedLayer : TVBestPlayerLayer(player);
      if (hasExpectedLayer && layer.player != player)
          return;
      if (TVCanStartForLayer(layer) && item.status == AVPlayerItemStatusReadyToPlay)
          TVEnsureController(layer, player, item);
      else if (retries && item.status != AVPlayerItemStatusFailed)
          TVScheduleController(layer, player, item, retries - 1);
    });
}

static void TVDisarmController(void) {
    AVPictureInPictureController *controller = TVArmedController;
    TVArmedController = nil;
    TVArmedItem = nil;
    ++TVPiPAttempt;
    controller.canStartPictureInPictureAutomaticallyFromInline = NO;
}

static void TVStartBestController(BOOL useBackgroundProxy) {
    if (TVAnyPiPActive()) {
        TVLog(@"PiP start skipped: already active");
        return;
    }
    TVDisarmController();
    AVPictureInPictureController *best = nil;
    NSInteger bestScore = NSIntegerMin;
    AVPlayer *targetPlayer = TVCurrentPlayer();
    for (AVPictureInPictureController *controller in TVControllerLayers.keyEnumerator) {
        AVPlayerLayer *layer = [TVControllerLayers objectForKey:controller];
        controller.canStartPictureInPictureAutomaticallyFromInline = NO;
        if (!TVCanStartForLayer(layer)) {
            continue;
        }
        NSInteger score = TVControllerScore(controller);
        if (targetPlayer && layer.player == targetPlayer)
            score += 200;
        TVLog(@"PiP candidate=%p score=%ld possible=%d ready=%d active=%d", controller, (long)score,
              controller.pictureInPicturePossible, layer.readyForDisplay,
              controller.pictureInPictureActive);
        if (!controller.pictureInPictureActive && score > bestScore) {
            best = controller;
            bestScore = score;
        }
    }
    if (!best || bestScore < 50) {
        AVPlayerLayer *layer = TVBestPlayerLayer(nil);
        AVPlayer *player = layer.player;
        TVEnsureController(layer, player, player.currentItem);
        for (AVPictureInPictureController *controller in TVControllerLayers.keyEnumerator) {
            if (!TVCanStartForLayer([TVControllerLayers objectForKey:controller]))
                continue;
            NSInteger score = TVControllerScore(controller);
            if (!controller.pictureInPictureActive && score > bestScore) {
                best = controller;
                bestScore = score;
            }
        }
    }
    if (!best || bestScore < 50) {
        TVLog(@"PiP start skipped bestScore=%ld", (long)bestScore);
        return;
    }
    TVProtectedLayer = [TVControllerLayers objectForKey:best];
    TVArmedController = best;
    TVArmedItem = TVProtectedLayer.player.currentItem;
    best.canStartPictureInPictureAutomaticallyFromInline = YES;
    TVPiPTransitionInProgress = YES;
    TVStartSilentKeepalive();
    TVScheduleKeepaliveSafetyTimeout();
    TVLog(@"PiP direct start controller=%p score=%ld possible=%d backgroundProxy=%d", best,
          (long)bestScore, best.pictureInPicturePossible, useBackgroundProxy);
    if (best.pictureInPicturePossible) {
        TVLog(@"PiP public start controller=%p", best);
        [best startPictureInPicture];
        return;
    }
    if (useBackgroundProxy) {
        @try {
            id adapter = [best valueForKey:@"platformAdapter"];
            id proxy = [adapter valueForKey:@"pegasusProxy"];
            if ([proxy respondsToSelector:@selector(startPictureInPicture)]) {
                TVLog(@"PiP background proxy start proxy=%p adapter=%p", proxy, adapter);
                ((void (*)(id, SEL))objc_msgSend)(proxy, @selector(startPictureInPicture));
                return;
            }
            TVLog(@"PiP background proxy unavailable; falling back to controller");
        } @catch (NSException *exception) {
            TVLog(@"PiP background proxy exception=%@", exception);
        }
    }
    [best startPictureInPicture];
}

static void TVInstallCommands(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      MPRemoteCommandCenter *c = MPRemoteCommandCenter.sharedCommandCenter;
      NSArray *managed = @[
          c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.skipForwardCommand,
          c.skipBackwardCommand, c.nextTrackCommand, c.previousTrackCommand,
          c.changePlaybackPositionCommand
      ];
      TVInstallingCommands = YES;
      for (MPRemoteCommand *command in managed) {
          [TVCommands addObject:command];
          [command removeTarget:nil];
          command.enabled = YES;
      }
      [c.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        return TVWithPlayer(^(AVPlayer *p) {
          [p play];
        });
      }];
      [c.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        return TVWithPlayer(^(AVPlayer *p) {
          [p pause];
        });
      }];
      [c.togglePlayPauseCommand
          addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
            return TVWithPlayer(^(AVPlayer *p) {
              p.rate == 0 ? [p play] : [p pause];
            });
          }];
      c.skipForwardCommand.preferredIntervals = @[ @15 ];
      [c.skipForwardCommand
          addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            MPSkipIntervalCommandEvent *e = (MPSkipIntervalCommandEvent *)event;
            return TVWithPlayer(^(AVPlayer *p) {
              TVSeek(p, e.interval > 0 ? e.interval : 15);
            });
          }];
      c.skipBackwardCommand.preferredIntervals = @[ @15 ];
      [c.skipBackwardCommand
          addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            MPSkipIntervalCommandEvent *e = (MPSkipIntervalCommandEvent *)event;
            return TVWithPlayer(^(AVPlayer *p) {
              TVSeek(p, -(e.interval > 0 ? e.interval : 15));
            });
          }];
      [c.nextTrackCommand
          addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
            return TVWithPlayer(^(AVPlayer *p) {
              TVSeek(p, 15);
            });
          }];
      [c.previousTrackCommand
          addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
            return TVWithPlayer(^(AVPlayer *p) {
              TVSeek(p, -15);
            });
          }];
      [c.changePlaybackPositionCommand
          addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            MPChangePlaybackPositionCommandEvent *e = (MPChangePlaybackPositionCommandEvent *)event;
            return TVWithPlayer(^(AVPlayer *p) {
              [p seekToTime:CMTimeMakeWithSeconds(MAX(0, e.positionTime), NSEC_PER_SEC)
                  toleranceBefore:kCMTimeZero
                   toleranceAfter:kCMTimeZero];
            });
          }];
      TVInstallingCommands = NO;
      TVLog(@"remote commands installed");
    });
}

static void TVPlayerPlay(AVPlayer *self, SEL _cmd) {
    TVRememberPlayer(self);
    TVInstallCommands();
    OrigPlayerPlay(self, _cmd);
    TVUpdateNowPlaying(self);
    TVScheduleController(nil, self, self.currentItem, 15);
}
static void TVPlayerPause(AVPlayer *self, SEL _cmd) {
    TVRememberPlayer(self);
    OrigPlayerPause(self, _cmd);
    TVUpdateNowPlaying(self);
}
static void TVPlayerReplace(AVPlayer *self, SEL _cmd, AVPlayerItem *item) {
    TVRememberPlayer(self);
    OrigPlayerReplace(self, _cmd, item);
    TVScheduleController(nil, self, item, 15);
}
static void TVLayerSetPlayer(AVPlayerLayer *self, SEL _cmd, AVPlayer *p) {
    if (!p && self == TVProtectedLayer && TVPiPTransitionInProgress) {
        TVLog(@"preserved PiP player on layer=%p during background transition", self);
        return;
    }
    TVRememberPlayer(p);
    TVInstallCommands();
    OrigLayerSetPlayer(self, _cmd, p);
    TVRememberLayer(self);
    TVScheduleController(self, p, p.currentItem, 15);
}
__attribute__((ns_returns_retained))
static id TVLayerInitPlayer(id self __attribute__((ns_consumed)), SEL _cmd, AVPlayer *player) {
    id layer = OrigLayerInitPlayer(self, _cmd, player);
    TVRememberLayer(layer);
    return layer;
}
__attribute__((ns_returns_retained))
static id TVPiPInitLayer(id self __attribute__((ns_consumed)), SEL _cmd, AVPlayerLayer *layer) {
    id obj = OrigPiPInitLayer(self, _cmd, layer);
    TVLog(@"PiP init playerLayer=%p controller=%p", layer, obj);
    TVRememberLayer(layer);
    TVRegisterController(obj, layer);
    return obj;
}
__attribute__((ns_returns_retained))
static id TVPiPInitSource(id self __attribute__((ns_consumed)), SEL _cmd,
                          AVPictureInPictureControllerContentSource *source) {
    id obj = OrigPiPInitSource(self, _cmd, source);
    TVLog(@"PiP init contentSource=%p controller=%p", source, obj);
    TVRememberLayer(source.playerLayer);
    TVRegisterController(obj, source.playerLayer);
    return obj;
}
static void TVPiPStart(id self, SEL _cmd) {
    AVPlayerLayer *layer = [TVControllerLayers objectForKey:self];
    if (layer && (self != TVArmedController || layer.player.currentItem != TVArmedItem ||
                  !TVCanStartForLayer(layer))) {
        TVLog(@"PiP start blocked controller=%p layer=%p", self, layer);
        return;
    }
    TVLog(@"PiP start requested controller=%p", self);
    TVStartSilentKeepalive();
    TVScheduleKeepaliveSafetyTimeout();
    TVRetainPiPObject(self);
    OrigPiPStart(self, _cmd);
}
static void TVPiPStop(id self, SEL _cmd) {
    OrigPiPStop(self, _cmd);
    TVStopSilentKeepalive();
}
static void TVPiPSetActive(id self, SEL _cmd, BOOL active) {
    OrigPiPSetActive(self, _cmd, active);
    if (active)
        TVStartSilentKeepalive();
    else if (!TVAnyPiPActive())
        TVStopSilentKeepalive();
}
static void TVCommandSetEnabled(MPRemoteCommand *self, SEL _cmd, BOOL enabled) {
    OrigCommandSetEnabled(self, _cmd, [TVCommands containsObject:self] ? YES : enabled);
}
static void TVCommandAddTargetAction(MPRemoteCommand *self, SEL _cmd, id target, SEL action) {
    if (![TVCommands containsObject:self] || TVInstallingCommands)
        OrigCommandAddTargetAction(self, _cmd, target, action);
}
static id TVCommandAddHandler(MPRemoteCommand *self, SEL _cmd, id handler) {
    if ([TVCommands containsObject:self] && !TVInstallingCommands)
        return nil;
    return OrigCommandAddHandler(self, _cmd, handler);
}
static void TVCommandRemoveTarget(MPRemoteCommand *self, SEL _cmd, id target) {
    if (![TVCommands containsObject:self] || TVInstallingCommands)
        OrigCommandRemoveTarget(self, _cmd, target);
}
static void TVCommandRemoveTargetAction(MPRemoteCommand *self, SEL _cmd, id target, SEL action) {
    if (![TVCommands containsObject:self] || TVInstallingCommands)
        OrigCommandRemoveTargetAction(self, _cmd, target, action);
}

static void TVHook(Class cls, SEL sel, IMP replacement, void **original) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method)
        return;
    *original = (void *)method_getImplementation(method);
    method_setImplementation(method, replacement);
}

__attribute__((constructor)) static void TVerPiPInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
          NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
          TVLog(@"initializing delayed hooks bundle=%@", bundleID);
          TVPlayers = [NSHashTable weakObjectsHashTable];
          TVObserver = [TVPiPObserver new];
          TVLayers = [NSHashTable weakObjectsHashTable];
          TVCommands = [NSHashTable weakObjectsHashTable];
          TVPiPObjects = [NSMutableArray array];
          TVControllerLayers = [NSMapTable weakToWeakObjectsMapTable];
          TVRejectedItems = [NSMapTable weakToWeakObjectsMapTable];
          TVHook(AVPlayer.class, @selector(play), (IMP)TVPlayerPlay, (void **)&OrigPlayerPlay);
          TVHook(AVPlayer.class, @selector(pause), (IMP)TVPlayerPause, (void **)&OrigPlayerPause);
          TVHook(AVPlayer.class, @selector(replaceCurrentItemWithPlayerItem:), (IMP)TVPlayerReplace,
                 (void **)&OrigPlayerReplace);
          TVHook(AVPlayerLayer.class, @selector(setPlayer:), (IMP)TVLayerSetPlayer,
                 (void **)&OrigLayerSetPlayer);
          TVHook(AVPlayerLayer.class, @selector(initWithPlayer:), (IMP)TVLayerInitPlayer,
                 (void **)&OrigLayerInitPlayer);
          TVHook(AVPictureInPictureController.class, @selector(initWithPlayerLayer:),
                 (IMP)TVPiPInitLayer, (void **)&OrigPiPInitLayer);
          TVHook(AVPictureInPictureController.class, @selector(initWithContentSource:),
                 (IMP)TVPiPInitSource, (void **)&OrigPiPInitSource);
          TVHook(AVPictureInPictureController.class, @selector(startPictureInPicture),
                 (IMP)TVPiPStart, (void **)&OrigPiPStart);
          TVHook(AVPictureInPictureController.class, @selector(stopPictureInPicture),
                 (IMP)TVPiPStop, (void **)&OrigPiPStop);
          TVHook(AVPictureInPictureController.class,
                 NSSelectorFromString(@"setPictureInPictureActive:"), (IMP)TVPiPSetActive,
                 (void **)&OrigPiPSetActive);
          TVHook(MPRemoteCommand.class, @selector(setEnabled:), (IMP)TVCommandSetEnabled,
                 (void **)&OrigCommandSetEnabled);
          TVHook(MPRemoteCommand.class, @selector(addTarget:action:), (IMP)TVCommandAddTargetAction,
                 (void **)&OrigCommandAddTargetAction);
          TVHook(MPRemoteCommand.class, @selector(addTargetWithHandler:), (IMP)TVCommandAddHandler,
                 (void **)&OrigCommandAddHandler);
          TVHook(MPRemoteCommand.class, @selector(removeTarget:), (IMP)TVCommandRemoveTarget,
                 (void **)&OrigCommandRemoveTarget);
          TVHook(MPRemoteCommand.class, @selector(removeTarget:action:),
                 (IMP)TVCommandRemoveTargetAction, (void **)&OrigCommandRemoveTargetAction);
          TVInstallCommands();
          [NSNotificationCenter.defaultCenter
              addObserverForName:UIApplicationWillResignActiveNotification
                          object:nil
                           queue:NSOperationQueue.mainQueue
                      usingBlock:^(NSNotification *note) {
                        TVLog(@"application will resign active");
                        TVStartBestController(YES);
                      }];
          [NSNotificationCenter.defaultCenter
              addObserverForName:UIApplicationDidBecomeActiveNotification
                          object:nil
                           queue:NSOperationQueue.mainQueue
                      usingBlock:^(NSNotification *note) {
                        TVLog(@"application became active: restoring inline playback");
                        TVDisarmController();
                        for (AVPictureInPictureController *controller in
                             TVControllerLayers.keyEnumerator) {
                            if (controller.pictureInPictureActive)
                                [controller stopPictureInPicture];
                        }
                        TVPiPTransitionInProgress = NO;
                        TVProtectedLayer = nil;
                        TVStopSilentKeepalive();
                      }];
          TVLog(@"hook initialization complete");
        });
    }
}

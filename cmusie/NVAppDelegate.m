#import "NVAppDelegate.h"
#import <dlfcn.h>
#import <MediaPlayer/MediaPlayer.h>

#define MEDIAKEY_DOWN(event) (((([event data1] & 0x0000FFFF) & 0xFF00) >> 8) == 0xA)
#define MEDIAKEY_CODE(event) (([event data1] & 0xFFFF0000) >> 16)

typedef NS_ENUM(NSUInteger, NVPlaybackTarget) {
    NVPlaybackTargetCmus,
    NVPlaybackTargetSystem,
};

typedef NS_ENUM(NSUInteger, NVSystemCommand) {
    NVSystemCommandPlay = 0,
    NVSystemCommandPause = 1,
    NVSystemCommandTogglePlayPause = 2,
    NVSystemCommandStop = 3,
    NVSystemCommandNextTrack = 4,
    NVSystemCommandPreviousTrack = 5,
};

typedef void (*MRNowPlayingInfoFunction)(dispatch_queue_t queue, void (^block)(CFDictionaryRef information));
typedef Boolean (*MRSendCommandFunction)(uint32_t command, CFDictionaryRef userInfo);

@interface NVAppDelegate () {
    CFMachPortRef _mk_tap_port;
    void *_mediaRemoteHandle;
}

@property (assign, nonatomic) NVPlaybackTarget lastActiveTarget;
@property (strong, nonatomic) NSTimer *permissionTimer;
@property (strong, nonatomic) NSTimer *playbackTimer;
@property (strong, nonatomic) NSString *mediaRemotePlaybackRateKey;
@property (assign, nonatomic) BOOL cmusRemoteActive;
@property (strong, nonatomic) NSDictionary *publishedNowPlayingInfo;
- (void)mediaKeysTopPriority;
- (void)mediaKeysRestart;
- (void)mediaKeysStart;
- (void)mediaKeysStop;
- (bool)mediaKeysHandle:(NSEvent*)sender;
- (void)requestAccessibilityPermissionIfNeeded;
- (void)startAccessibilityPollingIfNeeded;
- (void)handleAccessibilityTimer:(NSTimer*)timer;
- (NSDictionary*)cmusStatus;
- (BOOL)isSystemPlaybackActive;
- (NSDictionary*)systemNowPlayingInfo;
- (NVPlaybackTarget)playbackTargetForKeyCode:(int)keyCode;
- (BOOL)dispatchCommandForKeyCode:(int)keyCode target:(NVPlaybackTarget)target;
- (BOOL)dispatchSystemCommandForKeyCode:(int)keyCode;
- (NSString*)mediaRemoteStringConstantNamed:(const char*)symbolName;
- (void)remoteCommandsStart;
- (void)remoteCommandsStop;
- (void)handlePlaybackTimer:(NSTimer*)timer;
- (void)updateCmusRemoteState;
- (MPRemoteCommandHandlerStatus)handleRemoteCommand:(MPRemoteCommandEvent*)event;

@end

@implementation NVAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    self.lastActiveTarget = NVPlaybackTargetCmus;
    _mediaRemoteHandle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    self.mediaRemotePlaybackRateKey = [self mediaRemoteStringConstantNamed:"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
    [self remoteCommandsStart];

    [self requestAccessibilityPermissionIfNeeded];
    if (AXIsProcessTrusted()) {
        [self mediaKeysStart];
    } else {
        [self startAccessibilityPollingIfNeeded];
    }
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    [self.permissionTimer invalidate];
    self.permissionTimer = nil;
    [self.playbackTimer invalidate];
    self.playbackTimer = nil;
    [self remoteCommandsStop];
    [self mediaKeysStop];
    if (_mediaRemoteHandle) {
        dlclose(_mediaRemoteHandle);
        _mediaRemoteHandle = nil;
    }
}

- (void)remoteCommandsStart {
    MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
    [commandCenter.playCommand addTarget:self action:@selector(handleRemoteCommand:)];
    [commandCenter.pauseCommand addTarget:self action:@selector(handleRemoteCommand:)];
    [commandCenter.togglePlayPauseCommand addTarget:self action:@selector(handleRemoteCommand:)];

    self.playbackTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                          target:self
                                                        selector:@selector(handlePlaybackTimer:)
                                                        userInfo:nil
                                                         repeats:YES];
    [self updateCmusRemoteState];
}

- (void)remoteCommandsStop {
    MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
    [commandCenter.playCommand removeTarget:self];
    [commandCenter.pauseCommand removeTarget:self];
    [commandCenter.togglePlayPauseCommand removeTarget:self];

    MPNowPlayingInfoCenter *infoCenter = [MPNowPlayingInfoCenter defaultCenter];
    infoCenter.playbackState = MPNowPlayingPlaybackStateStopped;
    infoCenter.nowPlayingInfo = nil;
}

- (void)handlePlaybackTimer:(NSTimer*)timer {
    [self updateCmusRemoteState];
}

- (void)updateCmusRemoteState {
    NSDictionary *status = [self cmusStatus];
    BOOL running = [status[@"running"] boolValue];
    BOOL playing = [status[@"playing"] boolValue];

    if (playing) {
        self.cmusRemoteActive = YES;
    } else if (!self.cmusRemoteActive) {
        return;
    }

    MPNowPlayingInfoCenter *infoCenter = [MPNowPlayingInfoCenter defaultCenter];
    if (!running) {
        infoCenter.playbackState = MPNowPlayingPlaybackStateStopped;
        infoCenter.nowPlayingInfo = nil;
        self.publishedNowPlayingInfo = nil;
        self.cmusRemoteActive = NO;
        return;
    }

    NSDictionary *tags = status[@"tag"];
    NSMutableDictionary *nowPlayingInfo = [NSMutableDictionary dictionary];
    nowPlayingInfo[MPMediaItemPropertyTitle] = tags[@"title"] ?: @"cmus";
    if (tags[@"artist"]) {
        nowPlayingInfo[MPMediaItemPropertyArtist] = tags[@"artist"];
    }

    if (![self.publishedNowPlayingInfo isEqualToDictionary:nowPlayingInfo]) {
        infoCenter.nowPlayingInfo = nowPlayingInfo;
        self.publishedNowPlayingInfo = nowPlayingInfo;
    }

    MPNowPlayingPlaybackState playbackState = playing ? MPNowPlayingPlaybackStatePlaying : MPNowPlayingPlaybackStatePaused;
    if (infoCenter.playbackState != playbackState) {
        infoCenter.playbackState = playbackState;
    }
}

- (MPRemoteCommandHandlerStatus)handleRemoteCommand:(MPRemoteCommandEvent*)event {
    NSDictionary *status = [self cmusStatus];
    if (![status[@"running"] boolValue]) {
        return MPRemoteCommandHandlerStatusNoSuchContent;
    }

    BOOL playing = [status[@"playing"] boolValue];
    MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
    NSTask *task = nil;

    if (event.command == commandCenter.playCommand) {
        if (!playing) {
            task = [self runCommand:@[@"cmus-remote", @"--play"]];
        }
    } else if (event.command == commandCenter.pauseCommand) {
        if (playing) {
            task = [self runCommand:@[@"cmus-remote", @"--pause"]];
        }
    } else {
        task = [self runCommand:@[@"cmus-remote", @"--pause"]];
    }

    if (task && task.terminationStatus != 0) {
        return MPRemoteCommandHandlerStatusCommandFailed;
    }

    self.cmusRemoteActive = YES;
    [self updateCmusRemoteState];
    return MPRemoteCommandHandlerStatusSuccess;
}

- (void)requestAccessibilityPermissionIfNeeded {
    if (AXIsProcessTrusted()) {
        return;
    }

    NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((CFDictionaryRef)options);
}

- (void)startAccessibilityPollingIfNeeded {
    if (self.permissionTimer || AXIsProcessTrusted()) {
        return;
    }

    self.permissionTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                            target:self
                                                          selector:@selector(handleAccessibilityTimer:)
                                                          userInfo:nil
                                                           repeats:YES];
}

- (void)handleAccessibilityTimer:(NSTimer*)timer {
    if (!AXIsProcessTrusted()) {
        return;
    }

    [timer invalidate];
    self.permissionTimer = nil;
    [self mediaKeysStart];
}

- (NSDictionary*)cmusStatus {
    NSMutableDictionary *tag = [[NSMutableDictionary alloc] init];
    BOOL running = NO, playing = NO;
    
    NSTask *task = [self runCommand:@[@"cmus-remote", @"-Q"]];
    if (task.terminationStatus == 0) {
        running = YES;
        NSPipe *stdout = (NSPipe*)task.standardOutput;
        NSData *outputData = [[stdout fileHandleForReading] readDataToEndOfFile];
        NSString *outputString = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];

        NSArray *lines = [outputString componentsSeparatedByString:@"\n"];
        for (NSString *line in lines) {
            NSArray *chunks = [line componentsSeparatedByString:@" "];
            if ([chunks[0] isEqualToString:@"status"]) {
                playing = [chunks[1] isEqualToString:@"playing"];
            } else if ([chunks[0] isEqualToString:@"tag"]) {
                NSArray *valueChunks = [chunks subarrayWithRange:NSMakeRange(2, chunks.count - 2)];
                NSString *value = [valueChunks componentsJoinedByString:@" "];
                [tag setValue:value forKey:chunks[1]];
            }
        }
    }
    return @{
        @"tag": tag,
        @"running": [NSNumber numberWithBool:running],
        @"playing": [NSNumber numberWithBool:playing]
    };
}

- (BOOL)isSystemPlaybackActive {
    NSDictionary *info = [self systemNowPlayingInfo];
    if (!info || !self.mediaRemotePlaybackRateKey) {
        return NO;
    }

    NSNumber *rate = info[self.mediaRemotePlaybackRateKey];
    return [rate doubleValue] > 0.0;
}

- (void)applicationWillBecomeActive:(NSNotification *)notification {
    [self mediaKeysTopPriority];
}

- (void)mediaKeysTopPriority {
    if (self->_mk_tap_port == nil)
        return;
    
    CGEventTapInformation *taps = calloc(1, sizeof(CGEventTapInformation));
    uint32_t numTaps = 0;
    CGError err = CGGetEventTapList(1, taps, &numTaps);
    
    if (err == kCGErrorSuccess && numTaps > 0) {
        pid_t processID = [NSProcessInfo processInfo].processIdentifier;
        if (taps[0].tappingProcess != processID) {
            [self mediaKeysStop];
            [self mediaKeysStart];
        }
    }
    free(taps);
}

- (void)mediaKeysStart {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_mk_tap_port = CGEventTapCreate(
            kCGSessionEventTap,
            kCGHeadInsertEventTap,
            kCGEventTapOptionDefault,
            CGEventMaskBit(NX_SYSDEFINED),
            tap_event_callback,
            (__bridge void*)self);
        
        if (self->_mk_tap_port) {
            NSMachPort *port = (__bridge NSMachPort *)self->_mk_tap_port;
            [[NSRunLoop mainRunLoop] addPort:port forMode:NSRunLoopCommonModes];
        }
    });
}

- (void)mediaKeysRestart {
    if (self->_mk_tap_port) CGEventTapEnable(self->_mk_tap_port, true);
}

- (void)mediaKeysStop {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMachPort *port = (__bridge NSMachPort*)self->_mk_tap_port;
        if (port) {
            CGEventTapEnable(self->_mk_tap_port, false);
            [[NSRunLoop mainRunLoop] removePort:port forMode:NSRunLoopCommonModes];
            CFRelease(self->_mk_tap_port);
            self->_mk_tap_port = nil;
        }
    });
}

- (bool)mediaKeysHandle:(NSEvent*)event {
    int keyCode = MEDIAKEY_CODE(event);
    switch (keyCode) {
        case NX_KEYTYPE_PLAY:
        case NX_KEYTYPE_REWIND:
        case NX_KEYTYPE_FAST:
            return [self dispatchCommandForKeyCode:keyCode target:[self playbackTargetForKeyCode:keyCode]];
    }
    return false;
}

- (NVPlaybackTarget)playbackTargetForKeyCode:(int)keyCode {
    NSDictionary *cmusStatus = [self cmusStatus];
    if ([cmusStatus[@"playing"] boolValue]) {
        self.lastActiveTarget = NVPlaybackTargetCmus;
        return NVPlaybackTargetCmus;
    }

    if ([self isSystemPlaybackActive]) {
        self.lastActiveTarget = NVPlaybackTargetSystem;
        return NVPlaybackTargetSystem;
    }

    return self.lastActiveTarget;
}

- (BOOL)dispatchCommandForKeyCode:(int)keyCode target:(NVPlaybackTarget)target {
    switch (target) {
        case NVPlaybackTargetCmus:
            self.lastActiveTarget = NVPlaybackTargetCmus;
            switch (keyCode) {
                case NX_KEYTYPE_PLAY:
                    return [self runCommand:@[@"cmus-remote", @"--pause"]].terminationStatus == 0;
                case NX_KEYTYPE_REWIND:
                    return [self runCommand:@[@"cmus-remote", @"--prev"]].terminationStatus == 0;
                case NX_KEYTYPE_FAST:
                    return [self runCommand:@[@"cmus-remote", @"--next"]].terminationStatus == 0;
            }
            return NO;
        case NVPlaybackTargetSystem:
            self.lastActiveTarget = NVPlaybackTargetSystem;
            return [self dispatchSystemCommandForKeyCode:keyCode];
    }
}

- (BOOL)dispatchSystemCommandForKeyCode:(int)keyCode {
    MRSendCommandFunction sendCommand = (MRSendCommandFunction)dlsym(_mediaRemoteHandle, "MRMediaRemoteSendCommand");
    if (!sendCommand) {
        return NO;
    }

    uint32_t command = NVSystemCommandTogglePlayPause;
    switch (keyCode) {
        case NX_KEYTYPE_PLAY:
            command = NVSystemCommandTogglePlayPause;
            break;
        case NX_KEYTYPE_REWIND:
            command = NVSystemCommandPreviousTrack;
            break;
        case NX_KEYTYPE_FAST:
            command = NVSystemCommandNextTrack;
            break;
        default:
            return NO;
    }

    return sendCommand(command, NULL);
}

- (NSDictionary*)systemNowPlayingInfo {
    if (!_mediaRemoteHandle) {
        return nil;
    }

    MRNowPlayingInfoFunction getNowPlayingInfo = (MRNowPlayingInfoFunction)dlsym(_mediaRemoteHandle, "MRMediaRemoteGetNowPlayingInfo");
    if (!getNowPlayingInfo) {
        return nil;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSDictionary *info = nil;

    getNowPlayingInfo(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(CFDictionaryRef information) {
        if (information) {
            info = [(__bridge NSDictionary*)information copy];
        }
        dispatch_semaphore_signal(semaphore);
    });

    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC));
    return info;
}

- (NSString*)mediaRemoteStringConstantNamed:(const char*)symbolName {
    if (!_mediaRemoteHandle) {
        return nil;
    }

    void *symbol = dlsym(_mediaRemoteHandle, symbolName);
    if (!symbol) {
        return nil;
    }

    return (__bridge NSString *)(*(void **)symbol);
}

- (NSTask*)runCommand:(NSArray*)command {
    NSTask *task = [[NSTask alloc] init];
    
    NSMutableDictionary *env = [[NSMutableDictionary alloc] initWithDictionary:[[NSProcessInfo processInfo] environment]];
    NSString *path = [NSString stringWithFormat:@"%@:/usr/local/bin", [env objectForKey:@"PATH"]];
    [env setObject:path forKey:@"PATH"];
    [task setEnvironment:env];
    [task setExecutableURL:[NSURL fileURLWithPath:@"/usr/bin/env"]];
    [task setArguments:command];
    [task setStandardOutput:[NSPipe pipe]];
    [task launchAndReturnError:nil];
    [task waitUntilExit];
    return task;
}

static CGEventRef tap_event_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *ctx) {
    NVAppDelegate *delegate = (__bridge NVAppDelegate*)ctx;
    
    if (type == kCGEventTapDisabledByTimeout) {
        // The Mach Port receiving the taps became unresponsive for some
        // reason, restart listening on it.
        [delegate mediaKeysRestart];
        return event;
    }
    
    if (type == kCGEventTapDisabledByUserInput)
        return event;
    
    NSEvent *nse = [NSEvent eventWithCGEvent:event];
    
    if ([nse type] != NSEventTypeSystemDefined || [nse subtype] != 8)
        // This is not a media key
        return event;
    
    if (MEDIAKEY_DOWN(nse) && [delegate mediaKeysHandle:nse])
        return nil;
    return event;
}

@end

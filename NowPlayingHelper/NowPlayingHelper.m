//
// NowPlayingHelper
//
// A tiny library that reports the system-wide "Now Playing" session (any
// player: Music, Spotify, browsers, VLC, podcasts …) and forwards transport
// commands to it.
//
// Since macOS 15.4 the private MediaRemote framework only answers processes
// that Apple considers its own. AlcoveInspired therefore does not load this
// library itself: it starts `/usr/bin/perl` (a system binary), which loads
// the library with DynaLoader and calls `nph_run`. The library then talks to
// the parent app over a line protocol:
//
//   stdout  one JSON object per line: {"type":"ready"},
//           {"type":"error","message":…}, {"type":"nowPlaying",…}
//   stdin   one command per line: play | pause | toggle | next | previous |
//           seek <seconds> | refresh | quit
//
// The helper exits when the app closes its stdin (EOF) or its stdout.
//

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef void (*NPHGetNowPlayingInfoFunction)(dispatch_queue_t queue, void (^handler)(CFDictionaryRef info));
typedef void (*NPHGetIsPlayingFunction)(dispatch_queue_t queue, void (^handler)(Boolean playing));
typedef void (*NPHGetApplicationPIDFunction)(dispatch_queue_t queue, void (^handler)(int pid));
typedef void (*NPHRegisterFunction)(dispatch_queue_t queue);
typedef Boolean (*NPHSendCommandFunction)(int command, CFDictionaryRef options);
typedef void (*NPHSetElapsedTimeFunction)(double elapsedTime);

// MRMediaRemoteCommand values.
enum {
    NPHCommandPlay = 0,
    NPHCommandPause = 1,
    NPHCommandTogglePlayPause = 2,
    NPHCommandNextTrack = 4,
    NPHCommandPreviousTrack = 5,
};

static NPHGetNowPlayingInfoFunction NPHGetInfo;
static NPHGetIsPlayingFunction NPHGetIsPlaying;
static NPHGetApplicationPIDFunction NPHGetPID;
static NPHRegisterFunction NPHRegister;
static NPHSendCommandFunction NPHSendCommand;
static NPHSetElapsedTimeFunction NPHSetElapsedTime;

static NSData *NPHLastArtwork;
static NSUInteger NPHRefreshGeneration;

static void NPHEmit(NSDictionary *payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (json == nil) {
        return;
    }
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static id NPHJSONValue(id value) {
    if (value == nil) {
        return nil;
    }
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) {
        return value;
    }
    if ([value isKindOfClass:NSDate.class]) {
        return @([(NSDate *)value timeIntervalSince1970]);
    }
    return [value description];
}

static void NPHRefreshNow(void) {
    dispatch_queue_t queue = dispatch_get_main_queue();
    NPHGetPID(queue, ^(int pid) {
        NPHGetIsPlaying(queue, ^(Boolean playing) {
            NPHGetInfo(queue, ^(CFDictionaryRef cfInfo) {
                @autoreleasepool {
                    NSDictionary *info = (__bridge NSDictionary *)cfInfo;
                    NSMutableDictionary *output = [NSMutableDictionary dictionary];
                    output[@"type"] = @"nowPlaying";
                    output[@"playing"] = @(playing ? YES : NO);
                    if (pid > 0) {
                        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
                        if (app.bundleIdentifier != nil) {
                            output[@"bundleIdentifier"] = app.bundleIdentifier;
                        }
                        if (app.localizedName != nil) {
                            output[@"appName"] = app.localizedName;
                        }
                    }
                    if (info.count == 0) {
                        NPHLastArtwork = nil;
                        output[@"empty"] = @YES;
                        NPHEmit(output);
                        return;
                    }

                    NSDictionary<NSString *, NSString *> *keys = @{
                        @"title": @"kMRMediaRemoteNowPlayingInfoTitle",
                        @"artist": @"kMRMediaRemoteNowPlayingInfoArtist",
                        @"album": @"kMRMediaRemoteNowPlayingInfoAlbum",
                        @"duration": @"kMRMediaRemoteNowPlayingInfoDuration",
                        @"elapsed": @"kMRMediaRemoteNowPlayingInfoElapsedTime",
                        @"timestamp": @"kMRMediaRemoteNowPlayingInfoTimestamp",
                        @"rate": @"kMRMediaRemoteNowPlayingInfoPlaybackRate",
                        @"id": @"kMRMediaRemoteNowPlayingInfoContentItemIdentifier",
                    };
                    [keys enumerateKeysAndObjectsUsingBlock:^(NSString *outputKey, NSString *infoKey, BOOL *stop) {
                        id value = NPHJSONValue(info[infoKey]);
                        if (value != nil) {
                            output[outputKey] = value;
                        }
                    }];
                    if (output[@"id"] == nil) {
                        id unique = NPHJSONValue(info[@"kMRMediaRemoteNowPlayingInfoUniqueIdentifier"]);
                        if (unique != nil) {
                            output[@"id"] = [NSString stringWithFormat:@"%@", unique];
                        }
                    }

                    // Artwork is sent only when it changes (it can be large).
                    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                    if ([artwork isKindOfClass:NSData.class] && artwork.length > 0) {
                        output[@"hasArtwork"] = @YES;
                        if (![artwork isEqualToData:NPHLastArtwork]) {
                            NPHLastArtwork = artwork;
                            output[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
                        }
                    } else {
                        NPHLastArtwork = nil;
                        output[@"hasArtwork"] = @NO;
                    }
                    NPHEmit(output);
                }
            });
        });
    });
}

/// MediaRemote posts bursts of notifications; refresh once per burst.
static void NPHScheduleRefresh(void) {
    NSUInteger generation = ++NPHRefreshGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation == NPHRefreshGeneration) {
            NPHRefreshNow();
        }
    });
}

static void NPHHandleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *name = parts.firstObject ?: @"";
    if ([name isEqualToString:@"play"]) {
        NPHSendCommand(NPHCommandPlay, NULL);
    } else if ([name isEqualToString:@"pause"]) {
        NPHSendCommand(NPHCommandPause, NULL);
    } else if ([name isEqualToString:@"toggle"]) {
        NPHSendCommand(NPHCommandTogglePlayPause, NULL);
    } else if ([name isEqualToString:@"next"]) {
        NPHSendCommand(NPHCommandNextTrack, NULL);
    } else if ([name isEqualToString:@"previous"]) {
        NPHSendCommand(NPHCommandPreviousTrack, NULL);
    } else if ([name isEqualToString:@"seek"] && parts.count > 1 && NPHSetElapsedTime != NULL) {
        NPHSetElapsedTime(parts[1].doubleValue);
    } else if ([name isEqualToString:@"quit"]) {
        exit(0);
    }
    NPHScheduleRefresh();
}

static void NPHReadCommands(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char buffer[512];
        while (fgets(buffer, sizeof buffer, stdin) != NULL) {
            NSString *line = [[NSString stringWithUTF8String:buffer]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (line.length == 0) {
                continue;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                NPHHandleCommand(line);
            });
        }
        // The app closed our stdin: it quit or restarted the helper.
        exit(0);
    });
}

/// Entry point, called by perl as an XSUB (the two arguments are perl's
/// interpreter and CV pointers and are ignored). Never returns.
__attribute__((visibility("default")))
void nph_run(void *interpreter, void *cv) {
    (void)interpreter;
    (void)cv;
    @autoreleasepool {
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (handle == NULL) {
            NPHEmit(@{@"type": @"error", @"message": @"MediaRemote.framework is not available"});
            exit(2);
        }
        NPHGetInfo = (NPHGetNowPlayingInfoFunction)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        NPHGetIsPlaying = (NPHGetIsPlayingFunction)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        NPHGetPID = (NPHGetApplicationPIDFunction)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
        NPHRegister = (NPHRegisterFunction)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        NPHSendCommand = (NPHSendCommandFunction)dlsym(handle, "MRMediaRemoteSendCommand");
        NPHSetElapsedTime = (NPHSetElapsedTimeFunction)dlsym(handle, "MRMediaRemoteSetElapsedTime");
        if (NPHGetInfo == NULL || NPHGetIsPlaying == NULL || NPHGetPID == NULL || NPHRegister == NULL || NPHSendCommand == NULL) {
            NPHEmit(@{@"type": @"error", @"message": @"MediaRemote functions are missing"});
            exit(3);
        }

        NPHRegister(dispatch_get_main_queue());
        NSArray<NSString *> *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
        ];
        for (NSString *name in names) {
            [NSNotificationCenter.defaultCenter addObserverForName:name
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *note) {
                NPHScheduleRefresh();
            }];
        }

        NPHEmit(@{@"type": @"ready"});
        NPHRefreshNow();
        NPHReadCommands();
    }
    while (true) {
        @autoreleasepool {
            [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture];
        }
    }
}

#import "OLTgPeer.h"

#import <AVFoundation/AVFoundation.h>

#include <array>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "Instance.h"
#include "StaticThreads.h"
#include "VideoCaptureInterface.h"
#include "v2/InstanceV2Impl.h"
#include "platform/darwin/iOS/tgcalls_audio_device_module_ios.h"

#include "api/video/video_frame.h"
#include "api/video/video_sink_interface.h"

namespace {

class CountingSink : public rtc::VideoSinkInterface<webrtc::VideoFrame> {
public:
    void OnFrame(const webrtc::VideoFrame &frame) override {
        frames.fetch_add(1);
        width.store(frame.width());
        height.store(frame.height());
    }
    std::atomic<int> frames{0}, width{0}, height{0};
};

const char *StateName(tgcalls::State s) {
    switch (s) {
        case tgcalls::State::WaitInit: return "WaitInit";
        case tgcalls::State::WaitInitAck: return "WaitInitAck";
        case tgcalls::State::Established: return "Established";
        case tgcalls::State::Failed: return "Failed";
        case tgcalls::State::Reconnecting: return "Reconnecting";
    }
    return "Unknown";
}

struct Shared {
    std::mutex mu;
    std::string state = "WaitInit";
    double establishedAt = -1;
    int remoteMediaStates = 0;
    int remoteAudioActive = 0;
    int remoteVideoState = -1;
    float maxAudioLevel = 0;
    int blobsOut = 0;
};

} // namespace

@implementation OLTgPeer {
    std::shared_ptr<tgcalls::Instance> _instance;
    std::shared_ptr<tgcalls::VideoCaptureInterface> _capture;
    std::shared_ptr<CountingSink> _sink;
    std::shared_ptr<Shared> _shared;
    NSString *_version;
    NSString *_statsPath;
    CFAbsoluteTime _t0;
    int _blobsIn;
}

+ (void)registerOnce {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tgcalls::Register<tgcalls::InstanceV2Impl>();
    });
}

- (instancetype)initWithVersion:(NSString *)version
                            key:(NSData *)key
                     isOutgoing:(BOOL)isOutgoing
                          video:(BOOL)video
                         noSctp:(BOOL)noSctp
                        logPath:(NSString *)logPath
                      statsPath:(NSString *)statsPath
                           emit:(void (^)(NSData *))emit
                          event:(void (^)(NSDictionary *))event {
    self = [super init];
    if (!self) return nil;
    NSParameterAssert(key.length == 256);
    [OLTgPeer registerOnce];
    _version = [version copy];
    _statsPath = [statsPath copy];
    _t0 = CFAbsoluteTimeGetCurrent();
    _shared = std::make_shared<Shared>();
    _sink = std::make_shared<CountingSink>();

    auto keyValue = std::make_shared<std::array<uint8_t, 256>>();
    memcpy(keyValue->data(), key.bytes, 256);

    if (video) {
        // "" selects the front camera (VideoCapturerInterfaceImpl: !hasPrefix("back")).
        _capture = tgcalls::VideoCaptureInterface::Create(tgcalls::StaticThreads::getThreads(), "");
    }

    tgcalls::Config config;
    config.initializationTimeout = 20.0;
    config.receiveTimeout = 20.0;
    config.enableP2P = true; // the Pion server is reached via its host candidate
    config.enableAEC = false; // as Telegram-iOS: voice processing is the iOS ADM's job
    config.enableNS = true;
    config.enableAGC = true;
    config.logPath = tgcalls::FilePath{logPath.UTF8String};
    config.statsLogPath = tgcalls::FilePath{statsPath.UTF8String};
    if (noSctp) config.customParameters = "{\"network_signaling_nosctp\":true}";

    auto shared = _shared;
    CFAbsoluteTime t0 = _t0;
    void (^eventCopy)(NSDictionary *) = [event copy];
    void (^emitCopy)(NSData *) = [emit copy];

    _instance = std::shared_ptr<tgcalls::Instance>(tgcalls::Meta::Create(version.UTF8String, (tgcalls::Descriptor){
        .version = version.UTF8String,
        .config = config,
        .encryptionKey = tgcalls::EncryptionKey(keyValue, isOutgoing),
        .videoCapture = _capture,
        .stateUpdated = [shared, t0, eventCopy](tgcalls::State s) {
            double at = CFAbsoluteTimeGetCurrent() - t0;
            {
                std::lock_guard<std::mutex> lock(shared->mu);
                shared->state = StateName(s);
                if (s == tgcalls::State::Established && shared->establishedAt < 0) shared->establishedAt = at;
            }
            NSDictionary *ev = @{@"t": @"state", @"state": @(StateName(s)), @"at": @(at)};
            dispatch_async(dispatch_get_main_queue(), ^{ eventCopy(ev); });
        },
        .audioLevelUpdated = [shared](float level) {
            std::lock_guard<std::mutex> lock(shared->mu);
            if (level > shared->maxAudioLevel) shared->maxAudioLevel = level;
        },
        .remoteMediaStateUpdated = [shared, eventCopy](tgcalls::AudioState a, tgcalls::VideoState v) {
            {
                std::lock_guard<std::mutex> lock(shared->mu);
                shared->remoteMediaStates++;
                if (a == tgcalls::AudioState::Active) shared->remoteAudioActive++;
                shared->remoteVideoState = (int)v;
            }
            NSDictionary *ev = @{@"t": @"remoteMedia", @"audioActive": @(a == tgcalls::AudioState::Active), @"video": @((int)v)};
            dispatch_async(dispatch_get_main_queue(), ^{ eventCopy(ev); });
        },
        .signalingDataEmitted = [shared, emitCopy](const std::vector<uint8_t> &data) {
            {
                std::lock_guard<std::mutex> lock(shared->mu);
                shared->blobsOut++;
            }
            NSData *blob = [NSData dataWithBytes:data.data() length:data.size()];
            dispatch_async(dispatch_get_main_queue(), ^{ emitCopy(blob); });
        },
        // The tgcalls iOS ADM, constructed as Telegram-iOS does for a normal
        // call: (bypass_voice_processing, disable_recording, enableSystemMute,
        // numChannels). If the pinned WebRTC spells it webrtc::make_ref_counted,
        // change the namespace; the class and arguments stay.
        .createAudioDeviceModule = [](webrtc::TaskQueueFactory *) -> webrtc::scoped_refptr<webrtc::AudioDeviceModule> {
            return rtc::make_ref_counted<webrtc::tgcalls_ios_adm::AudioDeviceModuleIOS>(false, false, false, 1);
        },
    }).release());
    if (_instance && video) {
        _instance->setIncomingVideoOutput(_sink);
    }
    return self;
}

- (void)addSignalingData:(NSData *)data {
    if (!_instance) return;
    _blobsIn++;
    std::vector<uint8_t> v((const uint8_t *)data.bytes, (const uint8_t *)data.bytes + data.length);
    _instance->receiveSignalingData(v);
}

- (void)stop:(void (^)(NSDictionary *))completion {
    if (!_instance) {
        completion(@{@"t": @"summary", @"error": @"no instance (unsupported version?)"});
        return;
    }
    if (_capture) _capture->setState(tgcalls::VideoState::Inactive);
    auto instance = _instance;
    auto shared = _shared;
    auto sink = _sink;
    NSString *version = _version;
    NSString *statsPath = _statsPath;
    int blobsIn = _blobsIn;
    instance->stop([instance, shared, sink, version, statsPath, blobsIn, completion](tgcalls::FinalState) {
        // Count bitrate records the same way tgcalls_cli does.
        NSString *stats = [NSString stringWithContentsOfFile:statsPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSUInteger records = [stats componentsSeparatedByString:@"\"b\":"].count - 1;
        NSDictionary *summary;
        {
            std::lock_guard<std::mutex> lock(shared->mu);
            summary = @{
                @"t": @"summary",
                @"version": version,
                @"finalState": @(shared->state.c_str()),
                @"established": @(shared->establishedAt >= 0),
                @"establishedAt": @(shared->establishedAt),
                @"remoteMediaStates": @(shared->remoteMediaStates),
                @"remoteAudioActive": @(shared->remoteAudioActive),
                @"maxAudioLevel": @(shared->maxAudioLevel),
                @"videoFramesReceived": @(sink->frames.load()),
                @"videoLast": [NSString stringWithFormat:@"%dx%d", sink->width.load(), sink->height.load()],
                @"statsBitrateRecords": @(records),
                @"blobsOut": @(shared->blobsOut),
                @"blobsIn": @(blobsIn),
            };
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(summary); });
    });
    _instance.reset();
}

@end

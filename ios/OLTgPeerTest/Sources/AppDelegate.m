// OLTgPeerTest: minimal iOS app proving the tgcalls -> olcall (Pion) handshake
// on a real iPhone. One screen: server URL, join token, version, video/nosctp
// switches, Start / Hang up, and a log. Not part of the Open Lounge app UI.
//
// Evidence written to Documents/ (Finder file sharing is enabled):
//   olpeer-<UTC>.events.jsonl  states, remote media, summary (no key, no blob bytes)
//   olpeer-<UTC>.blobs.jsonl   capture-format record of every blob tgcalls emitted
//                              and received (ciphertext/SCTP framing only, no key)
//   olpeer-<UTC>.tgcalls.log   tgcalls/WebRTC log (Config.logPath)
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <sys/utsname.h>

#import "OLCallSocket.h"
#import "OLTgPeer.h"

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@interface OLViewController : UIViewController
@end

@implementation OLViewController {
    UITextField *_url, *_token, *_version;
    UISwitch *_video, *_noSctp;
    UITextView *_log;
    OLCallSocket *_socket;
    OLTgPeer *_peer;
    NSFileHandle *_events, *_blobs;
    NSString *_stamp;
    CFAbsoluteTime _t0;
}

static NSString *DeviceModel(void) {
    struct utsname u;
    uname(&u);
    return [NSString stringWithUTF8String:u.machine];
}

- (UITextField *)field:(NSString *)placeholder text:(NSString *)text {
    UITextField *f = [[UITextField alloc] init];
    f.placeholder = placeholder;
    f.text = text;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    return f;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _url = [self field:@"wss://host/v1/call" text:[NSUserDefaults.standardUserDefaults stringForKey:@"url"]];
    _token = [self field:@"join token (from the OL backend / test signer)" text:nil];
    _version = [self field:@"tgcalls version" text:@"13.0.0"];
    _video = [[UISwitch alloc] init];
    _noSctp = [[UISwitch alloc] init];
    UILabel *vl = [[UILabel alloc] init]; vl.text = @"video";
    UILabel *nl = [[UILabel alloc] init]; nl.text = @"nosctp";
    UIButton *start = [UIButton buttonWithType:UIButtonTypeSystem];
    [start setTitle:@"Start" forState:UIControlStateNormal];
    [start addTarget:self action:@selector(start) forControlEvents:UIControlEventTouchUpInside];
    UIButton *hang = [UIButton buttonWithType:UIButtonTypeSystem];
    [hang setTitle:@"Hang up" forState:UIControlStateNormal];
    [hang addTarget:self action:@selector(hangup) forControlEvents:UIControlEventTouchUpInside];
    _log = [[UITextView alloc] init];
    _log.editable = NO;
    _log.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[vl, _video, nl, _noSctp, start, hang]];
    row.spacing = 8;
    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[_url, _token, _version, row, _log]];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 8;
    col.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:col];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [col.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [col.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [col.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],
        [col.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-12],
    ]];
}

- (NSString *)docPath:(NSString *)suffix {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:[NSString stringWithFormat:@"olpeer-%@.%@", _stamp, suffix]];
}

- (NSFileHandle *)openFile:(NSString *)path {
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil
                                          attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}];
    return [NSFileHandle fileHandleForWritingAtPath:path];
}

- (void)writeLine:(NSDictionary *)obj to:(NSFileHandle *)h {
    NSMutableData *d = [[NSJSONSerialization dataWithJSONObject:obj options:0 error:nil] mutableCopy];
    [d appendBytes:"\n" length:1];
    [h writeData:d];
}

- (void)log:(NSDictionary *)ev {
    NSMutableDictionary *e = [ev mutableCopy];
    e[@"tMs"] = @((long long)((CFAbsoluteTimeGetCurrent() - _t0) * 1000));
    if (_events) [self writeLine:e to:_events];
    NSData *d = [NSJSONSerialization dataWithJSONObject:e options:0 error:nil];
    _log.text = [_log.text stringByAppendingFormat:@"%@\n", [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]];
    [_log scrollRangeToVisible:NSMakeRange(_log.text.length, 0)];
}

static NSString *Hex(NSData *d) {
    NSMutableString *s = [NSMutableString stringWithCapacity:d.length * 2];
    const uint8_t *b = d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

- (void)start {
    if (_socket) return;
    NSURL *url = [NSURL URLWithString:_url.text ?: @""];
    if (!url || _token.text.length == 0) {
        [self log:@{@"t": @"error", @"error": @"url and token required"}];
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:_url.text forKey:@"url"];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyyMMdd'T'HHmmss'Z'";
    df.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    _stamp = [df stringFromDate:[NSDate date]];
    _t0 = CFAbsoluteTimeGetCurrent();
    _events = [self openFile:[self docPath:@"events.jsonl"]];
    _blobs = [self openFile:[self docPath:@"blobs.jsonl"]];
    NSString *version = _version.text.length ? _version.text : @"13.0.0";
    BOOL video = _video.on, noSctp = _noSctp.on;
    NSString *device = DeviceModel();
    NSString *os = [NSString stringWithFormat:@"iOS %@", UIDevice.currentDevice.systemVersion];
    [self writeLine:@{@"capture": @"olcall-tgcalls-signaling/1", @"source": @"ios-app",
                      @"host": [NSString stringWithFormat:@"%@ %@ (real device, iOS ADM + camera)", device, os],
                      @"version": version, @"noSctp": @(noSctp),
                      @"keyNote": @"no key: decode via the server capture (CaptureDir) of the same call"} to:_blobs];
    [self log:@{@"t": @"start", @"version": version, @"video": @(video), @"noSctp": @(noSctp), @"device": device, @"os": os}];

    // Audio session as for a VoIP call; the tgcalls iOS ADM drives the RemoteIO unit.
    AVAudioSession *s = AVAudioSession.sharedInstance;
    NSError *err = nil;
    [s setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeVoiceChat
           options:AVAudioSessionCategoryOptionAllowBluetooth error:&err];
    if (!err) [s setActive:YES error:&err];
    if (err) [self log:@{@"t": @"audioSession", @"error": err.localizedDescription, @"code": @(err.code)}];

    __weak OLViewController *weakSelf = self;
    _socket = [[OLCallSocket alloc] initWithURL:url];
    __block NSString *role = @"caller";
    _socket.onJoined = ^(NSString *callId, NSString *leg, NSMutableData *key, BOOL isOutgoing) {
        OLViewController *me = weakSelf;
        if (!me) return;
        role = isOutgoing ? @"caller" : @"callee";
        [me log:@{@"t": @"joined", @"leg": leg, @"isOutgoing": @(isOutgoing)}];
        me->_peer = [[OLTgPeer alloc] initWithVersion:version key:key isOutgoing:isOutgoing video:video noSctp:noSctp
                                              logPath:[me docPath:@"tgcalls.log"] statsPath:[me docPath:@"stats.json"]
                                                 emit:^(NSData *blob) {
            OLViewController *me2 = weakSelf;
            if (!me2) return;
            [me2 writeLine:@{@"tMs": @((long long)((CFAbsoluteTimeGetCurrent() - me2->_t0) * 1000)), @"from": role,
                             @"party": @"client", @"hex": Hex(blob)} to:me2->_blobs];
            [me2->_socket sendBlob:blob];
        } event:^(NSDictionary *ev) {
            [weakSelf log:ev];
        }];
    };
    _socket.onBlob = ^(NSData *blob) {
        OLViewController *me = weakSelf;
        if (!me) return;
        [me writeLine:@{@"tMs": @((long long)((CFAbsoluteTimeGetCurrent() - me->_t0) * 1000)), @"from": role,
                        @"party": @"server", @"hex": Hex(blob)} to:me->_blobs];
        [me->_peer addSignalingData:blob];
    };
    _socket.onClosed = ^(NSString *reason) {
        [weakSelf log:@{@"t": @"closed", @"reason": reason}];
        [weakSelf finish];
    };
    NSString *engine = [NSString stringWithFormat:@"libtgcalls-ios/OLTgPeerTest"];
    [_socket joinWithToken:_token.text traceId:[NSUUID UUID].UUIDString version:version noSctp:noSctp
                    device:device os:os engine:engine];
}

- (void)hangup {
    [_socket hangup];
    [self finish];
}

- (void)finish {
    OLTgPeer *peer = _peer;
    _peer = nil;
    _socket = nil;
    if (!peer) return;
    __weak OLViewController *weakSelf = self;
    [peer stop:^(NSDictionary *summary) {
        OLViewController *me = weakSelf;
        if (!me) return;
        [me log:summary];
        [me->_events closeFile];
        [me->_blobs closeFile];
        me->_events = nil;
        me->_blobs = nil;
        [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    }];
}

@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[OLViewController alloc] init];
    [self.window makeKeyAndVisible];
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {}];
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {}];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}

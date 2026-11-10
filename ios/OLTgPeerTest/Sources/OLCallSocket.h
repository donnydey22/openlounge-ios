// Minimal client for the olcall WebSocket protocol (olcall/server/protocol.go,
// docs/PROTOCOL.md): join -> joined(key) -> blob <-> blob -> bye/hangup.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OLCallSocket : NSObject

@property (nonatomic, copy, nullable) void (^onJoined)(NSString *callId, NSString *leg, NSMutableData *key, BOOL isOutgoing);
@property (nonatomic, copy, nullable) void (^onBlob)(NSData *blob);
@property (nonatomic, copy, nullable) void (^onClosed)(NSString *reason);

- (instancetype)initWithURL:(NSURL *)url;
- (void)joinWithToken:(NSString *)token traceId:(NSString *)traceId version:(NSString *)version noSctp:(BOOL)noSctp
               device:(NSString *)device os:(NSString *)os engine:(NSString *)engine;
- (void)sendBlob:(NSData *)blob;
- (void)hangup;

@end

NS_ASSUME_NONNULL_END

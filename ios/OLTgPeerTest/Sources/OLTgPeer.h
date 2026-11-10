// One real tgcalls call leg on iOS: tgcalls::Instance (InstanceV2Impl) with the
// tgcalls iOS AudioDeviceModule and the iOS camera capturer, exactly the
// components Telegram-iOS uses. Signaling is handed to the caller (blocks) so
// it can travel over the olcall WebSocket to the Pion server.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OLTgPeer : NSObject

/// key must be 256 bytes (from the server's "joined" frame). It is copied;
/// the caller should wipe its own buffer afterwards.
- (instancetype)initWithVersion:(NSString *)version
                            key:(NSData *)key
                     isOutgoing:(BOOL)isOutgoing
                          video:(BOOL)video
                         noSctp:(BOOL)noSctp
                        logPath:(NSString *)logPath
                      statsPath:(NSString *)statsPath
                           emit:(void (^)(NSData *blob))emit
                          event:(void (^)(NSDictionary *event))event;

- (void)addSignalingData:(NSData *)data;

/// Stops the instance and reports a summary (main queue).
- (void)stop:(void (^)(NSDictionary *summary))completion;

@end

NS_ASSUME_NONNULL_END

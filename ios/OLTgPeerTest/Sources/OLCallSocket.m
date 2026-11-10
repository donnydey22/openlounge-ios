#import "OLCallSocket.h"

@implementation OLCallSocket {
    NSURLSession *_session;
    NSURLSessionWebSocketTask *_task;
    uint64_t _seq;
    BOOL _closed;
}

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        _session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
                                                 delegate:nil
                                            delegateQueue:[NSOperationQueue mainQueue]];
        _task = [_session webSocketTaskWithURL:url];
        _task.maximumMessageSize = 1 << 20;
        [_task resume];
        [self receive];
    }
    return self;
}

- (void)send:(NSMutableDictionary *)frame {
    if (_closed) return;
    frame[@"seq"] = @(++_seq);
    NSData *json = [NSJSONSerialization dataWithJSONObject:frame options:0 error:nil];
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    __weak OLCallSocket *weakSelf = self;
    [_task sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:text] completionHandler:^(NSError *error) {
        if (error) [weakSelf closeWithReason:[NSString stringWithFormat:@"send: %@", error.localizedDescription]];
    }];
}

- (void)joinWithToken:(NSString *)token traceId:(NSString *)traceId version:(NSString *)version noSctp:(BOOL)noSctp
               device:(NSString *)device os:(NSString *)os engine:(NSString *)engine {
    NSMutableDictionary *f = [@{@"t": @"join", @"token": token, @"traceId": traceId, @"surface": @"tgcalls",
                                @"version": version, @"platform": @"ios", @"device": device, @"os": os, @"engine": engine} mutableCopy];
    if (noSctp) f[@"noSctp"] = @YES;
    [self send:f];
}

- (void)sendBlob:(NSData *)blob {
    [self send:[@{@"t": @"blob", @"b64": [blob base64EncodedStringWithOptions:0]} mutableCopy]];
}

- (void)hangup {
    [self send:[@{@"t": @"hangup"} mutableCopy]];
}

- (void)closeWithReason:(NSString *)reason {
    if (_closed) return;
    _closed = YES;
    [_task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    if (self.onClosed) self.onClosed(reason);
}

- (void)receive {
    __weak OLCallSocket *weakSelf = self;
    [_task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        OLCallSocket *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) {
            [strongSelf closeWithReason:[NSString stringWithFormat:@"ws: %@", error.localizedDescription]];
            return;
        }
        NSData *data = message.type == NSURLSessionWebSocketMessageTypeString
            ? [message.string dataUsingEncoding:NSUTF8StringEncoding] : message.data;
        NSDictionary *f = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([f isKindOfClass:[NSDictionary class]]) [strongSelf handle:f];
        if (!strongSelf->_closed) [strongSelf receive];
    }];
}

- (void)handle:(NSDictionary *)f {
    NSString *t = f[@"t"];
    if ([t isEqualToString:@"joined"]) {
        NSData *k = [[NSData alloc] initWithBase64EncodedString:f[@"key"] ?: @"" options:0];
        NSNumber *outgoing = f[@"isOutgoing"];
        if (k.length != 256 || outgoing == nil) {
            [self closeWithReason:@"bad joined frame"];
            return;
        }
        NSMutableData *key = [k mutableCopy];
        if (self.onJoined) self.onJoined(f[@"callId"] ?: @"", f[@"leg"] ?: @"", key, outgoing.boolValue);
        [key resetBytesInRange:NSMakeRange(0, key.length)];
    } else if ([t isEqualToString:@"blob"]) {
        NSData *b = [[NSData alloc] initWithBase64EncodedString:f[@"b64"] ?: @"" options:0];
        if (b && self.onBlob) self.onBlob(b);
    } else if ([t isEqualToString:@"bye"]) {
        [self closeWithReason:[NSString stringWithFormat:@"bye: %@", f[@"reason"] ?: @""]];
    } else if ([t isEqualToString:@"error"]) {
        [self closeWithReason:[NSString stringWithFormat:@"error: %@", f[@"error"] ?: @""]];
    }
}

@end

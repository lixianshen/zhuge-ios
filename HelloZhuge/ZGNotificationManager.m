#if ! __has_feature(objc_arc)
#error This file must be compiled with ARC. Either turn on ARC for the project or use -fobjc-arc flag on this file.
#endif

#import "ZGNotificationManager.h"
#import "ZGNotification.h"
#import "ZGNotificationViewController.h"

#import <UIKit/UIDevice.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>

#include <sys/socket.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/if_dl.h>


#define DEVICE_TYPE 2

#pragma mark - 消息协议

typedef struct {
    uint16_t iHeadLen;  // 包头长度, 大于或者等于 sizeof(PkgHeader)=8 字节
    uint16_t iCmdType;  // 消息类型, 消息类型加1为对应的响应的类型
    uint32_t iTotalLen; // 总包长,   即包头长度+包体长度
} PkgHeader;

typedef enum {
    ZGNoticeCmdLogin          = 0x1000,	// 注册
    ZGNoticeCmdKeepalive      = 0x1002,	// 心跳检测
    ZGNoticeCmdUploadToken    = 0x1004,	// 上传ios token
    ZGNoticeCmdGetClientId    = 0x1006,	// 获取clientid
    ZGNoticeCmdClearMsgCnt    = 0x1008,	// 清除未读消息数量
    ZGNoticeCmdSetMsgRead     = 0x1010,	// 标记消息已经阅读
    ZGNoticeCmdSetShield      = 0x1012,	// 设置屏蔽消息
    ZGNoticeCmdGetShield      = 0x1014,	// 获取屏蔽消息
    ZGNoticeCmdSetRecvTime    = 0x1016,	// 设置消息接收时段
    ZGNoticeCmdGetRecvTime    = 0x1018,	// 获取消息接收时段
    ZGNoticeCmdMsg            = 0x2000,	// b2c消息
    ZGNoticeCmdLogout         = 0xFF00,	// logout
    ZGNoticeCmdKickout        = 0xFF02,	// kickout
} ZGNoticeCmdType;

typedef enum {
    ZGNoticeCmdAckLogin          = 0x1001,	// 注册
    ZGNoticeCmdAckKeepalive      = 0x1003,	// 心跳检测
    ZGNoticeCmdAckUploadToken    = 0x1005,	// 上传ios token
    ZGNoticeCmdAckGetClientId    = 0x1007,	// 获取clientid
    ZGNoticeCmdAckClearMsgCnt    = 0x1009,	// 清除未读消息数量
    ZGNoticeCmdAckSetMsgRead     = 0x1011,	// 标记消息已经阅读
    ZGNoticeCmdAckSetShield      = 0x1013,	// 设置屏蔽消息
    ZGNoticeCmdAckGetShield      = 0x1015,	// 获取屏蔽消息
    ZGNoticeCmdAckSetRecvTime    = 0x1017,	// 设置消息接收时段
    ZGNoticeCmdAckGetRecvTime    = 0x1019,	// 获取消息接收时段
    ZGNoticeCmdAckMsg            = 0x2001,	// b2c消息
    ZGNoticeCmdAckLogout         = 0xFF01,	// logout
    ZGNoticeCmdAckKickout        = 0xFF03,	// kickout
} ZGNoticeAckCmdType;


#pragma mark - NSRunLoop

@interface NSRunLoop (ZGNotificationManager)
+ (NSRunLoop *)zgNetworkRunLoop;
@end

@interface _ZGRunLoopThread : NSThread
@property (nonatomic, readonly) NSRunLoop *runLoop;
@end

#pragma mark - ZGNotificationManager

@interface ZGNotificationManager() <NSStreamDelegate, ZGNotificationViewControllerDelegate>

@property (nonatomic) ZGNotificationManagerState readyState;

@property (nonatomic, copy) NSString *serverUrl;
@property (nonatomic, strong) NSMutableArray *servers;
@property (nonatomic, copy) NSString *currentServer;
@property (atomic) int retry;
@property (nonatomic) NSUInteger keepaliveIntervalSecs; // 心跳间隔
@property (nonatomic) NSUInteger confIntervalDays; // 获取配置间隔

@property (nonatomic, strong) NSString *appKey;
@property (nonatomic, copy) NSString *did;
@property (nonatomic, copy) NSString *dt;
@property (nonatomic, copy) NSString *cid;
@property (atomic) NSNumber *seq;
@property (atomic) NSNumber *ver;

@property (nonatomic, strong) NSString *shield;
@property (nonatomic, strong) NSString *recvTimeStart;
@property (nonatomic, strong) NSString *recvTimeEnd;

@property (nonatomic, strong) NSTimer *timer;


// 通知
@property (nonatomic) BOOL decideResponseCached;
@property (atomic, copy) NSString *decideURL;
@property (nonatomic, strong) NSArray *notifications;
@property (nonatomic, strong) ZGNotification *currentlyShowingNotification;
@property (nonatomic, strong) ZGNotificationViewController *notificationViewController;
@property (nonatomic, strong) NSMutableSet *shownNotifications;
@property (atomic) CGFloat miniNotificationPresentationTime;


@end

@implementation ZGNotificationManager {
    dispatch_queue_t _connectQueue;
}

NSInputStream *_inputStream;
NSOutputStream *_outputStream;

#pragma mark - 初始化

- (id)init {
    self = [super init];
    if (self) {
        self.serverUrl = @"http://apipool.37degree.com/APIPOOL/?method=conf_srv.srv_list_get";
        
        self.retry = 1;
        self.keepaliveIntervalSecs = 30;
        self.confIntervalDays = 3;
        
        self.seq = [NSNumber numberWithInt:1];
        self.ver = [NSNumber numberWithInt:1];
        
        self.miniNotificationPresentationTime = 6.0;

        
        _connectQueue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
    }
    
    return self;
}

- (void)openWithAppKey:(NSString *)appkey andDeviceId:(NSString *)deviceId {
    self.appKey = appkey;
    self.did = deviceId;
    
    self.readyState = ZGNotificationManagerStateConnecting;

    [self _getServers];
    [self _connect];
    [self login];
    [self sendGetClientId];
    [self updateConfigFromOnline];
}

- (void)_connect {
    if (self.servers != nil && self.servers.count > 0) {
        self.currentServer = self.servers[arc4random() % [self.servers count]];
        NSLog(@"尝试连接服务器: %@", self.currentServer);
        if (self.currentServer) {
            NSArray *serverItems = [self.currentServer componentsSeparatedByString:@":"];
            
            CFReadStreamRef readStream;
            CFWriteStreamRef writeStream;
            
            CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)serverItems[0], [serverItems[1] intValue], &readStream, &writeStream);
            
            _inputStream = (NSInputStream *)CFBridgingRelease(readStream);
            _outputStream = (NSOutputStream *)CFBridgingRelease(writeStream);
            
            _inputStream.delegate = self;
            _outputStream.delegate = self;
            
            NSRunLoop * rl = [NSRunLoop zgNetworkRunLoop];
            [_inputStream scheduleInRunLoop:rl forMode:NSDefaultRunLoopMode];
            [_outputStream scheduleInRunLoop:rl forMode:NSDefaultRunLoopMode];
            
            [_inputStream open];
            [_outputStream open];
            
            self.timer = [NSTimer scheduledTimerWithTimeInterval:self.keepaliveIntervalSecs
                                                          target:self
                                                        selector:@selector(keepalive)
                                                        userInfo:nil
                                                         repeats:YES];
        }
    }
}

- (void)_connectFailed {
    if (self.servers != nil && self.servers.count > 0 ) {
        [self.servers removeObject:self.currentServer];
    }
    
    if (self.servers != nil && self.servers.count > 0) {
        [self _connect];
    } else {
        if (self.retry > 0) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey: @"zgPushServers"];
            [self _getServers];
            self.retry--;
            [self _connect];
        }
    }
}

- (void) _getServers {
    self.servers = [[[NSUserDefaults standardUserDefaults] arrayForKey:@"zgPushServers"] mutableCopy];
    if (self.servers == nil || self.servers.count == 0) {
        NSLog(@"推送服务器列表不存在，正在重新获取服务器列表...");
        
        NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:@"%@&did=%@", self.serverUrl, self.did]];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
        [request setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"];
        
        NSError *error = nil;
        NSURLResponse *urlResponse = nil;
        NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&urlResponse error:&error];
        
        if (error) {
            NSLog(@"%@ 获取推送服务器列表错误: %@", self, error);
        }
        
        NSDictionary *object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        self.servers = [object[@"data"][@"servers"] mutableCopy];
        [[NSUserDefaults standardUserDefaults] setObject:self.servers forKey:@"zgPushServers"];
        NSLog(@"重新获取推送服务器列表成功:%@", self.servers);
    }
}

- (void)updateConfigFromOnline {
    NSNumber *start = [[NSUserDefaults standardUserDefaults] objectForKey:@"zgPushRecvTimeStart"];
    NSNumber *end = [[NSUserDefaults standardUserDefaults] objectForKey:@"zgPushRecvTimeEnd"];
    NSNumber *shield = [[NSUserDefaults standardUserDefaults] objectForKey:@"zgPushShield"];
    NSNumber *zgConfigTime = [[NSUserDefaults standardUserDefaults] objectForKey:@"zgPushConfigTime"];
   NSNumber *ts = @(round([[NSDate date] timeIntervalSince1970]));
    if (start == nil || end == nil || shield == nil || zgConfigTime == nil ||[ts longValue] > [zgConfigTime longValue] + self.confIntervalDays*86400) {
        [self sendGetMessageShield];
        [self sendGetMessageReceiveTime];
        [[NSUserDefaults standardUserDefaults] setObject:ts forKey:@"zgPushConfigTime"];
    }
    
}

- (void)close {
    self.readyState = ZGNotificationManagerStateClosing;
}

- (ZGNotificationManagerState) state {
    return self.readyState;
}

#pragma mark - 请求命令

// 登录
- (void) login {
    NSMutableDictionary *msg = [NSMutableDictionary dictionary];
    msg[@"did"] = self.did;
    msg[@"dtype"] = [NSNumber numberWithInt:2];
    msg[@"encrpyt"] = [NSNumber numberWithInt:0];
    msg[@"compress"] = [NSNumber numberWithInt:0];
    
    [self sendMessage:msg withCmd:ZGNoticeCmdLogin];
}

// 保持心跳
- (void) keepalive {
    NSMutableDictionary *msg = [NSMutableDictionary dictionary];
    [self sendMessage:msg withCmd:ZGNoticeCmdKeepalive];
}

// 注册device token
- (void) registerDeviceToken:(NSString *)deviceToken {
    if (self.cid) {
        NSMutableDictionary *msg = [NSMutableDictionary dictionary];
        msg[@"cid"] = self.cid;
        msg[@"token"] = deviceToken;

        [self sendMessage:msg withCmd:ZGNoticeCmdUploadToken];
    }
}

// 获取客户端ID
- (NSString *) getClientId {
    return self.cid;
}
- (void) sendGetClientId {
    NSMutableDictionary *msg = [NSMutableDictionary dictionary];
    msg[@"did"] = self.did;
    msg[@"dtype"] = [NSNumber numberWithInt:DEVICE_TYPE];
    msg[@"appid"] = self.appKey;
    
    [self sendMessage:msg withCmd:ZGNoticeCmdGetClientId];
}

// 清除未读消息数量
- (void) clearMessageCount {
    if (self.cid) {
        NSMutableDictionary *msg = [NSMutableDictionary dictionary];
        msg[@"cid"] = self.cid;
    
        [self sendMessage:msg withCmd:ZGNoticeCmdClearMsgCnt];
    }
}

// 标记消息已读
- (void) setMessageReaded:(NSString *) messageId {
    NSMutableDictionary *msg = [NSMutableDictionary dictionary];
    msg[@"id"] = messageId;
    
    [self sendMessage:msg withCmd:ZGNoticeCmdSetMsgRead];
}

// 设置消息屏蔽
- (void) setMessageShield:(BOOL) shield {
    if (self.cid) {
        NSMutableDictionary *msg = [NSMutableDictionary dictionary];
        msg[@"cid"] = self.cid;
        msg[@"shield"] = shield ? @YES : @NO;
    
        [self sendMessage:msg withCmd:ZGNoticeCmdSetShield];
    }
}

// 获取消息屏蔽
- (BOOL) getMessageShield {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"zgPushShield"];
}

- (void) sendGetMessageShield {
    if (self.cid) {
        NSMutableDictionary *msg = [NSMutableDictionary dictionary];
        msg[@"cid"] = self.cid;
        [self sendMessage:msg withCmd:ZGNoticeCmdGetRecvTime];
    }
}

// 设置消息屏蔽时间
- (void) setMessageReceiveTimeStart:(int) start AndEnd:(int) end {
    if (self.cid) {
        NSMutableDictionary *msg = [NSMutableDictionary dictionary];
        msg[@"cid"] = self.cid;
        msg[@"start"] = [NSNumber numberWithInt:start];
        msg[@"end"] = [NSNumber numberWithInt:end];

        [self sendMessage:msg withCmd:ZGNoticeCmdSetRecvTime];
    }
}

// 获取消息屏蔽时间
- (NSDictionary *) getMessageReceiveTime {
    NSMutableDictionary *dic = [NSMutableDictionary dictionary];
    NSString *start = [[NSUserDefaults standardUserDefaults] objectForKey:@"zgPushRecvTimeStart"];
    NSString *end = [[NSUserDefaults standardUserDefaults] objectForKey:@"zgPushRecvTimeStart"];

    if (start != nil && end != nil) {
        dic[@"start"] = start;
        dic[@"end"] = end;
    }

    return dic;
}

- (void) sendGetMessageReceiveTime {
    if (self.cid) {
        NSMutableDictionary *msg = [NSMutableDictionary dictionary];
        msg[@"cid"] = self.cid;
        
        [self sendMessage:msg withCmd:ZGNoticeCmdGetRecvTime];
    }
}

- (void) sendMessage:(NSMutableDictionary *) msg withCmd:(uint16_t) cmd {
    msg[@"seq"] = self.seq;
    msg[@"ver"] = self.ver;
    
    NSString *json = [[NSString alloc] initWithData:[self JSONSerializeObject:msg] encoding:NSUTF8StringEncoding];
    NSLog(@"send json: %@", json);
    NSInteger iLenJson = json.length;
    
    PkgHeader pkgHeader;
    pkgHeader.iHeadLen = CFSwapInt16HostToBig(sizeof(pkgHeader));
    pkgHeader.iCmdType = CFSwapInt16HostToBig(cmd);
    pkgHeader.iTotalLen = CFSwapInt32HostToBig(sizeof(pkgHeader) + (uint32_t)iLenJson);

   NSMutableData *data = [NSMutableData data];
   [data appendBytes:&pkgHeader length:sizeof(pkgHeader)];
   [data appendBytes:[json UTF8String] length:iLenJson];
    
    dispatch_async(self->_connectQueue, ^{
       [_outputStream write:[data bytes] maxLength:[data length]];
   });
}

#pragma mark - 响应

- (void)stream:(NSStream *)theStream handleEvent:(NSStreamEvent)streamEvent {
    switch (streamEvent) {
        case  NSStreamEventOpenCompleted:
            NSLog(@"NSStreamEventOpenCompleted");
            if (theStream == _inputStream) {
                self.readyState = ZGNotificationManagerStateConnected;
                NSLog(@"已连接");
            }
            break;
        case  NSStreamEventHasBytesAvailable:
            NSLog(@"NSStreamEventHasBytesAvailable");
            if (theStream == _inputStream) {
                [self recvData];
            }
            break;
        case  NSStreamEventHasSpaceAvailable:
            NSLog(@"NSStreamEventHasSpaceAvailable");
            break;
        case  NSStreamEventErrorOccurred:
            NSLog(@"NSStreamEventErrorOccurred %@ %@", theStream, [[theStream streamError] copy]);
            if (self.readyState == ZGNotificationManagerStateConnecting) {
                NSLog(@"连接失败");
                [self _connectFailed];
            }
            
            break;
        case  NSStreamEventEndEncountered:
            NSLog(@"NSStreamEventEndEncountered");
            break;
        default:
            NSLog(@"no event");
            break;
    }
}

-(void) recvData {
    const int bufferSize = 2048;
    uint8_t buffer[bufferSize];
    while ([_inputStream hasBytesAvailable]) {
        NSInteger readBytes = [_inputStream read:buffer maxLength:bufferSize];
        if (readBytes > 0) {
            NSData *data = [NSData dataWithBytes:buffer length:readBytes];
            
            PkgHeader pkgHeader;
            [data getBytes:&pkgHeader length:sizeof(pkgHeader)];
            unsigned int iHeadLen = CFSwapInt16BigToHost(pkgHeader.iHeadLen);
            unsigned int iCmdType = CFSwapInt16BigToHost(pkgHeader.iCmdType);
            unsigned int iTotalLen = CFSwapInt32BigToHost(pkgHeader.iTotalLen);
            unsigned int iBodyLen = iTotalLen - iHeadLen;
            
            NSLog(@"PkgHeader iCmdType: %u,iHeadLen: %u, iTotalLen: %u", iCmdType, iHeadLen, iTotalLen);
            
            void *msgBuf = malloc(2048);
            [data getBytes:msgBuf range:NSMakeRange(iHeadLen, iBodyLen)];
            NSDictionary *ack = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:msgBuf length:iBodyLen ] options:0 error:nil];
            
            NSLog(@"ack: %@", ack);
            
            switch (iCmdType) {
                case ZGNoticeCmdAckLogin:
                    NSLog(@"ZGNoticeCmdACK_LOGIN");
                    self.readyState = ZGNotificationManagerStateLogin;
                    NSLog(@"登录成功");
                    break;
                case ZGNoticeCmdAckKeepalive:
                    NSLog(@"保持心跳成功");
                    break;
                case ZGNoticeCmdAckGetClientId:
                    NSLog(@"获取ClientId成功");
                    self.cid = ack[@"cid"];
                    [[NSUserDefaults standardUserDefaults] setObject:self.cid forKey:@"zgPushClientId"];
                    break;
                case ZGNoticeCmdAckGetShield:
                    NSLog(@"获取屏蔽成功");
                   self.shield = ack[@"shield"];
                    [[NSUserDefaults standardUserDefaults] setObject:self.shield forKey:@"zgPushShield"];
                    break;
                case ZGNoticeCmdAckGetRecvTime:
                    NSLog(@"获取消息接收时间成功");
                 self.recvTimeStart = ack[@"start"];
                    self.recvTimeEnd = ack[@"end"];
                    if (self.recvTimeStart != nil && self.recvTimeEnd != nil) {
                        [[NSUserDefaults standardUserDefaults] setObject:self.recvTimeStart forKey:@"zgPushRecvTimeStart"];
                        [[NSUserDefaults standardUserDefaults] setObject:self.recvTimeEnd forKey:@"zgPushRecvTimeEnd"];
                    }
                    break;
                case ZGNoticeCmdMsg:
                    NSLog(@"获取消息 msg: %@", NSStringFromClass([ack[@"msg"] class]));
                    
                    [self showMsg:ack[@"msg"]];
            
                    break;
                default:
                    break;
            }
            
            
        }
    }
}

-(void) showMsg:(NSString *) msgJson {
    
    NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:[msgJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];

    NSLog(@"showMsg: %@", msg);

   [self showNotificationWithObject:[ZGNotification notificationWithJSONObject: msg]];
}


// JSON序列化
- (NSData *)JSONSerializeObject:(id)obj {
    id coercedObj = [self JSONSerializableObjectForObject:obj];
    NSError *error = nil;
    NSData *data = nil;
    @try {
        data = [NSJSONSerialization dataWithJSONObject:coercedObj options:0 error:&error];
    }
    @catch (NSException *exception) {
        NSLog(@"%@ exception encoding api data: %@", self, exception);
    }
    if (error) {
        NSLog(@"%@ error encoding api data: %@", self, error);
    }
    return data;
}

// JSON序列化
- (id)JSONSerializableObjectForObject:(id)obj {
    // valid json types
    if ([obj isKindOfClass:[NSString class]] ||
        [obj isKindOfClass:[NSNumber class]] ||
        [obj isKindOfClass:[NSNull class]]) {
        return obj;
    }
    // recurse on containers
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray array];
        for (id i in obj) {
            [a addObject:[self JSONSerializableObjectForObject:i]];
        }
        return [NSArray arrayWithArray:a];
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (id key in obj) {
            NSString *stringKey;
            if (![key isKindOfClass:[NSString class]]) {
                stringKey = [key description];
                NSLog(@"%@ warning: property keys should be strings. got: %@. coercing to: %@", self, [key class], stringKey);
            } else {
                stringKey = [NSString stringWithString:key];
            }
            id v = [self JSONSerializableObjectForObject:obj[key]];
            d[stringKey] = v;
        }
        return [NSDictionary dictionaryWithDictionary:d];
    }
    
    // default to sending the object's description
    NSString *s = [obj description];
    NSLog(@"%@ warning: property values should be valid json types. got: %@. coercing to: %@", self, [obj class], s);
    return s;
}


- (void)dealloc {
    _inputStream.delegate = nil;
    _outputStream.delegate = nil;
    
    [_inputStream close];
    [_outputStream close];
}

#pragma mark - 通知

+ (UIViewController *)topPresentedViewController {
    UIViewController *controller = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }
    return controller;
}

- (void)checkForDecideResponseWithCompletion:(void (^)(NSArray *notifications))completion useCache:(BOOL)useCache {
//    dispatch_async(self.serialQueue, ^{
        NSLog(@"%@ decide check started", self);
        
        if (!useCache || !self.decideResponseCached) {
            NSLog(@"%@ decide cache not found, starting network request", self);
            NSString *params = [NSString stringWithFormat:@"version=1&lib=iphone&ak=%@&did=%@", self.appKey, self.did];
            NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:@"%@?%@", self.decideURL, params]];
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
            [request setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"];
            NSError *error = nil;
            NSURLResponse *urlResponse = nil;
            NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&urlResponse error:&error];
            if (error) {
                NSLog(@"%@ decide check http error: %@", self, error);
                return;
            }
            NSDictionary *object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            if (error) {
                NSLog(@"%@ decide check json error: %@, data: %@", self, error, [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
                return;
            }
            if (object[@"error"]) {
                NSLog(@"%@ decide check api error: %@", self, object[@"error"]);
                return;
            }
            
            NSArray *rawNotifications = object[@"notifications"];
            NSMutableArray *parsedNotifications = [NSMutableArray array];
            
            if (rawNotifications && [rawNotifications isKindOfClass:[NSArray class]]) {
                for (id obj in rawNotifications) {
                    ZGNotification *notification = [ZGNotification notificationWithJSONObject:obj];
                    if (notification) {
                        [parsedNotifications addObject:notification];
                    }
                }
            } else {
                NSLog(@"%@ in-app notifs check response format error: %@", self, object);
            }
            
            
            
            self.notifications = [NSArray arrayWithArray:parsedNotifications];
            
            self.decideResponseCached = YES;
        } else {
            NSLog(@"%@ decide cache found, skipping network request", self);
        }
        
        NSArray *unseenNotifications = [self.notifications objectsAtIndexes:[self.notifications indexesOfObjectsPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
            return [self.shownNotifications member:@(((ZGNotification *)obj).ID)] == nil;
        }]];
        
        NSLog(@"%@ decide check found %lu available notifs out of %lu total: %@", self, (unsigned long)[unseenNotifications count],
              (unsigned long)[self.notifications count], unseenNotifications);
        
        if (completion) {
            completion(unseenNotifications);
        }
//    });
}

- (void)checkForNotificationsWithCompletion:(void (^)(NSArray *notifications))completion {
    [self checkForDecideResponseWithCompletion:^(NSArray *notifications) {
        if (completion) {
            completion(notifications);
        }
    } useCache:YES];
}


- (void)showNotification {
    [self checkForNotificationsWithCompletion:^(NSArray *notifications) {
        if ([notifications count] > 0) {
            [self showNotificationWithObject:notifications[0]];
        }
    }];
}

- (void)showNotificationWithType:(NSString *)type {
    [self checkForNotificationsWithCompletion:^(NSArray *notifications) {
        if (type != nil) {
            for (ZGNotification *notification in notifications) {
                if ([notification.type isEqualToString:type]) {
                    [self showNotificationWithObject:notification];
                    break;
                }
            }
        }
    }];
}

- (void)showNotificationWithID:(NSUInteger)ID {
    [self checkForNotificationsWithCompletion:^(NSArray *notifications) {
        for (ZGNotification *notification in notifications) {
            if (notification.ID == ID) {
                [self showNotificationWithObject:notification];
                break;
            }
        }
    }];
}


- (void)showNotificationWithObject:(ZGNotification *)notification {
    NSData *image = notification.image;

    // if images fail to load, remove the notification from the queue
    if (!image) {
        NSMutableArray *notifications = [NSMutableArray arrayWithArray:_notifications];
        [notifications removeObject:notification];
        self.notifications = [NSArray arrayWithArray:notifications];
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.currentlyShowingNotification) {
            NSLog(@"%@ already showing in-app notification: %@", self, self.currentlyShowingNotification);
        } else {
            self.currentlyShowingNotification = notification;
            BOOL shown = false;
            if ([notification.type isEqualToString:ZGNotificationTypeMini]) {
                shown = [self showMiniNotificationWithObject:notification];
            } else {
                shown = [self showTakeoverNotificationWithObject:notification];
            }
            
            if (shown && ![notification.title isEqualToString:@"$ignore"]) {
                [self markNotificationShown:notification];
            }
        }
    });
}

- (BOOL)showTakeoverNotificationWithObject:(ZGNotification *)notification {
    UIViewController *presentingViewController = [ZGNotificationManager topPresentedViewController];
    
    if (![presentingViewController isBeingPresented] && ![presentingViewController isBeingDismissed]) {
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"ZGNotification" bundle:nil];
        ZGTakeoverNotificationViewController *controller = [storyboard instantiateViewControllerWithIdentifier:@"ZGNotificationViewController"];
        
        //controller.backgroundImage = [presentingViewController.view zg_snapshotImage];
        controller.notification = notification;
        controller.delegate = self;
        self.notificationViewController = controller;
        
        [presentingViewController presentViewController:controller animated:NO completion:nil];
        return YES;
    } else {
        return NO;
    }
}

- (BOOL)showMiniNotificationWithObject:(ZGNotification *)notification {
    ZGMiniNotificationViewController *controller = [[ZGMiniNotificationViewController alloc] init];
    controller.notification = notification;
    controller.delegate = self;
    self.notificationViewController = controller;
    
    [controller showWithAnimation];
    
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.miniNotificationPresentationTime * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        [self notificationController:controller wasDismissedWithStatus:NO];
    });
    return YES;
}

- (void)notificationController:(ZGNotificationViewController *)controller wasDismissedWithStatus:(BOOL)status {
    if (controller == nil || self.currentlyShowingNotification != controller.notification) {
        return;
    }
    
    void (^completionBlock)()  = ^void(){
        self.currentlyShowingNotification = nil;
        self.notificationViewController = nil;
    };
    
    if (status && controller.notification.callToActionURL) {
        NSLog(@"%@ opening URL %@", self, controller.notification.callToActionURL);
        BOOL success = [[UIApplication sharedApplication] openURL:controller.notification.callToActionURL];
        
        [controller hideWithAnimation:!success completion:completionBlock];
        
        if (!success) {
            NSLog(@"Mixpanel failed to open given URL: %@", controller.notification.callToActionURL);
        }
        
        [self trackNotification:controller.notification event:@"$campaign_open"];
    } else {
        [controller hideWithAnimation:YES completion:completionBlock];
    }
}

- (void)trackNotification:(ZGNotification *)notification event:(NSString *)event {
    if (![notification.title isEqualToString:@"$ignore"]) {
//        [self track:event properties:@{@"campaign_id": @(notification.ID),
//                                       @"message_id": @(notification.messageID),
//                                       @"message_type": @"inapp",
//                                       @"message_subtype": notification.type}];
    } else {
        NSLog(@"%@ ignoring notif track for %@, %@", self, @(notification.ID), event);
    }
}

- (void)markNotificationShown:(ZGNotification *)notification {
    NSLog(@"%@ marking notification shown: %@, %@", self, @(notification.ID), _shownNotifications);
    
    [_shownNotifications addObject:@(notification.ID)];
    
    NSDictionary *properties = @{
                                 @"$campaigns": @(notification.ID),
                                 @"$notifications": @{
                                         @"campaign_id": @(notification.ID),
                                         @"message_id": @(notification.messageID),
                                         @"type": @"inapp",
                                         @"time": [NSDate date]
                                         }
                                 };
    
    //[self.people append:properties];
    NSLog(@"%@" , properties);
    
    [self trackNotification:notification event:@"$campaign_delivery"];
}


@end

#pragma mark - NSRunLoop

static _ZGRunLoopThread *networkThread = nil;
static NSRunLoop *networkRunLoop = nil;

@implementation NSRunLoop (ZGNotificationManager)

+ (NSRunLoop *)zgNetworkRunLoop {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        networkThread = [[_ZGRunLoopThread alloc] init];
        networkThread.name = @"io.zhuge.push.NetworkThread";
        [networkThread start];
        networkRunLoop = networkThread.runLoop;
    });
    
    return networkRunLoop;
}

@end


@implementation _ZGRunLoopThread {
    dispatch_group_t _waitGroup;
}

@synthesize runLoop = _runLoop;

- (id)init {
    self = [super init];
    if (self) {
        _waitGroup = dispatch_group_create();
        dispatch_group_enter(_waitGroup);
    }
    return self;
}

- (void)main {
    @autoreleasepool {
        _runLoop = [NSRunLoop currentRunLoop];
        dispatch_group_leave(_waitGroup);
        
        NSTimer *timer = [[NSTimer alloc] initWithFireDate:[NSDate distantFuture] interval:0.0 target:nil selector:nil userInfo:nil repeats:NO];
        [_runLoop addTimer:timer forMode:NSDefaultRunLoopMode];
        
        while ([_runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]) {
            
        }
        assert(NO);
    }
}

- (NSRunLoop *)runLoop {
    dispatch_group_wait(_waitGroup, DISPATCH_TIME_FOREVER);
    return _runLoop;
}

@end
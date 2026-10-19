#import "SparksLicense.h"
#import <CommonCrypto/CommonHMAC.h>
#import <dlfcn.h>
#import <math.h>
#import "SparksLicensePolicy.h"

// 与已部署后台的 fmt=2 协议兼容；签名覆盖设备、产品、状态、专属 ID 和到期时间。
static NSString *const kSigningKey = @"358ce5f8d7d9a383ea7fd61a952de84aa2c6325cd12f4215014bbe4234b5e68a";
NSString *const SparksLicenseChangedNotification = @"SparksLicenseChanged";
static NSString *sStatus = @"";
static NSString *sError = nil;
static double sVerifiedUptime = 0, sServerNow = 0, sExpire = 0, sLastAttempt = -30;
static BOOL sChecking = NO;
// 仅保留本进程内的已验签授权；重启必须联网，避免跨重启单调时钟重置延长宽限。
static const double kGrace = 72 * 3600;

@implementation SparksLicense
// 固定首次有效标识，避免序列号权限变化/IDFV 变化导致后台出现多个设备。
// 保存在独立配置键，不参与插件配置备份导入。卸载抖音或清除其数据后可能需要重新授权。
+ (BOOL)validDeviceID:(NSString *)value {
    if (![value isKindOfClass:[NSString class]] || value.length < 6 || value.length > 64 ||
        [value.uppercaseString hasPrefix:@"UNKNOWN"] ||
        [value isEqualToString:@"00000000-0000-0000-0000-000000000000"]) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}
+ (NSString *)deviceID {
    static NSString *identifier;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *saved = [defaults stringForKey:@"sparks.license.device-id.v1"];
        if ([self validDeviceID:saved]) {
            identifier = [saved copy];
            return;
        }
        NSString *serial = nil;
        void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
        if (h) {
            CFTypeRef (*copyAnswer)(CFStringRef) = (CFTypeRef (*)(CFStringRef))dlsym(h, "MGCopyAnswer");
            if (copyAnswer) {
                CFTypeRef answer = copyAnswer(CFSTR("SerialNumber"));
                if (answer) {
                    if (CFGetTypeID(answer) == CFStringGetTypeID()) serial = [(__bridge NSString *)answer copy];
                    CFRelease(answer);
                }
            }
            dlclose(h);
        }
        if ([self validDeviceID:serial]) identifier = serial;
        else {
            NSString *vendorID = UIDevice.currentDevice.identifierForVendor.UUIDString;
            if ([self validDeviceID:vendorID]) {
                identifier = vendorID;
                SparksLog(@"授权：序列号不可用，已使用并保存应用设备标识");
            } else {
                identifier = NSUUID.UUID.UUIDString;
                SparksLog(@"授权：系统设备标识不可用，已生成并保存本机安装标识");
            }
        }
        [defaults setObject:identifier forKey:@"sparks.license.device-id.v1"];
        [defaults synchronize];
    });
    return identifier;
}
+ (BOOL)isActive {
    return SpLicenseAllowsSend([sStatus isEqualToString:@"ok"], sVerifiedUptime,
        NSProcessInfo.processInfo.systemUptime, sServerNow, sExpire, kGrace);
}
+ (NSString *)statusText {
    if ([self isActive]) {
        NSString *expiry = sExpire == 0 ? @"永久" : [NSDateFormatter localizedStringFromDate:
            [NSDate dateWithTimeIntervalSince1970:sExpire] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterNoStyle];
        return [NSString stringWithFormat:@"已授权 · %@%@", expiry, sError ? @" · 离线宽限" : @""];
    }
    if ([sStatus isEqualToString:@"pending"]) return @"待审核 · 请联系管理员开通";
    if ([sStatus isEqualToString:@"blocked"]) return @"已封禁 · 请联系管理员";
    if ([sStatus isEqualToString:@"expired"] || ([sStatus isEqualToString:@"ok"] && sExpire > 0 &&
        sServerNow + NSProcessInfo.processInfo.systemUptime - sVerifiedUptime >= sExpire)) return @"已到期 · 请续期";
    if (sChecking) return @"正在验证授权";
    return sError ?: @"未验证 · 点击刷新授权";
}
+ (void)notify {
    [[NSNotificationCenter defaultCenter] postNotificationName:SparksLicenseChangedNotification object:nil];
}
+ (void)checkNow {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self checkNow]; });
        return;
    }
    double uptime = NSProcessInfo.processInfo.systemUptime;
    if (sChecking || uptime - sLastAttempt < 30) return;
    sLastAttempt = uptime;
    if (![self deviceID].length) {
        sError = @"无法读取设备标识 · 无法验证授权";
        SparksLog(@"⚠️ %@", sError);
        [self notify];
        return;
    }
    sChecking = YES;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://fudai-auth.pages.dev/api/v1/check"]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 15;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"udid": [self deviceID],
        @"product": @"sparks", @"version": SPARKS_VER, @"fmt": @2} options:0 error:nil];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [self notify];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:
        ^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            sChecking = NO;
            if (error || ![response isKindOfClass:[NSHTTPURLResponse class]] ||
                ((NSHTTPURLResponse *)response).statusCode != 200 || !data.length) {
                sError = @"授权服务暂不可用 · 请联网重试";
            } else if (![self acceptResponse:data]) {
                // 无效响应不替换已验签结果，也不延长离线宽限。
                sError = @"授权响应校验失败 · 请检查网络或联系管理员";
            } else sError = nil;
            SparksLog(@"授权：%@", [self statusText]);
            [self notify];
        });
    }] resume];
}
+ (BOOL)acceptResponse:(NSData *)data {
    id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![j isKindOfClass:[NSDictionary class]]) return NO;
    NSString *status = j[@"status"], *nick = j[@"nick"], *code = j[@"code"], *sig = j[@"sig"];
    id now = j[@"now"], expire = j[@"expires_at"];
    if (![status isKindOfClass:[NSString class]] || ![@[@"ok", @"pending", @"blocked", @"expired"] containsObject:status] ||
        ![nick isKindOfClass:[NSString class]] || ![code isKindOfClass:[NSString class]] || !code.length ||
        ![sig isKindOfClass:[NSString class]] || sig.length != 64 ||
        ![now isKindOfClass:[NSNumber class]] ||
        !(expire == [NSNull null] || [expire isKindOfClass:[NSNumber class]])) return NO;
    double expiry = expire == [NSNull null] ? 0 : [expire doubleValue];
    double serverNow = [now doubleValue];
    if (!isfinite(expiry) || expiry < 0 || floor(expiry) != expiry ||
        !isfinite(serverNow) || serverNow <= 0 || floor(serverNow) != serverNow ||
        fabs(serverNow - NSDate.date.timeIntervalSince1970) > 900) return NO;
    NSString *payload = [NSString stringWithFormat:@"FA1|%@|sparks|%@|%@|%@|%.0f|%.0f",
        [self deviceID], status, nick, code, expiry, serverNow];
    NSData *key = [kSigningKey dataUsingEncoding:NSUTF8StringEncoding];
    NSData *message = [payload dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, message.bytes, message.length, mac);
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(mac); i++) [hex appendFormat:@"%02x", mac[i]];
    unsigned int mismatch = 0;
    NSString *normalized = sig.lowercaseString;
    for (NSUInteger i = 0; i < 64; i++) mismatch |= [hex characterAtIndex:i] ^ [normalized characterAtIndex:i];
    if (mismatch) return NO;
    // pending/blocked/expired 立即撤销此前授权；只有 ok 才能进入宽限。
    sStatus = [status copy];
    sServerNow = serverNow;
    sExpire = expiry;
    sVerifiedUptime = NSProcessInfo.processInfo.systemUptime;
    SparksConfig *cfg = [SparksConfig shared];
    cfg.authCode = code;
    [cfg saveSoon];
    return YES;
}
+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [self checkNow];
            [NSTimer scheduledTimerWithTimeInterval:600 target:self selector:@selector(onTimer:) userInfo:nil repeats:YES];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onTimer:)
                name:UIApplicationDidBecomeActiveNotification object:nil];
        });
    });
}
+ (void)onTimer:(id)sender { [self checkNow]; }
@end

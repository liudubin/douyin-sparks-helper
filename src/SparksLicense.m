//
//  SparksLicense.m
//  本构建已移除联网授权校验。
//
//  原来的实现:启动时向后台注册/验签(fmt=2),失败则 isActive=NO,引擎所有发送入口
//  都被闸门挡住。现在改成纯本地:不联网、不验签、isActive 恒为 YES。
//
//  接口名与通知名保持不变,引擎/面板的调用点一行都不用动 —— 将来要恢复授权,
//  只需把这个文件换回旧版即可。
//
#import "SparksLicense.h"

NSString *const SparksLicenseChangedNotification = @"SparksLicenseChanged";

@implementation SparksLicense

+ (void)start {}

+ (void)checkNow {}

+ (BOOL)isActive { return YES; }

+ (NSString *)statusText { return @"已启用(本地构建·无授权校验)"; }

// 面板"设备标识"那一栏仍然可用:优先用 IDFV,落盘保存,不参与配置备份
+ (NSString *)deviceID {
    static NSString *identifier;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *saved = [defaults stringForKey:@"sparks.license.device-id.v1"];
        if ([saved isKindOfClass:[NSString class]] && saved.length) {
            identifier = [saved copy];
            return;
        }
        NSString *vendorID = UIDevice.currentDevice.identifierForVendor.UUIDString;
        identifier = vendorID.length ? [vendorID copy] : NSUUID.UUID.UUIDString;
        [defaults setObject:identifier forKey:@"sparks.license.device-id.v1"];
    });
    return identifier;
}

@end

#import "SparksConfig.h"
#define SparksLicense SkL
extern NSString *const SparksLicenseChangedNotification;
@interface SparksLicense : NSObject
+ (void)start;
+ (void)checkNow;
+ (BOOL)isActive;
+ (NSString *)statusText;
+ (NSString *)deviceID;
@end

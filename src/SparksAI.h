//
//  SparksAI.h
//  OpenAI 兼容 /chat/completions 客户端(默认智谱 GLM)
//
#import "SparksConfig.h"

@interface SparksAI : NSObject

/// 生成一条发给好友/群聊的问候文本;失败回调 nil(调用方走兜底文案)
/// extra=该目标专属的补充要求(拼在全局风格之后),可为 nil
+ (void)generateForName:(NSString *)name
                 isGroup:(BOOL)isGroup
                   recent:(NSArray<NSString *> *)recent
                     extra:(NSString *)extra
               completion:(void (^)(NSString *text))completion;

/// 连通性/效果测试:生成一条示例
+ (void)testGenerateWithCompletion:(void (^)(NSString *text, NSString *error))completion;

/// 清洗模型输出:去引号/换行/多余空白,长度上限 60
+ (NSString *)sanitize:(NSString *)raw;

@end

//
//  SparksAI.m
//
#import "SparksAI.h"

static NSString *const kSysPrompt =
    @"你帮用户给好友发日常小消息,维护聊天火花(连续聊天标识)。"
     "只输出一条消息正文:口语化、自然随意、像熟人顺手发的,8~25个字,"
     "最多带一个常用emoji,不要客套问好句式,不要解释,不要引号。";

@interface SparksAI ()
+ (void)postSystem:(NSString *)sys user:(NSString *)user maxTokens:(NSInteger)maxTokens
        completion:(void (^)(NSString *))completion;
+ (void)sendRequest:(NSURLRequest *)req attempt:(NSUInteger)attempt maxTokens:(NSInteger)maxTokens
     timeoutRetried:(BOOL)timeoutRetried completion:(void (^)(NSString *))completion;
@end

@implementation SparksAI

+ (void)generateForName:(NSString *)name
                 isGroup:(BOOL)isGroup
                   recent:(NSArray<NSString *> *)recent
                     extra:(NSString *)extra
               completion:(void (^)(NSString *))completion {
    SparksConfig *cfg = [SparksConfig shared];
    if (cfg.aiKey.length == 0) {
        SparksLog(@"⚠️ 未配置 API Key,走兜底文案");
        if (completion) completion(nil);
        return;
    }
    NSMutableString *up = [NSMutableString string];
    if (isGroup) {
        [up appendFormat:@"在抖音群聊「%@」里发一句今天的冒泡消息,能让大家愿意接话,不用@任何人,别太正式。", name.length ? name : @"群聊"];
    } else {
        [up appendFormat:@"给好友「%@」发一条今天的问候,内容要新。", name.length ? name : @"好友"];
    }
    if (cfg.aiExtra.length) [up appendFormat:@"风格要求:%@。", cfg.aiExtra];
    if (extra.length) [up appendFormat:@"对这位好友的额外要求:%@。", extra];
    if (recent.count) [up appendFormat:@"最近发过这些,别重复类似意思:%@。",
                              [recent componentsJoinedByString:@"、"]];
    [self postSystem:kSysPrompt user:up completion:completion];
}

+ (void)testGenerateWithCompletion:(void (^)(NSString *, NSString *))completion {
    // 两个面板入口共用同一个测试锁，包含请求和重试等待时间。
    static BOOL testing = NO;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self testGenerateWithCompletion:completion];
        });
        return;
    }
    if (testing) {
        if (completion) completion(nil, @"测试正在进行，请等待结果，不要重复点击");
        return;
    }
    SparksConfig *cfg = [SparksConfig shared];
    if (cfg.aiKey.length == 0) {
        if (completion) completion(nil, @"未配置 API Key");
        return;
    }
    testing = YES;
    SparksLog(@"AI 接入测试开始：单次超时 90 秒，服务繁忙时最多重试 2 次");
    [self postSystem:kSysPrompt
                user:@"给好友「小明」发一条今天的问候,内容要新。"
          completion:^(NSString *text) {
        testing = NO;
        if (completion) completion(text, text ? nil : @"生成失败,请看日志");
    }];
}

+ (void)postSystem:(NSString *)sys user:(NSString *)user
        completion:(void (^)(NSString *))completion {
    [self postSystem:sys user:user maxTokens:1024 completion:completion];
}

+ (void)postSystem:(NSString *)sys user:(NSString *)user maxTokens:(NSInteger)maxTokens
        completion:(void (^)(NSString *))completion {
    SparksConfig *cfg = [SparksConfig shared];
    NSURL *url = [NSURL URLWithString:cfg.aiURL];
    if (!SparksURLOK(url)) {
        SparksLog(@"⚠️ AI 地址无效(需 https 公网地址):%@", cfg.aiURL);
        if (completion) completion(nil);
        return;
    }
    NSMutableDictionary *body = [@{
        @"model": cfg.aiModel,
        @"messages": @[
            @{@"role": @"system", @"content": sys},
            @{@"role": @"user",   @"content": user},
        ],
        @"temperature": @0.9,
        // 推理模型(DeepSeek-R1 等)思考也计 token:512 会被思考吃光,content 恒空(finish_reason=length)
        @"max_tokens": @(maxTokens > 0 ? maxTokens : 1024),
    } mutableCopy];
    NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 90;
    req.HTTPBody = payload;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", cfg.aiKey]
        forHTTPHeaderField:@"Authorization"];

    [self sendRequest:req attempt:0 maxTokens:maxTokens timeoutRetried:NO completion:completion];
}

+ (void)sendRequest:(NSURLRequest *)req attempt:(NSUInteger)attempt maxTokens:(NSInteger)maxTokens
     timeoutRetried:(BOOL)timeoutRetried completion:(void (^)(NSString *))completion {
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]]
                    ? ((NSHTTPURLResponse *)resp).statusCode : 0;
                BOOL retryable = !err && (status == 429 || status == 500 ||
                    status == 502 || status == 503 || status == 504);
                if (retryable && attempt < 2) {
                    NSTimeInterval delay = attempt == 0 ? 5 : 15;
                    NSString *retryAfter = [(NSHTTPURLResponse *)resp valueForHTTPHeaderField:@"Retry-After"];
                    if (retryAfter.length) {
                        double seconds = retryAfter.doubleValue;
                        if (seconds > 0) delay = MAX(delay, seconds);
                        else {
                            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
                            formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
                            formatter.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss z";
                            NSDate *date = [formatter dateFromString:retryAfter];
                            if (date) delay = MAX(delay, date.timeIntervalSinceNow);
                        }
                    }
                    // 过长的服务端等待要求直接失败，避免无限占用发送队列。
                    if (delay <= 60) {
                        SparksLog(@"⚠️ AI HTTP %ld：服务暂不可用，%.0f 秒后重试 (%lu/2)",
                                  (long)status, delay, (unsigned long)(attempt + 1));
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            [self sendRequest:req attempt:attempt + 1 maxTokens:maxTokens
                                 timeoutRetried:timeoutRetried completion:completion];
                        });
                        return;
                    }
                }
                if (err || !data) {
                    BOOL timedOut = [err.domain isEqualToString:NSURLErrorDomain] && err.code == NSURLErrorTimedOut;
                    // 超时自动重试一次:旧版直接放弃,目标只能发兜底文案,白白浪费一次机会
                    if (timedOut && !timeoutRetried) {
                        SparksLog(@"⚠️ AI 请求超时(90 秒),3 秒后自动重试 1 次");
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            [self sendRequest:req attempt:attempt maxTokens:maxTokens
                               timeoutRetried:YES completion:completion];
                        });
                        return;
                    }
                    if (timedOut) SparksLog(@"⚠️ AI 请求超时(已重试 1 次仍失败),本次使用兜底文案");
                    else SparksLog(@"⚠️ AI 请求失败:%@", err.localizedDescription ?: @"无数据");
                    if (completion) completion(nil);
                    return;
                }
            if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
                NSInteger code = ((NSHTTPURLResponse *)resp).statusCode;
                if (code >= 400) {
                    NSString *bodyStr = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
                    SparksLog(@"⚠️ AI HTTP %ld:%@", (long)code,
                              bodyStr.length > 300 ? [bodyStr substringToIndex:300] : (bodyStr ?: @"空"));
                    if (completion) completion(nil);
                    return;
                }
            }
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:[NSDictionary class]]) {
                NSString *bodyStr = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
                SparksLog(@"⚠️ AI 返回非 JSON:%@", bodyStr.length > 200 ? [bodyStr substringToIndex:200] : (bodyStr ?: @"空"));
                if (completion) completion(nil);
                return;
            }
            NSDictionary *errObj = json[@"error"];
            if ([errObj isKindOfClass:[NSDictionary class]]) {
                SparksLog(@"⚠️ AI 接口报错:%@", errObj[@"message"] ?: errObj);
                if (completion) completion(nil);
                return;
            }
            NSArray *choices = json[@"choices"];
            if ([choices isKindOfClass:[NSArray class]] && choices.count) {
                id choice = choices.firstObject;
                NSDictionary *msg = [choice isKindOfClass:[NSDictionary class]] ? choice[@"message"] : nil;
                if ([msg isKindOfClass:[NSDictionary class]]) {
                    NSString *raw = msg[@"content"];
                    if (![raw isKindOfClass:[NSString class]]) raw = nil;
                    NSString *clean = [self sanitize:raw];
                    if (clean.length < 2) {
                        NSString *reason = choice[@"finish_reason"] ?: @"?";
                        // 被思考吃光 max_tokens 时,翻倍重来一次比直接发兜底文案划算。
                        // 注意作用域:这里在 sendRequest: 的正文里,只有 req,没有 sys/user
                        // (旧写法直接引用 sys/user,编译期就过不去)。改成就地改请求体重发。
                        if ([reason isEqualToString:@"length"] && maxTokens < 4096) {
                            NSInteger next = maxTokens * 2;
                            NSMutableDictionary *body = [NSJSONSerialization
                                JSONObjectWithData:req.HTTPBody
                                           options:NSJSONReadingMutableContainers
                                             error:nil];
                            if ([body isKindOfClass:[NSMutableDictionary class]]) {
                                body[@"max_tokens"] = @(next);
                                NSMutableURLRequest *bigger = [req mutableCopy];
                                bigger.HTTPBody = [NSJSONSerialization dataWithJSONObject:body
                                                                                  options:0 error:nil];
                                SparksLog(@"⚠️ AI 思考耗尽 token(finish_reason=length),max_tokens %ld→%ld 重试 1 次",
                                          (long)maxTokens, (long)next);
                                [self sendRequest:bigger attempt:attempt maxTokens:next
                                   timeoutRetried:timeoutRetried completion:completion];
                                return;
                            }
                        }
                        SparksLog(@"⚠️ AI 未返回有效正文(finish_reason=%@)，使用兜底文案", reason);
                        if (completion) completion(nil);
                        return;
                    }
                    if (completion) completion(clean);
                    return;
                }
            }
            NSString *dump = [json description];
            SparksLog(@"⚠️ AI 返回结构异常:%@", dump.length > 500 ? [dump substringToIndex:500] : dump);
                if (completion) completion(nil);
            });
        }];
    [task resume];
}

+ (NSString *)sanitize:(NSString *)raw {
    if (![raw isKindOfClass:[NSString class]]) return nil;
    NSString *s = [raw stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSCharacterSet *quotes = [NSCharacterSet characterSetWithCharactersInString:@"\"'「」『』“”"];
    while (s.length && [quotes characterIsMember:[s characterAtIndex:0]]) {
        s = [s substringFromIndex:1];
    }
    while (s.length && [quotes characterIsMember:[s characterAtIndex:s.length - 1]]) {
        s = [s substringToIndex:s.length - 1];
    }
    // 多余空白折叠
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    while ([s rangeOfString:@"  "].location != NSNotFound) {
        s = [s stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    if (s.length > 60) {
        NSRange boundary = [s rangeOfComposedCharacterSequenceAtIndex:59];
        s = [s substringToIndex:NSMaxRange(boundary)];
    }
    return s;
}

@end

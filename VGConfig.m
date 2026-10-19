#import "VGConfig.h"
#import <QuartzCore/QuartzCore.h>

NSString *const VGDomain = @"com.shiyi.volumeglass";
NSString *const VGChangedNotification = @"com.shiyi.volumeglass-changed";

static id VGValue(NSString *key) {
    static CFTimeInterval lastSync = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastSync > 0.5) {   // 布局回调里会被高频调用，同步要限流
        lastSync = now;
        CFPreferencesAppSynchronize((__bridge CFStringRef)VGDomain);
    }
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)VGDomain);
    return CFBridgingRelease(v);
}

static BOOL VGBool(NSString *key, BOOL fallback) {
    id v = VGValue(key);
    if (!v) return fallback;
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return fallback;
}

static double VGDouble(NSString *key, double fallback) {
    id v = VGValue(key);
    if (!v) return fallback;
    if ([v respondsToSelector:@selector(doubleValue)]) return [v doubleValue];
    return fallback;
}

BOOL    VGEnabled(void)           { return VGBool(@"Enabled", YES); }
BOOL    VGRimEnabled(void)        { return VGBool(@"Rim", NO); }
BOOL    VGExtraBlur(void)         { return VGBool(@"ExtraBlur", NO); }
BOOL    VGApplyToBrightness(void) { return VGBool(@"Brightness", NO); }
BOOL    VGDebugEnabled(void)      { return VGBool(@"Debug", NO); }
BOOL    VGAutoCapsule(void)       { return VGBool(@"AutoCapsule", YES); }
BOOL    VGSlideIn(void)           { return VGBool(@"SlideIn", YES); }
BOOL    VGKillHalo(void)          { return VGBool(@"KillHalo", NO); }
BOOL    VGReplaceSkin(void)       { return VGBool(@"ReplaceSkin", YES); }

CGFloat VGRadius(void) {
    double r = VGDouble(@"Radius", 26.0);
    if (r < 0) r = 0;
    if (r > 60) r = 60;
    return (CGFloat)r;
}

CGFloat VGCornerPercent(void) {
    double p = VGDouble(@"CornerPercent", 100.0);
    if (p < 0) p = 0;
    if (p > 100) p = 100;
    return (CGFloat)p;
}

CGFloat VGTintAlpha(void) {
    double a = VGDouble(@"Tint", 0.0);
    if (a < 0) a = 0;
    if (a > 0.6) a = 0.6;
    return (CGFloat)a;
}

NSInteger VGLevelUp(void) {
    double n = VGDouble(@"LevelUp", 0.0);
    if (n < 0) n = 0;
    if (n > 4) n = 4;
    return (NSInteger)n;
}

NSString *VGClassOverride(void) {
    id v = VGValue(@"ClassOverride");
    if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    return nil;
}

// 版本升级时铺一遍新默认值。
// 用户的 UserDefaults 里存着老版本的 Tint=0.06 / Rim=YES / KillHalo=YES，
// 这些值会盖住新默认值 —— 光改代码里的 fallback 是不生效的。
// 这里用 CfgVer 做一次迁移，把 0.4.0 该有的默认铺进去。
void VGConfigMigrate(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFStringRef dom = (__bridge CFStringRef)VGDomain;
        CFStringRef verKey = CFSTR("CfgVer");

        CFPropertyListRef v = CFPreferencesCopyAppValue(verKey, dom);
        NSInteger cur = v ? [(__bridge id)v integerValue] : 0;
        if (v) CFRelease(v);
        if (cur >= 4) return;

        void (^put)(NSString *, id) = ^(NSString *k, id val) {
            CFPreferencesSetAppValue((__bridge CFStringRef)k,
                                     (__bridge CFPropertyListRef)val, dom);
        };
        put(@"CornerPercent", @100.0);
        put(@"Tint",          @0.0);     // 默认不额外加白，保持原生外观
        put(@"Rim",           @NO);      // 默认不描边 —— 那圈边就是之前的"尖尖的"
        put(@"ExtraBlur",     @NO);
        put(@"KillHalo",      @NO);      // 现在不动形状，也就不需要清外发光
        put(@"ReplaceSkin",   @YES);
        put(@"AutoCapsule",   @YES);
        put(@"SlideIn",       @YES);
        put(@"Brightness",    @NO);
        put(@"LevelUp",       @0);
        put(@"CfgVer",        @4);
        CFPreferencesAppSynchronize(dom);
    });
}

void VGLog(NSString *fmt, ...) {
    // SpringBoard 里早就缓存成"关"，按音量键永远看不到输出。
    static CFTimeInterval lastCheck = -1;
    static int cachedDebug = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (lastCheck < 0 || now - lastCheck > 1.0) {
        lastCheck = now;
        cachedDebug = VGDebugEnabled() ? 1 : 0;
    }
    if (cachedDebug != 1) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[VolumeGlass] %@", msg);
}

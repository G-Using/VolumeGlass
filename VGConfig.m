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
BOOL    VGRimEnabled(void)        { return VGBool(@"Rim", YES); }
BOOL    VGExtraBlur(void)         { return VGBool(@"ExtraBlur", NO); }
BOOL    VGApplyToBrightness(void) { return VGBool(@"Brightness", NO); }
BOOL    VGDebugEnabled(void)      { return VGBool(@"Debug", NO); }
BOOL    VGAutoCapsule(void)       { return VGBool(@"AutoCapsule", YES); }
BOOL    VGSlideIn(void)           { return VGBool(@"SlideIn", YES); }
BOOL    VGKillHalo(void)          { return VGBool(@"KillHalo", YES); }
BOOL    VGReplaceSkin(void)       { return VGBool(@"ReplaceSkin", YES); }
BOOL    VGHideGlass(void)         { return VGBool(@"HideGlass", NO); }
BOOL    VGMarkFrames(void)        { return VGBool(@"MarkFrames", NO); }
BOOL    VGDeepClean(void)         { return VGBool(@"DeepClean", NO); }
BOOL    VGFillNarrow(void)        { return VGBool(@"FillNarrow", NO); }

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
    double a = VGDouble(@"Tint", 0.06);
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

void VGLog(NSString *fmt, ...) {
    // 以前这里把 Debug 只读一次，结果设置里打开日志之后
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

#import "VGDecor.h"
#import "VGConfig.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>

#pragma mark - 统一的圆角入口

// 胶囊和圆角矩形的曲率不是一回事。
// cornerRadius 正好等于短边一半时，continuous 会让四个角的弧在边的中线上互相挤压，
// 收口处挤出一个"尖点"——收缩态只有 7pt 宽时最明显，整条会变成针尖形透镜。
// 所以：胶囊一律 circular，continuous 只留给真正的圆角矩形。
// 半径同时硬夹到「短边一半 - 0.5」，永远不许等于或超过一半。
static void VGSetCorner(CALayer *l, CGFloat radius, CGSize size) {
    if (!l) return;
    CGFloat shortSide = MIN(size.width, size.height);
    CGFloat maxR = shortSide * 0.5;
    if (maxR <= 0.5) { l.cornerRadius = 0; return; }

    CGFloat r = MIN(radius, maxR - 0.5);
    if (r < 0) r = 0;
    l.cornerRadius = r;
    l.cornerCurve  = (r >= maxR - 1.0) ? @"circular" : @"continuous";
    l.masksToBounds = YES;
}

#pragma mark - 可选：我们自己的底色层（默认关闭，开了会盖住系统材质）

static UIBezierPath *VGRingPath(CGRect rect, CGFloat radius, CGFloat width) {
    UIBezierPath *outer = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
    CGRect innerRect = CGRectInset(rect, width, width);
    if (innerRect.size.width <= 0 || innerRect.size.height <= 0) return outer;
    UIBezierPath *inner = [UIBezierPath bezierPathWithRoundedRect:innerRect
                                                    cornerRadius:MAX(radius - width, 0.5)];
    [outer appendPath:inner];
    outer.usesEvenOddFillRule = YES;
    return outer;
}

@interface VGGlassBackdrop : UIView
- (void)applyRadius:(CGFloat)radius tint:(CGFloat)tintAlpha blur:(BOOL)blur;
@end

@implementation VGGlassBackdrop {
    CALayer *_tint;
    CAGradientLayer *_highlight;
    UIVisualEffectView *_blur;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = YES;

        _blur = [[UIVisualEffectView alloc] initWithEffect:nil];
        _blur.userInteractionEnabled = NO;
        _blur.clipsToBounds = YES;
        _blur.hidden = YES;
        [self addSubview:_blur];

        _tint = [CALayer layer];
        _tint.backgroundColor = [UIColor clearColor].CGColor;
        [self.layer addSublayer:_tint];

        _highlight = [CAGradientLayer layer];
        _highlight.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.10].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.03].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.00].CGColor
        ];
        _highlight.locations = @[@0.0, @0.25, @0.70];
        _highlight.startPoint = CGPointMake(0.5, 0.0);
        _highlight.endPoint = CGPointMake(0.5, 1.0);
        _highlight.hidden = YES;
        [self.layer addSublayer:_highlight];
    }
    return self;
}

- (void)applyRadius:(CGFloat)radius tint:(CGFloat)tintAlpha blur:(BOOL)blur {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    VGSetCorner(self.layer, radius, self.bounds.size);

    _tint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:tintAlpha].CGColor;
    _tint.frame = self.bounds;
    VGSetCorner(_tint, radius, self.bounds.size);

    _highlight.frame = CGRectMake(0, 0, self.bounds.size.width, self.bounds.size.height * 0.55);

    // 底色为 0 就整层不画：默认就该是系统原样，不额外加白
    if (tintAlpha <= 0.001) {
        _highlight.hidden = YES;
        self.hidden = YES;
    } else {
        self.hidden = NO;
        _highlight.hidden = NO;
        CGFloat hi = MIN(tintAlpha * 1.6, 0.14);
        _highlight.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:hi].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:hi * 0.3].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor
        ];
    }

    [CATransaction commit];

    if (blur) {
        if (!_blur.effect) {
            _blur.effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
        }
        _blur.hidden = NO;
        _blur.frame = self.bounds;
        VGSetCorner(_blur.layer, radius, self.bounds.size);
    } else {
        _blur.hidden = YES;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _tint.frame = self.bounds;
    _highlight.frame = CGRectMake(0, 0, self.bounds.size.width, self.bounds.size.height * 0.55);
    _blur.frame = self.bounds;
    [CATransaction commit];
}

@end

#pragma mark - 可选：描边环

@interface VGRimView : UIView
- (void)applyRadius:(CGFloat)radius;
@end

@implementation VGRimView {
    CAGradientLayer *_gradient;
    CAShapeLayer *_ring;
    CGSize _lastSize;
    CGFloat _lastRadius;
    BOOL _hasPath;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];

        _gradient = [CAGradientLayer layer];
        _gradient.type = kCAGradientLayerConic;
        _gradient.startPoint = CGPointMake(0.5, 0.5);
        _gradient.endPoint = CGPointMake(0.5, 0.0);
        _gradient.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.30].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.03].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.14].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.02].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.30].CGColor
        ];
        _gradient.locations = @[@0.0, @0.22, @0.50, @0.78, @1.0];

        _ring = [CAShapeLayer layer];
        _ring.fillRule = kCAFillRuleEvenOdd;
        _ring.fillColor = [UIColor blackColor].CGColor;
        _gradient.mask = _ring;
        [self.layer addSublayer:_gradient];
    }
    return self;
}

- (void)applyRadius:(CGFloat)radius {
    if (_hasPath && fabs(radius - _lastRadius) < 0.01 &&
        CGSizeEqualToSize(_lastSize, self.bounds.size)) return;
    _hasPath = YES;
    _lastRadius = radius;
    _lastSize = self.bounds.size;

    // 环宽和透明度随短边自适应：7pt 宽的条上 1pt 环占 14%，看着就是一圈灰边
    CGFloat minSide = MIN(self.bounds.size.width, self.bounds.size.height);
    CGFloat w = MIN(MAX(minSide * 0.045, 0.4), 1.0);
    CGFloat fade = MAX(MIN(1.0, minSide / 28.0), 0.10);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _gradient.frame = self.bounds;
    _gradient.opacity = (float)fade;
    _ring.frame = self.bounds;
    _ring.path = VGRingPath(CGRectInset(self.bounds, w * 0.5, w * 0.5),
                            MAX(radius - w * 0.5, 0.5), w).CGPath;
    [CATransaction commit];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _hasPath = NO;
    [self applyRadius:_lastRadius];
}

@end

#pragma mark - 状态

@interface VGDecorState : NSObject
@property (nonatomic, weak) UIView *host;
@property (nonatomic, strong) VGGlassBackdrop *backdrop;
@property (nonatomic, strong) VGRimView *rim;
@property (nonatomic, assign) CGFloat origRadius;
@property (nonatomic, assign) BOOL origMasks;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *skinSnapshots; // 被倒圆角的原生底板
@property (nonatomic, assign) CGFloat lastRadius;
@property (nonatomic, assign) CGSize lastSize;
@end

@implementation VGDecorState
@end

static const void *kVGStateKey = &kVGStateKey;
static __weak UIView *gLastHost = nil;

static NSHashTable *VGDecoratedTable(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

// 两条 hook 路径可能命中父子两层，避免叠两圈
static BOOL VGHasDecoratedRelative(UIView *host) {
    NSHashTable *table = VGDecoratedTable();
    for (UIView *v = host.superview; v; v = v.superview) {
        if ([table containsObject:v]) return YES;
    }
    for (UIView *s in host.subviews) {
        if ([table containsObject:s]) return YES;
    }
    return NO;
}

static BOOL VGIsOurs(UIView *v) {
    return [NSStringFromClass([v class]) hasPrefix:@"VG"];
}

#pragma mark - 把系统原生底板改成圆角（不隐藏、不替换）

// 【关键决定】
// 0.2.x 的做法是「把系统那层材质 alpha=0 关掉，自己再画一层玻璃」。
// 结果：材质一没，收缩态 7pt 宽的那条只剩 1.5pt 描边 + 白色填充，
// 看着就是一条带尖角的细线 —— 无论怎么调圆角都救不回来，
// 因为**系统的材质本身就是那层"随壁纸变化的半透明底色"**，关掉它等于把底子拆了。
//
// 现在的做法：**一层都不关**。保留 MTMaterialView 原生材质（它就是 iOS 原样的外观），
// 只在它身上设 cornerRadius / masksToBounds，把方角改成圆角。
// 于是收缩态 = 原生胶囊（两端半圆），展开态 = 原生材质 + 我们给的圆角。

static BOOL VGLooksLikeSkin(UIView *v) {
    NSString *cn = NSStringFromClass([v class]);
    if (!cn.length) return NO;
    static NSArray<NSString *> *needles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        needles = @[@"MTMaterial", @"Platter", @"Backdrop", @"VisualEffect",
                    @"EffectView", @"MaterialView"];
    });
    for (NSString *n in needles) {
        if ([cn containsString:n]) return YES;
    }
    return NO;
}

// 里面装着文字/图标的不能用 masksToBounds 裁，否则会把数字图标切掉
static BOOL VGCarriesContent(UIView *v) {
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:[UILabel class]] ||
            [s isKindOfClass:[UIImageView class]] ||
            [s isKindOfClass:[UITextView class]]) return YES;
        if (VGCarriesContent(s)) return YES;
    }
    return NO;
}

// 收集"需要倒圆角"的层：
//   1) 和宿主平级、尺寸不小于宿主的层（真机结构里是两个 MTMaterialView
//      再加一个纯描边的 UIView，三个都一样大）
//   2) 宿主内部那层材质（槽），它是白的填充条的对比来源，只倒角不隐藏
static NSArray<UIView *> *VGFindTargets(UIView *host) {
    NSMutableArray<UIView *> *out = [NSMutableArray array];
    if (!host) return out;
    CGSize hs = host.bounds.size;

    UIView *sup = host.superview;
    if (sup) {
        for (UIView *sib in sup.subviews) {
            if (sib == host || sib.hidden || VGIsOurs(sib)) continue;
            CGSize s = sib.bounds.size;
            if (s.width <= 0.5 || s.height <= 0.5) continue;
            if (s.width > 700 || s.height > 700) continue;
            if (s.width + 1 < hs.width || s.height + 1 < hs.height) continue;
            if (s.width > hs.width + 80 || s.height > hs.height + 80) continue;
            [out addObject:sib];
        }
    }

    for (UIView *sub in host.subviews) {
        if (VGIsOurs(sub)) continue;
        if (!VGLooksLikeSkin(sub)) continue;
        if (VGCarriesContent(sub)) continue;
        CGSize s = sub.bounds.size;
        if (s.width <= 0.5 || s.height <= 0.5) continue;
        [out addObject:sub];
    }
    return out;
}

static NSDictionary *VGSkinSnapshot(UIView *v) {
    CALayer *l = v.layer;
    return @{
        @"v"  : v,
        @"r"  : @(l.cornerRadius),
        @"cc" : (l.cornerCurve ?: @""),
        @"m"  : @(l.masksToBounds),
        @"bw" : @(l.borderWidth),
        @"bc" : l.borderColor ? (id)[UIColor colorWithCGColor:l.borderColor] : (id)[NSNull null],
    };
}

static void VGRestoreSkin(NSDictionary *d) {
    UIView *v = d[@"v"];
    if (!v) return;
    CALayer *l = v.layer;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    l.cornerRadius  = [d[@"r"] doubleValue];
    NSString *cc = d[@"cc"];
    if (cc.length) l.cornerCurve = cc;
    l.masksToBounds = [d[@"m"] boolValue];
    l.borderWidth   = [d[@"bw"] doubleValue];
    id bc = d[@"bc"];
    l.borderColor = [bc isKindOfClass:[UIColor class]] ? ((UIColor *)bc).CGColor : NULL;
    [CATransaction commit];
}

static void VGApplyNativeRounding(UIView *host, CGFloat radius, VGDecorState *st) {
    if (!st || !host) return;

    if (!VGReplaceSkin()) {
        for (NSDictionary *d in st.skinSnapshots) VGRestoreSkin(d);
        [st.skinSnapshots removeAllObjects];
        return;
    }

    if (!st.skinSnapshots) st.skinSnapshots = [NSMutableArray array];
    CGSize hs = host.bounds.size;

    NSArray<UIView *> *targets = VGFindTargets(host);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (UIView *v in targets) {
        if (v == host) continue;
        if ([host isDescendantOfView:v]) continue;

        BOOL known = NO;
        for (NSDictionary *d in st.skinSnapshots) {
            if (d[@"v"] == v) { known = YES; break; }
        }
        if (!known) [st.skinSnapshots addObject:VGSkinSnapshot(v)];

        // 比宿主大的层（外皮）要按外扩量加半径，否则弧线对不齐
        CGSize s = v.bounds.size;
        CGFloat pad = MIN(s.width - hs.width, s.height - hs.height) * 0.5;
        if (pad < 0) pad = 0;
        VGSetCorner(v.layer, radius + pad, s);

        // 那圈 1.5pt 描边在 7pt 宽的条上就是全部可见内容，必须清掉
        v.layer.borderWidth = 0;

        VGLog(@"round skin: %@ %.0fx%.0f r=%.1f", NSStringFromClass([v class]),
              s.width, s.height, v.layer.cornerRadius);
    }
    [CATransaction commit];
}

#pragma mark - 结构诊断（写进设置面板，用户截图即可）

static NSString *VGDiagLine(UIView *v, NSString *tag) {
    UIColor *bg = v.backgroundColor;
    NSString *bgs = @"nil";
    if (bg) bgs = (CGColorGetAlpha(bg.CGColor) < 0.01) ? @"clear" : @"BG";
    CGSize s = v.bounds.size;
    return [NSString stringWithFormat:@"%@ %@ %.0fx%.0f %@ b%.1f r%.1f a%.2f",
            tag, NSStringFromClass([v class]), s.width, s.height, bgs,
            v.layer.borderWidth, v.layer.cornerRadius, v.alpha];
}

static void VGSaveDiag(UIView *host) {
    if (!host) return;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"host %@ %.0fx%.0f",
                      NSStringFromClass([host class]),
                      host.bounds.size.width, host.bounds.size.height]];

    NSUInteger n = 0;
    for (UIView *s in host.subviews) {
        if (n++ >= 6) break;
        [lines addObject:VGDiagLine(s, @" .")];
    }
    n = 0;
    UIView *sup = host.superview;
    if (sup) {
        for (UIView *s in sup.subviews) {
            if (s == host) continue;
            if (n++ >= 6) break;
            [lines addObject:VGDiagLine(s, @" s")];
        }
    }
    UIView *anc = sup;
    for (int i = 0; i < 5 && anc; i++, anc = anc.superview) {
        [lines addObject:VGDiagLine(anc, [NSString stringWithFormat:@"^%d", -(i + 1)])];
    }

    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:VGDomain];
    [d setObject:lines forKey:@"Diag"];
    [d synchronize];
}

#pragma mark - 收尾

void VGTeardownHUDView(UIView *host) {
    if (!host) return;
    VGDecorState *st = objc_getAssociatedObject(host, kVGStateKey);
    if (!st) return;

    [st.backdrop removeFromSuperview];
    [st.rim removeFromSuperview];

    for (NSDictionary *d in st.skinSnapshots) VGRestoreSkin(d);
    [st.skinSnapshots removeAllObjects];

    host.layer.cornerRadius = st.origRadius;
    host.layer.masksToBounds = st.origMasks;

    objc_setAssociatedObject(host, kVGStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSHashTable *set = VGDecoratedTable();
    [set removeObject:host];
}

// 安全阀：只有"HUD 尺寸"的视图才配装饰
static BOOL VGSizeLooksLikeHUD(UIView *host) {
    CGSize size = host.bounds.size;
    if (size.width <= 0 || size.height <= 0) return NO;
    if (size.width > 420 || size.height > 420) return NO;

    CGSize win = host.window.bounds.size;
    if (win.width > 0 && win.height > 0) {
        if (fabs(size.width - win.width) < 2 && fabs(size.height - win.height) < 2) return NO;
    }
    return YES;
}

static BOOL VGStyleActive(void) {
    return VGEnabled() && (VGAutoCapsule() || VGRadius() > 0.5);
}

// 圆角按"占短边半径的百分比"算：100 = 完全胶囊
static CGFloat VGResolvedRadius(UIView *host) {
    CGSize s = host.bounds.size;
    CGFloat half = MIN(s.width, s.height) * 0.5;
    if (half <= 0) return VGRadius();

    if (!VGAutoCapsule() && VGRadius() > 0.5) return MIN(VGRadius(), half);

    CGFloat pct = VGCornerPercent();
    if (pct < 6) pct = 6;
    if (pct > 100) pct = 100;
    return half * (pct / 100.0);
}

// 从侧面滑入：只加 CAAnimation，不改 model 值
static void VGPlaySlideIn(UIView *host) {
    CALayer *layer = host.layer;
    CGFloat offset = host.bounds.size.width + 24;

    CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    move.fromValue = @(-offset);
    move.toValue = @0;
    move.duration = 0.34;
    move.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [layer addAnimation:move forKey:@"vg.slideIn"];

    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0.0;
    fade.toValue = @1.0;
    fade.duration = 0.20;
    [layer addAnimation:fade forKey:@"vg.fadeIn"];
}

void VGDecorateHUDView(UIView *host) {
    if (!host) return;

    if (!VGStyleActive()) {
        VGTeardownHUDView(host);
        return;
    }

    if (!VGSizeLooksLikeHUD(host)) {
        if (host.bounds.size.width > 420 || host.bounds.size.height > 420) {
            VGLog(@"skip %@ bounds=%@ (looks not HUD, lower LevelUp)",
                  NSStringFromClass([host class]), NSStringFromCGRect(host.bounds));
        }
        return;
    }

    CGFloat radius = VGResolvedRadius(host);
    gLastHost = host;

    VGDecorState *st = objc_getAssociatedObject(host, kVGStateKey);
    if (!st && VGHasDecoratedRelative(host)) {
        VGLog(@"skip %@ (relative already decorated)", NSStringFromClass([host class]));
        return;
    }

    if (!st) {
        st = [VGDecorState new];
        st.host = host;
        st.origRadius = host.layer.cornerRadius;
        st.origMasks = host.layer.masksToBounds;
        st.skinSnapshots = [NSMutableArray array];

        VGGlassBackdrop *back = [[VGGlassBackdrop alloc] initWithFrame:host.bounds];
        back.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        // 夹在"背景材质之上、内容(图标/数字)之下"
        NSUInteger insertAt = 0;
        for (NSUInteger i = 0; i < host.subviews.count; i++) {
            if (VGLooksLikeSkin(host.subviews[i])) insertAt = i + 1;
            else break;
        }
        [host insertSubview:back atIndex:insertAt];

        VGRimView *rim = [[VGRimView alloc] initWithFrame:host.bounds];
        rim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host addSubview:rim];

        st.backdrop = back;
        st.rim = rim;

        objc_setAssociatedObject(host, kVGStateKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSHashTable *set = VGDecoratedTable();
        [set addObject:host];

        VGLog(@"decorate host=%@ bounds=%@", NSStringFromClass([host class]),
              NSStringFromCGRect(host.bounds));

        VGSaveDiag(host);

        if (VGSlideIn()) VGPlaySlideIn(host);
    }

    [st.backdrop setFrame:host.bounds];
    [st.rim setFrame:host.bounds];

    // 宿主自己也要圆（它可能就是那个看得见的"条"）
    host.layer.cornerRadius = radius;
    host.layer.cornerCurve  = (radius >= MIN(host.bounds.size.width,
                                             host.bounds.size.height) * 0.5 - 1.0)
                              ? @"circular" : @"continuous";
    host.layer.masksToBounds = YES;

    // 核心：把系统原生底板改成圆角，**不隐藏、不改 alpha**
    VGApplyNativeRounding(host, radius, st);

    // 可选自绘层，默认都是关的（Tint=0 / Rim=off），所以不影响原生外观
    CGFloat tint = VGTintAlpha();
    BOOL blur = VGExtraBlur();
    [st.backdrop applyRadius:radius tint:tint blur:blur];
    st.rim.hidden = !VGRimEnabled();
    [st.rim applyRadius:radius];

    st.lastRadius = radius;
    st.lastSize = host.bounds.size;
}

void VGRefreshDecor(void) {
    NSHashTable *set = VGDecoratedTable();
    NSArray *all = set.allObjects;
    for (UIView *v in all) VGTeardownHUDView(v);

    UIView *host = gLastHost;
    if (!host) return;
    if (!VGStyleActive()) return;
    VGDecorateHUDView(host);
}

#import "VGDecor.h"
#import "VGConfig.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>

#pragma mark - 圆角环路径

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

#pragma mark - 玻璃底色（底色 + 顶部高光 + 可选额外模糊）

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
        self.clipsToBounds = YES;      // 防止高光/模糊溢出边界形成"虚影"

        _blur = [[UIVisualEffectView alloc] initWithEffect:nil];
        _blur.userInteractionEnabled = NO;
        _blur.clipsToBounds = YES;
        _blur.hidden = YES;
        [self addSubview:_blur];

        _tint = [CALayer layer];
        _tint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
        [self.layer addSublayer:_tint];

        _highlight = [CAGradientLayer layer];
        _highlight.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.12].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.04].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.00].CGColor
        ];
        _highlight.locations = @[@0.0, @0.25, @0.70];
        _highlight.startPoint = CGPointMake(0.5, 0.0);
        _highlight.endPoint = CGPointMake(0.5, 1.0);
        [self.layer addSublayer:_highlight];
    }
    return self;
}

- (void)applyRadius:(CGFloat)radius tint:(CGFloat)tintAlpha blur:(BOOL)blur {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    self.layer.cornerRadius = radius;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;

    _tint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:tintAlpha].CGColor;
    _tint.frame = self.bounds;
    _tint.cornerRadius = radius;
    _tint.cornerCurve = kCACornerCurveContinuous;
    _tint.masksToBounds = YES;

    _highlight.frame = CGRectMake(0, 0, self.bounds.size.width, self.bounds.size.height * 0.55);

    // 高光跟着底色联动：底色拖到 0 就是完全干净的一层，
    // 否则单看"底色=0 还有虚影"会误判成别的原因。
    if (tintAlpha <= 0.001) {
        _highlight.hidden = YES;
    } else {
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
        _blur.layer.cornerRadius = radius;
        _blur.layer.cornerCurve = kCACornerCurveContinuous;
        _blur.layer.masksToBounds = YES;
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

#pragma mark - 描边环（锥形渐变 + 环形遮罩）

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
    if (_hasPath && radius == _lastRadius && CGSizeEqualToSize(_lastSize, self.bounds.size)) return;
    _hasPath = YES;
    _lastRadius = radius;
    _lastSize = self.bounds.size;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.cornerRadius = radius;
    _gradient.frame = self.bounds;
    _ring.frame = self.bounds;
    _ring.path = VGRingPath(CGRectInset(self.bounds, 0.5, 0.5), MAX(radius - 0.5, 0.5), 1.0).CGPath;
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
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *haloSnapshots;
@property (nonatomic, assign) CGFloat lastHaloRadius;
@end

@implementation VGDecorState
@end

static const void *kVGStateKey = &kVGStateKey;
static const void *kVGSubviewOrigKey = &kVGSubviewOrigKey;
static __weak UIView *gLastHost = nil;

static NSHashTable *VGDecoratedTable(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

// 两条 hook 路径可能命中父子两层，避免叠两圈描边
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

static BOOL VGIsBackgroundLike(UIView *v) {
    NSString *cn = NSStringFromClass([v class]);
    if (cn.length) {
        static NSArray<NSString *> *needles;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            needles = @[@"Material", @"VisualEffect", @"Backdrop", @"Blur",
                        @"EffectView", @"Glass"];
        });
        for (NSString *n in needles) {
            if ([cn containsString:n]) return YES;
        }
    }
    for (CALayer *l in v.layer.sublayers) {
        if ([NSStringFromClass([l class]) containsString:@"Backdrop"]) return YES;
    }
    return NO;
}

#pragma mark - 消除容器自带的外发光（真正的那圈"虚影"）

// 系统 HUD 容器自己带一层阴影/外发光，外面那层皮还是原来那个胶囊形状。
// 我们把里面那层的圆角改小之后，外面这层原胶囊的弧线就会从缝里露出来一圈，
// 看着就是"边缘虚影"。这里把外层一起圆成同样的形状并裁掉，阴影一并清掉。

static NSDictionary *VGSnapshotView(UIView *v) {
    CALayer *l = v.layer;
    return @{
        @"v"  : v,
        @"r"  : @(l.cornerRadius),
        @"cc" : (l.cornerCurve ?: @""),
        @"m"  : @(l.masksToBounds),
        @"so" : @(l.shadowOpacity),
        @"sr" : @(l.shadowRadius),
        @"ow" : @(l.shadowOffset.width),
        @"oh" : @(l.shadowOffset.height),
    };
}

static void VGRestoreView(NSDictionary *d) {
    UIView *v = d[@"v"];
    if (!v) return;
    CALayer *l = v.layer;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    l.cornerRadius  = [d[@"r"] doubleValue];
    // 16.x SDK 里 cornerCurve 就是 NSString*（CALayerCornerCurve），不是枚举
    NSString *cc = d[@"cc"];
    if (cc.length) l.cornerCurve = cc;
    l.masksToBounds = [d[@"m"] boolValue];
    l.shadowOpacity = [d[@"so"] floatValue];
    l.shadowRadius  = [d[@"sr"] doubleValue];
    l.shadowOffset  = CGSizeMake([d[@"ow"] doubleValue], [d[@"oh"] doubleValue]);
    l.shadowPath    = nil;
    [CATransaction commit];
}

// host 在 anc 里四周剩下的最小空隙；负数说明 host 伸出了 anc
static CGFloat VGPadAroundHost(UIView *host, UIView *anc) {
    CGRect r = [host convertRect:host.bounds toView:anc];
    CGRect b = anc.bounds;
    if (b.size.width <= 0 || b.size.height <= 0) return -1;
    CGFloat l  = CGRectGetMinX(r) - CGRectGetMinX(b);
    CGFloat rr = CGRectGetMaxX(b) - CGRectGetMaxX(r);
    CGFloat t  = CGRectGetMinY(r) - CGRectGetMinY(b);
    CGFloat bb = CGRectGetMaxY(b) - CGRectGetMaxY(r);
    return MIN(MIN(l, rr), MIN(t, bb));
}

static void VGApplyHaloFix(UIView *host, CGFloat radius, VGDecorState *st) {
    if (!st) return;
    // 布局回调是高频的，参数没变就别每次都拆了重建
    if (st.haloSnapshots.count > 0 && fabs(st.lastHaloRadius - radius) < 0.5) return;
    st.lastHaloRadius = radius;

    if (!st.haloSnapshots) {
        st.haloSnapshots = [NSMutableArray array];
    } else {
        for (NSDictionary *d in st.haloSnapshots) VGRestoreView(d);
        [st.haloSnapshots removeAllObjects];
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    // 宿主自身：圆角之外不该再有任何阴影
    [st.haloSnapshots addObject:VGSnapshotView(host)];
    host.layer.shadowOpacity = 0;
    host.layer.shadowRadius  = 0;
    host.layer.shadowPath    = nil;

    // 往上最多三层：只处理比宿主大 0~26pt 的容器，那才是 HUD 自己的皮。
    // 再大就是窗口级视图了，裁它会连同别的东西一起切掉。
    UIView *anc = host.superview;
    for (NSUInteger i = 0; i < 3 && anc; i++, anc = anc.superview) {
        CGSize s = anc.bounds.size;
        if (s.width <= 0 || s.height <= 0) continue;
        if (s.width > 480 || s.height > 480) break;

        CGFloat pad = VGPadAroundHost(host, anc);
        if (pad < -1.0 || pad > 26.0) continue;

        [st.haloSnapshots addObject:VGSnapshotView(anc)];
        anc.layer.cornerRadius  = radius + MAX(pad, 0);
        anc.layer.cornerCurve   = kCACornerCurveContinuous;
        anc.layer.masksToBounds = YES;
        anc.layer.shadowOpacity = 0;
        anc.layer.shadowRadius  = 0;

        VGLog(@"halo: %@ pad=%.1f -> r=%.1f",
              NSStringFromClass([anc class]), pad, radius + MAX(pad, 0));
    }

    [CATransaction commit];
}

void VGTeardownHUDView(UIView *host) {
    if (!host) return;
    VGDecorState *st = objc_getAssociatedObject(host, kVGStateKey);
    if (!st) return;

    [st.backdrop removeFromSuperview];
    [st.rim removeFromSuperview];

    for (NSDictionary *d in st.haloSnapshots) VGRestoreView(d);
    [st.haloSnapshots removeAllObjects];
    st.lastHaloRadius = 0;

    host.layer.cornerRadius = st.origRadius;
    host.layer.masksToBounds = st.origMasks;

    for (UIView *sub in host.subviews) {
        NSArray *orig = objc_getAssociatedObject(sub, kVGSubviewOrigKey);
        if (!orig) continue;
        sub.layer.cornerRadius = [orig[0] doubleValue];
        sub.layer.masksToBounds = [orig[1] boolValue];
        objc_setAssociatedObject(sub, kVGSubviewOrigKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    objc_setAssociatedObject(host, kVGStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSHashTable *set = VGDecoratedTable();
    [set removeObject:host];
}

// 安全阀：只有"HUD 尺寸"的视图才配装饰。
// 万一向上层数调错、命中了全屏容器，绝不能用全屏白底 + 全屏描边糊一脸。
static BOOL VGSizeLooksLikeHUD(UIView *host) {
    CGSize size = host.bounds.size;
    if (size.width <= 0 || size.height <= 0) return NO;      // 还没 layout，等下一轮
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

// 圆角按"占胶囊半径的百分比"算：100 = 完全胶囊，越小越接近方角。
// 用百分比而不是绝对点数，是因为 HUD 尺寸随机身/横竖屏变化，绝对点数会算飞。
static CGFloat VGResolvedRadius(UIView *host) {
    CGSize s = host.bounds.size;
    CGFloat half = MIN(s.width, s.height) * 0.5;
    if (half <= 0) return VGRadius();

    // 旧版兼容：关掉自动胶囊且填了绝对点数，就用绝对点数
    if (!VGAutoCapsule() && VGRadius() > 0.5) return MIN(VGRadius(), half);

    CGFloat pct = VGCornerPercent();
    if (pct < 6) pct = 6;
    if (pct > 100) pct = 100;
    return half * (pct / 100.0);
}

// 从侧面滑入：只加 CAAnimation，不改 model 值，不会把 HUD 留在错误位置
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

        VGGlassBackdrop *back = [[VGGlassBackdrop alloc] initWithFrame:host.bounds];
        back.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        // 夹在"背景材质之上、内容(图标/数字)之下"：既透出玻璃，又不挡音量显示
        NSUInteger insertAt = 0;
        for (NSUInteger i = 0; i < host.subviews.count; i++) {
            if (VGIsBackgroundLike(host.subviews[i])) insertAt = i + 1;
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

        if (VGSlideIn()) VGPlaySlideIn(host);
    }

    [st.backdrop setFrame:host.bounds];
    [st.rim setFrame:host.bounds];

    host.layer.cornerRadius = radius;
    host.layer.cornerCurve = kCACornerCurveContinuous;
    host.layer.masksToBounds = YES;

    // 材质/模糊层也得跟着圆，否则四角会露出直角
    for (UIView *sub in host.subviews) {
        if (sub == st.backdrop || sub == st.rim) continue;
        if (!VGIsBackgroundLike(sub)) continue;
        if (!objc_getAssociatedObject(sub, kVGSubviewOrigKey)) {
            objc_setAssociatedObject(sub, kVGSubviewOrigKey,
                                     @[@(sub.layer.cornerRadius), @(sub.layer.masksToBounds)],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        sub.layer.cornerRadius = radius;
        sub.layer.cornerCurve = kCACornerCurveContinuous;
        sub.layer.masksToBounds = YES;
    }

    [st.backdrop applyRadius:radius tint:VGTintAlpha() blur:VGExtraBlur()];
    st.rim.hidden = !VGRimEnabled();
    [st.rim applyRadius:radius];

    // 最后再处理外圈：要放在宿主圆角设好之后，不然算出来的 pad 是旧的
    if (VGKillHalo()) {
        VGApplyHaloFix(host, radius, st);
    } else if (st.haloSnapshots.count > 0) {
        // 关掉这个开关时要把之前清掉的阴影还原，不然它会一直"看不见"
        for (NSDictionary *d in st.haloSnapshots) VGRestoreView(d);
        [st.haloSnapshots removeAllObjects];
        st.lastHaloRadius = 0;
    }
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

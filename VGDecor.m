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

        _blur = [[UIVisualEffectView alloc] initWithEffect:nil];
        _blur.userInteractionEnabled = NO;
        _blur.hidden = YES;
        [self addSubview:_blur];

        _tint = [CALayer layer];
        _tint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
        [self.layer addSublayer:_tint];

        _highlight = [CAGradientLayer layer];
        _highlight.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.22].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.06].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.00].CGColor
        ];
        _highlight.locations = @[@0.0, @0.18, @0.55];
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
            (id)[UIColor colorWithWhite:1.0 alpha:0.62].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.05].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.38].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.04].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.62].CGColor
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

void VGTeardownHUDView(UIView *host) {
    if (!host) return;
    VGDecorState *st = objc_getAssociatedObject(host, kVGStateKey);
    if (!st) return;

    [st.backdrop removeFromSuperview];
    [st.rim removeFromSuperview];

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

// 竖条音量条（截图里贴左边缘那个胶囊）：圆角直接取短边一半
static CGFloat VGResolvedRadius(UIView *host) {
    CGSize s = host.bounds.size;
    if (VGAutoCapsule() && MIN(s.width, s.height) > 0) {
        return MIN(s.width, s.height) * 0.5;
    }
    return VGRadius();
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
            VGLog(@"%@ bounds=%@ 不像 HUD，跳过（把向上层数调小）",
                  NSStringFromClass([host class]), NSStringFromCGRect(host.bounds));
        }
        return;
    }

    CGFloat radius = VGResolvedRadius(host);
    gLastHost = host;

    VGDecorState *st = objc_getAssociatedObject(host, kVGStateKey);
    if (!st && VGHasDecoratedRelative(host)) {
        VGLog(@"%@ 的父子层已处理，跳过", NSStringFromClass([host class]));
        return;
    }

    if (!st) {
        st = [VGDecorState new];
        st.host = host;
        st.origRadius = host.layer.cornerRadius;
        st.origMasks = host.layer.masksToBounds;

        VGGlassBackdrop *back = [[VGGlassBackdrop alloc] initWithFrame:host.bounds];
        back.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host addSubview:back];   // 放在内容之上：玻璃本来就在内容上面，alpha 很低不会糊字

        VGRimView *rim = [[VGRimView alloc] initWithFrame:host.bounds];
        rim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host addSubview:rim];

        st.backdrop = back;
        st.rim = rim;

        objc_setAssociatedObject(host, kVGStateKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSHashTable *set = VGDecoratedTable();
        [set addObject:host];

        VGLog(@"装饰 host=%@ bounds=%@", NSStringFromClass([host class]),
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

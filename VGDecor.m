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
            (id)[UIColor colorWithWhite:1.0 alpha:0.24].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.03].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.10].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.02].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.24].CGColor
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

    CGFloat minSide = MIN(self.bounds.size.width, self.bounds.size.height);
    if (minSide <= 0) return;

    // 收缩状态下整条可能只有 8pt 宽，固定 1pt 的环会占掉 12%，
    // 看起来就是"外面套了一圈灰边"。环宽按短边缩（0.5~1.0），越细越淡。
    CGFloat w = MIN(MAX(minSide * 0.045, 0.5), 1.0);
    CGFloat fade = MAX(MIN(1.0, minSide / 28.0), 0.12);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.cornerRadius = radius;
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
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *haloSnapshots;
@property (nonatomic, assign) CGFloat lastHaloRadius;
@property (nonatomic, assign) CGSize lastHaloSize;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *bgSnapshots;  // 被清掉底色的祖先
@property (nonatomic, weak) UIView *nativeSkin;      // 系统自带的那层方形底板
@property (nonatomic, assign) CGFloat origSkinAlpha; // 它原来的透明度
@property (nonatomic, assign) BOOL skinHidden;
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

#pragma mark - 替换原生底板（方底 -> 我们的圆角玻璃）

// 系统音量 HUD 的背板是一块**方形**材质（MTMaterialView 那一类）。
// 我们在它上面画圆角玻璃，圆角外面就露出方形的四个角 —— 这就是那圈"虚影"。
// 正确做法不是把玻璃画得更厚，而是把这层原生底板关掉，
// 让我们的圆角玻璃成为唯一的背板。
//
// 注意：底板通常和滑块**平级**（同一个 superview，在滑块下面），
// 不是祖先。祖先不能设 alpha=0，那会把整个 HUD 一起弄没。

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

static UIView *VGFindNativeSkin(UIView *host) {
    if (!host) return nil;
    CGSize hs = host.bounds.size;

    // 1) 兄弟层：最常见。底板和滑块平级、比滑块大、压在滑块下面。
    UIView *super = host.superview;
    if (super) {
        for (UIView *sib in super.subviews) {
            if (sib == host || sib.hidden) continue;
            if (!VGLooksLikeSkin(sib)) continue;
            CGSize s = sib.bounds.size;
            if (s.width <= 0 || s.height <= 0) continue;
            // 底板至少要把宿主包住，太小的不是它
            if (s.width + 1 < hs.width || s.height + 1 < hs.height) continue;
            return sib;
        }
    }

    // 2) 内部层：有的版本底板是宿主自己的第一个子视图
    for (UIView *sub in host.subviews) {
        if (!VGLooksLikeSkin(sub)) continue;
        CGSize s = sub.bounds.size;
        if (s.width <= 0 || s.height <= 0) continue;
        return sub;
    }

    // 3) 祖先不处理：宿主是它的后代，设 alpha=0 会把整个 HUD 弄没。
    //    那种情况交给下面的"圆角裁切"（VGApplyHaloFix）去处理。
    return nil;
}

static void VGApplySkinReplace(UIView *host, VGDecorState *st) {
    if (!st) return;

    if (!VGReplaceSkin()) {
        if (st.nativeSkin && st.skinHidden) {
            st.nativeSkin.alpha = st.origSkinAlpha;
            st.skinHidden = NO;
        }
        return;
    }

    // weak 失效说明底板被系统重建了，重新找一遍
    if (!st.nativeSkin) {
        UIView *skin = VGFindNativeSkin(host);
        if (!skin || skin == host) return;
        if ([host isDescendantOfView:skin]) return;   // 安全的兜底
        st.nativeSkin = skin;
        st.origSkinAlpha = st.skinHidden ? 1.0 : skin.alpha;
    }

    UIView *skin = st.nativeSkin;
    if (!skin || skin == host) return;
    if (st.skinHidden && fabs(skin.alpha) < 0.001) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    skin.alpha = 0.0;
    [CATransaction commit];
    st.skinHidden = YES;

    VGLog(@"skin replaced: %@", NSStringFromClass([skin class]));
}

#pragma mark - 清掉祖先的底色（那个"框"真正的来源）

// 胶囊外面套着的那圈更大的方框，往往不是独立视图，而是某一层的 backgroundColor。
// 清 backgroundColor 不影响它的子视图，比 alpha=0 安全得多——
// alpha=0 会把整个子树（包括我们自己的宿主和填充条）一起弄没。
// 系统给音量条加的那圈 1px 细边是 layer.borderWidth，不是背景色。
// 收缩状态下整条只有 8pt 宽，1px 边框会占满整个边缘，看着就是一个"框"。
static void VGStripChrome(UIView *v, VGDecorState *st) {
    if (!v || !st) return;
    UIColor *bg = v.backgroundColor;
    BOOL hasBg = (bg != nil && CGColorGetAlpha(bg.CGColor) >= 0.01);
    CGFloat bw = v.layer.borderWidth;
    if (!hasBg && bw <= 0.01) return;

    // 系统可能在每次布局里把边框重设回来，快照只存第一次的原值
    BOOL known = NO;
    for (NSDictionary *d in st.bgSnapshots) {
        if (d[@"v"] == v) { known = YES; break; }
    }
    if (!known) {
        [st.bgSnapshots addObject:@{
            @"v"  : v,
            @"bg" : hasBg ? (id)bg : (id)[NSNull null],
            @"bw" : @(bw)
        }];
    }
    if (hasBg) v.backgroundColor = [UIColor clearColor];
    v.layer.borderWidth = 0;
    VGLog(@"strip chrome: %@ bg=%d bw=%.1f", NSStringFromClass([v class]), (int)hasBg, bw);
}

static void VGClearAncestorBackgrounds(UIView *host, VGDecorState *st) {
    if (!st) return;
    if (!st.bgSnapshots) st.bgSnapshots = [NSMutableArray array];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    VGStripChrome(host, st);

    for (UIView *sub in host.subviews) {
        if (sub == st.backdrop || sub == st.rim) continue;
        VGStripChrome(sub, st);
    }

    UIView *anc = host.superview;
    for (NSUInteger i = 0; i < 4 && anc; i++, anc = anc.superview) {
        CGSize s = anc.bounds.size;
        if (s.width <= 0 || s.height <= 0) continue;
        if (s.width > 600 || s.height > 600) break;

        CGRect hf = [host convertRect:host.bounds toView:anc];
        if (!CGRectContainsRect(CGRectInset(anc.bounds, -1, -1), hf)) continue;

        VGStripChrome(anc, st);
    }

    [CATransaction commit];
}

#pragma mark - 结构诊断（写进设置面板，用户直接截图）

static NSString *VGDiagLine(UIView *v, NSString *tag) {
    UIColor *bg = v.backgroundColor;
    NSString *bgs = @"nil";
    if (bg) bgs = (CGColorGetAlpha(bg.CGColor) < 0.01) ? @"clear" : @"BG";
    CGSize s = v.bounds.size;
    // bw 就是那圈细边框：sw 是这层的子层里有几层带描边
    NSUInteger strokes = 0;
    for (CALayer *l in v.layer.sublayers) {
        if ([l isKindOfClass:[CAShapeLayer class]] && ((CAShapeLayer *)l).lineWidth > 0.01) strokes++;
    }
    return [NSString stringWithFormat:@"%@ %@ %.0fx%.0f %@ bw=%.1f st=%lu",
            tag, NSStringFromClass([v class]), s.width, s.height, bgs,
            v.layer.borderWidth, (unsigned long)strokes];
}

static void VGSaveDiag(UIView *host) {
    if (!host) return;
    CGSize hs = host.bounds.size;
    if (hs.width < 1 || hs.height < 1) return;   // 还没布局，抓了也是 0

    // 展开和收缩是两种尺寸，各自抓一次；最后一次（收缩）会覆盖前面的
    static CGSize lastSize = {0, 0};
    if (CGSizeEqualToSize(lastSize, hs)) return;
    lastSize = hs;

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
    // 布局回调是高频的，参数没变就别每次都拆了重建。
    // 注意 size 也要参与判断：首次调用时 bounds 可能还是 0，
    // 只比 radius 的话会把"找不到祖先"这个结果一直缓存下去。
    CGSize hs = host.bounds.size;
    if (st.haloSnapshots.count > 0 &&
        fabs(st.lastHaloRadius - radius) < 0.5 &&
        CGSizeEqualToSize(st.lastHaloSize, hs)) return;
    st.lastHaloRadius = radius;
    st.lastHaloSize = hs;

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
        if (s.width > 560 || s.height > 560) break;

        CGFloat pad = VGPadAroundHost(host, anc);
        // 46pt：音量 HUD 的底板常常比滑块宽出一大截，26 会漏掉它
        if (pad < -1.0 || pad > 46.0) continue;

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

    if (st.nativeSkin && st.skinHidden) st.nativeSkin.alpha = st.origSkinAlpha;
    st.nativeSkin = nil;
    st.skinHidden = NO;

    for (NSDictionary *d in st.bgSnapshots) {
        UIView *v = d[@"v"];
        if (!v) continue;
        id bg = d[@"bg"];
        if (bg != (id)[NSNull null]) v.backgroundColor = bg;
        v.layer.borderWidth = [d[@"bw"] doubleValue];
    }
    [st.bgSnapshots removeAllObjects];

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

    // 抓结构要在"清边框"之前，不然记下来的都是被我们改过的值
    VGSaveDiag(host);

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

    // 关键一步：先把系统那层方形底板换掉。
    // 不换的话，圆角外面永远露着方底的四条边——那圈"虚影"就是这么来的。
    VGApplySkinReplace(host, st);
    // 再把祖先链上那些"方框底色"清掉（胶囊外圈那层更大的浅色框）
    VGClearAncestorBackgrounds(host, st);

    // 底板没了就没人提供"存在感"，这里给玻璃托个底：
    // 底色至少 0.16，并且补一层模糊，否则整个 HUD 会透得看不见。
    CGFloat tint = VGTintAlpha();
    BOOL blur = VGExtraBlur();
    if (st.skinHidden) {
        tint = MAX(tint, 0.16);
        blur = YES;
    }

    [st.backdrop applyRadius:radius tint:tint blur:blur];
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

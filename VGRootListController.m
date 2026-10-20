#import "VGRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <notify.h>

@implementation VGRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)applyPreset26:(PSSpecifier *)specifier {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.shiyi.volumeglass"];
    [d setObject:@YES     forKey:@"Enabled"];
    [d setObject:@YES     forKey:@"AutoCapsule"];
    [d setObject:@100     forKey:@"CornerPercent"];
    [d setObject:@26      forKey:@"Radius"];
    [d setObject:@0       forKey:@"Tint"];
    [d setObject:@NO      forKey:@"Rim"];
    [d setObject:@NO      forKey:@"ExtraBlur"];
    [d setObject:@YES     forKey:@"SlideIn"];
    [d setObject:@NO      forKey:@"KillHalo"];
    [d setObject:@YES     forKey:@"ReplaceSkin"];
    [d setObject:@NO      forKey:@"Brightness"];
    [d setObject:@0       forKey:@"LevelUp"];
    [d synchronize];

    notify_post("com.shiyi.volumeglass-changed");
    [self reloadSpecifiers];
}

- (void)resetDefaults:(PSSpecifier *)specifier {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.shiyi.volumeglass"];
    NSDictionary *defs = @{
        @"Enabled"    : @YES,
        @"CornerPercent": @100,
        @"Radius"     : @26,
        @"Tint"       : @0,
        @"Rim"        : @NO,
        @"ExtraBlur"  : @NO,
        @"Brightness" : @NO,
        @"AutoCapsule": @YES,
        @"SlideIn"    : @YES,
        @"KillHalo"   : @NO,
        @"ReplaceSkin": @YES,
        @"LevelUp"    : @0,
        @"Debug"      : @NO,
    };
    for (NSString *k in defs) [d setObject:defs[k] forKey:k];
    [d removeObjectForKey:@"ClassOverride"];
    [d synchronize];

    notify_post("com.shiyi.volumeglass-changed");
    [self reloadSpecifiers];
}

@end

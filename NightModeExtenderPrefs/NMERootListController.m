#import "NMERootListController.h"
#import <Preferences/PSSpecifier.h>

@implementation NMERootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

@end

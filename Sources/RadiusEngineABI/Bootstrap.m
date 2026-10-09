// SPDX-License-Identifier: MPL-2.0
#import <AppKit/AppKit.h>
#include "RadiusEngineABI.h"

/// CEF requires these event-state selectors on the application's NSApplication.
/// The optional bridge adds its public CefAppProtocol conformance when loaded.
@interface RadiusApplication : NSApplication {
    BOOL _handlingSendEvent;
}
@end
@implementation RadiusApplication
- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)setHandlingSendEvent:(BOOL)value { _handlingSendEvent = value; }
- (void)sendEvent:(NSEvent *)event {
    BOOL previous = _handlingSendEvent;
    _handlingSendEvent = YES;
    @try { [super sendEvent:event]; }
    @finally { _handlingSendEvent = previous; }
}
@end

void RadiusBootstrapApplication(void) {
    [RadiusApplication sharedApplication];
    NSCAssert([NSApp isKindOfClass:[RadiusApplication class]], @"Radius must create its application before SwiftUI starts.");
}

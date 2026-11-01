// Every window this process creates is made invisible: `alphaValue` 0, and no
// order-in animation. A test process draws its windows over whatever the
// person running the suite is doing, and a test does not need to see them —
// but it does need them ordered in, key-eligible and `isVisible`, and a
// transparent window is all three.
//
// The same is done for the app's own suite by a principal class, which XCTest
// instantiates from the test bundle's Info.plist; SwiftPM gives a package's
// test bundle no such plist, so the swizzle is installed by a constructor of
// this target, which the test bundle links. The constructor runs at load,
// before the first test, and the object is linked even though no test names a
// symbol of it.
//
// `alphaValue` 0 rather than ordering out: ordering the host's window out
// exits the app under test before XCTest connects. The order-in animation is
// turned off as well — it does not finish on a sleeping display, and each one
// left running parks a dispatch worker until every later dispatch callback in
// the host starves.

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#include "TestWindowHiding.h"

static IMP originalInit = NULL;

static id hiddenInit(id self, SEL _cmd, NSRect rect, NSWindowStyleMask style,
                     NSBackingStoreType backing, BOOL deferred) {
    id (*original)(id, SEL, NSRect, NSWindowStyleMask, NSBackingStoreType, BOOL) =
        (id (*)(id, SEL, NSRect, NSWindowStyleMask, NSBackingStoreType, BOOL))originalInit;
    id window = original(self, _cmd, rect, style, backing, deferred);
    if (window != nil && [NSThread isMainThread]) {
        NSWindow *made = (NSWindow *)window;
        [made setAlphaValue:0];
        [made setAnimationBehavior:NSWindowAnimationBehaviorNone];
    }
    return window;
}

__attribute__((constructor)) static void installWindowHiding(void) {
    Method method = class_getInstanceMethod(
        [NSWindow class], @selector(initWithContentRect:styleMask:backing:defer:));
    if (method == NULL) return;
    originalInit = method_setImplementation(method, (IMP)hiddenInit);
}

int testWindowHidingInstalled(void) { return originalInit != NULL; }

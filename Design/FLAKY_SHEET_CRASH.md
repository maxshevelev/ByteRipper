# Flaky test-host crash: the sheet's animated close asserts on a zero contents scale

The headless test host flakily crashes (2–3 of 5 runs) with an AppKit assertion
`contentsScale != 0` in `-[NSTextLayer display]`. This is not an app bug — the
animated sheet close is correct in a real app, where there is a real display and
a valid contents scale. It reproduces on the parent commit, so it predates the
"reveal origin" fix (165b67e). The app works; the fix belongs in the test
infrastructure, not the app.

## Mechanism

From the `.ips` crash log (faulting thread 0): the `BlockingOperationSheet`
animated close (`dismiss` → `dismissViewController:` → `NSSheetMoveHelper
closeSheet` → `NSMoveHelper _doAnimation`) sets up a display link. While a test
is waiting (`waitForExpectations` / `Task.sleep` pumping the main run loop), the
display link fires → `CA::Transaction::commit` → `-[NSTextLayer display]` →
asserts, because the window's `contentsScale` is 0 in the headless environment
(no real screen backing the sheet window).

The two tests that present the sheet are `testCancellingTheUpdateSheetWritesNothing`
and `testAZoneThatIsAFileGoesBackWithItsChecksumsRight`
(`ByteRipperTests/LinkedPartTests.swift`). Both wait for
`presentedViewControllers` to become empty, and that wait is what lets the
display link fire mid-test.

## Why the obvious app-side fix is a catch-22

- `NSViewController.dismiss(_:)` is the only public way to clear the presentation
  state (`presentedViewControllers`), and it always runs the sheet's animated
  dismissal.
- `NSWindow.endSheet(_:)` ends the window sheet but does not clear
  `presentedViewControllers`, so the two tests above (which assert it is empty)
  would fail.
- A custom `NSViewControllerPresentationAnimator` (presented via
  `presentViewController(_:animator:)`) whose `animateDismissalOfViewController`
  calls `endSheet` would clear the state (AppKit does that in
  `dismissViewController:`) and skip the animation — the deterministic app-side
  fix, but it touches app code.

## Fix direction: the test infrastructure

1. Give the test window a valid contents scale so the text-layer display can't
   assert. In `makeTestWindow` (`ByteRipperTests/TestSupport.swift:164`) the
   window is created but never ordered front, so it is not on a screen and its
   `contentsScale` can be 0. Try `window.makeKeyAndOrderFront(nil)` (put it on
   the virtual display) so `contentsScale` becomes the display's scale. Risk:
   may still be flaky if it is a race with the display — verify over several
   runs of `LinkedPartTests`.
2. If (1) stays flaky, the robust fallback is the custom-animator test-only path
   above (guarded by `MainViewController.isRunningTests`) — deterministic, but it
   touches app code, so get sign-off first.

## Investigation (2026-09-19): direction 1 does not work

Tried (1) — `window.makeKeyAndOrderFront(nil)` in `LinkedPartTests.makeController`
(the window source for both sheet tests). Instrumented the test to print the
scale state right after the sheet is presented:

- The environment **does** have a screen: `NSScreen.screens.count == 1`.
- After `makeKeyAndOrderFront`, both the parent and the sheet window report
  `backingScaleFactor == 2.0` and are on a screen.
- **Every** layer in the sheet's view tree — `NSViewBackingLayer` and the
  `NSTextLayer`s — reports `contentsScale == 2.0` at presentation time.

So the window and the text layers all have a valid scale while the sheet is up.
The scale only becomes 0 **during the animated close**, which is exactly when the
display link fires (`NS_setFlushesWithDisplayLink` → `CA::Transaction::commit` →
`-[NSTextLayer display]`). Giving the window a scale at presentation cannot help,
because the sheet window loses it mid-close. Crash rate is unchanged (~40%, 3 of 7
full-class runs) with or without the order-front; the change was reverted.

A second test-only route was also ruled out: spinning the wait's run loop in a
mode that excludes the display link. The crash backtrace shows the "display link"
is an `NSRunLoopObserver` (`NSRunLoopObserverCreateWithHandler`) that commits the
`CATransaction`, and it is what *drives* the close animation — blocking the mode
it fires in would stall the dismissal and hang the test on
`presentedViewControllers`. The run loop's modes are not enumerable via public
API, so the excluding mode can't even be confirmed.

Conclusion: the fault is the layer's `contentsScale` being 0 mid-close, not the
window's scale at presentation. A test-infrastructure change that only affects
the window's initial state cannot reach it, and the animation cannot be suppressed
without touching app code. The deterministic fix remains (2), the custom-animator
path that skips the animated dismissal. Decision (2026-09-19): leave the flaky
crash as-is and keep this doc as the record; pick up (2) if it starts biting.

Verify with the classes the change touches (`LinkedPartTests`), not the full
suite. A crashed host still reports "0 failures" (XCTest merges totals across
launches) — grep the log for the restart.

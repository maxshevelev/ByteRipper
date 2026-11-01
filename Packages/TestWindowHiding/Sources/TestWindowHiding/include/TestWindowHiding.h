#ifndef TEST_WINDOW_HIDING_H
#define TEST_WINDOW_HIDING_H

/// Whether the swizzle is in place. For a test: a window made before this
/// code loaded would not be hidden, and a test should say so rather than
/// assume.
int testWindowHidingInstalled(void);

#endif

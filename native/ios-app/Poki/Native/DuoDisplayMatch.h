#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <math.h>

// XCTest's screen bounds are in fixed axes. On Duo they may describe the
// render grid (logical points × UIKit scale), rather than UIKit's nativeBounds.
static inline BOOL PKDuoMatchesRenderSize(CGSize candidate, CGSize logical, CGFloat scale) {
    if (!isfinite(candidate.width) || !isfinite(candidate.height) ||
        !isfinite(logical.width) || !isfinite(logical.height) ||
        candidate.width <= 0 || candidate.height <= 0 || logical.width <= 0 ||
        logical.height <= 0 || !isfinite(scale) || scale < 1) return NO;
    return fabs(MIN(candidate.width, candidate.height) - MIN(logical.width, logical.height) * scale) <= 3 &&
           fabs(MAX(candidate.width, candidate.height) - MAX(logical.width, logical.height) * scale) <= 3;
}

// Validate both axes after orientation normalization, before any viewport crop.
// Actual captures may differ from the advertised render grid by a pixel.
static inline BOOL PKDuoFrameMatchesGrid(CGSize uprightImage, CGSize uprightBounds, CGSize selectedGrid, CGFloat scale) {
    if (!PKDuoMatchesRenderSize(selectedGrid, uprightBounds, scale) &&
        !PKDuoMatchesRenderSize(selectedGrid, uprightBounds, 1)) return NO;
    return scale >= 1 && uprightImage.width > 0 && uprightImage.height > 0 &&
           fabs(uprightImage.width - uprightBounds.width * scale) <= 3 &&
           fabs(uprightImage.height - uprightBounds.height * scale) <= 3;
}

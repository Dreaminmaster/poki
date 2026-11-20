#import <XCTest/XCTest.h>
#import "DuoDisplayMatch.h"

@interface DuoDisplayMatchTests : XCTestCase
@end

@implementation DuoDisplayMatchTests

- (void)testRenderGridRequiresTheSameScaleOnBothAxes {
    CGSize logical = CGSizeMake(669, 951);
    XCTAssertFalse(PKDuoMatchesRenderSize(CGSizeMake(669 * 2, 951 * 3), logical, 3));
    XCTAssertFalse(PKDuoMatchesRenderSize(CGSizeZero, logical, 3));
}

- (void)testLandscapeRejectsAStalePortraitFrameAndTheOtherPanel {
    CGSize landscape = CGSizeMake(951, 669);
    CGSize grid = CGSizeMake(2007, 2853);
    XCTAssertFalse(PKDuoFrameMatchesGrid(CGSizeMake(2006, 2852), landscape, grid, 3));
    // An inactive cover's image fit the old aspect-ratio check.
    XCTAssertFalse(PKDuoFrameMatchesGrid(CGSizeMake(2034, 1398), landscape, grid, 3));
}

- (void)testXCTestBoundsGivenInPointsStillRequireRenderedPixels {
    CGSize landscape = CGSizeMake(951, 669);
    CGSize points = CGSizeMake(669, 951);
    XCTAssertTrue(PKDuoFrameMatchesGrid(CGSizeMake(2852, 2006), landscape, points, 3));
    XCTAssertFalse(PKDuoFrameMatchesGrid(landscape, landscape, points, 3));
}

- (void)testScreenshotMustAgreeWithBothTheSelectedPanelAndTheActiveWindow {
    CGSize landscape = CGSizeMake(951, 669);
    CGSize innerImage = CGSizeMake(2852, 2006);
    CGSize coverGrid = CGSizeMake(1398, 2034);
    XCTAssertFalse(PKDuoFrameMatchesGrid(innerImage, landscape, coverGrid, 3));
    XCTAssertFalse(PKDuoFrameMatchesGrid(CGSizeMake(2034, 1398), landscape, coverGrid, 3));
}

@end

#import <UIKit/UIKit.h>
#import "InProcess.h"
#import "RecoveredNative.h"

// The simulator ordinarily enumerates only its cover. Supply the two screens
// XCTest reported on the physical Duo in #472, including its unchanged default.
@interface XCUIScreen : NSObject
@property(nonatomic) CGRect bounds;
@property(nonatomic) long long displayID;
@property(nonatomic, strong) NSData *pixels;
@end

static NSArray<XCUIScreen *> *panels;
static long long capturedDisplayID;

@implementation XCUIScreen
+ (NSArray *)screens { return panels; }
+ (instancetype)mainScreen { return panels.firstObject; }
- (instancetype)screenshot { capturedDisplayID = self.displayID; return self; }
- (NSData *)PNGRepresentation { return self.pixels; }
@end

@interface ReadySession : SRNativeSession
@end
@implementation ReadySession
- (id)prepare:(NSError **)error { return self; }
- (uint64_t)generation { return 1; }
@end

@interface FoldFixture : PKInProcess
@property(nonatomic) PKDisplayGeometry currentGeometry;
@end
@implementation FoldFixture
- (PKDisplayGeometry)displayGeometry { return self.currentGeometry; }
// The foreground scene supplies known geometry; this check needs no AX or daemon session.
- (BOOL)isPokiSceneVisible { return YES; }
- (NSData *)daemonJPEGForScreen:(id)screen { return nil; }
@end

static XCUIScreen *panel(long long displayID, CGSize grid, CGSize picture, UIColor *color) {
    XCUIScreen *screen = [XCUIScreen new];
    screen.displayID = displayID;
    screen.bounds = (CGRect){CGPointZero, grid};
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:picture format:format];
    screen.pixels = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
        [color setFill];
        [context fillRect:(CGRect){CGPointZero, picture}];
    }];
    return screen;
}

// Both fixture rasters are solid, so a single decoded grayscale sample identifies their content.
static int graySample(CGImageRef image) {
    if (!image) return -1;
    uint8_t gray = 0;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(&gray, 1, 1, 8, 1, space, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(space);
    if (!context) return -1;
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image);
    CGContextRelease(context);
    return gray;
}

static BOOL checkShot(FoldFixture *runner, long long displayID, CGSize expected, int expectedGray, NSString *stage) {
    capturedDisplayID = 0;
    NSString *reason = nil;
    NSData *data = [runner screenshot:&reason refreshViewport:NO];
    UIImage *picture = data ? [UIImage imageWithData:data] : nil;
    CGImageRef image = picture.CGImage;
    CGSize actual = image ? CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image)) : CGSizeZero;
    int gray = graySample(image);
    printf("%s: expected display %lld %.0fx%.0f gray %d, got display %lld %.0fx%.0f gray %d%s%s\n",
           stage.UTF8String, displayID, expected.width, expected.height, expectedGray, capturedDisplayID,
           actual.width, actual.height, gray, reason ? ": " : "", reason.UTF8String ?: "");
    return capturedDisplayID == displayID && CGSizeEqualToSize(actual, expected) &&
           gray >= 0 && abs(gray - expectedGray) <= 2;
}

int main(void) {
    @autoreleasepool {
        CGSize cover = CGSizeMake(1398, 2034), inner = CGSizeMake(2852, 2006);
        panels = @[panel(1, cover, cover, UIColor.blackColor),
                   panel(2, CGSizeMake(2007, 2853), inner, UIColor.whiteColor)];
        FoldFixture *runner = [FoldFixture new];
        [runner setValue:[ReadySession new] forKey:@"sessions"];
        PKDisplayGeometry geometry = {.bounds = CGRectMake(0, 0, 466, 678),
            .peer = CGRectNull, .nativeSize = cover, .toFixed = CGAffineTransformIdentity,
            .orientation = UIInterfaceOrientationPortrait, .routesDisplay = YES};
        runner.currentGeometry = geometry;
        if (!checkShot(runner, 1, cover, 0, @"cover")) return 1;

        geometry.bounds = CGRectMake(0, 0, 951, 669);
        geometry.nativeSize = CGSizeMake(1878, 2670);
        geometry.toFixed = CGAffineTransformMake(0, -1, 1, 0, 0, 951);
        geometry.orientation = UIInterfaceOrientationLandscapeLeft;
        geometry.orientationRevision++;
        runner.currentGeometry = geometry;
        return checkShot(runner, 2, inner, 255, @"unfolded inner landscape") ? 0 : 1;
    }
}

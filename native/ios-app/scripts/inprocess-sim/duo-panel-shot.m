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

@interface XCPointerEventPath : NSObject
@property(nonatomic) CGPoint start;
- (instancetype)initForTouchAtPoint:(CGPoint)start offset:(double)offset;
@end
@implementation XCPointerEventPath
- (instancetype)initForTouchAtPoint:(CGPoint)start offset:(double)offset {
    if ((self = [super init])) _start = start;
    return self;
}
- (void)moveToPoint:(CGPoint)point atOffset:(double)offset {}
- (void)liftUpAtOffset:(double)offset {}
@end

@interface XCSynthesizedEventRecord : NSObject
@property(nonatomic) unsigned long long displayID;
@property(nonatomic, strong) XCPointerEventPath *path;
@end
@implementation XCSynthesizedEventRecord
- (instancetype)initWithName:(NSString *)name { return [super init]; }
- (instancetype)initWithName:(NSString *)name displayID:(unsigned long long)display interfaceOrientation:(NSInteger)orientation {
    if ((self = [super init])) _displayID = display;
    return self;
}
- (void)addPointerEventPath:(XCPointerEventPath *)path { self.path = path; }
@end

@interface ReadySession : SRNativeSession
@property(nonatomic, strong) XCSynthesizedEventRecord *gesture;
@end
@implementation ReadySession
- (id)prepare:(NSError **)error { return self; }
- (uint64_t)generation { return 1; }
- (BOOL)isCurrent:(id)session generation:(uint64_t)generation { return session == self && generation == 1; }
- (id)daemonProxy { return self; }
- (void)_XCT_synthesizeEvent:(XCSynthesizedEventRecord *)record implicitConfirmationInterval:(double)interval completion:(void (^)(NSError *))completion {
    self.gesture = record;
    completion(nil);
}
@end

@interface FoldFixture : PKInProcess
@property(nonatomic) PKDisplayGeometry currentGeometry;
@property(nonatomic) CGRect targetPane;
@end
@implementation FoldFixture
- (PKDisplayGeometry)sceneDisplayGeometry { return self.currentGeometry; }
// The foreground scene supplies known geometry; this check needs no AX or daemon session.
- (BOOL)isPokiSceneVisible { return YES; }
- (NSData *)daemonJPEGForScreen:(id)screen { return nil; }
- (id)sharedFront:(NSDictionary **)info ax:(id *)ax code:(NSString **)code {
    if (info) *info = @{@"pane": [NSValue valueWithCGRect:self.targetPane]};
    return nil;
}
@end

@interface AXNode : NSObject
@property(nonatomic) int processIdentifier;
@property(nonatomic) long long elementType;
@property(nonatomic) CGRect frame;
@property(nonatomic, copy) NSString *label;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSArray<AXNode *> *children;
@property(nonatomic, strong) id value;
@end
@implementation AXNode
@end

@interface CompanionFixture : PKInProcess
@property(nonatomic) PKDisplayGeometry scene;
@property(nonatomic, strong) AXNode *own;
@property(nonatomic, strong) AXNode *target;
@property(nonatomic, strong) AXNode *snapshot;
@property(nonatomic) BOOL missTarget;
@property(nonatomic) BOOL ownOnRight;
@end
@implementation CompanionFixture
- (PKDisplayGeometry)sceneDisplayGeometry { return self.scene; }
- (BOOL)isPokiSceneVisible { return YES; }
- (NSData *)daemonJPEGForScreen:(id)screen { return nil; }
- (id)current:(uint64_t *)generation outcome:(PKOutcome **)outcome { *generation = 1; return [self valueForKey:@"sessions"]; }
- (id)accessibilityFor:(uint64_t)generation { return self; }
- (NSString *)bundleForPID:(int)pid session:(id)session {
    return pid == self.target.processIdentifier ? @"com.apple.calculator" : @"local.poki";
}
- (NSArray *)activeApplications { return @[self.own, self.target]; }
- (id)elementAtPoint:(CGPoint)point error:(NSError **)error {
    BOOL left = point.y >= 475.5;
    return left != self.ownOnRight ? self.own : self.missTarget ? nil : self.target;
}
- (id)requestSnapshotForElement:(id)element attributes:(NSArray *)attributes parameters:(NSDictionary *)parameters error:(NSError **)error {
    return self.snapshot;
}
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

static BOOL checkShot(PKInProcess *runner, long long displayID, CGSize expected, int expectedGray, NSString *stage, BOOL split) {
    capturedDisplayID = 0;
    NSString *reason = nil;
    NSData *data = [runner screenshot:&reason refreshViewport:split];
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

static CompanionFixture *companion(PKDisplayGeometry scene) {
    CompanionFixture *runner = [CompanionFixture new];
    [runner setValue:[ReadySession new] forKey:@"sessions"];
    runner.scene = scene;
    runner.own = [AXNode new];
    runner.own.processIdentifier = getpid();
    runner.target = [AXNode new];
    runner.target.processIdentifier = getpid() + 1;
    return runner;
}

static BOOL checkPictureWithoutWindow(PKDisplayGeometry scene) {
    CompanionFixture *runner = companion(scene);
    NSString *reason = nil;
    NSDictionary *pane = [runner selectPane:@"right" code:&reason];
    if (![pane[@"bundleId"] isEqual:@"com.apple.calculator"] || [pane[@"x"] integerValue] != 482) {
        NSLog(@"confirmed companion refused without an AX window: %@", reason);
        return NO;
    }
    if (![runner screenshot:&reason refreshViewport:YES]) { NSLog(@"missing companion picture: %@", reason); return NO; }
    NSDictionary *observation = nil;
    if (![runner screenshot:&reason refreshViewport:NO observation:&observation] ||
        ![observation[@"identity"] isEqual:pane[@"identity"]] ||
        ![observation[@"bundleId"] isEqual:pane[@"bundleId"]]) {
        NSLog(@"missing held-read companion picture or confirmation: %@", reason);
        return NO;
    }
    [runner selectPane:@"auto" code:NULL];
    if ([runner screenshot:&reason refreshViewport:NO observation:NULL]) {
        NSLog(@"a held read reused confirmation after the selection changed");
        return NO;
    }
    runner = companion(scene);
    if ([runner sourceXML:NULL code:&reason]) return NO;
    if (![runner screenshot:&reason refreshViewport:NO]) { NSLog(@"missing automatic picture for a confirmed companion: %@", reason); return NO; }
    runner = companion(scene);
    runner.missTarget = YES;
    if ([runner selectPane:@"right" code:&reason] || [runner screenshot:&reason refreshViewport:YES]) {
        NSLog(@"reported a companion without independent target evidence");
        return NO;
    }
    return YES;
}

static BOOL checkInsetWindow(PKDisplayGeometry scene, CGSize image) {
    CompanionFixture *runner = companion(scene);
    AXNode *button = [AXNode new];
    button.elementType = 9;
    button.label = @"7";
    button.frame = CGRectMake(506, 80, 40, 40);
    AXNode *root = [AXNode new];
    root.elementType = 2;
    root.frame = CGRectMake(486, 0, 465, 669);
    root.children = @[button];
    runner.snapshot = root;
    if (!checkShot(runner, 2, image, 255, @"automatic inset companion", YES)) return NO;
    CGRect pictured = runner.viewport;
    NSString *reason = nil, *xml = [runner sourceXML:NULL code:&reason];
    BOOL stable = CGRectEqualToRect(pictured, runner.viewport) &&
        [xml containsString:@"label=\"7\" x=\"24\" y=\"80\" width=\"40\" height=\"40\""];
    if (!stable) {
        NSLog(@"automatic read and touch disagree: picture %@, tree origin %@, source %@", NSStringFromCGRect(pictured), NSStringFromCGRect(runner.viewport), xml ?: reason);
        return NO;
    }
    CGPoint centre = CGPointMake(CGRectGetMinX(runner.viewport) + 44, 100);
    PKOutcome *tap = [runner touch:@[@[[PKTouchPoint at:centre offset:0], [PKTouchPoint at:centre offset:0.05]]]
                           timeout:1 geometry:runner.displayGeometry];
    ReadySession *session = [runner valueForKey:@"sessions"];
    BOOL sent = tap.delivery == PKDeliverySent && session.gesture.displayID == 2 &&
        CGPointEqualToPoint(session.gesture.path.start, CGPointMake(100, 425));
    if (!sent) NSLog(@"inset companion touch did not reach the expected panel coordinate: %@", tap.code);
    return sent;
}

static BOOL checkCompanionActivation(PKDisplayGeometry scene) {
    CompanionFixture *runner = companion(scene);
    NSString *error = [runner app:@"com.apple.calculator" action:@"activate"];
    if (error) { NSLog(@"the app already beside Poki should stay in place: %@", error); return NO; }
    error = [runner app:@"com.apple.Preferences" action:@"activate"];
    if (![error hasPrefix:@"not sent:"] || ![error containsString:@"right pane"]) {
        NSLog(@"changing apps should preserve Poki and name the target pane: %@", error);
        return NO;
    }
    return YES;
}

static BOOL checkLaunchPlacement(PKDisplayGeometry scene) {
    CompanionFixture *runner = companion(scene);
    NSString *placement = runner.duoPlacement;
    if (![placement isEqualToString:@"split-unknown"]) {
        NSLog(@"task launch called a pane-local scene %@", placement);
        return NO;
    }
    scene.bounds.size.width = 951;
    scene.nativeSize = CGSizeMake(1878, 2670);
    runner.scene = scene;
    return [runner.duoPlacement isEqualToString:@"fullscreen"];
}

static BOOL checkRecoveredCompanionEdge(PKDisplayGeometry scene, CGSize crop) {
    CompanionFixture *runner = companion(scene);
    runner.ownOnRight = YES;
    AXNode *button = [AXNode new];
    button.elementType = 9;
    button.label = @"Edge";
    button.frame = CGRectMake(400, 80, 40, 40);
    AXNode *window = [AXNode new];
    window.elementType = 4;
    window.frame = CGRectMake(0, 0, 469, 669);
    window.children = @[button];
    AXNode *root = [AXNode new];
    root.elementType = 2;
    root.frame = CGRectMake(0, 0, 951, 669);
    root.children = @[window];
    runner.snapshot = root;
    NSString *reason = nil;
    if (!checkShot(runner, 2, crop, 0, @"left companion beside a 389-point UIKit scene", YES)) return NO;
    NSString *xml = [runner sourceXML:NULL code:&reason];
    if (![xml containsString:@"label=\"Edge\" x=\"400\" y=\"80\" width=\"40\" height=\"40\""] ||
        !CGRectContainsPoint(runner.viewport, CGPointMake(420, 100))) return NO;
    PKOutcome *tap = [runner touch:@[@[[PKTouchPoint at:CGPointMake(420, 100) offset:0], [PKTouchPoint at:CGPointMake(420, 100) offset:0.05]]]
                           timeout:1 geometry:runner.displayGeometry];
    ReadySession *session = [runner valueForKey:@"sessions"];
    return tap.delivery == PKDeliverySent && session.gesture.displayID == 2 &&
        CGPointEqualToPoint(session.gesture.path.start, CGPointMake(100, 531));
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
        if (!checkShot(runner, 1, cover, 0, @"cover", NO)) return 1;

        geometry.bounds = CGRectMake(0, 0, 951, 669);
        geometry.nativeSize = CGSizeMake(1878, 2670);
        geometry.toFixed = CGAffineTransformMake(0, -1, 1, 0, 0, 951);
        geometry.orientation = UIInterfaceOrientationLandscapeLeft;
        geometry.orientationRevision++;
        runner.currentGeometry = geometry;
        if (!checkShot(runner, 2, inner, 255, @"unfolded inner landscape", NO)) return 1;

        XCUIScreen *active = panels[1];
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
        format.scale = 1;
        format.opaque = YES;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:inner format:format];
        active.pixels = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
            [UIColor.whiteColor setFill];
            [context fillRect:(CGRect){CGPointZero, inner}];
            [UIColor.blackColor setFill];
            [context fillRect:CGRectMake(0, 0, 1407, inner.height)];
        }];
        geometry.bounds = CGRectMake(0, 0, 469, 669);
        geometry.nativeSize = CGSizeMake(2007, 1407);
        runner.currentGeometry = geometry;
        runner.targetPane = CGRectMake(482, 0, 469, 669);
        CGSize crop = CGSizeMake(1407, 2006);
        if (!checkShot(runner, 2, crop, 255, @"Poki left, target right", YES)) return 1;

        geometry.bounds.size.width = 389;
        geometry.nativeSize.height = 1167;
        runner.currentGeometry = geometry;
        runner.targetPane = CGRectMake(0, 0, 469, 669);
        if (!checkShot(runner, 2, crop, 0, @"Poki right, target left", YES)) return 1;
        BOOL launchPlacement = checkLaunchPlacement(geometry);
        BOOL recoveredEdge = checkRecoveredCompanionEdge(geometry, crop);
        geometry.bounds.size.width = 469;
        geometry.nativeSize = CGSizeMake(2007, 1407);
        BOOL picture = checkPictureWithoutWindow(geometry);
        geometry.bounds = CGRectMake(0, 0, 951, 669);
        geometry.nativeSize = CGSizeMake(1878, 2670);
        geometry.peer = CGRectMake(482, 0, 469, 669);
        geometry.panePlacementKnown = YES;
        BOOL inset = checkInsetWindow(geometry, crop);
        BOOL activation = checkCompanionActivation(geometry);
        return launchPlacement && recoveredEdge && picture && inset && activation ? 0 : 1;
    }
}

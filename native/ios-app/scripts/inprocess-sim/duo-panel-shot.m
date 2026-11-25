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
static void (^onScreenCapture)(void);

@implementation XCUIScreen
+ (NSArray *)screens { return panels; }
+ (instancetype)mainScreen { return panels.firstObject; }
- (instancetype)screenshot {
    capturedDisplayID = self.displayID;
    if (onScreenCapture) {
        void (^hook)(void) = onScreenCapture;
        onScreenCapture = nil;
        hook();
    }
    return self;
}
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
@property(nonatomic) NSInteger reportedOrientation;
@property(nonatomic) BOOL omitOrientationRPC;
@property(nonatomic, copy) NSString *launchedBundle;
@property(nonatomic, copy) void (^onLaunch)(NSString *bundle);
@property(nonatomic, copy) void (^activate)(NSString *bundle);
@end
@implementation ReadySession
- (id)prepare:(NSError **)error { return self; }
- (uint64_t)generation { return 1; }
- (BOOL)isCurrent:(id)session generation:(uint64_t)generation { return session == self && generation == 1; }
- (id)daemonProxy { return self; }
- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(getInterfaceOrientationWithReply:) && self.omitOrientationRPC) return NO;
    return [super respondsToSelector:aSelector];
}
- (void)getInterfaceOrientationWithReply:(void (^)(NSInteger, NSError *))reply {
    reply(self.reportedOrientation ?: UIInterfaceOrientationPortrait, nil);
}
- (void)_XCT_launchApplicationWithBundleID:(NSString *)bundle arguments:(NSArray *)arguments environment:(NSDictionary *)environment completion:(void (^)(NSError *))completion {
    self.launchedBundle = bundle;
    if (self.onLaunch) self.onLaunch(bundle);
    if (self.activate) self.activate(bundle);
    completion(nil);
}
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
@property(nonatomic, copy) NSString *targetBundle;
@property(nonatomic, strong) AXNode *snapshot;
@property(nonatomic, strong) AXNode *otherWindow;
@property(nonatomic) BOOL missTarget;
@property(nonatomic) BOOL ownOnRight;
@property(nonatomic) BOOL pokiHidden;
@property(nonatomic) BOOL hitsFollowFocus;
@end
@implementation CompanionFixture
- (PKDisplayGeometry)sceneDisplayGeometry { return self.scene; }
- (BOOL)isPokiSceneVisible { return !self.pokiHidden; }
- (BOOL)screenLocked { return NO; }
- (NSData *)daemonJPEGForScreen:(id)screen { return nil; }
- (id)current:(uint64_t *)generation outcome:(PKOutcome **)outcome { *generation = 1; return [self valueForKey:@"sessions"]; }
- (id)accessibilityFor:(uint64_t)generation { return self; }
- (NSString *)bundleForPID:(int)pid session:(id)session {
    if (pid == self.target.processIdentifier) return self.targetBundle;
    return pid == getpid() ? @"local.poki" : @"com.apple.mobiletimer";
}
- (NSArray *)activeApplications { return @[self.own, self.target]; }
- (id)elementAtPoint:(CGPoint)point error:(NSError **)error {
    if (self.hitsFollowFocus) return self.own;
    BOOL left = point.y >= 475.5;
    return left != self.ownOnRight ? self.own : self.missTarget ? nil : self.target;
}
- (id)requestSnapshotForElement:(id)element attributes:(NSArray *)attributes parameters:(NSDictionary *)parameters error:(NSError **)error {
    return element == self.own ? self.otherWindow : self.snapshot;
}
@end

@interface PKInProcess (CompanionTask)
- (BOOL)beginDuoCompanionTask;
- (BOOL)bindDuoCompanionTarget;
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
    runner.targetBundle = @"com.apple.calculator";
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

static BOOL checkTaskOpensCalculatorBesidePoki(PKDisplayGeometry scene) {
    CompanionFixture *runner = companion(scene);
    runner.targetBundle = @"com.apple.mobilenotes";
    if (![runner beginDuoCompanionTask] || ![runner bindDuoCompanionTarget] ||
        ![[runner frontApp][@"bundleId"] isEqual:@"com.apple.mobilenotes"]) {
        NSLog(@"test setup failed: Notes must be beside Poki when the task starts");
        return NO;
    }
    ReadySession *session = [runner valueForKey:@"sessions"];
    __weak CompanionFixture *weakRunner = runner;
    session.activate = ^(NSString *bundle) {
        if (![bundle isEqualToString:@"com.apple.calculator"]) return;
        AXNode *calculator = [AXNode new];
        calculator.processIdentifier = getpid() + 2;
        weakRunner.target = calculator;
        weakRunner.targetBundle = bundle;

        AXNode *key = [AXNode new];
        key.elementType = 9;
        key.label = @"7";
        key.frame = CGRectMake(506, 80, 40, 40);
        AXNode *window = [AXNode new];
        window.elementType = 2;
        window.frame = scene.peer;
        window.children = @[key];
        weakRunner.snapshot = window;
    };
    NSString *error = [runner app:@"com.apple.calculator" action:@"activate"];
    NSDictionary *front = [runner frontApp];
    NSString *xml = [runner sourceXML:NULL code:NULL];
    BOOL passed = !error && [front[@"bundleId"] isEqual:@"com.apple.calculator"] &&
        [front[@"pokiPane"] isEqual:@"left"] && [xml containsString:@"label=\"7\" x=\"24\" y=\"80\""];
    NSLog(@"Calculator opens and can be read beside Poki: %@", passed ? @"passed" : error ?: @"right pane not confirmed");
    return passed;
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

static BOOL checkCompanionAfterSwitch(PKDisplayGeometry scene, CGSize crop, BOOL switchBeforeRead) {
    CompanionFixture *runner = companion(scene);
    AXNode *button = [AXNode new];
    button.elementType = 9;
    button.label = @"Calculator";
    button.frame = CGRectMake(506, 80, 40, 40);
    AXNode *root = [AXNode new];
    root.elementType = 2;
    root.frame = scene.peer;
    root.children = @[button];
    runner.snapshot = root;
    if ([runner respondsToSelector:@selector(beginDuoCompanionTask)] && ![runner beginDuoCompanionTask]) return NO;
    if ([runner respondsToSelector:@selector(bindDuoCompanionTarget)] && ![runner bindDuoCompanionTarget]) return NO;
    if (!switchBeforeRead && !checkShot(runner, 2, crop, 255, @"before replacing Poki", YES)) return NO;

    runner.pokiHidden = YES;
    runner.own.processIdentifier = getpid() + 2;
    runner.otherWindow = [AXNode new];
    runner.otherWindow.frame = CGRectMake(0, 0, 469, 669);
    scene.peer = CGRectNull;
    scene.panePlacementKnown = NO;
    runner.scene = scene;
    NSString *scenario = switchBeforeRead ? @"first read after Clock replaces Poki" : @"same target after Clock replaces Poki";
    if (!checkShot(runner, 2, crop, 255, scenario, YES)) return NO;
    NSString *xml = [runner sourceXML:NULL code:NULL];
    if (![xml containsString:@"label=\"Calculator\" x=\"24\" y=\"80\""]) return NO;
    CGRect viewport = runner.viewport;
    CGPoint target = CGPointMake(526, 100);
    NSArray *tap = @[@[[PKTouchPoint at:target offset:0], [PKTouchPoint at:target offset:0.05]]];
    ReadySession *session = [runner valueForKey:@"sessions"];
    PKOutcome *sent = [runner touch:tap timeout:1 geometry:runner.displayGeometry];
    if (!CGRectEqualToRect(viewport, CGRectMake(482, 0, 469, 669)) ||
        sent.delivery != PKDeliverySent || session.gesture.displayID != 2 ||
        !CGPointEqualToPoint(session.gesture.path.start, CGPointMake(100, 425))) return NO;

    runner.hitsFollowFocus = YES;
    if (!checkShot(runner, 2, crop, 255, @"when Clock has focus", YES)) return NO;
    sent = [runner touch:tap timeout:1 geometry:runner.displayGeometry];
    if (sent.delivery != PKDeliverySent || session.gesture.displayID != 2 ||
        !CGPointEqualToPoint(session.gesture.path.start, CGPointMake(100, 425))) return NO;

    session.gesture = nil;
    runner.hitsFollowFocus = NO;
    runner.ownOnRight = YES;
    PKOutcome *refused = [runner touch:tap timeout:1 geometry:runner.displayGeometry];
    if (refused.delivery != PKDeliveryNotSent || session.gesture ||
        [runner screenshot:NULL refreshViewport:YES]) {
        NSLog(@"the target moved to the other pane and its old location was still read or tapped");
        return NO;
    }
    return YES;
}


static BOOL checkCompanionBindingRetry(PKDisplayGeometry scene, CGSize crop) {
    CompanionFixture *runner = companion(scene);
    runner.missTarget = YES;
    if (![runner beginDuoCompanionTask] || [runner bindDuoCompanionTarget]) {
        NSLog(@"the startup binding must fail while the companion cannot be confirmed");
        return NO;
    }
    runner.missTarget = NO;
    return checkShot(runner, 2, crop, 255, @"first read retries the startup binding", YES);
}

@interface CoverWeChatFixture : PKInProcess
@property(nonatomic) PKDisplayGeometry scene;
@property(nonatomic) BOOL pokiVisible;
@property(nonatomic, strong) AXNode *wechat;
@property(nonatomic, strong) AXNode *springBoard;
@property(nonatomic, strong) AXNode *wechatSnapshot;
@property(nonatomic, strong) AXNode *springBoardSnapshot;
@property(nonatomic, copy) NSArray<AXNode *> *activeApps;
@property(nonatomic) NSInteger wechatSnapshotCalls;
@end
@implementation CoverWeChatFixture
- (PKDisplayGeometry)sceneDisplayGeometry { return self.scene; }
- (BOOL)isPokiSceneVisible { return self.pokiVisible; }
- (NSData *)daemonJPEGForScreen:(id)screen { return nil; }
- (id)current:(uint64_t *)generation outcome:(PKOutcome **)outcome {
    if (generation) *generation = 1;
    return [self valueForKey:@"sessions"];
}
- (id)accessibilityFor:(uint64_t)generation { return self; }
- (NSString *)bundleForPID:(int)pid session:(id)session {
    if (pid == self.wechat.processIdentifier) return @"com.tencent.xin";
    if (pid == self.springBoard.processIdentifier) return @"com.apple.springboard";
    return pid == getpid() ? @"local.poki" : @"";
}
- (NSArray *)activeApplications { return self.activeApps ?: (self.wechat ? @[self.wechat] : @[]); }
- (id)systemApplication { return self.springBoard; }
- (id)requestSnapshotForElement:(id)element attributes:(NSArray *)attributes parameters:(NSDictionary *)parameters error:(NSError **)error {
    if (element == self.wechat) {
        self.wechatSnapshotCalls++;
        return self.wechatSnapshot;
    }
    if (element == self.springBoard) return self.springBoardSnapshot;
    return nil;
}
@end

static CoverWeChatFixture *coverWeChat(PKDisplayGeometry scene) {
    CoverWeChatFixture *runner = [CoverWeChatFixture new];
    ReadySession *session = [ReadySession new];
    session.reportedOrientation = UIInterfaceOrientationPortrait;
    [runner setValue:session forKey:@"sessions"];
    runner.scene = scene;
    runner.wechat = [AXNode new];
    runner.wechat.processIdentifier = getpid() + 10;
    runner.springBoard = [AXNode new];
    runner.springBoard.processIdentifier = getpid() + 11;
    AXNode *sbRoot = [AXNode new];
    sbRoot.elementType = 2;
    sbRoot.frame = CGRectMake(0, 0, 466, 678);
    runner.springBoardSnapshot = sbRoot;
    return runner;
}

static BOOL checkCoverWeChatUnavailableAXFallback(PKDisplayGeometry coverScene, CGSize coverPixels) {
    CoverWeChatFixture *runner = coverWeChat(coverScene);
    runner.pokiVisible = NO;
    // Simulate WeChat answering kAXErrorServerNotFound (nil snapshot) right after launch.
    runner.wechatSnapshot = nil;
    PKDisplayGeometry geometry = [runner readDisplayGeometry];
    if (!CGRectEqualToRect(geometry.bounds, CGRectMake(0, 0, 466, 678))) {
        printf("FAIL cover WeChat nil-AX fallback: readDisplayGeometry bounds=%s\n", NSStringFromCGRect(geometry.bounds).UTF8String);
        return NO;
    }
    if (!checkShot(runner, 1, coverPixels, 0, @"cover WeChat nil-AX SpringBoard fallback", NO)) return NO;
    ReadySession *session = [runner valueForKey:@"sessions"];
    PKOutcome *tap = [runner touch:@[@[[PKTouchPoint at:CGPointMake(120, 240) offset:0], [PKTouchPoint at:CGPointMake(120, 240) offset:0.05]]]
                           timeout:1 geometry:runner.displayGeometry];
    if (tap.delivery != PKDeliverySent || session.gesture.displayID != 1) {
        printf("FAIL cover WeChat nil-AX fallback tap: delivery=%ld code=%s display=%llu\n",
               (long)tap.delivery, tap.code.UTF8String ?: "", session.gesture.displayID);
        return NO;
    }
    // Safety guard: a partial non-full window snapshot (root != nil) must STILL be refused.
    AXNode *sheet = [AXNode new];
    sheet.elementType = 4;
    sheet.frame = CGRectMake(20, 40, 280, 380);
    AXNode *root = [AXNode new];
    root.elementType = 2;
    root.frame = CGRectMake(0, 0, 466, 678);
    root.children = @[sheet];
    runner.wechatSnapshot = root;
    NSString *reason = nil;
    if ([runner screenshot:&reason refreshViewport:NO] != nil) {
        printf("FAIL partial non-full window on cover was not refused\n");
        return NO;
    }
    return YES;
}

static BOOL checkCoverCompatKeyboardAndLeadingOffset(PKDisplayGeometry coverScene, CGSize coverPixels) {
    CoverWeChatFixture *runner = coverWeChat(coverScene);
    runner.pokiVisible = NO;
    AXNode *compat = [AXNode new];
    compat.elementType = 4;
    compat.frame = CGRectMake(0, 0, 386, 678);
    AXNode *fullRootCompatOnly = [AXNode new];
    fullRootCompatOnly.elementType = 2;
    fullRootCompatOnly.frame = CGRectMake(0, 0, 466, 678);
    fullRootCompatOnly.children = @[compat];
    runner.wechatSnapshot = fullRootCompatOnly;
    if (!checkShot(runner, 1, coverPixels, 0, @"cover compat full-root + 386x678 window", NO)) return NO;

    AXNode *keyboard = [AXNode new];
    keyboard.elementType = 4;
    keyboard.frame = CGRectMake(0, 0, 466, 678);
    AXNode *root = [AXNode new];
    root.elementType = 2;
    root.frame = CGRectMake(0, 0, 386, 678);
    root.children = @[compat, keyboard];
    runner.wechatSnapshot = root;
    if (!checkShot(runner, 1, coverPixels, 0, @"cover compat 386x678 root + keyboard window", NO)) return NO;

    AXNode *leading = [AXNode new];
    leading.elementType = 4;
    leading.frame = CGRectMake(80, 0, 386, 678);
    AXNode *leadingRoot = [AXNode new];
    leadingRoot.elementType = 2;
    leadingRoot.frame = CGRectMake(80, 0, 386, 678);
    leadingRoot.children = @[leading];
    runner.wechatSnapshot = leadingRoot;
    return checkShot(runner, 1, coverPixels, 0, @"cover compat leading 80pt status area", NO);
}

static BOOL checkCoverPortraitOrientationPNGFallback(PKDisplayGeometry coverScene, CGSize coverPixels) {
    CoverWeChatFixture *runner = coverWeChat(coverScene);
    runner.pokiVisible = NO;
    ReadySession *session = [runner valueForKey:@"sessions"];
    session.omitOrientationRPC = YES;
    AXNode *compat = [AXNode new];
    compat.elementType = 4;
    compat.frame = CGRectMake(0, 0, 386, 678);
    AXNode *root = [AXNode new];
    root.elementType = 2;
    root.frame = CGRectMake(0, 0, 386, 678);
    root.children = @[compat];
    runner.wechatSnapshot = root;
    return checkShot(runner, 1, coverPixels, 0, @"cover portrait PNG orientation fallback", NO);
}

static BOOL checkCoverLaunchSkipsAXSnapshotAndIgnoresTransientLandscape(PKDisplayGeometry coverScene) {
    BOOL ok = YES;
    PKDisplayGeometry transient = coverScene;
    transient.orientation = UIInterfaceOrientationLandscapeLeft;
    CoverWeChatFixture *transientRunner = coverWeChat(transient);
    transientRunner.pokiVisible = YES;
    if (![transientRunner.duoPlacement isEqualToString:@"fullscreen"] || transientRunner.hasDuoCompanion) {
        printf("FAIL cover with transient landscape orientation misclassified: placement=%s hasCompanion=%d\n",
               transientRunner.duoPlacement.UTF8String ?: "(nil)", transientRunner.hasDuoCompanion);
        ok = NO;
    }

    CoverWeChatFixture *runner = coverWeChat(coverScene);
    runner.pokiVisible = YES;
    AXNode *own = [AXNode new];
    own.processIdentifier = getpid();
    runner.activeApps = @[own];
    ReadySession *session = [runner valueForKey:@"sessions"];
    __weak CoverWeChatFixture *weakRunner = runner;
    session.onLaunch = ^(NSString *bundle) {
        if ([bundle isEqualToString:@"com.tencent.xin"]) weakRunner.activeApps = @[weakRunner.wechat];
    };
    NSString *launchError = [runner app:@"com.tencent.xin" action:@"activate"];
    if (launchError || ![session.launchedBundle isEqualToString:@"com.tencent.xin"] || runner.wechatSnapshotCalls != 0) {
        printf("FAIL cover WeChat launch: err=%s launched=%s snapshotCalls=%ld\n",
               launchError.UTF8String ?: "(nil)", session.launchedBundle.UTF8String ?: "(nil)", (long)runner.wechatSnapshotCalls);
        ok = NO;
    }
    return ok;
}

static BOOL checkCoverSceneToBackgroundHandoffDuringScreenshot(PKDisplayGeometry coverScene, CGSize coverPixels) {
    CoverWeChatFixture *runner = coverWeChat(coverScene);
    runner.pokiVisible = YES;
    AXNode *compat = [AXNode new];
    compat.elementType = 4;
    compat.frame = CGRectMake(0, 0, 386, 678);
    AXNode *root = [AXNode new];
    root.elementType = 2;
    root.frame = CGRectMake(0, 0, 386, 678);
    root.children = @[compat];
    runner.wechatSnapshot = root;
    __weak CoverWeChatFixture *weakRunner = runner;
    onScreenCapture = ^{ weakRunner.pokiVisible = NO; };
    if (!checkShot(runner, 1, coverPixels, 0, @"cover scene->background handoff mid-screenshot", NO)) return NO;
    ReadySession *session = [runner valueForKey:@"sessions"];
    PKOutcome *tap = [runner touch:@[@[[PKTouchPoint at:CGPointMake(120, 240) offset:0], [PKTouchPoint at:CGPointMake(120, 240) offset:0.05]]]
                           timeout:1 geometry:runner.displayGeometry];
    if (tap.delivery != PKDeliverySent || session.gesture.displayID != 1) {
        printf("FAIL cover handoff tap: delivery=%ld code=%s display=%llu\n",
               (long)tap.delivery, tap.code.UTF8String ?: "", session.gesture.displayID);
        return NO;
    }
    return YES;
}

static BOOL checkCompanionTaskHeldPicture(PKDisplayGeometry scene, CGSize crop) {
    CompanionFixture *runner = companion(scene);
    if (![runner beginDuoCompanionTask] || ![runner bindDuoCompanionTarget]) return NO;
    if ([runner screenshot:NULL refreshViewport:NO]) {
        NSLog(@"a held picture was returned without a confirmed front read");
        return NO;
    }
    if ([runner sourceXML:NULL code:NULL]) return NO;
    return checkShot(runner, 2, crop, 255, @"held AX read preserves the confirmed task pane picture", NO);
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
        BOOL opensCalculator = checkTaskOpensCalculatorBesidePoki(geometry);
        BOOL afterSwitch = checkCompanionAfterSwitch(geometry, crop, NO);
        BOOL switchBeforeRead = checkCompanionAfterSwitch(geometry, crop, YES);
        BOOL bindingRetry = checkCompanionBindingRetry(geometry, crop);
        BOOL heldTaskPicture = checkCompanionTaskHeldPicture(geometry, crop);
        PKDisplayGeometry coverGeometry = {.bounds = CGRectMake(0, 0, 466, 678),
            .peer = CGRectNull, .nativeSize = cover, .toFixed = CGAffineTransformIdentity,
            .orientation = UIInterfaceOrientationPortrait, .routesDisplay = YES};
        __block BOOL coverFallback = NO, coverCompatLayout = NO, coverPortraitPNG = NO, coverLaunch = NO, coverHandoff = NO;
        dispatch_semaphore_t coverDone = dispatch_semaphore_create(0);
        dispatch_async(dispatch_queue_create("duo.cover.test", DISPATCH_QUEUE_SERIAL), ^{
            coverFallback = checkCoverWeChatUnavailableAXFallback(coverGeometry, cover);
            coverCompatLayout = checkCoverCompatKeyboardAndLeadingOffset(coverGeometry, cover);
            coverPortraitPNG = checkCoverPortraitOrientationPNGFallback(coverGeometry, cover);
            coverLaunch = checkCoverLaunchSkipsAXSnapshotAndIgnoresTransientLandscape(coverGeometry);
            coverHandoff = checkCoverSceneToBackgroundHandoffDuringScreenshot(coverGeometry, cover);
            dispatch_semaphore_signal(coverDone);
        });
        dispatch_semaphore_wait(coverDone, DISPATCH_TIME_FOREVER);
        return launchPlacement && recoveredEdge && picture && inset && activation && opensCalculator && afterSwitch &&
            switchBeforeRead && bindingRetry && heldTaskPicture && coverFallback && coverCompatLayout &&
            coverPortraitPNG && coverLaunch && coverHandoff ? 0 : 1;
    }
}

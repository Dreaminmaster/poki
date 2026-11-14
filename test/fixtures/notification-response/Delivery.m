#import "Delivery.h"
#import <Foundation/Foundation.h>

// Only the input payload is synthetic. Delivery uses the SDK's Objective-C delegate selector.
@interface TestNotification : NSObject
@property(nonatomic, strong) UNNotificationRequest *request;
@end
@implementation TestNotification
@end
@interface TestResponse : NSObject
@property(nonatomic, strong) TestNotification *notification;
@property(nonatomic, copy) NSString *actionIdentifier;
@end
@implementation TestResponse
@end

static void deliver(id<UNUserNotificationCenterDelegate> delegate, NSUInteger index) {
    NSArray *actions = @[UNNotificationDefaultActionIdentifier, @"approval.allow", @"approval.deny", @"unknown"];
    if (index == actions.count) {
        puts("PASS: notification responses complete on the main thread");
        exit(0);
    }
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.userInfo = index == 0 ? @{@"poki_link": @"poki://setup"} : @{@"approval": @"test-approval"};
    TestNotification *notification = [TestNotification new];
    notification.request = [UNNotificationRequest requestWithIdentifier:@"test" content:content trigger:nil];
    TestResponse *response = [TestResponse new];
    response.notification = notification;
    response.actionIdentifier = actions[index];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [delegate userNotificationCenter:UNUserNotificationCenter.currentNotificationCenter
          didReceiveNotificationResponse:(UNNotificationResponse *)response
                   withCompletionHandler:^{
            if (!NSThread.isMainThread) {
                fprintf(stderr, "FAIL: notification response completion must run on main thread (case %lu)\n", (unsigned long)index);
                exit(1);
            }
            deliver(delegate, index + 1);
        }];
    });
}
void checkNotificationResponses(id<UNUserNotificationCenterDelegate> delegate) {
    deliver(delegate, 0);
}

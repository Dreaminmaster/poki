#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Private XCTest calls, made from Objective-C so ARC and error out-parameters follow the
/// real method conventions (same approach as Poki's InProcess.m).
@interface PBHelper : NSObject
+ (nullable NSNumber *)requestBackgroundAssertionForPID:(int)pid;
+ (nullable id)snapshotForPID:(int)pid timeout:(NSTimeInterval)seconds status:(NSString * _Nullable * _Nullable)status;
+ (nullable id)snapshotForPID:(int)pid depth:(NSInteger)depth timeout:(NSTimeInterval)seconds status:(NSString * _Nullable * _Nullable)status;
+ (nullable id)snapshotOnCallerForPID:(int)pid status:(NSString * _Nullable * _Nullable)status;
+ (BOOL)setAttribute:(NSString *)name value:(id)value onSnapshot:(id)snapshot error:(NSString * _Nullable * _Nullable)error;
+ (NSString *)axRuntimeConstants;
+ (NSString *)describeAction:(NSInteger)action;
+ (BOOL)pressSnapshot:(id)snapshot action:(NSInteger)action error:(NSString * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END

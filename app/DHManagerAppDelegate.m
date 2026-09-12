// DHManagerAppDelegate.m — 管理器 App 入口（无 storyboard / 无 scene，纯代码建窗，iOS 14 起可用）

#import <UIKit/UIKit.h>
#import "DHRootViewController.h"

@interface DHManagerAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation DHManagerAppDelegate

- (BOOL)application:(__unused UIApplication *)application
    didFinishLaunchingWithOptions:(__unused NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    DHRootViewController *root = [[DHRootViewController alloc] initWithStyle:UITableViewStyleGrouped];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([DHManagerAppDelegate class]));
    }
}

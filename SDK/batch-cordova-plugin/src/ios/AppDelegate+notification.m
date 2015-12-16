#import "AppDelegate+notification.h"
#import "BatchCordovaPlugin.h"
#import <objc/runtime.h>


@implementation AppDelegate (notification)

- (id) getCommandInstance
{
    return [self.viewController getCommandInstance:@"Batch"];
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    [[self getCommandInstance] didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    [[self getCommandInstance] didFailToRegisterForRemoteNotificationsWithError:error];
}

@end

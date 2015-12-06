//
//  BatchCordovaPlugin.m
//  BatchCordovaPlugin
//
//  Copyright (c) 2015 Batch.com. All rights reserved.
//

#import "BatchCordovaPlugin.h"

@implementation BatchCordovaPlugin


#pragma mark Fake Selector tools

// Cordova calls the actions requested by Batch directly on this object's methods
// We want to forward to the bridge which already implements what we need, so
// override forwardInvocation: to forward to the bridge if needed
// Note that all Batch actions will have "ba_" added in front
// of them to ensure that there is no collision
//
// For reference, this is the signature of a Cordova call:
// - (void)action:(CDVInvokedUrlCommand*)command;
- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    NSString *selector = NSStringFromSelector(anInvocation.selector);
    //NSLog(@"Got selector %@", selector);
    
    if ([selector hasPrefix:@"BA_"])
    {
        @try
        {
            // It crashes if not __unsafe_unretained
            __unsafe_unretained CDVInvokedUrlCommand *command;
            [anInvocation getArgument:&command atIndex:2];
            [self callBatchBridgeWithAction:selector cordovaCommand:command];
        }
        @catch (NSException *exception)
        {
            NSLog(@"Error while getting the CDVInvokedUrlCommand");
        }
        
        return;
    }
    
    [super forwardInvocation:anInvocation];
}

- (BOOL)respondsToSelector:(SEL)aSelector
{
    //NSLog(@"Reponds to selector %@", NSStringFromSelector(aSelector));
    NSString *selector = NSStringFromSelector(aSelector);
    
    if ([selector hasPrefix:@"BA_"])
    {
        return true;
    }
    return [super respondsToSelector:aSelector];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    if ([NSStringFromSelector(aSelector) hasPrefix:@"BA_"])
    {
        return [BatchCordovaPlugin instanceMethodSignatureForSelector:@selector(batchFakeAction:)];
    }
    return [BatchCordovaPlugin instanceMethodSignatureForSelector:aSelector];
}

// Empty method used for faking the signature for bridge method instances
- (void)batchFakeAction:(CDVInvokedUrlCommand*)command
{
    
}

#pragma mark Cordova Plugin methods

- (void)pluginInitialize
{
    //NSLog(@"[Batch] DEBUG - PluginInitialize");
    setenv("BATCH_PLUGIN_VERSION", PluginVersion, 1);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_batchPushReceived:) name:BatchPushReceivedNotification object:nil];

    self->_wasLaunchedWithOptions = NO;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidFinishLaunchingNotification:)
                                                 name:@"UIApplicationDidFinishLaunchingNotification" object:nil];

    //[self.commandDelegate evalJs:@"batch._setupCallback()"];
    
    [Batch setLoggerDelegate:self];
}

- (void)onReset
{
    // When the webview navigates, the callback id is no longer usuable
    self.genericCallbackId = nil;
}

- (void)handleOpenURL:(NSNotification *)notification
{
    [super handleOpenURL:notification];
    
    NSURL* url = [notification object];
    
    if ([url isKindOfClass:[NSURL class]])
    {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-result"
        [BatchBridge call:REDEEM_URL withParameters:@{@"url": [url absoluteString]} callback:self];
    }
}
#pragma clang diagnostic pop



// Called by the javascript part of the plugin
- (void)_setupCallback:(CDVInvokedUrlCommand*)command
{
    //NSLog(@"[BatchCordovaCallback] DEBUG: Setting up the generic callback %@", command.callbackId);
    self.genericCallbackId = command.callbackId;
}


// set callback waiting for device token
- (void) waitForRemoteNotificationDeviceToken: (CDVInvokedUrlCommand*)command
{
    self->waitForRegisterRemoveNotificationCallbackId = command.callbackId;
}

// callback launched when device is registered for remote notification
- (void)didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
    NSString *token = [[[[deviceToken description] stringByReplacingOccurrencesOfString:@"<"withString:@""]
                        stringByReplacingOccurrencesOfString:@">" withString:@""]
                       stringByReplacingOccurrencesOfString: @" " withString: @""];
    
    CDVPluginResult *cdvResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:@{@"code": @(0), @"token": token}];
    if (!self->waitForRegisterRemoveNotificationCallbackId)
    {
        NSLog(@"[BatchCordovaCallback] Not sending device token to Batch, callback id not set.");
    }
    else
    {
        [self.commandDelegate sendPluginResult:cdvResult callbackId:self->waitForRegisterRemoveNotificationCallbackId];
    }
    self->waitForRegisterRemoveNotificationCallbackId = nil;
}

// callback launched when device is registered if remote notification has failed
- (void)didFailToRegisterForRemoteNotificationsWithError:(NSError *)error
{
    CDVPluginResult *cdvResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:@{@"code": @(error.code), @"error":error.localizedDescription}];
    if (!self->waitForRegisterRemoveNotificationCallbackId)
    {
        NSLog(@"[BatchCordovaCallback] Not sending device token error to Batch, callback id not set. Something bad happened.");
    }
    else
    {
        [self.commandDelegate sendPluginResult:cdvResult callbackId:self->waitForRegisterRemoveNotificationCallbackId];
    }
    self->waitForRegisterRemoveNotificationCallbackId = nil;
}

//callback launched when app is started by clicking on a notification
- (void)applicationDidFinishLaunchingNotification:(NSNotification *)notification
{
    NSDictionary *launchOptions = [notification userInfo];
    self->_wasLaunchedWithOptions = (notification && launchOptions);
}

-(void)unregister:(CDVInvokedUrlCommand*)command
{
    [[UIApplication sharedApplication] unregisterForRemoteNotifications];
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@""];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)_batchPushReceived:(NSNotification*)notification
{
    //NSLog(@"[Batch] DEBUG - BatchPush %@", notification.userInfo);
    if (!notification.userInfo)
    {
        NSLog(@"[Batch] Error: got a push with no userInfo.");
        return;
    }
    
    NSMutableDictionary *userInfo = [notification.userInfo mutableCopy];
    
    BOOL isColdStart =  self->_wasLaunchedWithOptions;
    self->_wasLaunchedWithOptions = NO;
    [userInfo setValue:@(isColdStart) forKey:@"coldstart"];
    
    UIApplicationState state = [UIApplication sharedApplication].applicationState;
    BOOL isInForeground = (state == UIApplicationStateActive) && !isColdStart;
    [userInfo setValue:@(isInForeground) forKey:@"foreground"];
    
    CDVPluginResult *cdvResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:@{@"action": @"_dispatchPush", @"payload": userInfo}];
    [cdvResult setKeepCallbackAsBool:YES];
    if (!self.genericCallbackId)
    {
        NSLog(@"[BatchCordovaCallback] Not sending push to Batch, _setupCallback doesn't seem to have been called. Something bad happened.");
    }
    else
    {
        [self.commandDelegate sendPluginResult:cdvResult callbackId:self.genericCallbackId];
    }
}

#pragma mark Bridge calls

- (void)callBatchBridgeWithAction:(NSString*)action cordovaCommand:(CDVInvokedUrlCommand*)cdvCommand
{
    // Remove "BA_" from the action
    NSString *cleanAction = [cdvCommand.methodName substringFromIndex:3];
    
    // Allows us to conditionally forward calls to the bridge. Useful so that we don't setup the modules or start Batch multiple times.
    // Not that it matters, but the logs are annoying.
    bool skipBridgeCall = NO;
    
    static bool batchStarted = NO;
    static bool pushSetup = NO;
    if ([START isEqualToString:cleanAction])
    {
        if (batchStarted)
        {
            skipBridgeCall = YES;
        }
        batchStarted = YES;
    }
    else if ([PUSH_SETUP isEqualToString:cleanAction])
    {
        if (pushSetup)
        {
            skipBridgeCall = YES;
        }
        pushSetup = YES;
    }
    
    //NSLog(@"[BatchCordova] DEBUG: Sending to bridge %@ %@ %@ %@", cleanAction, cdvCommand.className, cdvCommand.methodName, cdvCommand.arguments);
    NSString *bridgeResult = nil;
    if (!skipBridgeCall)
    {
        bridgeResult = [BatchBridge call:cleanAction withParameters:[cdvCommand.arguments objectAtIndex:0] callback:self];
    }
    
    // Thought using NO_RESULT was a good idea? Think again https://github.com/don/cordova-plugin-ble-central/issues/32
    CDVPluginResult *cdvResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:bridgeResult ? bridgeResult : @""];
    
    [self.commandDelegate sendPluginResult:cdvResult callbackId:cdvCommand.callbackId];
}

#pragma mark BatchLoggerDelegate

- (void)logWithMessage:(NSString*)message
{
    if (self.genericCallbackId)
    {
        CDVPluginResult *cdvResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:@{@"action":@"_log", @"message":message}];
        [cdvResult setKeepCallbackAsBool:YES];
    
        [self.commandDelegate sendPluginResult:cdvResult callbackId:self.genericCallbackId];
    }
}

#pragma mark Batch Callback
- (void)call:(NSString *)actionString withResult:(id<NSSecureCoding, NSObject>)result
{
    
    //NSLog(@"[BatchCordovaCallback] DEBUG: Sending action %@ to Cordova", actionString);
    
    if (![result isKindOfClass:[NSDictionary class]])
    {
        NSLog(@"[BatchCordovaCallback] Bridge's result is not a NSDictionary, aborting. (action: %@)", actionString);
        return;
    }
    
    CDVPluginResult *cdvResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:@{@"action": actionString, @"result":(NSDictionary*)result}];
    [cdvResult setKeepCallbackAsBool:YES];
    
    if (!self.genericCallbackId)
    {
        NSLog(@"[BatchCordovaCallback] Not sending callback to Batch, _setupCallback doesn't seem to have been called. Something bad happened.");
    }
    else
    {
        NSLog(@"[BatchCordovaCallback] %@ %@ %@", self.genericCallbackId, actionString, result);
        [self.commandDelegate sendPluginResult:cdvResult callbackId:self.genericCallbackId];
    }
}

@end
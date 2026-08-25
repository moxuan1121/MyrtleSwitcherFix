#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <substrate.h>
#if __has_include(<ptrauth.h>)
#import <ptrauth.h>
#endif

static id MRSafeValue(id object, NSString *key)
{
    if (object == nil || key.length == 0) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *MRFirstString(id object, NSArray<NSString *> *keys)
{
    for (NSString *key in keys) {
        id value = MRSafeValue(object, key);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) return value;
    }
    return nil;
}

static NSString *MRBundleIdentifierForScene(id scene)
{
    NSString *bundleID = MRFirstString(scene, @[@"applicationBundleIdentifier", @"bundleIdentifier"]);
    if ([bundleID containsString:@"."]) return bundleID;

    id process = MRSafeValue(scene, @"clientProcess");
    bundleID = MRFirstString(process, @[
        @"applicationBundleID", @"applicationBundleIdentifier", @"bundleIdentifier", @"bundleID"
    ]);
    if ([bundleID containsString:@"."]) return bundleID;

    id identity = MRSafeValue(process, @"identity");
    return MRFirstString(identity, @[
        @"embeddedApplicationIdentifier", @"applicationIdentifier", @"bundleIdentifier"
    ]);
}

static BOOL MRCallerIsMyrtle(void *address)
{
#if __has_include(<ptrauth.h>)
    address = ptrauth_strip(address, ptrauth_key_return_address);
#endif
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (address == NULL || dladdr(address, &info) == 0 || info.dli_fname == NULL) return NO;
    NSString *image = [NSString stringWithUTF8String:info.dli_fname];
    return [image.lastPathComponent isEqualToString:@"Myrtle.dylib"];
}

static BOOL MRIsOrdinaryApplicationIdentifier(NSString *bundleID)
{
    if (bundleID.length == 0 || ![bundleID containsString:@"."]) return NO;
    static NSSet<NSString *> *excluded;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        excluded = [NSSet setWithArray:@[@"com.apple.springboard", @"com.apple.UIKit"]];
    });
    return ![excluded containsObject:bundleID];
}

static id MRSendClassNoArgs(Class cls, SEL selector)
{
    if (cls == Nil || ![cls respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, selector);
}

static id MRSendObjectArg(id target, SEL selector, id argument)
{
    if (target == nil || ![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, argument);
}

static void MRAddApplicationToSwitcher(NSString *bundleID)
{
    if (!MRIsOrdinaryApplicationIdentifier(bundleID)) return;

    id controller = MRSendClassNoArgs(NSClassFromString(@"SBApplicationController"),
                                      NSSelectorFromString(@"sharedInstance"));
    id application = MRSendObjectArg(controller,
                                     NSSelectorFromString(@"applicationWithBundleIdentifier:"),
                                     bundleID);
    if (application == nil) return;

    Class layoutClass = NSClassFromString(@"SBDisplayLayout");
    SEL layoutSelector = NSSelectorFromString(@"fullScreenDisplayLayoutForApplication:");
    if (layoutClass == Nil || ![layoutClass respondsToSelector:layoutSelector]) return;
    id layout = ((id (*)(id, SEL, id))objc_msgSend)(layoutClass, layoutSelector, application);
    if (layout == nil) return;

    id model = MRSendClassNoArgs(NSClassFromString(@"SBAppSwitcherModel"),
                                 NSSelectorFromString(@"sharedInstance"));
    SEL addSelector = NSSelectorFromString(@"addToFront:");
    if (model != nil && [model respondsToSelector:addSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(model, addSelector, layout);
    }
}

static id (*MROriginalHostInit)(id, SEL, id, id) = NULL;

static id MRHookHostInit(id self, SEL selector, id scene, id description)
{
    void *caller = __builtin_return_address(0);
    id result = MROriginalHostInit != NULL ? MROriginalHostInit(self, selector, scene, description) : nil;
    if (result != nil && MRCallerIsMyrtle(caller)) {
        NSString *bundleID = MRBundleIdentifierForScene(scene);
        if (MRIsOrdinaryApplicationIdentifier(bundleID)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                MRAddApplicationToSwitcher(bundleID);
            });
        }
    }
    return result;
}

static BOOL MRInstallHostHook(void)
{
    SEL selector = NSSelectorFromString(@"initWithScene:debugDescription:");
    for (NSString *className in @[@"FBSceneLayerHostContainerView", @"FBSceneHostView"]) {
        Class cls = NSClassFromString(className);
        if (cls != Nil && class_getInstanceMethod(cls, selector) != NULL) {
            MSHookMessageEx(cls, selector, (IMP)MRHookHostInit, (IMP *)&MROriginalHostInit);
            return YES;
        }
    }
    return NO;
}

static void MRInstallWhenReady(NSUInteger attempt)
{
    if (MRInstallHostHook() || attempt >= 30) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        MRInstallWhenReady(attempt + 1);
    });
}

%ctor
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            MRInstallWhenReady(0);
        });
    }
}


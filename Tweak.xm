#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <stdlib.h>
#import <substrate.h>

static NSString *const MRLogPath = @"/var/mobile/Library/Preferences/com.local.myrtleswitcherfix.log";
static NSString *const MRCloseSelector = @"MT_IlllIIIlIIIlIlllIIIl::";
static __strong id MRObservedSwitcherModel = nil;

static void MRLog(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSData *data = [[NSString stringWithFormat:@"%@ %@\n", NSDate.date, message]
                    dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:MRLogPath];
    if (handle == nil) [data writeToFile:MRLogPath atomically:YES];
    else {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    }
}

static id MRSafeValue(id object, NSString *key)
{
    if (object == nil || key.length == 0) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static NSString *MRDirectBundleIdentifier(id object)
{
    if ([object isKindOfClass:NSString.class]) {
        NSString *value = object;
        return [value containsString:@"."] ? value : nil;
    }
    for (NSString *key in @[@"bundleIdentifier", @"displayIdentifier",
                             @"applicationBundleIdentifier", @"applicationBundleID",
                             @"bundleID", @"continuousExposeIdentifier"]) {
        id value = MRSafeValue(object, key);
        if ([value isKindOfClass:NSString.class] && [value containsString:@"."]) return value;
    }
    return nil;
}

static NSString *MRBundleIdentifierFromLayout(id layout)
{
    NSString *bundleID = MRDirectBundleIdentifier(layout);
    if (bundleID.length != 0) return bundleID;
    for (NSString *key in @[@"rolesToLayoutItemsMap", @"layoutItems", @"allItems", @"displayItems"]) {
        id collection = MRSafeValue(layout, key);
        NSArray *values = nil;
        if ([collection isKindOfClass:NSDictionary.class]) values = [collection allValues];
        else if ([collection isKindOfClass:NSArray.class]) values = collection;
        else if ([collection isKindOfClass:NSSet.class]) values = [collection allObjects];
        for (id item in values) {
            bundleID = MRDirectBundleIdentifier(item);
            if (bundleID.length != 0) return bundleID;
        }
    }
    return nil;
}

static id MRSendClassNoArgs(NSString *className, NSString *selectorName)
{
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    if (cls == Nil || ![cls respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, selector);
}

static id MRSendObject(id target, NSString *selectorName, id argument)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, argument);
}

static id MRMainSwitcherCoordinator(void)
{
    return MRSendClassNoArgs(@"SBMainSwitcherControllerCoordinator", @"sharedInstance");
}

static id MRContainedObjectOfClass(id owner, Class wantedClass)
{
    if (owner == nil || wantedClass == Nil) return nil;
    for (NSString *key in @[@"appSwitcherModel", @"_appSwitcherModel",
                             @"switcherModel", @"_switcherModel", @"model", @"_model"]) {
        id value = MRSafeValue(owner, key);
        if ([value isKindOfClass:wantedClass]) return value;
    }
    for (Class cls = [owner class]; cls != Nil; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            const char *type = ivar_getTypeEncoding(ivars[index]);
            if (type == NULL || type[0] != '@') continue;
            id value = object_getIvar(owner, ivars[index]);
            if ([value isKindOfClass:wantedClass]) {
                free(ivars);
                return value;
            }
        }
        free(ivars);
    }
    return nil;
}

static void MRLogRelevantMethods(id object, NSString *label);

static id MRAppSwitcherModel(void)
{
    if (MRObservedSwitcherModel != nil) return MRObservedSwitcherModel;
    // iOS 15 owns this model from the main switcher coordinator; the model
    // itself deliberately has no +sharedInstance.
    return MRContainedObjectOfClass(MRMainSwitcherCoordinator(),
                                    NSClassFromString(@"SBAppSwitcherModel"));
}

typedef id (*MRSwitcherModelInitIMP)(id, SEL);
static MRSwitcherModelInitIMP MROriginalSwitcherModelInit = NULL;

static id MRHookSwitcherModelInit(id self, SEL selector)
{
    id result = MROriginalSwitcherModelInit(self, selector);
    MRObservedSwitcherModel = result;
    MRLog(@"captured real SBAppSwitcherModel instance=%@", result);
    MRLogRelevantMethods(result, @"captured switcher model");
    return result;
}

static BOOL MRInstallSwitcherModelCapture(void)
{
    Class cls = NSClassFromString(@"SBAppSwitcherModel");
    SEL selector = @selector(init);
    Method method = class_getInstanceMethod(cls, selector);
    if (cls == Nil || method == NULL || method_getNumberOfArguments(method) != 2) {
        MRLog(@"SBAppSwitcherModel init unavailable");
        return NO;
    }
    MSHookMessageEx(cls, selector, (IMP)MRHookSwitcherModelInit,
                    (IMP *)&MROriginalSwitcherModelInit);
    MRLog(@"installed SBAppSwitcherModel init capture");
    return MROriginalSwitcherModelInit != NULL;
}

static void MRLogRelevantMethods(id object, NSString *label)
{
    if (object == nil) {
        MRLog(@"%@ unavailable", label);
        return;
    }
    NSMutableArray *result = [NSMutableArray array];
    unsigned int count = 0;
    Method *methods = class_copyMethodList([object class], &count);
    for (unsigned int index = 0; index < count; index++) {
        NSString *name = NSStringFromSelector(method_getName(methods[index]));
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"layout"] || [lower containsString:@"front"] ||
            [lower containsString:@"recent"] || [lower containsString:@"add"])
            [result addObject:name];
    }
    free(methods);
    MRLog(@"%@ class=%@ relevantMethods=%@", label,
          NSStringFromClass([object class]), result);
}

static id MRExistingAppLayout(NSString *bundleID)
{
    id model = MRAppSwitcherModel();
    id layouts = MRSafeValue(model, @"recentAppLayouts");
    if (![layouts isKindOfClass:NSArray.class]) {
        for (NSString *key in @[@"layouts", @"appLayouts", @"allLayouts", @"snapshot"]) {
            id candidate = MRSafeValue(layouts, key);
            if ([candidate isKindOfClass:NSArray.class]) {
                layouts = candidate;
                break;
            }
        }
    }
    if (![layouts isKindOfClass:NSArray.class]) return nil;
    for (id layout in layouts) {
        NSString *candidate = MRBundleIdentifierFromLayout(layout);
        if ([candidate caseInsensitiveCompare:bundleID] == NSOrderedSame) return layout;
    }
    return nil;
}

static id MRCompatibilityDisplayLayout(id application)
{
    Class cls = NSClassFromString(@"SBDisplayLayout");
    SEL selector = NSSelectorFromString(@"fullScreenDisplayLayoutForApplication:");
    if (cls != Nil && [cls respondsToSelector:selector])
        return ((id (*)(id, SEL, id))objc_msgSend)(cls, selector, application);
    return nil;
}

static BOOL MRAddLayoutToFront(id model, id layout, NSArray<NSString *> *selectorNames)
{
    for (NSString *name in selectorNames) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod([model class], selector);
        if (model == nil || ![model respondsToSelector:selector] ||
            method == NULL || method_getNumberOfArguments(method) != 3) continue;
        ((void (*)(id, SEL, id))objc_msgSend)(model, selector, layout);
        MRLog(@"sent %@ with %@", name, NSStringFromClass([layout class]));
        return YES;
    }
    return NO;
}

static void MRAddApplicationToSwitcher(NSString *bundleID)
{
    if (bundleID.length == 0 || ![bundleID containsString:@"."]) return;
    id coordinator = MRMainSwitcherCoordinator();
    id model = MRAppSwitcherModel();
    id appController = MRSendClassNoArgs(@"SBApplicationController", @"sharedInstance");
    id application = MRSendObject(appController, @"applicationWithBundleIdentifier:", bundleID);
    if (model == nil || application == nil) {
        MRLog(@"cannot add %@: coordinator=%@ model=%@ application=%@",
              bundleID, coordinator, model, application);
        static dispatch_once_t diagnosticOnce;
        dispatch_once(&diagnosticOnce, ^{
            MRLogRelevantMethods(coordinator, @"coordinator");
            MRLogRelevantMethods(model, @"switcher model");
        });
        return;
    }

    // Never pass an SBAppLayout to the legacy addToFront: API. On iOS 15 the
    // two layout classes coexist, and mixing them is a SpringBoard crash risk.
    id existing = MRExistingAppLayout(bundleID);
    BOOL sent = existing != nil && MRAddLayoutToFront(model, existing,
        @[@"addToFront:", @"addAppLayoutToFront:", @"_addAppLayoutToFront:"]);
    NSString *source = @"recentAppLayouts";
    if (!sent) {
        id compatibilityLayout = MRCompatibilityDisplayLayout(application);
        source = @"SBDisplayLayout compatibility factory";
        sent = compatibilityLayout != nil &&
               MRAddLayoutToFront(model, compatibilityLayout, @[@"addToFront:"]);
        if (compatibilityLayout == nil) MRLog(@"no compatible layout for %@", bundleID);
    }
    MRLog(@"add %@ source=%@ sent=%d", bundleID, source, sent);
}

typedef void (*MRSetCurrentBundleIMP)(id, SEL, NSString *);
static MRSetCurrentBundleIMP MROriginalSetCurrentBundle = NULL;

static void MRHookSetCurrentBundle(id self, SEL selector, NSString *bundleID)
{
    MROriginalSetCurrentBundle(self, selector, bundleID);
    NSString *stableBundleID = [bundleID copy];
    MRLog(@"Myrtle committed currentBundleID=%@", stableBundleID);
    if (stableBundleID.length == 0) return;
    for (NSNumber *delay in @[@0.0, @0.35, @1.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
            NSString *current = MRSafeValue(manager, @"currentBundleID");
            if ([current isEqualToString:stableBundleID]) MRAddApplicationToSwitcher(stableBundleID);
        });
    }
}

static void MRCloseMyrtleWindowForBundleID(NSString *bundleID)
{
    id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
    NSString *current = MRSafeValue(manager, @"currentBundleID");
    if (bundleID.length == 0 || ![current isEqualToString:bundleID]) return;
    SEL selector = NSSelectorFromString(MRCloseSelector);
    Method method = class_getInstanceMethod([manager class], selector);
    if (manager != nil && [manager respondsToSelector:selector] &&
        method != NULL && method_getNumberOfArguments(method) == 4) {
        MRLog(@"closing Myrtle host after switcher deleted %@", bundleID);
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(manager, selector, YES, nil);
    } else MRLog(@"Myrtle close selector unavailable for %@", bundleID);
}

typedef void (*MRDeleteLayoutIMP)(id, SEL, id, long long);
static MRDeleteLayoutIMP MROriginalDeleteLayout = NULL;

static void MRHookDeleteLayout(id self, SEL selector, id layout, long long reason)
{
    NSString *bundleID = [MRBundleIdentifierFromLayout(layout) copy];
    MROriginalDeleteLayout(self, selector, layout, reason);
    MRCloseMyrtleWindowForBundleID(bundleID);
}

static BOOL MRInstallMyrtleHook(void)
{
    Class cls = NSClassFromString(@"MyrtleHostManager");
    SEL selector = NSSelectorFromString(@"setCurrentBundleID:");
    Method method = class_getInstanceMethod(cls, selector);
    if (cls == Nil || method == NULL || method_getNumberOfArguments(method) != 3) return NO;
    MSHookMessageEx(cls, selector, (IMP)MRHookSetCurrentBundle,
                    (IMP *)&MROriginalSetCurrentBundle);
    MRLog(@"installed direct MyrtleHostManager hook");
    return MROriginalSetCurrentBundle != NULL;
}

static void MRInstallSwitcherDeleteHook(void)
{
    Class cls = NSClassFromString(@"SBMainSwitcherControllerCoordinator");
    SEL selector = NSSelectorFromString(@"_deleteAppLayout:forReason:");
    Method method = class_getInstanceMethod(cls, selector);
    if (cls != Nil && method != NULL && method_getNumberOfArguments(method) == 4) {
        MSHookMessageEx(cls, selector, (IMP)MRHookDeleteLayout,
                        (IMP *)&MROriginalDeleteLayout);
        MRLog(@"installed switcher deletion hook");
    } else MRLog(@"switcher deletion method unavailable");
}

static void MRInstallWhenReady(NSUInteger attempt)
{
    if (MRInstallMyrtleHook()) return;
    if (attempt >= 60) {
        MRLog(@"MyrtleHostManager was not loaded after 60 seconds");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ MRInstallWhenReady(attempt + 1); });
}

%ctor
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            MRLog(@"MyrtleSwitcherFix 0.3.4 model-init capture loaded");
            MRInstallSwitcherModelCapture();
            MRInstallSwitcherDeleteHook();
            MRInstallWhenReady(0);
        });
    }
}

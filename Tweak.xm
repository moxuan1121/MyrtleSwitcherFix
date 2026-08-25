#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <substrate.h>

static NSString *const MRLogPath = @"/var/mobile/Library/Preferences/com.local.myrtleswitcherfix.log";
static NSString *const MRCloseSelector = @"MT_IlllIIIlIIIlIlllIIIl::";
static __strong NSString *MRPendingFrontBundleID = nil;
static BOOL MRReconcilingFront = NO;

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

static id MRSendClassNoArgs(NSString *className, NSString *selectorName)
{
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    if (cls == Nil || ![cls respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, selector);
}

static id MRMainSwitcher(void)
{
    // iOS 15.5/15.6 owns both the recents UI and its model from this singleton.
    return MRSendClassNoArgs(@"SBMainSwitcherViewController", @"sharedInstance");
}

static NSArray *MRRecentAppLayouts(id switcher)
{
    SEL selector = NSSelectorFromString(@"recentAppLayouts");
    if (switcher == nil || ![switcher respondsToSelector:selector]) return nil;
    id result = ((id (*)(id, SEL))objc_msgSend)(switcher, selector);
    return [result isKindOfClass:NSArray.class] ? result : nil;
}

static NSString *MRDirectBundleIdentifier(id object)
{
    if ([object isKindOfClass:NSString.class]) {
        NSString *value = object;
        return [value containsString:@"."] ? value : nil;
    }
    for (NSString *key in @[@"bundleIdentifier", @"displayIdentifier",
                             @"applicationBundleIdentifier", @"applicationBundleID",
                             @"bundleID"]) {
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

static BOOL MRLayoutContainsBundleIdentifier(id layout, NSString *bundleID)
{
    SEL selector = NSSelectorFromString(@"containsItemWithBundleIdentifier:");
    if (layout != nil && [layout respondsToSelector:selector])
        return ((BOOL (*)(id, SEL, id))objc_msgSend)(layout, selector, bundleID);
    return [[MRBundleIdentifierFromLayout(layout) lowercaseString]
            isEqualToString:bundleID.lowercaseString];
}

static id MRLayoutForBundleIdentifier(NSArray *layouts, NSString *bundleID,
                                      NSUInteger *indexOut)
{
    NSUInteger index = 0;
    for (id layout in layouts) {
        if (MRLayoutContainsBundleIdentifier(layout, bundleID)) {
            if (indexOut != NULL) *indexOut = index;
            return layout;
        }
        index++;
    }
    if (indexOut != NULL) *indexOut = NSNotFound;
    return nil;
}

static BOOL MRHasInstanceMethod(Class cls, NSString *name, unsigned int argumentCount)
{
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
    return method != NULL && method_getNumberOfArguments(method) == argumentCount;
}

static void MRLogSwitcherCapabilities(id switcher)
{
    Class cls = [switcher class];
    NSArray *layouts = MRRecentAppLayouts(switcher);
    MRLog(@"switcher=%@ class=%@ layouts=%lu recent=%d promote=%d insert=%d remove=%d changed=%d",
          switcher, NSStringFromClass(cls), (unsigned long)layouts.count,
          MRHasInstanceMethod(cls, @"recentAppLayouts", 2),
          MRHasInstanceMethod(cls, @"_addAppLayoutToFront:", 3),
          MRHasInstanceMethod(cls, @"_insertCardForDisplayIdentifier:atIndex:", 4),
          MRHasInstanceMethod(cls, @"_removeAppLayout:forReason:", 4),
          MRHasInstanceMethod(cls, @"_switcherModelChanged:", 3));
}

static void MRVerifySwitcherResult(NSString *bundleID, NSString *action)
{
    id switcher = MRMainSwitcher();
    NSArray *layouts = MRRecentAppLayouts(switcher);
    NSUInteger index = NSNotFound;
    id layout = MRLayoutForBundleIdentifier(layouts, bundleID, &index);
    MRLog(@"verify %@ action=%@ found=%d index=%@ count=%lu layoutClass=%@",
          bundleID, action, layout != nil,
          index == NSNotFound ? @"NSNotFound" : [NSString stringWithFormat:@"%lu", (unsigned long)index],
          (unsigned long)layouts.count,
          layout == nil ? @"(null)" : NSStringFromClass([layout class]));
}

static void MRReconcilePendingFront(NSString *trigger)
{
    if (MRReconcilingFront || MRPendingFrontBundleID.length == 0) return;
    NSString *bundleID = [MRPendingFrontBundleID copy];
    id switcher = MRMainSwitcher();
    NSArray *layouts = MRRecentAppLayouts(switcher);
    NSUInteger index = NSNotFound;
    id layout = MRLayoutForBundleIdentifier(layouts, bundleID, &index);
    if (layout == nil) {
        MRLog(@"reconcile %@ trigger=%@ pending-not-materialized count=%lu",
              bundleID, trigger, (unsigned long)layouts.count);
        return;
    }

    if (index != 0) {
        SEL selector = NSSelectorFromString(@"_addAppLayoutToFront:");
        if (![switcher respondsToSelector:selector]) {
            MRLog(@"reconcile %@ trigger=%@ promote-unavailable index=%lu",
                  bundleID, trigger, (unsigned long)index);
            return;
        }
        MRReconcilingFront = YES;
        ((void (*)(id, SEL, id))objc_msgSend)(switcher, selector, layout);
        MRReconcilingFront = NO;
        MRLog(@"reconcile promoted %@ trigger=%@ oldIndex=%lu",
              bundleID, trigger, (unsigned long)index);
    }

    NSArray *updatedLayouts = MRRecentAppLayouts(switcher);
    NSUInteger updatedIndex = NSNotFound;
    id updatedLayout = MRLayoutForBundleIdentifier(updatedLayouts, bundleID, &updatedIndex);
    MRLog(@"reconcile verify %@ trigger=%@ found=%d index=%@ count=%lu",
          bundleID, trigger, updatedLayout != nil,
          updatedIndex == NSNotFound ? @"NSNotFound" : [NSString stringWithFormat:@"%lu", (unsigned long)updatedIndex],
          (unsigned long)updatedLayouts.count);
    if (updatedLayout != nil && updatedIndex == 0 &&
        [MRPendingFrontBundleID isEqualToString:bundleID]) {
        MRPendingFrontBundleID = nil;
    }
}

static void MRPromoteOrInsertSwitcherCard(NSString *bundleID)
{
    if (bundleID.length == 0 || ![bundleID containsString:@"."]) return;

    id switcher = MRMainSwitcher();
    id appController = MRSendClassNoArgs(@"SBApplicationController", @"sharedInstance");
    SEL appSelector = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    id application = nil;
    if (appController != nil && [appController respondsToSelector:appSelector])
        application = ((id (*)(id, SEL, id))objc_msgSend)(appController, appSelector, bundleID);

    if (switcher == nil || application == nil) {
        MRLog(@"cannot handle %@: switcher=%@ application=%@", bundleID, switcher, application);
        return;
    }

    static dispatch_once_t capabilityOnce;
    dispatch_once(&capabilityOnce, ^{ MRLogSwitcherCapabilities(switcher); });

    NSArray *layouts = MRRecentAppLayouts(switcher);
    NSUInteger oldIndex = NSNotFound;
    id existing = MRLayoutForBundleIdentifier(layouts, bundleID, &oldIndex);
    NSString *action = nil;

    if (existing != nil) {
        MRPendingFrontBundleID = nil;
        SEL promoteSelector = NSSelectorFromString(@"_addAppLayoutToFront:");
        if (![switcher respondsToSelector:promoteSelector] ||
            !MRHasInstanceMethod([switcher class], @"_addAppLayoutToFront:", 3)) {
            MRLog(@"cannot promote %@: _addAppLayoutToFront: unavailable", bundleID);
            return;
        }
        ((void (*)(id, SEL, id))objc_msgSend)(switcher, promoteSelector, existing);
        action = @"promote-existing";
        MRLog(@"sent promote %@ oldIndex=%lu layoutClass=%@", bundleID,
              (unsigned long)oldIndex, NSStringFromClass([existing class]));
    } else {
        SEL insertSelector = NSSelectorFromString(@"_insertCardForDisplayIdentifier:atIndex:");
        if (![switcher respondsToSelector:insertSelector] ||
            !MRHasInstanceMethod([switcher class], @"_insertCardForDisplayIdentifier:atIndex:", 4)) {
            MRLog(@"cannot insert %@: _insertCardForDisplayIdentifier:atIndex: unavailable", bundleID);
            return;
        }
        MRPendingFrontBundleID = [bundleID copy];
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(switcher, insertSelector, bundleID, 0);
        action = @"insert-absent";
        MRLog(@"sent insert %@ atIndex=0", bundleID);
    }

    if ([action isEqualToString:@"promote-existing"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ MRVerifySwitcherResult(bundleID, action); });
    } else {
        NSArray<NSNumber *> *delays = @[@0.75, @1.5, @3.0, @6.0];
        for (NSNumber *delay in delays) {
            NSString *trigger = [NSString stringWithFormat:@"timer-%.2fs", delay.doubleValue];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ MRReconcilePendingFront(trigger); });
        }
    }
}

typedef void (*MRSetCurrentBundleIMP)(id, SEL, NSString *);
static MRSetCurrentBundleIMP MROriginalSetCurrentBundle = NULL;

static void MRHookSetCurrentBundle(id self, SEL selector, NSString *bundleID)
{
    MROriginalSetCurrentBundle(self, selector, bundleID);
    NSString *stableBundleID = [bundleID copy];
    MRLog(@"Myrtle committed currentBundleID=%@", stableBundleID);
    if (stableBundleID.length == 0) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
        NSString *current = MRSafeValue(manager, @"currentBundleID");
        if ([current isEqualToString:stableBundleID])
            MRPromoteOrInsertSwitcherCard(stableBundleID);
        else
            MRLog(@"skip %@ because Myrtle currentBundleID changed to %@", stableBundleID, current);
    });
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
        MRLog(@"closing Myrtle host after switcher removed %@", bundleID);
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(manager, selector, YES, nil);
    } else {
        MRLog(@"Myrtle close selector unavailable for %@", bundleID);
    }
}

typedef void (*MRRemoveLayoutIMP)(id, SEL, id, long long);
static MRRemoveLayoutIMP MROriginalRemoveLayout = NULL;

typedef void (*MRModelChangedIMP)(id, SEL, id);
static MRModelChangedIMP MROriginalModelChanged = NULL;

typedef void (*MRViewWillAppearIMP)(id, SEL, BOOL);
static MRViewWillAppearIMP MROriginalViewWillAppear = NULL;

static void MRHookRemoveLayout(id self, SEL selector, id layout, long long reason)
{
    NSString *bundleID = [MRBundleIdentifierFromLayout(layout) copy];
    MRLog(@"switcher removing %@ reason=%lld layoutClass=%@", bundleID, reason,
          layout == nil ? @"(null)" : NSStringFromClass([layout class]));
    MROriginalRemoveLayout(self, selector, layout, reason);
    MRCloseMyrtleWindowForBundleID(bundleID);
}

static void MRHookModelChanged(id self, SEL selector, id model)
{
    MROriginalModelChanged(self, selector, model);
    if (MRPendingFrontBundleID.length != 0 && !MRReconcilingFront)
        dispatch_async(dispatch_get_main_queue(), ^{ MRReconcilePendingFront(@"model-changed"); });
}

static void MRHookViewWillAppear(id self, SEL selector, BOOL animated)
{
    MROriginalViewWillAppear(self, selector, animated);
    if (MRPendingFrontBundleID.length != 0)
        dispatch_async(dispatch_get_main_queue(), ^{ MRReconcilePendingFront(@"view-will-appear"); });
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

static void MRInstallSwitcherRemoveHook(void)
{
    Class cls = NSClassFromString(@"SBMainSwitcherViewController");
    SEL selector = NSSelectorFromString(@"_removeAppLayout:forReason:");
    Method method = class_getInstanceMethod(cls, selector);
    if (cls != Nil && method != NULL && method_getNumberOfArguments(method) == 4) {
        MSHookMessageEx(cls, selector, (IMP)MRHookRemoveLayout,
                        (IMP *)&MROriginalRemoveLayout);
        MRLog(@"installed SBMainSwitcherViewController removal hook");
    } else {
        MRLog(@"SBMainSwitcherViewController removal method unavailable");
    }
}

static void MRInstallSwitcherReconciliationHooks(void)
{
    Class cls = NSClassFromString(@"SBMainSwitcherViewController");
    SEL changedSelector = NSSelectorFromString(@"_switcherModelChanged:");
    Method changedMethod = class_getInstanceMethod(cls, changedSelector);
    if (cls != Nil && changedMethod != NULL && method_getNumberOfArguments(changedMethod) == 3) {
        MSHookMessageEx(cls, changedSelector, (IMP)MRHookModelChanged,
                        (IMP *)&MROriginalModelChanged);
        MRLog(@"installed switcher model-change reconciliation hook");
    } else {
        MRLog(@"switcher model-change reconciliation method unavailable");
    }

    SEL appearSelector = @selector(viewWillAppear:);
    Method appearMethod = class_getInstanceMethod(cls, appearSelector);
    if (cls != Nil && appearMethod != NULL && method_getNumberOfArguments(appearMethod) == 3) {
        MSHookMessageEx(cls, appearSelector, (IMP)MRHookViewWillAppear,
                        (IMP *)&MROriginalViewWillAppear);
        MRLog(@"installed switcher appearance reconciliation hook");
    } else {
        MRLog(@"switcher appearance reconciliation method unavailable");
    }
}

static void MRInstallMyrtleWhenReady(NSUInteger attempt)
{
    if (MRInstallMyrtleHook()) return;
    if (attempt >= 60) {
        MRLog(@"MyrtleHostManager was not loaded after 60 seconds");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ MRInstallMyrtleWhenReady(attempt + 1); });
}

%ctor
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            MRLog(@"MyrtleSwitcherFix 0.3.6 async front reconciliation loaded");
            MRInstallSwitcherRemoveHook();
            MRInstallSwitcherReconciliationHooks();
            id existingSwitcher = MRSendClassNoArgs(@"SBMainSwitcherViewController", @"sharedInstanceIfExists");
            if (existingSwitcher != nil) MRLogSwitcherCapabilities(existingSwitcher);
            MRInstallMyrtleWhenReady(0);
        });
    }
}

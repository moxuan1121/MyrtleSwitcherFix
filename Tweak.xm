#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <substrate.h>

static NSString *const MRLogPath = @"/var/mobile/Library/Preferences/com.moxuan.myrtleswitcherfix.log";
static NSString *const MRCloseSelector = @"MT_IlllIIIlIIIlIlllIIIl::";
static const unsigned long long MRMaximumLogSize = 1024 * 1024;
static __strong NSMutableArray<NSString *> *MRDesiredFrontOrder = nil;
static __strong NSString *MRUnderlyingMainBundleID = nil;
static __strong NSString *MRMyrtleFullscreenIntentBundleID = nil;
static __strong NSString *MRRecentlyClosedMyrtleBundleID = nil;
static BOOL MRReconcilingFront = NO;
static NSUInteger MRDesiredFrontGeneration = 0;
static NSUInteger MRReturnToMainGeneration = 0;
static NSUInteger MRMyrtleFullscreenIntentGeneration = 0;
static NSTimeInterval MRRecentlyClosedMyrtleTime = 0;

static void MRLog(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSData *data = [[NSString stringWithFormat:@"%@ %@\n", NSDate.date, message]
                    dataUsingEncoding:NSUTF8StringEncoding];
    unsigned long long size = [[[NSFileManager defaultManager]
                                attributesOfItemAtPath:MRLogPath error:nil]
                               fileSize];
    if (size >= MRMaximumLogSize) {
        NSData *rotated = [[NSString stringWithFormat:
                            @"%@ log reset after reaching 1 MiB\n%@",
                            NSDate.date, [[NSString alloc] initWithData:data
                                                               encoding:NSUTF8StringEncoding]]
                           dataUsingEncoding:NSUTF8StringEncoding];
        [rotated writeToFile:MRLogPath atomically:YES];
        return;
    }
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
    MRLog(@"switcher=%@ class=%@ layouts=%lu recent=%d promote=%d addDisplay=%d remove=%d changed=%d",
          switcher, NSStringFromClass(cls), (unsigned long)layouts.count,
          MRHasInstanceMethod(cls, @"recentAppLayouts", 2),
          MRHasInstanceMethod(cls, @"_addAppLayoutToFront:", 3),
          MRHasInstanceMethod(cls, @"addAppLayoutForDisplayItem:completion:", 4),
          MRHasInstanceMethod(cls, @"_removeAppLayout:forReason:", 4),
          MRHasInstanceMethod(cls, @"_switcherModelChanged:", 3));
}

static NSUInteger MREnqueueDesiredFront(NSString *bundleID)
{
    if (bundleID.length == 0) return MRDesiredFrontGeneration;
    if (MRDesiredFrontOrder == nil) MRDesiredFrontOrder = [NSMutableArray array];
    [MRDesiredFrontOrder removeObject:bundleID];
    [MRDesiredFrontOrder addObject:bundleID];
    while (MRDesiredFrontOrder.count > 32) [MRDesiredFrontOrder removeObjectAtIndex:0];
    MRDesiredFrontGeneration++;
    MRLog(@"desired front generation=%lu oldest-to-newest=%@",
          (unsigned long)MRDesiredFrontGeneration, MRDesiredFrontOrder);
    return MRDesiredFrontGeneration;
}

static void MRRemoveDesiredFront(NSString *bundleID)
{
    if (bundleID.length == 0) return;
    [MRDesiredFrontOrder removeObject:bundleID];
    MRLog(@"removed %@ from desired order remaining=%@", bundleID, MRDesiredFrontOrder);
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

static BOOL MRReconcilePendingFront(NSString *trigger)
{
    if (MRReconcilingFront || MRDesiredFrontOrder.count == 0) return NO;
    NSArray<NSString *> *desired = [MRDesiredFrontOrder copy];
    id switcher = MRMainSwitcher();
    NSArray *layouts = MRRecentAppLayouts(switcher);
    NSMutableArray<NSString *> *resolvedIDs = [NSMutableArray array];
    NSMutableArray *resolvedLayouts = [NSMutableArray array];
    for (NSString *bundleID in desired) {
        id layout = MRLayoutForBundleIdentifier(layouts, bundleID, NULL);
        if (layout != nil) {
            [resolvedIDs addObject:bundleID];
            [resolvedLayouts addObject:layout];
        }
    }

    BOOL stable = resolvedIDs.count == desired.count;
    NSArray<NSString *> *expectedFront = [[resolvedIDs reverseObjectEnumerator] allObjects];
    if (stable && layouts.count >= expectedFront.count) {
        for (NSUInteger index = 0; index < expectedFront.count; index++) {
            if (!MRLayoutContainsBundleIdentifier(layouts[index], expectedFront[index])) {
                stable = NO;
                break;
            }
        }
    } else {
        stable = NO;
    }

    if (!stable && resolvedLayouts.count != 0) {
        SEL selector = NSSelectorFromString(@"_addAppLayoutToFront:");
        if (![switcher respondsToSelector:selector]) return NO;
        MRReconcilingFront = YES;
        for (NSUInteger index = 0; index < resolvedLayouts.count; index++) {
            ((void (*)(id, SEL, id))objc_msgSend)(switcher, selector, resolvedLayouts[index]);
            MRLog(@"reconcile promoted %@ trigger=%@", resolvedIDs[index], trigger);
        }
        MRReconcilingFront = NO;
    }

    NSArray *updatedLayouts = MRRecentAppLayouts(switcher);
    NSMutableArray<NSString *> *actualFront = [NSMutableArray array];
    for (NSUInteger index = 0; index < MIN(updatedLayouts.count, expectedFront.count); index++) {
        NSString *bundleID = MRBundleIdentifierFromLayout(updatedLayouts[index]);
        [actualFront addObject:bundleID ?: @"(unknown)"];
    }
    BOOL allMaterialized = resolvedIDs.count == desired.count;
    BOOL verified = allMaterialized && actualFront.count == expectedFront.count;
    if (verified) {
        for (NSUInteger index = 0; index < expectedFront.count; index++) {
            if (!MRLayoutContainsBundleIdentifier(updatedLayouts[index], expectedFront[index])) {
                verified = NO;
                break;
            }
        }
    }
    MRLog(@"reconcile trigger=%@ desired=%@ resolved=%@ expectedFront=%@ actualFront=%@ all=%d verified=%d count=%lu",
          trigger, desired, resolvedIDs, expectedFront, actualFront,
          allMaterialized, verified, (unsigned long)updatedLayouts.count);
    return verified;
}

static void MRScheduleFrontReconciliation(NSUInteger generation)
{
    NSArray<NSNumber *> *delays = @[@0.75, @1.5, @3.0, @6.0, @10.0];
    for (NSNumber *delay in delays) {
        BOOL finalAttempt = delay.doubleValue == 10.0;
        NSString *trigger = [NSString stringWithFormat:@"batch-%lu-%.2fs",
                             (unsigned long)generation, delay.doubleValue];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (generation != MRDesiredFrontGeneration) {
                MRLog(@"skip stale reconciliation %@ currentGeneration=%lu",
                      trigger, (unsigned long)MRDesiredFrontGeneration);
                return;
            }
            BOOL verified = MRReconcilePendingFront(trigger);
            if (finalAttempt && generation == MRDesiredFrontGeneration) {
                NSArray *expired = [MRDesiredFrontOrder copy];
                [MRDesiredFrontOrder removeAllObjects];
                MRDesiredFrontGeneration++;
                MRLog(@"finished reconciliation generation=%lu verified=%d cleared=%@",
                      (unsigned long)generation, verified, expired);
            }
        });
    }
}

static id MRMyrtleSceneForApplication(id application)
{
    Class cls = NSClassFromString(@"MyrtleHostCore");
    SEL selector = NSSelectorFromString(@"MT_IllllIIlllIllIllllIl:");
    Method method = class_getClassMethod(cls, selector);
    if (cls == Nil || method == NULL || method_getNumberOfArguments(method) != 3) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(cls, selector, application); }
    @catch (NSException *exception) {
        MRLog(@"Myrtle scene lookup exception for %@: %@", application, exception);
        return nil;
    }
}

static NSString *MRSceneIdentifier(id application, id *sceneOut)
{
    id scene = MRMyrtleSceneForApplication(application);
    if (sceneOut != NULL) *sceneOut = scene;
    id identifier = MRSafeValue(scene, @"identifier");
    if (![identifier isKindOfClass:NSString.class] || [identifier length] == 0)
        identifier = MRSafeValue(application, @"_baseSceneIdentifier");
    return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}

static BOOL MRAddProductionDisplayItem(id switcher, id application, NSString *bundleID)
{
    id scene = nil;
    NSString *sceneIdentifier = MRSceneIdentifier(application, &scene);
    if (sceneIdentifier.length == 0) {
        MRLog(@"refusing production add %@ because no real scene identifier was found; scene=%@",
              bundleID, scene);
        return NO;
    }
    Class displayItemClass = NSClassFromString(@"SBDisplayItem");
    SEL factory = NSSelectorFromString(@"applicationDisplayItemWithBundleIdentifier:sceneIdentifier:");
    Method factoryMethod = class_getClassMethod(displayItemClass, factory);
    if (displayItemClass == Nil || factoryMethod == NULL ||
        method_getNumberOfArguments(factoryMethod) != 4) {
        MRLog(@"cannot create production display item for %@: factory unavailable", bundleID);
        return NO;
    }
    id displayItem = ((id (*)(id, SEL, id, id))objc_msgSend)(displayItemClass, factory,
                                                             bundleID, sceneIdentifier);
    SEL addSelector = NSSelectorFromString(@"addAppLayoutForDisplayItem:completion:");
    if (displayItem == nil || ![switcher respondsToSelector:addSelector] ||
        !MRHasInstanceMethod([switcher class], @"addAppLayoutForDisplayItem:completion:", 4)) {
        MRLog(@"cannot add production display item %@: scene=%@ sceneID=%@ item=%@",
              bundleID, scene, sceneIdentifier, displayItem);
        return NO;
    }

    dispatch_block_t completion = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            MRLog(@"production add completion %@ sceneID=%@", bundleID, sceneIdentifier);
            MRReconcilePendingFront(@"add-completion");
        });
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(switcher, addSelector, displayItem, completion);
    MRLog(@"sent production add %@ sceneClass=%@ sceneID=%@ item=%@",
          bundleID, scene == nil ? @"(null)" : NSStringFromClass([scene class]),
          sceneIdentifier, displayItem);
    return YES;
}

static NSString *MRCurrentMainApplicationBundleID(void)
{
    id switcher = MRMainSwitcher();
    SEL selector = NSSelectorFromString(@"_currentAppLayout");
    id layout = nil;
    if (switcher != nil && [switcher respondsToSelector:selector])
        layout = ((id (*)(id, SEL))objc_msgSend)(switcher, selector);
    NSString *bundleID = MRBundleIdentifierFromLayout(layout);
    if (bundleID.length != 0) return bundleID;

    id springBoard = [UIApplication sharedApplication];
    SEL frontSelector = NSSelectorFromString(@"_accessibilityFrontMostApplication");
    id application = nil;
    if ([springBoard respondsToSelector:frontSelector])
        application = ((id (*)(id, SEL))objc_msgSend)(springBoard, frontSelector);
    return MRDirectBundleIdentifier(application);
}

static BOOL MRPromoteExistingCard(NSString *bundleID, NSString *trigger)
{
    if (bundleID.length == 0) return NO;
    id switcher = MRMainSwitcher();
    NSArray *layouts = MRRecentAppLayouts(switcher);
    NSUInteger index = NSNotFound;
    id layout = MRLayoutForBundleIdentifier(layouts, bundleID, &index);
    if (layout == nil) {
        MRLog(@"return-to-main %@ trigger=%@ layout-not-found count=%lu",
              bundleID, trigger, (unsigned long)layouts.count);
        return NO;
    }
    if (index != 0) {
        SEL selector = NSSelectorFromString(@"_addAppLayoutToFront:");
        if (![switcher respondsToSelector:selector]) return NO;
        ((void (*)(id, SEL, id))objc_msgSend)(switcher, selector, layout);
        MRLog(@"return-to-main promoted %@ trigger=%@ oldIndex=%lu",
              bundleID, trigger, (unsigned long)index);
    }
    NSArray *updated = MRRecentAppLayouts(switcher);
    NSUInteger updatedIndex = NSNotFound;
    id updatedLayout = MRLayoutForBundleIdentifier(updated, bundleID, &updatedIndex);
    MRLog(@"return-to-main verify %@ trigger=%@ found=%d index=%@ count=%lu",
          bundleID, trigger, updatedLayout != nil,
          updatedIndex == NSNotFound ? @"NSNotFound" : [NSString stringWithFormat:@"%lu", (unsigned long)updatedIndex],
          (unsigned long)updated.count);
    return updatedLayout != nil && updatedIndex == 0;
}

static void MRScheduleReturnToMainPromotion(NSString *bundleID, NSUInteger generation)
{
    if (bundleID.length == 0) return;
    // Myrtle reuses its close path before launching a hosted app fullscreen.
    // This short first delay lets the launch hook classify that transition
    // without bringing A forward for one frame. A normal close still settles
    // far faster than the system's native recency update.
    NSArray<NSNumber *> *delays = @[@0.08, @0.2, @0.5];
    for (NSNumber *delay in delays) {
        NSString *trigger = [NSString stringWithFormat:@"close-%.2fs", delay.doubleValue];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (generation != MRReturnToMainGeneration) {
                MRLog(@"skip stale return-to-main %@ generation=%lu current=%lu",
                      trigger, (unsigned long)generation,
                      (unsigned long)MRReturnToMainGeneration);
                return;
            }
            id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
            NSString *current = MRSafeValue(manager, @"currentBundleID");
            if (current.length != 0) {
                MRLog(@"skip return-to-main %@ because Myrtle now hosts %@", trigger, current);
                return;
            }
            MRPromoteExistingCard(bundleID, trigger);
        });
    }
}

static void MRScheduleFullscreenPromotion(NSString *bundleID, NSUInteger generation)
{
    if (bundleID.length == 0) return;
    NSArray<NSNumber *> *delays = @[@0.0, @0.15, @0.5];
    for (NSNumber *delay in delays) {
        NSString *trigger = [NSString stringWithFormat:@"fullscreen-%.2fs", delay.doubleValue];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (generation != MRReturnToMainGeneration) {
                MRLog(@"skip stale fullscreen promotion %@ generation=%lu current=%lu",
                      trigger, (unsigned long)generation,
                      (unsigned long)MRReturnToMainGeneration);
                return;
            }
            id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
            NSString *current = MRSafeValue(manager, @"currentBundleID");
            if (current.length != 0) {
                MRLog(@"skip fullscreen promotion %@ because Myrtle now hosts %@",
                      trigger, current);
                return;
            }
            MRPromoteExistingCard(bundleID, trigger);
        });
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
    NSUInteger generation = MREnqueueDesiredFront(bundleID);
    MRScheduleFrontReconciliation(generation);

    if (existing != nil) {
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
        if (!MRAddProductionDisplayItem(switcher, application, bundleID)) {
            MRRemoveDesiredFront(bundleID);
            return;
        }
        action = @"add-production-display-item";
    }

    if ([action isEqualToString:@"promote-existing"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ MRVerifySwitcherResult(bundleID, action); });
    }
}

typedef void (*MRSetCurrentBundleIMP)(id, SEL, NSString *);
static MRSetCurrentBundleIMP MROriginalSetCurrentBundle = NULL;

static void MRHookSetCurrentBundle(id self, SEL selector, NSString *bundleID)
{
    NSString *previousBundleID = [MRSafeValue(self, @"currentBundleID") copy];
    BOOL fullscreenTransition = bundleID.length == 0 && previousBundleID.length != 0 &&
        [MRMyrtleFullscreenIntentBundleID isEqualToString:previousBundleID];
    NSString *underlyingBeforeChange = nil;
    if (bundleID.length != 0 && previousBundleID.length == 0)
        underlyingBeforeChange = [MRCurrentMainApplicationBundleID() copy];

    BOOL meaningfulTransition = bundleID.length != 0 || previousBundleID.length != 0;
    NSUInteger transitionGeneration = MRReturnToMainGeneration;
    if (meaningfulTransition) transitionGeneration = ++MRReturnToMainGeneration;
    MROriginalSetCurrentBundle(self, selector, bundleID);
    NSString *stableBundleID = [bundleID copy];
    if (stableBundleID.length != 0 && underlyingBeforeChange.length != 0 &&
        ![underlyingBeforeChange isEqualToString:stableBundleID]) {
        MRUnderlyingMainBundleID = underlyingBeforeChange;
    }
    if (stableBundleID.length != 0) {
        MRRecentlyClosedMyrtleBundleID = nil;
        MRRecentlyClosedMyrtleTime = 0;
    }
    MRLog(@"Myrtle committed currentBundleID=%@ previous=%@ underlyingMain=%@",
          stableBundleID, previousBundleID, MRUnderlyingMainBundleID);
    if (stableBundleID.length == 0) {
        if (fullscreenTransition) {
            NSString *fullscreenBundleID = [previousBundleID copy];
            MRMyrtleFullscreenIntentBundleID = nil;
            MRMyrtleFullscreenIntentGeneration++;
            MRUnderlyingMainBundleID = nil;
            [MRDesiredFrontOrder removeAllObjects];
            MRDesiredFrontGeneration++;
            MRLog(@"Myrtle fullscreen transition %@; preserving target recency",
                  fullscreenBundleID);
            MRScheduleFullscreenPromotion(fullscreenBundleID, transitionGeneration);
            return;
        }
        NSString *returnBundleID = [MRUnderlyingMainBundleID copy];
        MRRecentlyClosedMyrtleBundleID = [previousBundleID copy];
        MRRecentlyClosedMyrtleTime = [NSDate timeIntervalSinceReferenceDate];
        MRUnderlyingMainBundleID = nil;
        [MRDesiredFrontOrder removeAllObjects];
        MRDesiredFrontGeneration++;
        MRLog(@"Myrtle closed %@; returning immediately to main=%@",
              previousBundleID, returnBundleID);
        MRScheduleReturnToMainPromotion(returnBundleID, transitionGeneration);
        return;
    }

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

typedef void (*MRMyrtleFullscreenIMP)(id, SEL);
static MRMyrtleFullscreenIMP MROriginalMyrtleFullscreen = NULL;

typedef void (*MRMyrtleHostCoreLaunchIMP)(id, SEL, NSString *);
static MRMyrtleHostCoreLaunchIMP MROriginalMyrtleHostCoreLaunch = NULL;

static void MRRecordMyrtleFullscreenIntent(NSString *bundleID, NSString *source)
{
    if (bundleID.length == 0) return;
    NSUInteger intentGeneration = ++MRMyrtleFullscreenIntentGeneration;
    MRMyrtleFullscreenIntentBundleID = [bundleID copy];
    MRLog(@"Myrtle fullscreen intent bundle=%@ generation=%lu source=%@",
          bundleID, (unsigned long)intentGeneration, source);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (intentGeneration == MRMyrtleFullscreenIntentGeneration &&
            [MRMyrtleFullscreenIntentBundleID isEqualToString:bundleID]) {
            MRMyrtleFullscreenIntentBundleID = nil;
            MRMyrtleFullscreenIntentGeneration++;
            MRLog(@"expired unconsumed Myrtle fullscreen intent bundle=%@ source=%@",
                  bundleID, source);
        }
    });
}

static void MRHookMyrtleFullscreen(id self, SEL selector)
{
    NSString *bundleID = [MRSafeValue(self, @"currentWindowBundleID") copy];
    if (bundleID.length == 0)
        bundleID = [MRSafeValue(self, @"lastWindowBundleID") copy];
    if (bundleID.length == 0) {
        id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
        bundleID = [MRSafeValue(manager, @"currentBundleID") copy];
    }

    MRRecordMyrtleFullscreenIntent(bundleID, @"view-controller");
    MROriginalMyrtleFullscreen(self, selector);
}

static void MRHookMyrtleHostCoreLaunch(id self, SEL selector, NSString *bundleID)
{
    NSString *stableBundleID = [bundleID copy];
    id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
    NSString *currentBundleID = [MRSafeValue(manager, @"currentBundleID") copy];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval sinceClose = now - MRRecentlyClosedMyrtleTime;

    if (stableBundleID.length != 0 &&
        [currentBundleID isEqualToString:stableBundleID]) {
        MRRecordMyrtleFullscreenIntent(stableBundleID, @"host-core-current");
    } else if (stableBundleID.length != 0 &&
               [MRRecentlyClosedMyrtleBundleID isEqualToString:stableBundleID] &&
               MRRecentlyClosedMyrtleTime > 0 && sinceClose >= 0 && sinceClose <= 0.75) {
        // Some Myrtle paths clear currentBundleID immediately before calling
        // the launch helper. Cancel the just-scheduled return-to-A promotion
        // and restore B at the front before the switcher can be displayed.
        NSUInteger generation = ++MRReturnToMainGeneration;
        MRRecentlyClosedMyrtleBundleID = nil;
        MRRecentlyClosedMyrtleTime = 0;
        MRMyrtleFullscreenIntentBundleID = nil;
        MRMyrtleFullscreenIntentGeneration++;
        MRLog(@"Myrtle late fullscreen launch bundle=%@ sinceClose=%.3f; cancelling return-to-main",
              stableBundleID, sinceClose);
        MRScheduleFullscreenPromotion(stableBundleID, generation);
    } else {
        MRLog(@"Myrtle HostCore launch observed bundle=%@ current=%@ recentClosed=%@ age=%.3f",
              stableBundleID, currentBundleID, MRRecentlyClosedMyrtleBundleID, sinceClose);
    }

    MROriginalMyrtleHostCoreLaunch(self, selector, stableBundleID);
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

typedef void (*MRDeletedDisplayItemIMP)(id, SEL, id, id, id, long long);
static MRDeletedDisplayItemIMP MROriginalDeletedDisplayItem = NULL;

static void MRHookRemoveLayout(id self, SEL selector, id layout, long long reason)
{
    NSString *bundleID = [MRBundleIdentifierFromLayout(layout) copy];
    MRLog(@"switcher removing %@ reason=%lld layoutClass=%@", bundleID, reason,
          layout == nil ? @"(null)" : NSStringFromClass([layout class]));
    MROriginalRemoveLayout(self, selector, layout, reason);
    MRRemoveDesiredFront(bundleID);
    MRCloseMyrtleWindowForBundleID(bundleID);
}

static void MRHookDeletedDisplayItem(id self, SEL selector, id controller,
                                     id displayItem, id layout, long long reason)
{
    NSString *bundleID = [MRDirectBundleIdentifier(displayItem) copy];
    if (bundleID.length == 0) bundleID = [MRBundleIdentifierFromLayout(layout) copy];
    MRLog(@"user deleted display item %@ reason=%lld item=%@ layoutClass=%@",
          bundleID, reason, displayItem,
          layout == nil ? @"(null)" : NSStringFromClass([layout class]));
    MROriginalDeletedDisplayItem(self, selector, controller, displayItem, layout, reason);
    MRRemoveDesiredFront(bundleID);
    MRCloseMyrtleWindowForBundleID(bundleID);
}

static void MRHookModelChanged(id self, SEL selector, id model)
{
    MROriginalModelChanged(self, selector, model);
    id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
    NSString *myrtleBundleID = [MRSafeValue(manager, @"currentBundleID") copy];
    if (myrtleBundleID.length != 0) {
        NSString *systemCurrentBundleID = [MRCurrentMainApplicationBundleID() copy];
        MRLog(@"model changed while Myrtle hosts=%@ systemCurrent=%@ underlyingMain=%@",
              myrtleBundleID, systemCurrentBundleID, MRUnderlyingMainBundleID);
        if ([systemCurrentBundleID isEqualToString:myrtleBundleID] &&
            ![MRUnderlyingMainBundleID isEqualToString:myrtleBundleID]) {
            // Myrtle's fullscreen action may activate the already-hosted scene
            // without using either of its explicit launch helpers. SpringBoard
            // publishes the new current app layout before Myrtle clears its
            // currentBundleID, which is a reliable distinction from a normal
            // close back to the underlying app.
            MRRecordMyrtleFullscreenIntent(myrtleBundleID,
                                           @"switcher-current-layout");
        }
    }
    if (MRDesiredFrontOrder.count != 0 && !MRReconcilingFront)
        dispatch_async(dispatch_get_main_queue(), ^{ MRReconcilePendingFront(@"model-changed"); });
}

static void MRHookViewWillAppear(id self, SEL selector, BOOL animated)
{
    MROriginalViewWillAppear(self, selector, animated);
    if (MRDesiredFrontOrder.count != 0)
        dispatch_async(dispatch_get_main_queue(), ^{ MRReconcilePendingFront(@"view-will-appear"); });
}

static BOOL MRInstallMyrtleHook(void)
{
    if (MROriginalSetCurrentBundle != NULL) return YES;
    Class cls = NSClassFromString(@"MyrtleHostManager");
    SEL selector = NSSelectorFromString(@"setCurrentBundleID:");
    Method method = class_getInstanceMethod(cls, selector);
    if (cls == Nil || method == NULL || method_getNumberOfArguments(method) != 3) return NO;
    MSHookMessageEx(cls, selector, (IMP)MRHookSetCurrentBundle,
                    (IMP *)&MROriginalSetCurrentBundle);
    MRLog(@"installed direct MyrtleHostManager hook");
    return MROriginalSetCurrentBundle != NULL;
}

static BOOL MRInstallMyrtleFullscreenHook(void)
{
    if (MROriginalMyrtleFullscreen != NULL) return YES;
    Class cls = NSClassFromString(@"MyrtleViewController");
    SEL selector = NSSelectorFromString(@"MT_llIIIlIIlIlllIlIIIII");
    Method method = class_getInstanceMethod(cls, selector);
    if (cls == Nil || method == NULL || method_getNumberOfArguments(method) != 2) return NO;
    MSHookMessageEx(cls, selector, (IMP)MRHookMyrtleFullscreen,
                    (IMP *)&MROriginalMyrtleFullscreen);
    MRLog(@"installed direct Myrtle fullscreen-launch hook");
    return MROriginalMyrtleFullscreen != NULL;
}

static BOOL MRInstallMyrtleHostCoreLaunchHook(void)
{
    if (MROriginalMyrtleHostCoreLaunch != NULL) return YES;
    Class cls = NSClassFromString(@"MyrtleHostCore");
    SEL selector = NSSelectorFromString(@"MT_IllIlllIIllIllIIIIII:");
    Method method = class_getClassMethod(cls, selector);
    if (cls == Nil || method == NULL || method_getNumberOfArguments(method) != 3) return NO;
    MSHookMessageEx(object_getClass(cls), selector, (IMP)MRHookMyrtleHostCoreLaunch,
                    (IMP *)&MROriginalMyrtleHostCoreLaunch);
    MRLog(@"installed direct Myrtle HostCore launch hook");
    return MROriginalMyrtleHostCoreLaunch != NULL;
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

static void MRInstallUserDeletionHook(void)
{
    Class cls = NSClassFromString(@"SBMainSwitcherViewController");
    SEL selector = NSSelectorFromString(@"switcherContentController:deletedDisplayItem:inAppLayout:forReason:");
    Method method = class_getInstanceMethod(cls, selector);
    if (cls != Nil && method != NULL && method_getNumberOfArguments(method) == 6) {
        MSHookMessageEx(cls, selector, (IMP)MRHookDeletedDisplayItem,
                        (IMP *)&MROriginalDeletedDisplayItem);
        MRLog(@"installed direct user-card deletion hook");
    } else {
        MRLog(@"direct user-card deletion method unavailable");
    }
}

static void MRInstallMyrtleWhenReady(NSUInteger attempt)
{
    BOOL managerInstalled = MRInstallMyrtleHook();
    BOOL fullscreenInstalled = MRInstallMyrtleFullscreenHook();
    BOOL hostCoreLaunchInstalled = MRInstallMyrtleHostCoreLaunchHook();
    if (managerInstalled && fullscreenInstalled && hostCoreLaunchInstalled) return;
    if (attempt >= 60) {
        MRLog(@"Myrtle hooks unavailable after 60 seconds manager=%d fullscreen=%d hostCoreLaunch=%d",
              managerInstalled, fullscreenInstalled, hostCoreLaunchInstalled);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ MRInstallMyrtleWhenReady(attempt + 1); });
}

%ctor
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            MRLog(@"MyrtleSwitcherFix 0.4.3 switcher-current fullscreen detection loaded");
            MRInstallSwitcherRemoveHook();
            MRInstallSwitcherReconciliationHooks();
            MRInstallUserDeletionHook();
            id existingSwitcher = MRSendClassNoArgs(@"SBMainSwitcherViewController", @"sharedInstanceIfExists");
            if (existingSwitcher != nil) MRLogSwitcherCapabilities(existingSwitcher);
            MRInstallMyrtleWhenReady(0);
        });
    }
}

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>

static NSString *const MRCloseSelector = @"MT_IlllIIIlIIIlIlllIIIl::";
static __strong NSMutableArray<NSString *> *MRDesiredFrontOrder = nil;
static __strong NSString *MRUnderlyingMainBundleID = nil;
static __strong NSString *MRMyrtleFullscreenIntentBundleID = nil;
static __strong NSString *MRRecentlyClosedMyrtleBundleID = nil;
static BOOL MRReconcilingFront = NO;
static NSUInteger MRDesiredFrontGeneration = 0;
static NSUInteger MRReturnToMainGeneration = 0;
static NSUInteger MRMyrtleFullscreenIntentGeneration = 0;
static NSTimeInterval MRRecentlyClosedMyrtleTime = 0;
static const CGFloat MRFixedPortraitKeyboardHeight = 360.0;
static const CGFloat MRKeyboardHandleGap = 18.0;
static BOOL MRForegroundReloadInFlight = NO;
static __strong NSString *MRForegroundReloadCandidateBundleID = nil;
static NSUInteger MRForegroundReloadCandidateGeneration = 0;
static NSUInteger MRHomePageRestoreGeneration = 0;
static BOOL MRHomePageGuardActive = NO;
static long long MRHomePageGuardPageIndex = 0;
static long long MRHomePageGuardMinimumIndex = 0;
static BOOL MRHomePageGuardClosing = NO;
static __strong NSString *MRHomePageGuardBundleID = nil;
static __weak UIScrollView *MRHomePageGuardScrollView = nil;

typedef void (*MRSetContentOffsetAnimatedIMP)(id, SEL, CGPoint, BOOL);
static MRSetContentOffsetAnimatedIMP MROriginalSetContentOffsetAnimated = NULL;
typedef void (*MRSetContentOffsetIMP)(id, SEL, CGPoint);
static MRSetContentOffsetIMP MROriginalSetContentOffset = NULL;

// Production builds discard the complete diagnostic expression at preprocessing
// time: no arguments or diagnostic strings reach SpringBoard.
#define MRLog(...) do {} while (0)

static void MRURLTrace(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    const char *bytes = line.UTF8String;
    if (bytes == NULL) return;
    int fd = open("/var/mobile/Documents/com.moxuan.myrtleswitcherfix.url.log",
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) return;
    size_t remaining = strlen(bytes);
    while (remaining > 0) {
        ssize_t count = write(fd, bytes, remaining);
        if (count <= 0) break;
        bytes += count;
        remaining -= (size_t)count;
    }
    close(fd);
}

typedef BOOL (*MRCanOpenURLIMP)(id, SEL, NSURL *);
static MRCanOpenURLIMP MROriginalCanOpenURL = NULL;
typedef void (^MROpenURLCompletion)(BOOL success);
typedef void (*MROpenURLIMP)(id, SEL, NSURL *, NSDictionary *, MROpenURLCompletion);
static MROpenURLIMP MROriginalOpenURL = NULL;
typedef void (*MRSBWorkspaceOpenRequestIMP)(id, SEL, id, id, id);
static MRSBWorkspaceOpenRequestIMP MROriginalSBWorkspaceOpenRequest = NULL;
typedef void (*MRSBHandleOpenRequestIMP)(id, SEL, id, id, id, id, id);
static MRSBHandleOpenRequestIMP MROriginalSBHandleOpenRequest = NULL;
typedef void (*MRFBSystemOpenIMP)(id, SEL, id, id, id, id, id);
static MRFBSystemOpenIMP MROriginalFBSystemOpen = NULL;
typedef void (^MRFBSystemRawCompletion)(uintptr_t, uintptr_t, uintptr_t, uintptr_t,
                                        uintptr_t, uintptr_t, uintptr_t, uintptr_t,
                                        uintptr_t, uintptr_t);
typedef void (*MRFBSOpenServiceIMP)(id, SEL, id, id, id);
static MRFBSOpenServiceIMP MROriginalFBSOpenService = NULL;
static id MRSafeValue(id object, NSString *key);
static id MRSendClassNoArgs(NSString *className, NSString *selectorName);

enum {
    MRBlockHasCopyDispose = (1 << 25),
    MRBlockHasSignature = (1 << 30),
};

struct MRBlockLiteral {
    void *isa;
    int flags;
    int reserved;
    void (*invoke)(void *, ...);
    struct MRBlockDescriptor *descriptor;
};

static NSString *MRBlockSignature(id block)
{
    if (block == nil) return @"nil";
    struct MRBlockLiteral *literal = (__bridge struct MRBlockLiteral *)block;
    if ((literal->flags & MRBlockHasSignature) == 0 || literal->descriptor == NULL)
        return @"unavailable";
    uint8_t *cursor = (uint8_t *)literal->descriptor;
    cursor += sizeof(unsigned long int) * 2;
    if ((literal->flags & MRBlockHasCopyDispose) != 0)
        cursor += sizeof(void *) * 2;
    const char *signature = (*(const char **)cursor);
    return signature == NULL ? @"null" : [NSString stringWithUTF8String:signature];
}

static NSString *MRURLObjectSummary(id object)
{
    if (object == nil) return @"(null)";
    NSMutableArray<NSString *> *fields = [NSMutableArray array];
    for (NSString *key in @[@"URL", @"url", @"bundleIdentifier", @"bundleID",
                              @"applicationIdentifier", @"options", @"payload"]) {
        id value = MRSafeValue(object, key);
        if (value != nil)
            [fields addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
    }
    NSString *description = nil;
    @try { description = [object description]; }
    @catch (__unused NSException *exception) { description = @"<description threw>"; }
    if (description.length > 1000) description = [description substringToIndex:1000];
    return [NSString stringWithFormat:@"class=%@ fields={%@} desc=%@",
            NSStringFromClass([object class]), [fields componentsJoinedByString:@", "],
            description];
}

static void MRHookSBWorkspaceOpenRequest(id self, SEL selector, id service,
                                         id request, id completion)
{
    MRURLTrace(@"SBMainWorkspace systemService request={%@} service={%@} completion=%@",
               MRURLObjectSummary(request), MRURLObjectSummary(service),
               completion ? NSStringFromClass([completion class]) : @"nil");
    MROriginalSBWorkspaceOpenRequest(self, selector, service, request, completion);
}

static void MRHookSBHandleOpenRequest(id self, SEL selector, id application,
                                      id options, id activationSettings, id origin,
                                      id result)
{
    MRURLTrace(@"SBMainWorkspace handle selector=%@ app={%@} options={%@} activation={%@} origin={%@} resultBlock=%@",
               NSStringFromSelector(selector), MRURLObjectSummary(application),
               MRURLObjectSummary(options), MRURLObjectSummary(activationSettings),
               MRURLObjectSummary(origin), result ? NSStringFromClass([result class]) : @"nil");
    MROriginalSBHandleOpenRequest(self, selector, application, options,
                                  activationSettings, origin, result);
}

static void MRHookFBSystemOpen(id self, SEL selector, id application, id options,
                               id originator, id requestID, id completion)
{
    MRURLTrace(@"FBSystemService open app={%@} options={%@} originator={%@} requestID={%@} completion=%@ signature=%@",
               MRURLObjectSummary(application), MRURLObjectSummary(options),
               MRURLObjectSummary(originator), requestID,
               completion ? NSStringFromClass([completion class]) : @"nil",
               MRBlockSignature(completion));
    MRFBSystemRawCompletion originalCompletion = completion;
    MRFBSystemRawCompletion wrappedCompletion = nil;
    if (originalCompletion != nil) {
        wrappedCompletion =
        ^(uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t a4, uintptr_t a5,
          uintptr_t a6, uintptr_t a7, uintptr_t a8, uintptr_t a9, uintptr_t a10) {
            MRURLTrace(@"FBSystemService COMPLETE-RAW app=%@ args=[0x%llx 0x%llx 0x%llx 0x%llx 0x%llx 0x%llx 0x%llx 0x%llx 0x%llx 0x%llx]",
                       application, (unsigned long long)a1, (unsigned long long)a2,
                       (unsigned long long)a3, (unsigned long long)a4,
                       (unsigned long long)a5, (unsigned long long)a6,
                       (unsigned long long)a7, (unsigned long long)a8,
                       (unsigned long long)a9, (unsigned long long)a10);
            originalCompletion(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10);
        };
    }
    MROriginalFBSystemOpen(self, selector, application, options, originator,
                           requestID, wrappedCompletion);
    NSString *target = [application isKindOfClass:NSString.class] ? application : nil;
    if ([target isEqualToString:@"com.apple.Preferences"]) {
        for (NSNumber *delay in @[@0.0, @0.1, @0.3]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
                MRURLTrace(@"FBSystemService POST delay=%.1f currentMyrtle=%@",
                           delay.doubleValue, MRSafeValue(manager, @"currentBundleID"));
            });
        }
    }
}

static void MRHookFBSOpenService(id self, SEL selector, id application, id options,
                                 id completion)
{
    MRURLTrace(@"FBSOpenApplicationService open app={%@} options={%@} completion=%@",
               MRURLObjectSummary(application), MRURLObjectSummary(options),
               completion ? NSStringFromClass([completion class]) : @"nil");
    MROriginalFBSOpenService(self, selector, application, options, completion);
}

static BOOL MRHookCanOpenURL(id self, SEL selector, NSURL *URL)
{
    BOOL result = MROriginalCanOpenURL(self, selector, URL);
    MRURLTrace(@"UIApplication canOpenURL url=%@ scheme=%@ result=%d",
               URL.absoluteString, URL.scheme, result);
    return result;
}

static void MRHookOpenURL(id self, SEL selector, NSURL *URL,
                          NSDictionary *options, MROpenURLCompletion completion)
{
    MRURLTrace(@"UIApplication open BEGIN url=%@ scheme=%@ options=%@ completion=%d",
               URL.absoluteString, URL.scheme, options, completion != nil);
    MROpenURLCompletion wrapped = ^(BOOL success) {
        MRURLTrace(@"UIApplication open COMPLETE url=%@ scheme=%@ success=%d",
                   URL.absoluteString, URL.scheme, success);
        if (completion != nil) completion(success);
    };
    MROriginalOpenURL(self, selector, URL, options, wrapped);
}

static void MRTraceURLMethodsForClass(NSString *className)
{
    Class cls = NSClassFromString(className);
    if (cls == Nil) {
        MRURLTrace(@"CLASS %@ unavailable", className);
        return;
    }
    for (NSUInteger pass = 0; pass < 2; pass++) {
        Class target = pass == 0 ? cls : object_getClass(cls);
        unsigned int count = 0;
        Method *methods = class_copyMethodList(target, &count);
        for (unsigned int index = 0; index < count; index++) {
            SEL selector = method_getName(methods[index]);
            NSString *name = NSStringFromSelector(selector);
            if ([name rangeOfString:@"URL" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                [name rangeOfString:@"open" options:NSCaseInsensitiveSearch].location == NSNotFound)
                continue;
            MRURLTrace(@"METHOD %@ %@ selector=%@ args=%u types=%s",
                       className, pass == 0 ? @"instance" : @"class", name,
                       method_getNumberOfArguments(methods[index]),
                       method_getTypeEncoding(methods[index]));
        }
        free(methods);
    }
}

static void MRInstallURLDiagnostics(void)
{
    Class applicationClass = [UIApplication class];
    Method canMethod = class_getInstanceMethod(applicationClass, @selector(canOpenURL:));
    if (canMethod != NULL && method_getNumberOfArguments(canMethod) == 3)
        MSHookMessageEx(applicationClass, @selector(canOpenURL:), (IMP)MRHookCanOpenURL,
                        (IMP *)&MROriginalCanOpenURL);

    SEL openSelector = @selector(openURL:options:completionHandler:);
    Method openMethod = class_getInstanceMethod(applicationClass, openSelector);
    if (openMethod != NULL && method_getNumberOfArguments(openMethod) == 5)
        MSHookMessageEx(applicationClass, openSelector, (IMP)MRHookOpenURL,
                        (IMP *)&MROriginalOpenURL);

    Class workspaceClass = NSClassFromString(@"SBMainWorkspace");
    SEL workspaceSelector = NSSelectorFromString(@"systemService:handleOpenApplicationRequest:withCompletion:");
    Method workspaceMethod = class_getInstanceMethod(workspaceClass, workspaceSelector);
    if (workspaceMethod != NULL && method_getNumberOfArguments(workspaceMethod) == 5)
        MSHookMessageEx(workspaceClass, workspaceSelector, (IMP)MRHookSBWorkspaceOpenRequest,
                        (IMP *)&MROriginalSBWorkspaceOpenRequest);

    SEL handleSelector = NSSelectorFromString(@"_handleOpenApplicationRequest:options:activationSettings:origin:withResult:");
    Method handleMethod = class_getInstanceMethod(workspaceClass, handleSelector);
    if (handleMethod != NULL && method_getNumberOfArguments(handleMethod) == 7)
        MSHookMessageEx(workspaceClass, handleSelector, (IMP)MRHookSBHandleOpenRequest,
                        (IMP *)&MROriginalSBHandleOpenRequest);

    Class systemServiceClass = NSClassFromString(@"FBSystemService");
    SEL systemOpenSelector = NSSelectorFromString(@"openApplication:withOptions:originator:requestID:completion:");
    Method systemOpenMethod = class_getInstanceMethod(systemServiceClass, systemOpenSelector);
    if (systemOpenMethod != NULL && method_getNumberOfArguments(systemOpenMethod) == 7)
        MSHookMessageEx(systemServiceClass, systemOpenSelector, (IMP)MRHookFBSystemOpen,
                        (IMP *)&MROriginalFBSystemOpen);

    Class openServiceClass = NSClassFromString(@"FBSOpenApplicationService");
    SEL serviceOpenSelector = NSSelectorFromString(@"openApplication:withOptions:completion:");
    Method serviceOpenMethod = class_getInstanceMethod(openServiceClass, serviceOpenSelector);
    if (serviceOpenMethod != NULL && method_getNumberOfArguments(serviceOpenMethod) == 5)
        MSHookMessageEx(openServiceClass, serviceOpenSelector, (IMP)MRHookFBSOpenService,
                        (IMP *)&MROriginalFBSOpenService);

    MRURLTrace(@"INSTALL UIApplication can=%d open=%d SBWorkspace=%d SBHandle=%d FBSystem=%d FBSService=%d",
               MROriginalCanOpenURL != NULL, MROriginalOpenURL != NULL,
               MROriginalSBWorkspaceOpenRequest != NULL,
               MROriginalSBHandleOpenRequest != NULL,
               MROriginalFBSystemOpen != NULL, MROriginalFBSOpenService != NULL);
    for (NSString *className in @[@"UIApplication", @"LSApplicationWorkspace",
                                   @"SBMainWorkspace", @"SBApplicationController",
                                   @"FBSystemService", @"FBSOpenApplicationService"])
        MRTraceURLMethodsForClass(className);
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

static BOOL MRReconcilePendingFront(void)
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
        }
        MRReconcilingFront = NO;
    }

    NSArray *updatedLayouts = MRRecentAppLayouts(switcher);
    BOOL allMaterialized = resolvedIDs.count == desired.count;
    BOOL verified = allMaterialized && updatedLayouts.count >= expectedFront.count;
    if (verified) {
        for (NSUInteger index = 0; index < expectedFront.count; index++) {
            if (!MRLayoutContainsBundleIdentifier(updatedLayouts[index], expectedFront[index])) {
                verified = NO;
                break;
            }
        }
    }
    return verified;
}

static void MRScheduleFrontReconciliation(NSUInteger generation)
{
    NSArray<NSNumber *> *delays = @[@0.75, @1.5, @3.0, @6.0, @10.0];
    for (NSNumber *delay in delays) {
        BOOL finalAttempt = delay.doubleValue == 10.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (generation != MRDesiredFrontGeneration) {
                return;
            }
            MRReconcilePendingFront();
            if (finalAttempt && generation == MRDesiredFrontGeneration) {
                [MRDesiredFrontOrder removeAllObjects];
                MRDesiredFrontGeneration++;
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
    @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *MRSceneIdentifier(id application)
{
    id scene = MRMyrtleSceneForApplication(application);
    id identifier = MRSafeValue(scene, @"identifier");
    if (![identifier isKindOfClass:NSString.class] || [identifier length] == 0)
        identifier = MRSafeValue(application, @"_baseSceneIdentifier");
    return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}

static BOOL MRAddProductionDisplayItem(id switcher, id application, NSString *bundleID)
{
    NSString *sceneIdentifier = MRSceneIdentifier(application);
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
            MRReconcilePendingFront();
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

static NSString *MRScalarGetterValue(id object, NSString *selectorName)
{
    if (object == nil) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (method == NULL || method_getNumberOfArguments(method) != 2) return nil;
    char returnType[32] = {};
    method_getReturnType(method, returnType, sizeof(returnType));
    @try {
        switch (returnType[0]) {
            case 'q': return [NSString stringWithFormat:@"%lld", ((long long (*)(id, SEL))objc_msgSend)(object, selector)];
            case 'Q': return [NSString stringWithFormat:@"%llu", ((unsigned long long (*)(id, SEL))objc_msgSend)(object, selector)];
            case 'i': return [NSString stringWithFormat:@"%d", ((int (*)(id, SEL))objc_msgSend)(object, selector)];
            case 'I': return [NSString stringWithFormat:@"%u", ((unsigned int (*)(id, SEL))objc_msgSend)(object, selector)];
            case 's': return [NSString stringWithFormat:@"%d", (int)((short (*)(id, SEL))objc_msgSend)(object, selector)];
            case 'S': return [NSString stringWithFormat:@"%u", (unsigned int)((unsigned short (*)(id, SEL))objc_msgSend)(object, selector)];
            case 'B': return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector) ? @"1" : @"0";
            default: return nil;
        }
    } @catch (__unused NSException *exception) { return nil; }
}

static BOOL MRIntegerGetter(id object, NSString *selectorName, long long *value)
{
    NSString *text = MRScalarGetterValue(object, selectorName);
    if (text == nil) return NO;
    if (value != NULL) *value = text.longLongValue;
    return YES;
}

static id MRRootFolderController(void)
{
    id iconController = MRSendClassNoArgs(@"SBIconController", @"sharedInstance");
    return MRSafeValue(iconController, @"rootFolderController");
}

static void MRClearHomePageGuard(void)
{
    MRHomePageGuardActive = NO;
    MRHomePageGuardClosing = NO;
    MRHomePageGuardBundleID = nil;
    MRHomePageGuardScrollView = nil;
}

static BOOL MRGuardRootScrollOffset(id scrollView, CGPoint requestedOffset,
                                    CGPoint *replacementOffset)
{
    if (!MRHomePageGuardActive || scrollView != MRHomePageGuardScrollView) return NO;
    UIScrollView *rootScrollView = scrollView;
    if (rootScrollView.tracking || rootScrollView.dragging ||
        rootScrollView.decelerating) {
        MRClearHomePageGuard();
        return NO;
    }
    CGFloat targetX = (CGFloat)(MRHomePageGuardPageIndex - MRHomePageGuardMinimumIndex) *
        rootScrollView.bounds.size.width;
    if (requestedOffset.x >= targetX - 0.5) return NO;
    if (replacementOffset != NULL)
        *replacementOffset = CGPointMake(targetX, requestedOffset.y);
    return YES;
}

static void MRHookSetContentOffsetAnimated(id self, SEL selector, CGPoint offset,
                                           BOOL animated)
{
    CGPoint replacement = offset;
    if (MRGuardRootScrollOffset(self, offset, &replacement)) {
        MROriginalSetContentOffsetAnimated(self, selector, replacement, NO);
        return;
    }
    MROriginalSetContentOffsetAnimated(self, selector, offset, animated);
}

static void MRHookSetContentOffset(id self, SEL selector, CGPoint offset)
{
    CGPoint replacement = offset;
    if (MRGuardRootScrollOffset(self, offset, &replacement)) {
        MROriginalSetContentOffset(self, selector, replacement);
        return;
    }
    MROriginalSetContentOffset(self, selector, offset);
}

static void MRArmHomePageGuard(long long pageIndex, NSString *bundleID)
{
    id controller = MRRootFolderController();
    id rootFolderView = MRSafeValue(controller, @"rootFolderView");
    id rootScrollView = MRSafeValue(rootFolderView, @"scrollView");
    long long minimumPageIndex = 0;
    long long maximumPageIndex = 0;
    if (!MRIntegerGetter(controller, @"minimumPageIndex", &minimumPageIndex) ||
        !MRIntegerGetter(controller, @"maximumPageIndex", &maximumPageIndex) ||
        pageIndex < minimumPageIndex || pageIndex > maximumPageIndex ||
        pageIndex == minimumPageIndex || bundleID.length == 0 ||
        ![rootScrollView isKindOfClass:[UIScrollView class]]) {
        MRClearHomePageGuard();
        return;
    }
    MRHomePageGuardPageIndex = pageIndex;
    MRHomePageGuardMinimumIndex = minimumPageIndex;
    MRHomePageGuardBundleID = [bundleID copy];
    MRHomePageGuardScrollView = rootScrollView;
    MRHomePageGuardClosing = NO;
    MRHomePageGuardActive = YES;
}

static void MRReloadForegroundApplication(void)
{
    if (MRForegroundReloadInFlight) return;
    NSString *bundleID = [MRForegroundReloadCandidateBundleID copy];
    MRForegroundReloadCandidateBundleID = nil;
    if (bundleID.length == 0)
        bundleID = [MRCurrentMainApplicationBundleID() copy];
    if (bundleID.length == 0 || ![bundleID containsString:@"."] ||
        [bundleID isEqualToString:@"com.apple.springboard"]) return;

    Class hostCore = NSClassFromString(@"MyrtleHostCore");
    SEL processSelector = NSSelectorFromString(@"MT_llIIIIIIIIllIlIIIlIl:");
    Method processMethod = class_getClassMethod(hostCore, processSelector);
    id springBoard = [UIApplication sharedApplication];
    SEL launchSelector = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    Method launchMethod = class_getInstanceMethod([springBoard class], launchSelector);
    if (hostCore == Nil || processMethod == NULL ||
        method_getNumberOfArguments(processMethod) != 3 ||
        springBoard == nil || launchMethod == NULL ||
        method_getNumberOfArguments(launchMethod) != 4) return;

    id application = ((id (*)(id, SEL, id))objc_msgSend)(hostCore, processSelector, bundleID);
    SEL killSelector = NSSelectorFromString(@"killForReason:andReport:withDescription:");
    id process = nil;
    for (NSString *key in @[@"mainProcess", @"applicationProcess", @"process"]) {
        id candidate = MRSafeValue(application, key);
        if (candidate != nil) {
            process = candidate;
            break;
        }
    }
    if (process == nil) {
        id processManager = MRSendClassNoArgs(@"FBProcessManager", @"sharedInstance");
        for (NSString *name in @[@"applicationProcessForBundleIdentifier:",
                                  @"processForBundleIdentifier:"]) {
            SEL lookup = NSSelectorFromString(name);
            if (processManager != nil && [processManager respondsToSelector:lookup]) {
                process = ((id (*)(id, SEL, id))objc_msgSend)(processManager, lookup, bundleID);
                if (process != nil) break;
            }
        }
    }
    Method killMethod = process == nil ? NULL : class_getInstanceMethod([process class], killSelector);
    if (killMethod == NULL || method_getNumberOfArguments(killMethod) != 5) return;

    MRForegroundReloadInFlight = YES;
    ((void (*)(id, SEL, long long, BOOL, id))objc_msgSend)(
        process, killSelector, 1, NO, @"Myrtle reload foreground application");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(springBoard, launchSelector,
                                                    bundleID, NO);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ MRForegroundReloadInFlight = NO; });
}

static void MRPromoteExistingCard(NSString *bundleID)
{
    if (bundleID.length == 0) return;
    id switcher = MRMainSwitcher();
    NSArray *layouts = MRRecentAppLayouts(switcher);
    NSUInteger index = NSNotFound;
    id layout = MRLayoutForBundleIdentifier(layouts, bundleID, &index);
    if (layout == nil) {
        MRLog(@"return-to-main %@ trigger=%@ layout-not-found count=%lu",
              bundleID, trigger, (unsigned long)layouts.count);
        return;
    }
    if (index != 0) {
        SEL selector = NSSelectorFromString(@"_addAppLayoutToFront:");
        if (![switcher respondsToSelector:selector]) return;
        ((void (*)(id, SEL, id))objc_msgSend)(switcher, selector, layout);
        MRLog(@"return-to-main promoted %@ trigger=%@ oldIndex=%lu",
              bundleID, trigger, (unsigned long)index);
    }
}

static void MRScheduleReturnToMainPromotion(NSString *bundleID, NSUInteger generation)
{
    if (bundleID.length == 0) return;
    // Myrtle reuses its close path before launching a hosted app fullscreen.
    // This short first delay lets the launch hook classify that transition
    // without bringing A forward for one frame. A normal close still settles
    // far faster than the system's native recency update.
    NSArray<NSNumber *> *delays = @[@0.08, @0.2, @0.5, @1.0];
    for (NSNumber *delay in delays) {
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
            MRPromoteExistingCard(bundleID);
        });
    }
}

static void MRScheduleFullscreenPromotion(NSString *bundleID, NSUInteger generation)
{
    if (bundleID.length == 0) return;
    NSArray<NSNumber *> *delays = @[@0.0, @0.15, @0.5];
    for (NSNumber *delay in delays) {
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
            MRPromoteExistingCard(bundleID);
        });
    }
}

static BOOL MRPromoteOrInsertSwitcherCard(NSString *bundleID)
{
    if (bundleID.length == 0 || ![bundleID containsString:@"."]) return NO;

    id switcher = MRMainSwitcher();
    id appController = MRSendClassNoArgs(@"SBApplicationController", @"sharedInstance");
    SEL appSelector = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    id application = nil;
    if (appController != nil && [appController respondsToSelector:appSelector])
        application = ((id (*)(id, SEL, id))objc_msgSend)(appController, appSelector, bundleID);

    if (switcher == nil || application == nil) {
        MRLog(@"cannot handle %@: switcher=%@ application=%@", bundleID, switcher, application);
        return NO;
    }

    NSArray *layouts = MRRecentAppLayouts(switcher);
    id existing = MRLayoutForBundleIdentifier(layouts, bundleID, NULL);
    NSUInteger generation = MREnqueueDesiredFront(bundleID);
    MRScheduleFrontReconciliation(generation);

    if (existing != nil) {
        SEL promoteSelector = NSSelectorFromString(@"_addAppLayoutToFront:");
        if (![switcher respondsToSelector:promoteSelector] ||
            !MRHasInstanceMethod([switcher class], @"_addAppLayoutToFront:", 3)) {
            MRLog(@"cannot promote %@: _addAppLayoutToFront: unavailable", bundleID);
            MRRemoveDesiredFront(bundleID);
            return NO;
        }
        ((void (*)(id, SEL, id))objc_msgSend)(switcher, promoteSelector, existing);
        MRLog(@"sent promote %@ oldIndex=%lu layoutClass=%@", bundleID,
              (unsigned long)oldIndex, NSStringFromClass([existing class]));
    } else {
        if (!MRAddProductionDisplayItem(switcher, application, bundleID)) {
            MRRemoveDesiredFront(bundleID);
            return NO;
        }
    }
    return YES;
}

static BOOL MREnsureSwitcherCardAfterMyrtleClosed(NSString *bundleID,
                                                   NSString *underlyingBundleID)
{
    if (bundleID.length == 0 || ![bundleID containsString:@"."]) return NO;
    id switcher = MRMainSwitcher();
    NSArray *layouts = MRRecentAppLayouts(switcher);
    id existing = MRLayoutForBundleIdentifier(layouts, bundleID, NULL);
    if (existing != nil) {
        MRLog(@"quick-close card already materialized %@", bundleID);
        MRScheduleReturnToMainPromotion(underlyingBundleID,
                                        MRReturnToMainGeneration);
        return YES;
    }

    id appController = MRSendClassNoArgs(@"SBApplicationController", @"sharedInstance");
    SEL appSelector = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    id application = nil;
    if (appController != nil && [appController respondsToSelector:appSelector])
        application = ((id (*)(id, SEL, id))objc_msgSend)(appController,
                                                          appSelector, bundleID);
    if (switcher == nil || application == nil) {
        MRLog(@"quick-close cannot ensure %@ switcher=%@ application=%@",
              bundleID, switcher, application);
        return NO;
    }
    if (!MRAddProductionDisplayItem(switcher, application, bundleID)) return NO;

    // addAppLayoutForDisplayItem: may place the newly materialized B at the
    // front. The window is already closed, so re-promote its underlying A
    // after the asynchronous model insertion settles. No desired-front entry
    // is added for B on this path.
    MRLog(@"quick-close sent card add %@; restoring underlying=%@",
          bundleID, underlyingBundleID);
    MRScheduleReturnToMainPromotion(underlyingBundleID,
                                    MRReturnToMainGeneration);
    return YES;
}

typedef void (*MRSetCurrentBundleIMP)(id, SEL, NSString *);
static MRSetCurrentBundleIMP MROriginalSetCurrentBundle = NULL;

static void MRHookSetCurrentBundle(id self, SEL selector, NSString *bundleID)
{
    NSString *previousBundleID = [MRSafeValue(self, @"currentBundleID") copy];
    BOOL openingFirstMyrtleWindow = bundleID.length != 0 && previousBundleID.length == 0;
    long long preservedHomePage = 0;
    BOOL hasPreservedHomePage = NO;
    if (openingFirstMyrtleWindow) {
        id rootFolderController = MRRootFolderController();
        hasPreservedHomePage = MRIntegerGetter(rootFolderController,
                                               @"currentPageIndex",
                                               &preservedHomePage);
        ++MRHomePageRestoreGeneration;
        if (hasPreservedHomePage)
            MRArmHomePageGuard(preservedHomePage, bundleID);
        else
            MRClearHomePageGuard();
    } else if (bundleID.length == 0 && previousBundleID.length != 0) {
        NSUInteger closingGeneration = ++MRHomePageRestoreGeneration;
        if (MRHomePageGuardActive &&
            [MRHomePageGuardBundleID isEqualToString:previousBundleID]) {
            MRHomePageGuardClosing = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(2.05 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (closingGeneration == MRHomePageRestoreGeneration &&
                    MRHomePageGuardClosing) {
                    MRClearHomePageGuard();
                }
            });
        } else {
            MRClearHomePageGuard();
        }
    }
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

    NSString *underlyingForOpen = [MRUnderlyingMainBundleID copy];
    __block BOOL cardHandled = NO;
    NSArray<NSNumber *> *delays = @[@0.0, @0.08, @0.2, @0.35];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (cardHandled) return;
            id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
            NSString *current = MRSafeValue(manager, @"currentBundleID");
            if ([current isEqualToString:stableBundleID]) {
                cardHandled = MRPromoteOrInsertSwitcherCard(stableBundleID);
                MRLog(@"open card attempt %@ delay=%.2f active=1 handled=%d",
                      stableBundleID, delay.doubleValue, cardHandled);
            } else {
                cardHandled = MREnsureSwitcherCardAfterMyrtleClosed(stableBundleID,
                                                                    underlyingForOpen);
                MRLog(@"open card attempt %@ delay=%.2f active=0 current=%@ handled=%d",
                      stableBundleID, delay.doubleValue, current, cardHandled);
            }
        });
    }
}

typedef void (*MRMyrtleFullscreenIMP)(id, SEL);
static MRMyrtleFullscreenIMP MROriginalMyrtleFullscreen = NULL;

typedef void (*MRMyrtleHostCoreLaunchIMP)(id, SEL, NSString *);
static MRMyrtleHostCoreLaunchIMP MROriginalMyrtleHostCoreLaunch = NULL;

static void MRRecordMyrtleFullscreenIntent(NSString *bundleID)
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

    MRRecordMyrtleFullscreenIntent(bundleID);
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
        MRRecordMyrtleFullscreenIntent(stableBundleID);
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
            MRRecordMyrtleFullscreenIntent(myrtleBundleID);
        }
    }
    if (MRDesiredFrontOrder.count != 0 && !MRReconcilingFront)
        dispatch_async(dispatch_get_main_queue(), ^{ MRReconcilePendingFront(); });
}

static void MRHookViewWillAppear(id self, SEL selector, BOOL animated)
{
    MROriginalViewWillAppear(self, selector, animated);
    if (MRDesiredFrontOrder.count != 0)
        dispatch_async(dispatch_get_main_queue(), ^{ MRReconcilePendingFront(); });
}

typedef void (*MRKeyboardWillShowIMP)(id, SEL, NSNotification *);
static MRKeyboardWillShowIMP MROriginalKeyboardWillShow = NULL;
typedef void (*MRKeyboardWillHideIMP)(id, SEL, NSNotification *);
static MRKeyboardWillHideIMP MROriginalKeyboardWillHide = NULL;
typedef void (*MROpenSelectorAtPointIMP)(id, SEL, CGPoint);
static MROpenSelectorAtPointIMP MROriginalOpenSelectorAtPoint = NULL;
typedef void (*MRActionDispatcherIMP)(id, SEL, id, id, id);
static MRActionDispatcherIMP MROriginalActionDispatcher = NULL;

static void MRHookActionDispatcher(id self, SEL selector, id argument1,
                                   id argument2, id argument3)
{
    BOOL isReloadAction = [argument1 isKindOfClass:NSString.class] &&
        [(NSString *)argument1 isEqualToString:@"reloadApp"];
    BOOL isWindowOpen = [MRSafeValue(self, @"isWindowOpen") boolValue];
    if (isReloadAction && !isWindowOpen) MRReloadForegroundApplication();
    MROriginalActionDispatcher(self, selector, argument1, argument2, argument3);
    MRForegroundReloadCandidateBundleID = nil;
    MRForegroundReloadCandidateGeneration++;
}
static const void *MRPinnedHandleControllerKey = &MRPinnedHandleControllerKey;
static const void *MRPinnedHandleInstalledKey = &MRPinnedHandleInstalledKey;
static const void *MRPinnedHandleBypassKey = &MRPinnedHandleBypassKey;

static BOOL MRFixedKeyboardHandleCenter(id controller, UIView *movementView,
                                        CGPoint proposedCenter, CGPoint *fixedCenter)
{
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    BOOL portrait = CGRectGetHeight(screenBounds) > CGRectGetWidth(screenBounds);
    if (!portrait) return NO;

    // Apply the fixed height only after Myrtle itself accepted an in-app
    // keyboard notification and saved the original handle position.  System
    // surfaces that Myrtle rejects are deliberately left completely untouched.
    NSNumber *movedValue = MRSafeValue(controller, @"handleWasMovedForKeyboard");
    if (![movedValue respondsToSelector:@selector(boolValue)] || !movedValue.boolValue) return NO;

    UIView *handle = MRSafeValue(controller, @"handle");
    if (![handle isKindOfClass:UIView.class]) return NO;
    // Myrtle uses `handle` only to measure the visible grip.  The object whose
    // center it saves, animates and restores is the outer `handleHitView`.
    // Moving the inner handle merely shifts it inside a 37x120 hit container
    // and does not relocate the control on screen.
    if (![movementView isKindOfClass:UIView.class]) return NO;
    UIView *coordinateView = movementView.superview ?: MRSafeValue(controller, @"view");
    if (![coordinateView isKindOfClass:UIView.class]) return NO;

    // Convert the fixed screen-space keyboard top into the handle's actual
    // superview.  Keeping Myrtle's real notification above means this step no
    // longer participates in its CGRectIntersectsRect gate.
    CGFloat fixedKeyboardTop = CGRectGetMaxY(screenBounds) - MRFixedPortraitKeyboardHeight;
    CGPoint fixedTopInView = [coordinateView convertPoint:CGPointMake(CGRectGetMidX(screenBounds),
                                                                      fixedKeyboardTop)
                                                  fromView:nil];
    CGFloat halfHandleHeight = CGRectGetHeight(handle.bounds) * 0.5;
    CGFloat targetY = fixedTopInView.y - halfHandleHeight - MRKeyboardHandleGap;

    CGRect availableBounds = coordinateView.bounds;
    UIEdgeInsets safeInsets = coordinateView.safeAreaInsets;
    CGFloat minimumY = CGRectGetMinY(availableBounds) + safeInsets.top +
                       halfHandleHeight + MRKeyboardHandleGap;
    CGFloat maximumY = CGRectGetMaxY(availableBounds) - safeInsets.bottom -
                       halfHandleHeight - MRKeyboardHandleGap;
    if (maximumY >= minimumY)
        targetY = MIN(MAX(targetY, minimumY), maximumY);

    proposedCenter.y = targetY;
    if (fixedCenter != NULL) *fixedCenter = proposedCenter;
    return YES;
}

static void MRPinnedHandleSetCenter(id view, SEL selector, CGPoint proposedCenter)
{
    id controller = objc_getAssociatedObject(view, MRPinnedHandleControllerKey);
    NSNumber *bypass = objc_getAssociatedObject(view, MRPinnedHandleBypassKey);
    CGPoint effectiveCenter = proposedCenter;
    if (!bypass.boolValue)
        MRFixedKeyboardHandleCenter(controller, view, proposedCenter, &effectiveCenter);

    // The generated subclass is installed directly above the handle's original
    // UIKit class, so forwarding here preserves every original animation.  We
    // change only the model-layer Y destination while the keyboard is active.
    Class originalClass = class_getSuperclass(object_getClass(view));
    IMP implementation = class_getMethodImplementation(originalClass, selector);
    ((void (*)(id, SEL, CGPoint))implementation)(view, selector, effectiveCenter);
}

static BOOL MRInstallPinnedHandleCenterGuard(id controller)
{
    UIView *movementView = MRSafeValue(controller, @"handleHitView");
    if (![movementView isKindOfClass:UIView.class]) return NO;

    objc_setAssociatedObject(movementView, MRPinnedHandleControllerKey, controller,
                             OBJC_ASSOCIATION_ASSIGN);
    if ([objc_getAssociatedObject(movementView, MRPinnedHandleInstalledKey) boolValue])
        return YES;

    Class originalClass = object_getClass(movementView);
    NSString *subclassName = [NSString stringWithFormat:@"MRMyrtleKeyboardPinned_%s",
                                                        class_getName(originalClass)];
    Class subclass = NSClassFromString(subclassName);
    if (subclass == Nil) {
        subclass = objc_allocateClassPair(originalClass, subclassName.UTF8String, 0);
        if (subclass == Nil) return NO;

        Method method = class_getInstanceMethod(originalClass, @selector(setCenter:));
        if (method == NULL) {
            objc_disposeClassPair(subclass);
            return NO;
        }
        const char *types = method_getTypeEncoding(method);
        if (!class_addMethod(subclass, @selector(setCenter:),
                             (IMP)MRPinnedHandleSetCenter, types)) {
            objc_disposeClassPair(subclass);
            return NO;
        }
        objc_registerClassPair(subclass);
    }

    object_setClass(movementView, subclass);
    objc_setAssociatedObject(movementView, MRPinnedHandleInstalledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static BOOL MRApplyFixedKeyboardHandlePosition(id controller, NSDictionary *animationInfo)
{
    UIView *movementView = MRSafeValue(controller, @"handleHitView");
    if (![movementView isKindOfClass:UIView.class]) return NO;
    CGPoint targetCenter;
    if (!MRFixedKeyboardHandleCenter(controller, movementView,
                                     movementView.center, &targetCenter)) return NO;

    NSTimeInterval duration = [animationInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    if (duration <= 0.0 || duration > 2.0) duration = 0.25;
    NSNumber *curveValue = animationInfo[UIKeyboardAnimationCurveUserInfoKey];
    UIViewAnimationOptions options = curveValue != nil
        ? (UIViewAnimationOptions)(curveValue.integerValue << 16)
        : UIViewAnimationOptionCurveEaseInOut;
    [UIView animateWithDuration:duration
                          delay:0.0
                        options:options | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ movementView.center = targetCenter; }
                     completion:nil];
    return YES;
}

static void MRHookKeyboardWillShow(id self, SEL selector, NSNotification *notification)
{
    // Preserve Myrtle's own eligibility checks, saved-center bookkeeping and
    // hide-time restoration.  In particular, do not replace the notification
    // frame: Myrtle first intersects that frame with the handle in a different
    // view coordinate space, and a synthetic screen frame can suppress the
    // avoidance path entirely on iOS 15.
    MROriginalKeyboardWillShow(self, selector, notification);

    if (![notification isKindOfClass:NSNotification.class]) return;
    NSDictionary *userInfo = notification.userInfo;
    NSValue *frameValue = userInfo[UIKeyboardFrameEndUserInfoKey];
    if (![frameValue isKindOfClass:NSValue.class] ||
        strcmp(frameValue.objCType, @encode(CGRect)) != 0) return;
    CGRect keyboardFrame = frameValue.CGRectValue;
    if (CGRectGetWidth(keyboardFrame) <= 0.0 || CGRectGetHeight(keyboardFrame) <= 0.0) return;
    MRInstallPinnedHandleCenterGuard(self);
    MRApplyFixedKeyboardHandlePosition(self, userInfo);
}

static void MRHookKeyboardWillHide(id self, SEL selector, NSNotification *notification)
{
    UIView *movementView = MRSafeValue(self, @"handleHitView");
    BOOL guarded = [movementView isKindOfClass:UIView.class] &&
        [objc_getAssociatedObject(movementView, MRPinnedHandleInstalledKey) boolValue];
    if (guarded)
        objc_setAssociatedObject(movementView, MRPinnedHandleBypassKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        MROriginalKeyboardWillHide(self, selector, notification);
    } @finally {
        if (guarded)
            objc_setAssociatedObject(movementView, MRPinnedHandleBypassKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void MRHookOpenSelectorAtPoint(id self, SEL selector, CGPoint centerPoint)
{
    // This is Myrtle's selector-construction method.  Its CGPoint becomes the
    // radial menu's center before `setIsOverlayOpen:YES`.  Correct both the
    // live handle model and the incoming center before Myrtle creates/layouts
    // the selector, keeping the grip and radial items in one coordinate system.
    if (![MRSafeValue(self, @"isWindowOpen") boolValue])
        MRForegroundReloadCandidateBundleID = [MRCurrentMainApplicationBundleID() copy];
    else
        MRForegroundReloadCandidateBundleID = nil;
    NSUInteger candidateGeneration = ++MRForegroundReloadCandidateGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (candidateGeneration == MRForegroundReloadCandidateGeneration) {
            MRForegroundReloadCandidateBundleID = nil;
            MRForegroundReloadCandidateGeneration++;
        }
    });
    MRInstallPinnedHandleCenterGuard(self);
    if (MRApplyFixedKeyboardHandlePosition(self, nil)) {
        UIView *movementView = MRSafeValue(self, @"handleHitView");
        if ([movementView isKindOfClass:UIView.class]) centerPoint.y = movementView.center.y;
    }
    MROriginalOpenSelectorAtPoint(self, selector, centerPoint);
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

static BOOL MRInstallMyrtleKeyboardAvoidanceHook(void)
{
    Class cls = NSClassFromString(@"MyrtleViewController");
    if (cls == Nil) return NO;

    if (MROriginalKeyboardWillShow == NULL) {
        SEL showSelector = NSSelectorFromString(@"MT_IIlIllIllIIIIlllllII:");
        Method showMethod = class_getInstanceMethod(cls, showSelector);
        if (showMethod == NULL || method_getNumberOfArguments(showMethod) != 3) return NO;
        char returnType[16] = {};
        char argumentType[16] = {};
        method_getReturnType(showMethod, returnType, sizeof(returnType));
        method_getArgumentType(showMethod, 2, argumentType, sizeof(argumentType));
        if (returnType[0] != 'v' || argumentType[0] != '@') return NO;
        MSHookMessageEx(cls, showSelector, (IMP)MRHookKeyboardWillShow,
                        (IMP *)&MROriginalKeyboardWillShow);
    }

    if (MROriginalKeyboardWillHide == NULL) {
        SEL hideSelector = NSSelectorFromString(@"MT_lIIlIlIIIIlIIlIlllIl:");
        Method hideMethod = class_getInstanceMethod(cls, hideSelector);
        if (hideMethod == NULL || method_getNumberOfArguments(hideMethod) != 3) return NO;
        char returnType[16] = {};
        char argumentType[16] = {};
        method_getReturnType(hideMethod, returnType, sizeof(returnType));
        method_getArgumentType(hideMethod, 2, argumentType, sizeof(argumentType));
        if (returnType[0] != 'v' || argumentType[0] != '@') return NO;
        MSHookMessageEx(cls, hideSelector, (IMP)MRHookKeyboardWillHide,
                        (IMP *)&MROriginalKeyboardWillHide);
    }

    return MROriginalKeyboardWillShow != NULL && MROriginalKeyboardWillHide != NULL;
}

static BOOL MRInstallMyrtleSelectorCenterHook(void)
{
    if (MROriginalOpenSelectorAtPoint != NULL) return YES;
    Class cls = NSClassFromString(@"MyrtleViewController");
    SEL selector = NSSelectorFromString(@"MT_IIllIlllIIIIllIIIlII:");
    Method method = class_getInstanceMethod(cls, selector);
    if (cls == Nil || method == NULL || method_getNumberOfArguments(method) != 3) return NO;

    char returnType[16] = {};
    char argumentType[16] = {};
    method_getReturnType(method, returnType, sizeof(returnType));
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    if (returnType[0] != 'v' || argumentType[0] != '{') return NO;

    MSHookMessageEx(cls, selector, (IMP)MRHookOpenSelectorAtPoint,
                    (IMP *)&MROriginalOpenSelectorAtPoint);
    return MROriginalOpenSelectorAtPoint != NULL;
}

static BOOL MRInstallMyrtleActionDispatcherHook(void)
{
    if (MROriginalActionDispatcher != NULL) return YES;
    Class cls = NSClassFromString(@"MyrtleViewController");
    SEL selector = NSSelectorFromString(@"MT_IlIIllIIlIlllIIIIllI:::");
    Method method = class_getInstanceMethod(cls, selector);
    if (cls == Nil || method == NULL || method_getNumberOfArguments(method) != 5) return NO;
    char returnType[16] = {};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (returnType[0] != 'v') return NO;
    MSHookMessageEx(cls, selector, (IMP)MRHookActionDispatcher,
                    (IMP *)&MROriginalActionDispatcher);
    return MROriginalActionDispatcher != NULL;
}

static BOOL MRInstallRootIconScrollHooks(void)
{
    Class cls = NSClassFromString(@"SBIconScrollView");
    if (cls == Nil) return NO;

    if (MROriginalSetContentOffsetAnimated == NULL) {
        SEL selector = @selector(setContentOffset:animated:);
        Method method = class_getInstanceMethod(cls, selector);
        if (method != NULL && method_getNumberOfArguments(method) == 4) {
            IMP inheritedOrDirect = method_getImplementation(method);
            const char *types = method_getTypeEncoding(method);
            if (class_addMethod(cls, selector, (IMP)MRHookSetContentOffsetAnimated, types))
                MROriginalSetContentOffsetAnimated = (MRSetContentOffsetAnimatedIMP)inheritedOrDirect;
            else
                MSHookMessageEx(cls, selector, (IMP)MRHookSetContentOffsetAnimated,
                                (IMP *)&MROriginalSetContentOffsetAnimated);
        }
    }
    if (MROriginalSetContentOffset == NULL) {
        SEL selector = @selector(setContentOffset:);
        Method method = class_getInstanceMethod(cls, selector);
        if (method != NULL && method_getNumberOfArguments(method) == 3) {
            IMP inheritedOrDirect = method_getImplementation(method);
            const char *types = method_getTypeEncoding(method);
            if (class_addMethod(cls, selector, (IMP)MRHookSetContentOffset, types))
                MROriginalSetContentOffset = (MRSetContentOffsetIMP)inheritedOrDirect;
            else
                MSHookMessageEx(cls, selector, (IMP)MRHookSetContentOffset,
                                (IMP *)&MROriginalSetContentOffset);
        }
    }
    return MROriginalSetContentOffsetAnimated != NULL ||
        MROriginalSetContentOffset != NULL;
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
    BOOL keyboardAvoidanceInstalled = MRInstallMyrtleKeyboardAvoidanceHook();
    BOOL selectorCenterInstalled = MRInstallMyrtleSelectorCenterHook();
    BOOL actionDispatcherInstalled = MRInstallMyrtleActionDispatcherHook();
    if (managerInstalled && fullscreenInstalled && hostCoreLaunchInstalled &&
        keyboardAvoidanceInstalled && selectorCenterInstalled &&
        actionDispatcherInstalled) return;
    if (attempt >= 60) {
        MRLog(@"Myrtle hooks unavailable after 60 seconds manager=%d fullscreen=%d hostCoreLaunch=%d keyboard=%d selectorCenter=%d",
              managerInstalled, fullscreenInstalled, hostCoreLaunchInstalled,
              keyboardAvoidanceInstalled, selectorCenterInstalled);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ MRInstallMyrtleWhenReady(attempt + 1); });
}

%ctor
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            MRInstallURLDiagnostics();
            MRInstallSwitcherRemoveHook();
            MRInstallSwitcherReconciliationHooks();
            MRInstallUserDeletionHook();
            MRInstallRootIconScrollHooks();
            MRInstallMyrtleWhenReady(0);
        });
    }
}

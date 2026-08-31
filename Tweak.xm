#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <math.h>

static NSString *const MRCloseSelector = @"MT_IlllIIIlIIIlIlllIIIl::";
static NSString *const MRControllerCloseSelector = @"MT_llIIIlllIIIllIllllIl:";
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
// iPhone 13 Pro Max is 428 x 926 pt.  The updated 3x reference marks the
// desired lowest handle center at roughly 2160 px / 3 = 720 pt.  This is a
// center-coordinate ceiling shared by the left and right handles; keyboard
// avoidance continues to use its independent fixed position above.
static const CGFloat MRPortraitHandleMaximumCenterY = 720.0;
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
static __strong NSMutableArray<UIControl *> *MROutsideKeyboardTapCatchers = nil;
static const void *MROutsideKeyboardTapCatcherKey = &MROutsideKeyboardTapCatcherKey;

typedef void (*MRSetContentOffsetAnimatedIMP)(id, SEL, CGPoint, BOOL);
static MRSetContentOffsetAnimatedIMP MROriginalSetContentOffsetAnimated = NULL;
typedef void (*MRSetContentOffsetIMP)(id, SEL, CGPoint);
static MRSetContentOffsetIMP MROriginalSetContentOffset = NULL;
typedef UIView *(*MRMyrtleWindowHitTestIMP)(id, SEL, CGPoint, UIEvent *);
static MRMyrtleWindowHitTestIMP MROriginalMyrtleWindowHitTest = NULL;
static MRMyrtleWindowHitTestIMP MROriginalMyrtleHostWindowHitTest = NULL;

// Production builds discard the complete diagnostic expression at preprocessing
// time: no arguments or diagnostic strings reach SpringBoard.
#define MRLog(...) do {} while (0)

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

static void MRDeactivateOutsideKeyboardTapCatcher(void);

static BOOL MRUsableProtectedHostRect(CGRect rect, CGRect screenBounds)
{
    if (CGRectIsNull(rect) || CGRectIsInfinite(rect) || CGRectIsEmpty(rect)) return NO;
    if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) ||
        !isfinite(rect.size.width) || !isfinite(rect.size.height)) return NO;
    if (rect.size.width < 44.0 || rect.size.height < 44.0) return NO;
    CGRect visible = CGRectIntersection(rect, screenBounds);
    if (CGRectIsNull(visible) || CGRectIsEmpty(visible)) return NO;

    // A full-screen ancestor is Myrtle's transparent routing view, not the
    // visible application card.  It must never become the protected rect or
    // there would be no tappable outside area.
    CGFloat screenArea = CGRectGetWidth(screenBounds) * CGRectGetHeight(screenBounds);
    CGFloat visibleArea = CGRectGetWidth(visible) * CGRectGetHeight(visible);
    return screenArea > 0.0 && visibleArea < screenArea * 0.96;
}

static CGRect MRProtectedMyrtleHostRectInScreen(void)
{
    id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
    UIView *hostView = MRSafeValue(manager, @"hostView");
    if (![hostView isKindOfClass:UIView.class] || hostView.window == nil)
        return CGRectNull;

    CGRect screenBounds = UIScreen.mainScreen.bounds;
    CGRect bestRect = CGRectNull;
    CGFloat bestArea = 0.0;

    // Walk from Myrtle's rendered host surface towards its host window.  The
    // largest non-full-screen ancestor includes the title/controls around the
    // application surface while excluding the transparent screen-sized root.
    for (UIView *candidate = hostView;
         [candidate isKindOfClass:UIView.class] && ![candidate isKindOfClass:UIWindow.class];
         candidate = candidate.superview) {
        CGRect rect = [candidate convertRect:candidate.bounds toView:nil];
        if (!MRUsableProtectedHostRect(rect, screenBounds)) continue;
        CGFloat area = CGRectGetWidth(rect) * CGRectGetHeight(rect);
        if (area > bestArea) {
            bestRect = rect;
            bestArea = area;
        }
    }

    UIWindow *hostWindow = MRSafeValue(manager, @"hostWindow");
    if ([hostWindow isKindOfClass:UIWindow.class]) {
        CGRect rect = [hostWindow convertRect:hostWindow.bounds toWindow:nil];
        if (MRUsableProtectedHostRect(rect, screenBounds)) {
            CGFloat area = CGRectGetWidth(rect) * CGRectGetHeight(rect);
            if (area > bestArea) bestRect = rect;
        }
    }

    // Include the shadow/rounded-edge tolerance so a tap directly on the card
    // perimeter remains an application-window tap rather than a close action.
    return CGRectIsNull(bestRect) ? CGRectNull : CGRectInset(bestRect, -6.0, -6.0);
}

static BOOL MRScreenPointInsideView(CGPoint screenPoint, id object, CGFloat padding)
{
    UIView *view = [object isKindOfClass:UIView.class] ? object : nil;
    if (view == nil || view.window == nil || view.hidden || view.alpha <= 0.01)
        return NO;
    CGRect rect = [view convertRect:view.bounds toView:nil];
    if (CGRectIsNull(rect) || CGRectIsInfinite(rect) || CGRectIsEmpty(rect)) return NO;
    return CGRectContainsPoint(CGRectInset(rect, -padding, -padding), screenPoint);
}

@interface MROutsideKeyboardTapControl : UIControl
@property (nonatomic, weak) id myrtleController;
@property (nonatomic, assign) CGFloat keyboardTopInScreen;
@end

@implementation MROutsideKeyboardTapControl

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    if (![super pointInside:point withEvent:event] || self.hidden || !self.enabled)
        return NO;

    id controller = self.myrtleController;
    if (controller == nil || ![MRSafeValue(controller, @"isWindowOpen") boolValue])
        return NO;

    // Preserve every radial selector and launcher interaction.  Outside-tap
    // closing is available only while the plain split window is on screen.
    if ([MRSafeValue(controller, @"isOverlayOpen") boolValue] ||
        [MRSafeValue(controller, @"isAppLauncherOpen") boolValue] ||
        [MRSafeValue(controller, @"isAlphaAppLauncherOpen") boolValue])
        return NO;

    id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
    NSString *bundleID = MRSafeValue(manager, @"currentBundleID");
    if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0) return NO;

    CGPoint screenPoint = [self convertPoint:point toView:nil];
    if (!isfinite(screenPoint.x) || !isfinite(screenPoint.y) ||
        self.keyboardTopInScreen <= 0.0 || screenPoint.y >= self.keyboardTopInScreen)
        return NO;

    // The grip is intentionally outside the app card.  Keep both left/right
    // hit containers interactive while the keyboard catcher is enabled.
    if (MRScreenPointInsideView(screenPoint, MRSafeValue(controller, @"handleHitView"), 8.0) ||
        MRScreenPointInsideView(screenPoint, MRSafeValue(controller, @"secondaryHandleHitView"), 8.0))
        return NO;

    CGRect protectedRect = MRProtectedMyrtleHostRectInScreen();
    if (CGRectIsNull(protectedRect)) return NO;
    return !CGRectContainsPoint(protectedRect, screenPoint);
}

- (void)mr_closeMyrtleWindowFromOutsideTap:(__unused id)sender
{
    id controller = self.myrtleController;
    id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
    NSString *bundleID = MRSafeValue(manager, @"currentBundleID");
    SEL closeSelector = NSSelectorFromString(MRControllerCloseSelector);
    Method closeMethod = controller == nil ? NULL :
        class_getInstanceMethod([controller class], closeSelector);
    if (bundleID.length == 0 || closeMethod == NULL ||
        method_getNumberOfArguments(closeMethod) != 3) return;

    // Disable first so the same physical tap cannot fall through and launch a
    // Home Screen icon while Myrtle performs its close animation.  Then use
    // MyrtleViewController's own close-notification handler: unlike calling
    // MyrtleHostManager directly, it also clears isWindowOpen/current bundle,
    // resets snap status and refreshes the handle/selector center icon.
    MRDeactivateOutsideKeyboardTapCatcher();
    ((void (*)(id, SEL, id))objc_msgSend)(controller, closeSelector, nil);
}

@end


static void MRActivateOutsideKeyboardTapCatcher(id controller, CGRect keyboardFrame)
{
    if (controller == nil || ![MRSafeValue(controller, @"isWindowOpen") boolValue]) {
        MRDeactivateOutsideKeyboardTapCatcher();
        return;
    }

    MRDeactivateOutsideKeyboardTapCatcher();

    NSMutableOrderedSet<UIWindow *> *windows = [NSMutableOrderedSet orderedSet];
    UIView *controllerView = MRSafeValue(controller, @"view");
    if ([controllerView.window isKindOfClass:UIWindow.class])
        [windows addObject:controllerView.window];

    id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
    UIWindow *managerHostWindow = MRSafeValue(manager, @"hostWindow");
    if ([managerHostWindow isKindOfClass:UIWindow.class])
        [windows addObject:managerHostWindow];

    for (NSString *className in @[@"MyrtleWindow", @"MyrtleHostWindow"]) {
        UIWindow *sharedWindow = MRSendClassNoArgs(className, @"sharedWindow");
        if ([sharedWindow isKindOfClass:UIWindow.class])
            [windows addObject:sharedWindow];
    }

    MROutsideKeyboardTapCatchers = [NSMutableArray array];
    for (UIWindow *window in windows) {
        UIView *rootView = window.rootViewController.view ?: window;
        if (![rootView isKindOfClass:UIView.class]) continue;

        MROutsideKeyboardTapControl *catcher =
            objc_getAssociatedObject(window, MROutsideKeyboardTapCatcherKey);
        if (![catcher isKindOfClass:MROutsideKeyboardTapControl.class]) {
            catcher = [[MROutsideKeyboardTapControl alloc] initWithFrame:rootView.bounds];
            catcher.backgroundColor = UIColor.clearColor;
            catcher.opaque = NO;
            catcher.exclusiveTouch = YES;
            catcher.accessibilityElementsHidden = YES;
            [catcher addTarget:catcher
                        action:@selector(mr_closeMyrtleWindowFromOutsideTap:)
              forControlEvents:UIControlEventTouchUpInside];
            objc_setAssociatedObject(window, MROutsideKeyboardTapCatcherKey, catcher,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        [catcher removeFromSuperview];
        catcher.myrtleController = controller;
        catcher.keyboardTopInScreen = CGRectGetMinY(keyboardFrame);
        catcher.frame = rootView.bounds;
        catcher.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                   UIViewAutoresizingFlexibleHeight;
        catcher.hidden = NO;
        catcher.enabled = YES;
        [rootView insertSubview:catcher atIndex:0];
        [MROutsideKeyboardTapCatchers addObject:catcher];
    }
}

static void MRDeactivateOutsideKeyboardTapCatcher(void)
{
    for (MROutsideKeyboardTapControl *catcher in
         [MROutsideKeyboardTapCatchers copy]) {
        catcher.enabled = NO;
        catcher.hidden = YES;
        catcher.myrtleController = nil;
        [catcher removeFromSuperview];
    }
    [MROutsideKeyboardTapCatchers removeAllObjects];
}

static UIView *MRMyrtleWindowHitTestRecover(id self, SEL selector,
                                            CGPoint point, UIEvent *event,
                                            MRMyrtleWindowHitTestIMP original)
{
    UIView *originalResult = original(self, selector, point, event);
    if (originalResult != nil) return originalResult;

    // MyrtleWindow normally passes every unclaimed point through to the layer
    // below it.  On the Home Screen the inserted control is reached during the
    // ordinary hierarchy walk, but with a full-screen foreground application
    // Myrtle's routing path can return nil before that control is considered.
    // Preserve every native hit; only recover an otherwise-unclaimed point.
    MROutsideKeyboardTapControl *catcher =
        objc_getAssociatedObject(self, MROutsideKeyboardTapCatcherKey);
    if (![catcher isKindOfClass:MROutsideKeyboardTapControl.class] ||
        catcher.superview == nil)
        return nil;

    CGPoint catcherPoint = [catcher convertPoint:point fromView:(UIView *)self];
    return [catcher pointInside:catcherPoint withEvent:event] ? catcher : nil;
}

static UIView *MRHookMyrtleWindowHitTest(id self, SEL selector,
                                         CGPoint point, UIEvent *event)
{
    return MRMyrtleWindowHitTestRecover(self, selector, point, event,
                                        MROriginalMyrtleWindowHitTest);
}

static UIView *MRHookMyrtleHostWindowHitTest(id self, SEL selector,
                                             CGPoint point, UIEvent *event)
{
    return MRMyrtleWindowHitTestRecover(self, selector, point, event,
                                        MROriginalMyrtleHostWindowHitTest);
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
typedef void (*MRMyrtleViewDidLoadIMP)(id, SEL);
static MRMyrtleViewDidLoadIMP MROriginalMyrtleViewDidLoad = NULL;
typedef void (*MRMyrtleHandlePanIMP)(id, SEL, id);
static MRMyrtleHandlePanIMP MROriginalMyrtleHandlePan = NULL;

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

static BOOL MRBoundHandleCenter(id controller, UIView *movementView,
                                CGPoint proposedCenter, CGPoint *boundedCenter)
{
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    if (CGRectGetHeight(screenBounds) <= CGRectGetWidth(screenBounds)) return NO;
    if (![movementView isKindOfClass:UIView.class]) return NO;
    UIView *coordinateView = movementView.superview ?: MRSafeValue(controller, @"view");
    if (![coordinateView isKindOfClass:UIView.class]) return NO;

    CGFloat screenLimit = MIN(MRPortraitHandleMaximumCenterY,
                              CGRectGetMaxY(screenBounds));
    CGPoint limitInView = [coordinateView convertPoint:
        CGPointMake(CGRectGetMidX(screenBounds), screenLimit) fromView:nil];
    if (proposedCenter.y > limitInView.y) proposedCenter.y = limitInView.y;
    if (boundedCenter != NULL) *boundedCenter = proposedCenter;
    return YES;
}

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
    MRBoundHandleCenter(controller, view, effectiveCenter, &effectiveCenter);
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

static void MRApplyHandleBottomBoundary(id controller)
{
    UIView *movementView = MRSafeValue(controller, @"handleHitView");
    if (![movementView isKindOfClass:UIView.class]) return;
    if (!MRInstallPinnedHandleCenterGuard(controller)) return;
    CGPoint boundedCenter = movementView.center;
    if (MRBoundHandleCenter(controller, movementView, movementView.center,
                            &boundedCenter) &&
        !CGPointEqualToPoint(boundedCenter, movementView.center)) {
        movementView.center = boundedCenter;
    }
}

static void MRHookMyrtleViewDidLoad(id self, SEL selector)
{
    MROriginalMyrtleViewDidLoad(self, selector);
    MRApplyHandleBottomBoundary(self);
}

static void MRHookMyrtleHandlePan(id self, SEL selector, id gesture)
{
    MROriginalMyrtleHandlePan(self, selector, gesture);
    MRApplyHandleBottomBoundary(self);
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
    MRActivateOutsideKeyboardTapCatcher(self, keyboardFrame);
}

static void MRHookKeyboardWillHide(id self, SEL selector, NSNotification *notification)
{
    MRDeactivateOutsideKeyboardTapCatcher();
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

static BOOL MRInstallMyrtleWindowHitTestHook(void)
{
    SEL selector = @selector(hitTest:withEvent:);
    if (MROriginalMyrtleWindowHitTest == NULL) {
        Class cls = NSClassFromString(@"MyrtleWindow");
        Method method = class_getInstanceMethod(cls, selector);
        if (cls == Nil || method == NULL || method_getNumberOfArguments(method) != 4)
            return NO;

        char returnType[16] = {};
        char pointType[16] = {};
        char eventType[16] = {};
        method_getReturnType(method, returnType, sizeof(returnType));
        method_getArgumentType(method, 2, pointType, sizeof(pointType));
        method_getArgumentType(method, 3, eventType, sizeof(eventType));
        if (returnType[0] != '@' || pointType[0] != '{' || eventType[0] != '@')
            return NO;

        MSHookMessageEx(cls, selector, (IMP)MRHookMyrtleWindowHitTest,
                        (IMP *)&MROriginalMyrtleWindowHitTest);
    }

    if (MROriginalMyrtleHostWindowHitTest == NULL) {
        Class cls = NSClassFromString(@"MyrtleHostWindow");
        Method method = class_getInstanceMethod(cls, selector);
        if (cls == Nil || method == NULL || method_getNumberOfArguments(method) != 4)
            return NO;

        char returnType[16] = {};
        char pointType[16] = {};
        char eventType[16] = {};
        method_getReturnType(method, returnType, sizeof(returnType));
        method_getArgumentType(method, 2, pointType, sizeof(pointType));
        method_getArgumentType(method, 3, eventType, sizeof(eventType));
        if (returnType[0] != '@' || pointType[0] != '{' || eventType[0] != '@')
            return NO;

        MSHookMessageEx(cls, selector, (IMP)MRHookMyrtleHostWindowHitTest,
                        (IMP *)&MROriginalMyrtleHostWindowHitTest);
    }

    return MROriginalMyrtleWindowHitTest != NULL &&
           MROriginalMyrtleHostWindowHitTest != NULL;
}

static BOOL MRInstallMyrtleHandleBoundaryHooks(void)
{
    Class cls = NSClassFromString(@"MyrtleViewController");
    if (cls == Nil) return NO;

    if (MROriginalMyrtleViewDidLoad == NULL) {
        SEL selector = @selector(viewDidLoad);
        Method method = class_getInstanceMethod(cls, selector);
        if (method == NULL || method_getNumberOfArguments(method) != 2) return NO;
        MSHookMessageEx(cls, selector, (IMP)MRHookMyrtleViewDidLoad,
                        (IMP *)&MROriginalMyrtleViewDidLoad);
    }

    if (MROriginalMyrtleHandlePan == NULL) {
        SEL selector = NSSelectorFromString(@"MT_IIlIllIlIlIlIlIlIlII:");
        Method method = class_getInstanceMethod(cls, selector);
        if (method == NULL || method_getNumberOfArguments(method) != 3) return NO;
        char returnType[16] = {};
        char argumentType[16] = {};
        method_getReturnType(method, returnType, sizeof(returnType));
        method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
        if (returnType[0] != 'v' || argumentType[0] != '@') return NO;
        MSHookMessageEx(cls, selector, (IMP)MRHookMyrtleHandlePan,
                        (IMP *)&MROriginalMyrtleHandlePan);
    }

    return MROriginalMyrtleViewDidLoad != NULL && MROriginalMyrtleHandlePan != NULL;
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
    BOOL windowHitTestInstalled = MRInstallMyrtleWindowHitTestHook();
    BOOL handleBoundaryInstalled = MRInstallMyrtleHandleBoundaryHooks();
    BOOL selectorCenterInstalled = MRInstallMyrtleSelectorCenterHook();
    BOOL actionDispatcherInstalled = MRInstallMyrtleActionDispatcherHook();
    if (managerInstalled && fullscreenInstalled && hostCoreLaunchInstalled &&
        keyboardAvoidanceInstalled && windowHitTestInstalled && handleBoundaryInstalled &&
        selectorCenterInstalled && actionDispatcherInstalled) return;
    if (attempt >= 60) {
        MRLog(@"Myrtle hooks unavailable after 60 seconds manager=%d fullscreen=%d hostCoreLaunch=%d keyboard=%d windowHitTest=%d boundary=%d selectorCenter=%d",
              managerInstalled, fullscreenInstalled, hostCoreLaunchInstalled,
              keyboardAvoidanceInstalled, windowHitTestInstalled,
              handleBoundaryInstalled, selectorCenterInstalled);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ MRInstallMyrtleWhenReady(attempt + 1); });
}

%ctor
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            MRInstallSwitcherRemoveHook();
            MRInstallSwitcherReconciliationHooks();
            MRInstallUserDeletionHook();
            MRInstallRootIconScrollHooks();
            MRInstallMyrtleWhenReady(0);
        });
    }
}

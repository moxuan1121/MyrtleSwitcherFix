#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>
#import <math.h>
#import <stdlib.h>
#import <stdio.h>
#import <string.h>
#if __has_include(<ptrauth.h>)
#import <ptrauth.h>
#endif

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
static BOOL MRMyrtleHostedKeyboardVisible = NO;
static __weak id MRMyrtleKeyboardOwnerController = nil;
static __strong NSString *MRMyrtleKeyboardOwnerBundleID = nil;
static NSString *MRCurrentMainApplicationBundleID(void);

typedef void (*MRSetContentOffsetAnimatedIMP)(id, SEL, CGPoint, BOOL);
static MRSetContentOffsetAnimatedIMP MROriginalSetContentOffsetAnimated = NULL;
typedef void (*MRSetContentOffsetIMP)(id, SEL, CGPoint);
static MRSetContentOffsetIMP MROriginalSetContentOffset = NULL;
typedef void (*MRMyrtleOutsideActionIMP)(id, SEL);
static MRMyrtleOutsideActionIMP MROriginalMyrtleOutsideAction = NULL;
typedef UIView *(*MRMyrtleHostWindowHitTestIMP)(id, SEL, CGPoint, UIEvent *);
static MRMyrtleHostWindowHitTestIMP MROriginalMyrtleHostWindowHitTest = NULL;
typedef void (*MRWindowLayoutSubviewsIMP)(id, SEL);
static MRWindowLayoutSubviewsIMP MROriginalMyrtleHostWindowLayoutSubviews = NULL;
typedef void (*MRMyrtleHostGestureIMP)(id, SEL, UIGestureRecognizer *);
static MRMyrtleHostGestureIMP MROriginalMyrtleHostGesture = NULL;
typedef void (*MRMyrtleSnapTransitionIMP)(id, SEL, BOOL);
static MRMyrtleSnapTransitionIMP MROriginalMyrtleSnapTransition = NULL;
// Retained only while beta4 compares the former selector-internal hypothesis
// with the verified standalone launcher path. These hooks are never installed.
typedef void (*MRSelectorAlphaBuildOverlayIMP)(id, SEL, id);
static MRSelectorAlphaBuildOverlayIMP MROriginalSelectorAlphaBuildOverlay = NULL;
typedef void (*MRSelectorAlphaPointerIMP)(id, SEL, CGPoint);
static MRSelectorAlphaPointerIMP MROriginalSelectorAlphaPointer = NULL;
typedef void (*MRSelectorAlphaFinishIMP)(id, SEL, BOOL);
static MRSelectorAlphaFinishIMP MROriginalSelectorAlphaFinish = NULL;
typedef void (*MRAlphaLauncherLifecycleIMP)(id, SEL);
static MRAlphaLauncherLifecycleIMP MROriginalAlphaLauncherViewDidLoad = NULL;
static MRAlphaLauncherLifecycleIMP MROriginalAlphaLauncherViewDidLayoutSubviews = NULL;
static NSUInteger MRMyrtleSnapTransitionGeneration = 0;
static BOOL MRMyrtleSnapTransitionInFlight = NO;
static UIWindow *MRScopedMyrtleHostWindow = nil;
static CGRect MRNativeMyrtleHostWindowFrame = {{0.0, 0.0}, {0.0, 0.0}};
static CGRect MRNativeMyrtleHostWindowBounds = {{0.0, 0.0}, {0.0, 0.0}};
static BOOL MRNativeMyrtleHostWindowClipsToBounds = NO;
static __weak UIView *MRScopedMyrtleHostRootView = nil;
static CGRect MRNativeMyrtleHostRootViewFrame = {{0.0, 0.0}, {0.0, 0.0}};
static CGRect MRNativeMyrtleHostRootViewBounds = {{0.0, 0.0}, {0.0, 0.0}};
static UIViewAutoresizing MRNativeMyrtleHostRootViewAutoresizingMask = UIViewAutoresizingNone;
static BOOL MRNativeMyrtleHostWindowGeometrySaved = NO;
static BOOL MRMyrtleHostWindowCropApplied = NO;
static BOOL MRMyrtleHostWindowGeometrySyncing = NO;
static BOOL MRMyrtleHostWindowGeometrySyncScheduled = NO;
static BOOL MRMyrtleHostWindowGeometryFollowupScheduled = NO;
static CGRect MRMyrtleHostWindowCandidateRect = {{0.0, 0.0}, {0.0, 0.0}};
static NSUInteger MRMyrtleHostWindowCandidateCount = 0;
static CGRect MRMyrtleHostWindowActiveCropRect = {{0.0, 0.0}, {0.0, 0.0}};
typedef NSInteger (*MRIntegerValueIMP)(id, SEL);
static MRIntegerValueIMP MROriginalMyrtleTapOutsideValueIntegerValue = NULL;
static uintptr_t MRMyrtleTapOutsideIntegerValueReturnAddress = 0;
static BOOL MRMyrtleTapOutsidePreferenceOverrideInstalled = NO;
static void MRScheduleMyrtleHostWindowGeometrySync(void);
static void MRScheduleMyrtleHostWindowGeometryFollowup(void);
static void MRRestoreMyrtleHostWindowGeometry(void);

// Stable builds discard logging at preprocessing time: neither arguments nor
// strings reach SpringBoard.
#define MRLog(...) do {} while (0)

static void MRAlphaLauncherDiagnostic(NSString *line)
{
    static NSUInteger lineCount = 0;
    if (line.length == 0 || lineCount >= 24) return;
    lineCount++;
    NSString *record = [NSString stringWithFormat:@"%@\n", line];
    NSData *data = [record dataUsingEncoding:NSUTF8StringEncoding];
    const char *path = "/var/mobile/Library/Preferences/com.moxuan.myrtleswitcherfix.alpha-launcher.log";
    FILE *file = fopen(path, "ab");
    if (file == NULL) return;
    fwrite(data.bytes, 1, data.length, file);
    fclose(file);
}

static uintptr_t MRStripCodePointer(const void *pointer)
{
#if __has_feature(ptrauth_calls) && __has_include(<ptrauth.h>)
    return (uintptr_t)ptrauth_strip((void *)pointer, ptrauth_key_function_pointer);
#else
    return (uintptr_t)pointer;
#endif
}

static NSInteger MRHookMyrtleTapOutsideValueIntegerValue(id self, SEL selector)
{
    uintptr_t caller = MRStripCodePointer(__builtin_return_address(0));
    if (!MRMyrtleHostedKeyboardVisible &&
        MRMyrtleTapOutsideIntegerValueReturnAddress != 0 &&
        caller == MRMyrtleTapOutsideIntegerValueReturnAddress) {
        return 0;
    }

    return MROriginalMyrtleTapOutsideValueIntegerValue(self, selector);
}

static Class MRClassOwningInstanceSelector(Class cls, SEL selector)
{
    for (Class candidate = cls; candidate != Nil; candidate = class_getSuperclass(candidate)) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(candidate, &methodCount);
        BOOL ownsMethod = NO;
        for (unsigned int index = 0; index < methodCount; index++) {
            if (method_getName(methods[index]) == selector) {
                ownsMethod = YES;
                break;
            }
        }
        free(methods);
        if (ownsMethod) return candidate;
    }
    return Nil;
}

static BOOL MRConfigureMyrtleTapOutsidePreferenceOverride(IMP hostWindowHitTestIMP)
{
    if (MRMyrtleTapOutsidePreferenceOverrideInstalled) return YES;

    uintptr_t methodAddress = MRStripCodePointer((const void *)hostWindowHitTestIMP);
    Dl_info imageInfo = {};
    if (methodAddress == 0 || dladdr((const void *)methodAddress, &imageInfo) == 0 ||
        imageInfo.dli_fbase == NULL)
        return NO;

    uintptr_t imageBase = (uintptr_t)imageInfo.dli_fbase;
    uintptr_t methodOffset = methodAddress - imageBase;
    uintptr_t callerOffset = 0;
    uintptr_t preferencesSlotOffset = 0;
    // Myrtle 1.4.1 contains arm64 and arm64e slices. Whitelist both exact
    // hitTest implementations, their preference globals, and the single return
    // address immediately after the TapOutsideAction integerValue call.
    if (methodOffset == 0x198fbc) {
        callerOffset = 0x19afa8;
        preferencesSlotOffset = 0x331400;
    } else if (methodOffset == 0x1a49c0) {
        callerOffset = 0x1aab5c;
        preferencesSlotOffset = 0x341420;
    }
    else return NO;

    // OneWindow.plist declares TapOutsideAction's default and all valid values
    // as strings ("0" through "4"). Do not guess or enumerate NSNumber
    // subclasses: read Myrtle's own verified preference dictionary slot and
    // hook only the concrete class that actually supplies integerValue here.
    void **preferencesSlot = (void **)(imageBase + preferencesSlotOffset);
    id preferences = (__bridge id)(*preferencesSlot);
    SEL keyedSubscriptSelector = @selector(objectForKeyedSubscript:);
    if (preferences == nil || ![preferences respondsToSelector:keyedSubscriptSelector])
        return NO;
    id tapOutsideValue = ((id (*)(id, SEL, id))objc_msgSend)(
        preferences, keyedSubscriptSelector, @"TapOutsideAction");
    if (tapOutsideValue == nil || ![tapOutsideValue respondsToSelector:@selector(integerValue)])
        return NO;

    Class ownerClass = MRClassOwningInstanceSelector(object_getClass(tapOutsideValue),
                                                     @selector(integerValue));
    if (ownerClass == Nil) return NO;

    MRMyrtleTapOutsideIntegerValueReturnAddress = imageBase + callerOffset;
    MSHookMessageEx(ownerClass, @selector(integerValue),
                    (IMP)MRHookMyrtleTapOutsideValueIntegerValue,
                    (IMP *)&MROriginalMyrtleTapOutsideValueIntegerValue);
    if (MROriginalMyrtleTapOutsideValueIntegerValue == NULL) {
        MRMyrtleTapOutsideIntegerValueReturnAddress = 0;
        return NO;
    }
    MRMyrtleTapOutsidePreferenceOverrideInstalled = YES;
    return YES;
}

static id MRSafeValue(id object, NSString *key)
{
    if (object == nil || key.length == 0) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static CGFloat MRPixelAligned(CGFloat value)
{
    CGFloat scale = UIScreen.mainScreen.scale;
    if (scale <= 0.0 || !isfinite(scale)) scale = 1.0;
    return round(value * scale) / scale;
}

static void MRSafeSetValue(id object, NSString *key, id value)
{
    if (object == nil || key.length == 0) return;
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static const void *MRSelectorAlphaStripKey = &MRSelectorAlphaStripKey;

// This is MyrtleViewController's selector-internal A-Z mode. Myrtle still
// owns its data source, icon cache, selection state, haptics, dismissal and
// final application activation; only the active overlay geometry is replaced.
static void MRLayoutSelectorAlphaStrip(id controller)
{
    UIView *rootView = MRSafeValue(controller, @"view");
    UIView *railView = MRSafeValue(controller, @"selectorAlphaLetterPanelView");
    NSArray *letterLabels = MRSafeValue(controller, @"selectorAlphaLetterLabels");
    UICollectionView *collectionView = MRSafeValue(controller, @"selectorAlphaCollectionView");
    if (![rootView isKindOfClass:UIView.class] ||
        ![railView isKindOfClass:UIView.class] ||
        ![letterLabels isKindOfClass:NSArray.class] || letterLabels.count == 0 ||
        ![collectionView isKindOfClass:UICollectionView.class]) return;

    UIView *hostView = railView.superview ?: collectionView.superview;
    if (![hostView isKindOfClass:UIView.class]) return;
    CGRect bounds = hostView.bounds;
    CGFloat rootWidth = CGRectGetWidth(bounds);
    CGFloat rootHeight = CGRectGetHeight(bounds);
    if (!isfinite(rootWidth) || !isfinite(rootHeight) ||
        rootWidth < 160.0 || rootHeight < 280.0) return;

    UIEdgeInsets safeInsets = rootView.safeAreaInsets;
    CGFloat safeTop = CGRectGetMinY(bounds) + MAX(0.0, safeInsets.top);
    CGFloat safeBottom = CGRectGetMaxY(bounds) - MAX(0.0, safeInsets.bottom);
    CGFloat safeRight = CGRectGetMaxX(bounds) - MAX(0.0, safeInsets.right);
    CGFloat availableHeight = MAX(0.0, safeBottom - safeTop);

    // The approved iPhone 13 Pro Max design is 116 x 680 pt. Adapt down for
    // smaller displays and landscape bounds without changing the interaction.
    CGFloat stripWidth = MIN(116.0, MAX(88.0, rootWidth - 32.0));
    CGFloat stripHeight = MIN(680.0, MAX(240.0, availableHeight - 24.0));
    stripHeight = MIN(stripHeight, availableHeight);
    CGFloat rightMargin = MIN(16.0, MAX(8.0, rootWidth * 0.04));
    CGFloat stripX = safeRight - rightMargin - stripWidth;
    CGFloat stripY = safeTop + MAX(0.0, (availableHeight - stripHeight) * 0.5);
    CGRect stripFrame = CGRectMake(MRPixelAligned(stripX), MRPixelAligned(stripY),
                                   MRPixelAligned(stripWidth), MRPixelAligned(stripHeight));

    UIVisualEffectView *stripView = objc_getAssociatedObject(controller,
                                                              MRSelectorAlphaStripKey);
    if (![stripView isKindOfClass:UIVisualEffectView.class] ||
        stripView.superview != hostView) {
        UIBlurEffectStyle style = rootView.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
            ? UIBlurEffectStyleSystemChromeMaterialDark
            : UIBlurEffectStyleSystemChromeMaterialLight;
        stripView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:style]];
        stripView.userInteractionEnabled = NO;
        stripView.layer.shadowColor = UIColor.blackColor.CGColor;
        stripView.layer.shadowOpacity = 0.18;
        stripView.layer.shadowRadius = 18.0;
        stripView.layer.shadowOffset = CGSizeMake(0.0, 6.0);
        [hostView insertSubview:stripView belowSubview:railView];
        objc_setAssociatedObject(controller, MRSelectorAlphaStripKey, stripView,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    stripView.frame = stripFrame;
    stripView.layer.cornerRadius = MIN(30.0, stripWidth * 0.27);
    stripView.layer.masksToBounds = NO;
    if ([stripView.layer respondsToSelector:@selector(setCornerCurve:)])
        stripView.layer.cornerCurve = @"continuous";
    stripView.contentView.layer.cornerRadius = stripView.layer.cornerRadius;
    stripView.contentView.layer.masksToBounds = YES;

    CGFloat innerTop = 16.0;
    CGFloat innerBottom = 16.0;
    CGFloat railX = 8.0;
    CGFloat railWidth = 25.0;
    CGFloat contentGap = 4.0;
    CGFloat contentRight = 8.0;
    CGFloat innerHeight = MAX(1.0, stripHeight - innerTop - innerBottom);
    railView.frame = CGRectMake(stripX + railX, stripY + innerTop,
                                railWidth, innerHeight);
    railView.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.10];
    railView.layer.cornerRadius = railWidth * 0.5;
    if ([railView.layer respondsToSelector:@selector(setCornerCurve:)])
        railView.layer.cornerCurve = @"continuous";
    railView.layer.masksToBounds = YES;

    CGFloat letterHeight = innerHeight / (CGFloat)letterLabels.count;
    [letterLabels enumerateObjectsUsingBlock:^(id object, NSUInteger index, BOOL *stop) {
        (void)stop;
        if (![object isKindOfClass:UILabel.class]) return;
        UILabel *label = object;
        label.frame = CGRectMake(0.0, MRPixelAligned(letterHeight * index),
                                 railWidth, MRPixelAligned(letterHeight));
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:MAX(8.0, MIN(11.0, letterHeight * 0.58))
                                        weight:UIFontWeightMedium];
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.65;
    }];

    // The labels are native Myrtle objects. If Myrtle originally attached
    // them to another temporary view, move them to the visible rail without
    // replacing their identity or selected-state styling.
    for (UIView *label in letterLabels) {
        if ([label isKindOfClass:UIView.class] && label.superview != railView)
            [railView addSubview:label];
    }

    CGFloat collectionX = railX + railWidth + contentGap;
    CGFloat collectionWidth = MAX(44.0, stripWidth - collectionX - contentRight);
    collectionView.frame = CGRectMake(stripX + collectionX, stripY + innerTop,
                                      collectionWidth, innerHeight);
    collectionView.backgroundColor = UIColor.clearColor;
    collectionView.alwaysBounceVertical = YES;
    collectionView.showsVerticalScrollIndicator = NO;
    collectionView.showsHorizontalScrollIndicator = NO;

    UICollectionViewLayout *layout = collectionView.collectionViewLayout;
    if ([layout isKindOfClass:UICollectionViewFlowLayout.class]) {
        UICollectionViewFlowLayout *flowLayout = (UICollectionViewFlowLayout *)layout;
        CGFloat itemSide = MIN(64.0, MAX(44.0, collectionWidth - 8.0));
        CGFloat horizontalInset = MAX(0.0, (collectionWidth - itemSide) * 0.5);
        flowLayout.scrollDirection = UICollectionViewScrollDirectionVertical;
        flowLayout.itemSize = CGSizeMake(itemSide, itemSide);
        flowLayout.minimumInteritemSpacing = 0.0;
        flowLayout.minimumLineSpacing = 10.0;
        flowLayout.sectionInset = UIEdgeInsetsMake(8.0, horizontalInset,
                                                   8.0, horizontalInset);
        [flowLayout invalidateLayout];
    }

    [hostView bringSubviewToFront:railView];
    [hostView bringSubviewToFront:collectionView];
}

static BOOL MRSelectorAlphaStripIsActive(id controller)
{
    UIVisualEffectView *stripView = objc_getAssociatedObject(controller,
                                                              MRSelectorAlphaStripKey);
    UICollectionView *collectionView = MRSafeValue(controller,
                                                    @"selectorAlphaCollectionView");
    return [stripView isKindOfClass:UIVisualEffectView.class] &&
        stripView.superview != nil &&
        [collectionView isKindOfClass:UICollectionView.class] &&
        collectionView.superview != nil;
}

static void MRHookSelectorAlphaBuildOverlay(id self, SEL selector, id action)
{
    MROriginalSelectorAlphaBuildOverlay(self, selector, action);
    MRLayoutSelectorAlphaStrip(self);
}

static NSInteger MRClampIndex(NSInteger value, NSInteger count)
{
    if (count <= 0) return NSNotFound;
    return MIN(MAX(value, 0), count - 1);
}

static void MRSelectorAlphaSelectionChanged(id controller)
{
    id feedback = MRSafeValue(controller, @"selectorAlphaSelectionFeedback");
    if ([feedback respondsToSelector:@selector(selectionChanged)])
        ((void (*)(id, SEL))objc_msgSend)(feedback, @selector(selectionChanged));
}

static void MRHookSelectorAlphaPointer(id self, SEL selector, CGPoint point)
{
    if (!MRSelectorAlphaStripIsActive(self)) {
        MROriginalSelectorAlphaPointer(self, selector, point);
        return;
    }

    UIView *rootView = MRSafeValue(self, @"view");
    UIView *railView = MRSafeValue(self, @"selectorAlphaLetterPanelView");
    NSArray *letters = MRSafeValue(self, @"selectorAlphaLetters");
    UICollectionView *collectionView = MRSafeValue(self, @"selectorAlphaCollectionView");
    NSArray *bundleIDs = MRSafeValue(self, @"selectorAlphaCurrentBundleIDs");
    if (![rootView isKindOfClass:UIView.class] ||
        ![railView isKindOfClass:UIView.class] ||
        ![letters isKindOfClass:NSArray.class] || letters.count == 0 ||
        ![collectionView isKindOfClass:UICollectionView.class]) {
        MROriginalSelectorAlphaPointer(self, selector, point);
        return;
    }

    CGPoint railPoint = [rootView convertPoint:point toView:railView];
    CGRect railHitBounds = CGRectInset(railView.bounds, -10.0, -8.0);
    if (CGRectContainsPoint(railHitBounds, railPoint)) {
        CGFloat height = MAX(1.0, CGRectGetHeight(railView.bounds));
        NSInteger letterIndex = MRClampIndex((NSInteger)floor(
            railPoint.y / height * (CGFloat)letters.count), (NSInteger)letters.count);
        NSInteger oldLetterIndex = [MRSafeValue(self, @"selectorAlphaSelectedLetterIndex") integerValue];
        if (letterIndex != NSNotFound && letterIndex != oldLetterIndex) {
            MRSafeSetValue(self, @"selectorAlphaSelectedLetterIndex", @(letterIndex));
            MRSafeSetValue(self, @"selectorAlphaSelectedAppIndex", @0);
            ((void (*)(id, SEL))objc_msgSend)(self,
                NSSelectorFromString(@"MT_IlIlllllIllIlIlllIlI"));
            ((void (*)(id, SEL))objc_msgSend)(self,
                NSSelectorFromString(@"MT_IlIIlIllIIllllllIIlI"));
            bundleIDs = MRSafeValue(self, @"selectorAlphaCurrentBundleIDs");
            if ([bundleIDs isKindOfClass:NSArray.class] && bundleIDs.count != 0)
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(self,
                    NSSelectorFromString(@"MT_IlIlIlllllIIllIllIlI:"), 0);
            MRSelectorAlphaSelectionChanged(self);
        }
        return;
    }

    CGPoint collectionPoint = [rootView convertPoint:point toView:collectionView];
    CGRect collectionHitBounds = CGRectInset(collectionView.bounds, -12.0, -8.0);
    if (CGRectContainsPoint(collectionHitBounds, collectionPoint)) {
        bundleIDs = MRSafeValue(self, @"selectorAlphaCurrentBundleIDs");
        if (![bundleIDs isKindOfClass:NSArray.class] || bundleIDs.count == 0) return;

        // Divide the visible column into one continuous band per application.
        // This keeps every app reachable by one held gesture even when a
        // letter owns more icons than fit on screen; the collection scrolls to
        // reveal the selected native cell.
        CGFloat collectionHeight = MAX(1.0, CGRectGetHeight(collectionView.bounds));
        CGFloat localY = collectionPoint.y - CGRectGetMinY(collectionView.bounds);
        NSInteger appIndex = (NSInteger)floor(
            localY / collectionHeight * (CGFloat)bundleIDs.count);
        appIndex = MRClampIndex(appIndex, (NSInteger)bundleIDs.count);
        NSInteger oldAppIndex = [MRSafeValue(self, @"selectorAlphaSelectedAppIndex") integerValue];
        if (appIndex != NSNotFound && appIndex != oldAppIndex) {
            ((void (*)(id, SEL))objc_msgSend)(self,
                NSSelectorFromString(@"MT_IllIlIllllllIIlIIlll"));
            MRSafeSetValue(self, @"selectorAlphaSelectedAppIndex", @(appIndex));
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(self,
                NSSelectorFromString(@"MT_IlIlIlllllIIllIllIlI:"), appIndex);
            NSIndexPath *target = [NSIndexPath indexPathForItem:appIndex inSection:0];
            [collectionView scrollToItemAtIndexPath:target
                                   atScrollPosition:UICollectionViewScrollPositionCenteredVertically
                                           animated:NO];
            MRSelectorAlphaSelectionChanged(self);
        }
        return;
    }

    // Outside the strip, keep Myrtle's initial state but do not feed the old
    // wide-grid mapper; that mapper is the geometry this hook replaces.
}

static void MRHookSelectorAlphaFinish(id self, SEL selector, BOOL commit)
{
    MROriginalSelectorAlphaFinish(self, selector, commit);
    UIVisualEffectView *stripView = objc_getAssociatedObject(self,
                                                              MRSelectorAlphaStripKey);
    [stripView removeFromSuperview];
    objc_setAssociatedObject(self, MRSelectorAlphaStripKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void MRLayoutStandaloneAlphaLauncher(id controller, NSString *stage)
{
    UIView *rootView = MRSafeValue(controller, @"view");
    UIView *containerView = MRSafeValue(controller, @"containerView");
    UIView *railView = MRSafeValue(controller, @"railView");
    UICollectionView *collectionView = MRSafeValue(controller, @"collectionView");
    UILabel *topLabel = MRSafeValue(controller, @"railTopLabel");
    UILabel *currentLabel = MRSafeValue(controller, @"currentLetterLabel");
    UILabel *bottomLabel = MRSafeValue(controller, @"railBottomLabel");
    MRAlphaLauncherDiagnostic([NSString stringWithFormat:
        @"%@ class=%@ root=%@ container=%@ rail=%@ collection=%@ rootBounds=%@ containerFrame=%@",
        stage, NSStringFromClass([controller class]), NSStringFromClass([rootView class]),
        NSStringFromClass([containerView class]), NSStringFromClass([railView class]),
        NSStringFromClass([collectionView class]), NSStringFromCGRect(rootView.bounds),
        NSStringFromCGRect(containerView.frame)]);
    if (![rootView isKindOfClass:UIView.class] ||
        ![containerView isKindOfClass:UIView.class] ||
        ![railView isKindOfClass:UIView.class] ||
        ![collectionView isKindOfClass:UICollectionView.class]) {
        MRAlphaLauncherDiagnostic(@"layout skipped: required native views unavailable");
        return;
    }

    CGRect bounds = rootView.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width < 160.0 || height < 280.0) {
        MRAlphaLauncherDiagnostic(@"layout skipped: root bounds not ready");
        return;
    }

    UIEdgeInsets safe = rootView.safeAreaInsets;
    CGFloat top = CGRectGetMinY(bounds) + MAX(8.0, safe.top + 8.0);
    CGFloat bottom = CGRectGetMaxY(bounds) - MAX(8.0, safe.bottom + 8.0);
    CGFloat right = CGRectGetMaxX(bounds) - MAX(12.0, safe.right + 12.0);
    CGFloat stripWidth = MIN(116.0, width - 32.0);
    CGFloat stripHeight = MIN(680.0, MAX(260.0, bottom - top));
    CGFloat stripX = right - stripWidth;
    CGFloat stripY = top + MAX(0.0, (bottom - top - stripHeight) * 0.5);
    containerView.frame = CGRectMake(MRPixelAligned(stripX), MRPixelAligned(stripY),
                                     MRPixelAligned(stripWidth), MRPixelAligned(stripHeight));
    containerView.layer.cornerRadius = MIN(30.0, stripWidth * 0.26);
    containerView.clipsToBounds = YES;

    CGFloat inset = 10.0;
    CGFloat railWidth = 26.0;
    CGFloat gap = 5.0;
    CGFloat contentWidth = MAX(48.0, stripWidth - inset * 2.0 - railWidth - gap);
    CGFloat contentHeight = MAX(1.0, stripHeight - inset * 2.0);
    railView.frame = CGRectMake(inset, inset, railWidth, contentHeight);
    railView.layer.cornerRadius = railWidth * 0.5;
    railView.clipsToBounds = YES;

    CGFloat currentHeight = MIN(48.0, contentHeight * 0.16);
    CGFloat sideHeight = MAX(0.0, (contentHeight - currentHeight) * 0.5);
    if ([topLabel isKindOfClass:UILabel.class]) {
        topLabel.frame = CGRectMake(0.0, 0.0, railWidth, sideHeight);
        topLabel.numberOfLines = 0;
        topLabel.textAlignment = NSTextAlignmentCenter;
    }
    if ([currentLabel isKindOfClass:UILabel.class]) {
        currentLabel.frame = CGRectMake(0.0, sideHeight, railWidth, currentHeight);
        currentLabel.textAlignment = NSTextAlignmentCenter;
        currentLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightSemibold];
    }
    if ([bottomLabel isKindOfClass:UILabel.class]) {
        bottomLabel.frame = CGRectMake(0.0, sideHeight + currentHeight,
                                       railWidth, sideHeight);
        bottomLabel.numberOfLines = 0;
        bottomLabel.textAlignment = NSTextAlignmentCenter;
    }

    collectionView.frame = CGRectMake(inset + railWidth + gap, inset,
                                      contentWidth, contentHeight);
    collectionView.alwaysBounceVertical = YES;
    collectionView.showsVerticalScrollIndicator = NO;
    collectionView.showsHorizontalScrollIndicator = NO;
    UICollectionViewFlowLayout *layout =
        [collectionView.collectionViewLayout isKindOfClass:UICollectionViewFlowLayout.class]
            ? (UICollectionViewFlowLayout *)collectionView.collectionViewLayout : nil;
    if (layout != nil) {
        CGFloat side = MIN(64.0, MAX(44.0, contentWidth - 4.0));
        CGFloat horizontal = MAX(0.0, (contentWidth - side) * 0.5);
        layout.scrollDirection = UICollectionViewScrollDirectionVertical;
        layout.itemSize = CGSizeMake(side, side);
        layout.minimumInteritemSpacing = 0.0;
        layout.minimumLineSpacing = 10.0;
        layout.sectionInset = UIEdgeInsetsMake(8.0, horizontal, 8.0, horizontal);
        [layout invalidateLayout];
    }
    MRAlphaLauncherDiagnostic([NSString stringWithFormat:
        @"%@ applied container=%@ rail=%@ collection=%@ items=%@",
        stage, NSStringFromCGRect(containerView.frame), NSStringFromCGRect(railView.frame),
        NSStringFromCGRect(collectionView.frame), NSStringFromCGSize(layout.itemSize)]);
}

static void MRHookAlphaLauncherViewDidLoad(id self, SEL selector)
{
    MROriginalAlphaLauncherViewDidLoad(self, selector);
    MRLayoutStandaloneAlphaLauncher(self, @"viewDidLoad");
}

static void MRHookAlphaLauncherViewDidLayoutSubviews(id self, SEL selector)
{
    MROriginalAlphaLauncherViewDidLayoutSubviews(self, selector);
    MRLayoutStandaloneAlphaLauncher(self, @"viewDidLayoutSubviews");
}

static id MRSendClassNoArgs(NSString *className, NSString *selectorName)
{
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    if (cls == Nil || ![cls respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, selector);
}

static void MRClearMyrtleHostedKeyboardState(void)
{
    MRMyrtleHostedKeyboardVisible = NO;
    MRMyrtleKeyboardOwnerController = nil;
    MRMyrtleKeyboardOwnerBundleID = nil;
    MRScheduleMyrtleHostWindowGeometrySync();
}

static void MRUpdateMyrtleHostedKeyboardState(id controller, CGRect keyboardFrame)
{
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    CGRect visibleKeyboard = CGRectIntersection(screenBounds, keyboardFrame);
    id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
    NSString *managerBundleID = MRSafeValue(manager, @"currentBundleID");
    NSString *controllerBundleID = MRSafeValue(controller, @"currentWindowBundleID");
    BOOL validGeometry = !CGRectIsNull(visibleKeyboard) &&
        !CGRectIsEmpty(visibleKeyboard) &&
        CGRectGetWidth(visibleKeyboard) > 1.0 &&
        CGRectGetHeight(visibleKeyboard) > 20.0;
    BOOL validHost = controller != nil &&
        [MRSafeValue(controller, @"isWindowOpen") boolValue] &&
        [managerBundleID isKindOfClass:NSString.class] &&
        managerBundleID.length != 0 &&
        [controllerBundleID isKindOfClass:NSString.class] &&
        [controllerBundleID isEqualToString:managerBundleID];
    if (!validGeometry || !validHost) {
        MRClearMyrtleHostedKeyboardState();
        return;
    }

    MRMyrtleKeyboardOwnerController = controller;
    MRMyrtleKeyboardOwnerBundleID = [managerBundleID copy];
    MRMyrtleHostedKeyboardVisible = YES;
    MRScheduleMyrtleHostWindowGeometrySync();
}

static BOOL MRShouldAllowMyrtleOutsideAction(id controller)
{
    if (!MRMyrtleHostedKeyboardVisible || controller == nil ||
        MRMyrtleKeyboardOwnerController != controller ||
        ![MRSafeValue(controller, @"isWindowOpen") boolValue]) return NO;

    NSString *controllerBundleID = MRSafeValue(controller, @"currentWindowBundleID");
    id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
    NSString *managerBundleID = MRSafeValue(manager, @"currentBundleID");
    return MRMyrtleKeyboardOwnerBundleID.length != 0 &&
        [controllerBundleID isEqualToString:MRMyrtleKeyboardOwnerBundleID] &&
        [managerBundleID isEqualToString:MRMyrtleKeyboardOwnerBundleID];
}

static void MRHookMyrtleOutsideAction(id self, SEL selector)
{
    if (!MRShouldAllowMyrtleOutsideAction(self)) return;
    MROriginalMyrtleOutsideAction(self, selector);
}

static BOOL MRUsableMyrtleHostRect(CGRect rect, CGRect screenBounds)
{
    if (CGRectIsNull(rect) || CGRectIsInfinite(rect) || CGRectIsEmpty(rect)) return NO;
    if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) ||
        !isfinite(rect.size.width) || !isfinite(rect.size.height)) return NO;
    if (rect.size.width < 44.0 || rect.size.height < 44.0) return NO;

    CGRect visible = CGRectIntersection(rect, screenBounds);
    if (CGRectIsNull(visible) || CGRectIsEmpty(visible)) return NO;
    CGFloat screenArea = CGRectGetWidth(screenBounds) * CGRectGetHeight(screenBounds);
    CGFloat visibleArea = CGRectGetWidth(visible) * CGRectGetHeight(visible);
    // The hosted scene itself may retain full-screen logical bounds.  That is
    // not the visible split card and must not be treated as its touch region.
    return screenArea > 0.0 && visibleArea < screenArea * 0.96;
}

static CGRect MRVisibleMyrtleHostRectInScreen(UIView *hostView)
{
    if (![hostView isKindOfClass:UIView.class] || hostView.window == nil)
        return CGRectNull;

    CGRect screenBounds = UIScreen.mainScreen.bounds;
    id<UICoordinateSpace> screenSpace = UIScreen.mainScreen.fixedCoordinateSpace;
    CGRect bestRect = CGRectNull;
    CGFloat bestArea = 0.0;
    // Myrtle scales/clips the hosted scene through one or more containers.
    // The largest non-full-screen ancestor includes the complete visible card
    // while excluding the screen-sized routing roots above it.
    for (UIView *candidate = hostView;
         [candidate isKindOfClass:UIView.class] && ![candidate isKindOfClass:UIWindow.class];
         candidate = candidate.superview) {
        CGRect rect = [candidate convertRect:candidate.bounds
                           toCoordinateSpace:screenSpace];
        if (!MRUsableMyrtleHostRect(rect, screenBounds)) continue;
        CGFloat area = CGRectGetWidth(rect) * CGRectGetHeight(rect);
        if (area > bestArea) {
            bestRect = rect;
            bestArea = area;
        }
    }
    return CGRectIsNull(bestRect) ? CGRectNull : CGRectInset(bestRect, -6.0, -6.0);
}

static BOOL MRRectsNearlyEqual(CGRect lhs, CGRect rhs)
{
    return fabs(lhs.origin.x - rhs.origin.x) < 0.25 &&
        fabs(lhs.origin.y - rhs.origin.y) < 0.25 &&
        fabs(lhs.size.width - rhs.size.width) < 0.25 &&
        fabs(lhs.size.height - rhs.size.height) < 0.25;
}

static UIWindow *MRMyrtleHostWindow(void)
{
    id window = MRSendClassNoArgs(@"MyrtleHostWindow", @"sharedWindow");
    return [window isKindOfClass:UIWindow.class] ? window : nil;
}

static void MRSaveNativeMyrtleHostWindowGeometry(UIWindow *window)
{
    if (window == nil || MRNativeMyrtleHostWindowGeometrySaved) return;
    MRScopedMyrtleHostWindow = window;
    MRNativeMyrtleHostWindowFrame = window.frame;
    MRNativeMyrtleHostWindowBounds = window.bounds;
    MRNativeMyrtleHostWindowClipsToBounds = window.clipsToBounds;
    UIView *rootView = window.rootViewController.view;
    if ([rootView isKindOfClass:UIView.class]) {
        MRScopedMyrtleHostRootView = rootView;
        MRNativeMyrtleHostRootViewFrame = rootView.frame;
        MRNativeMyrtleHostRootViewBounds = rootView.bounds;
        MRNativeMyrtleHostRootViewAutoresizingMask = rootView.autoresizingMask;
    }
    MRNativeMyrtleHostWindowGeometrySaved = YES;
}

static void MRResetMyrtleHostWindowGeometryCandidate(void)
{
    MRMyrtleHostWindowCandidateRect = CGRectZero;
    MRMyrtleHostWindowCandidateCount = 0;
    MRMyrtleHostWindowActiveCropRect = CGRectZero;
}

static void MRInvalidateMyrtleSnapTransition(void)
{
    // Cancel a delayed settle belonging to an older window/session. The
    // generation check makes already-enqueued blocks harmless without keeping
    // a timer or observer alive.
    ++MRMyrtleSnapTransitionGeneration;
    MRMyrtleSnapTransitionInFlight = NO;
}

static void MRRestoreMyrtleHostWindowGeometry(void)
{
    UIWindow *window = MRScopedMyrtleHostWindow ?: MRMyrtleHostWindow();
    if (window == nil || !MRNativeMyrtleHostWindowGeometrySaved ||
        !MRMyrtleHostWindowCropApplied) return;

    MRMyrtleHostWindowGeometrySyncing = YES;
    @try {
        [UIView performWithoutAnimation:^{
            window.bounds = MRNativeMyrtleHostWindowBounds;
            window.frame = MRNativeMyrtleHostWindowFrame;
            window.clipsToBounds = MRNativeMyrtleHostWindowClipsToBounds;
            UIView *rootView = MRScopedMyrtleHostRootView ?: window.rootViewController.view;
            if ([rootView isKindOfClass:UIView.class]) {
                rootView.autoresizingMask = MRNativeMyrtleHostRootViewAutoresizingMask;
                rootView.bounds = MRNativeMyrtleHostRootViewBounds;
                rootView.frame = MRNativeMyrtleHostRootViewFrame;
            }
        }];
    } @finally {
        MRMyrtleHostWindowGeometrySyncing = NO;
    }
    MRMyrtleHostWindowCropApplied = NO;
}

static void MRApplyMyrtleHostWindowGeometry(void)
{
    if (MRMyrtleHostWindowGeometrySyncing) return;
    // The handle's up/down snap action animates through a separate controller
    // path. Never crop an intermediate animation frame, because that preserves
    // the old visible intersection and cuts away content moving on screen.
    if (MRMyrtleSnapTransitionInFlight) return;
    UIWindow *window = MRMyrtleHostWindow();
    id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
    NSString *bundleID = MRSafeValue(manager, @"currentBundleID");
    UIView *hostView = MRSafeValue(manager, @"hostView");
    UIView *splashContainer = MRSafeValue(manager, @"splashContainer");
    BOOL isOperating = [MRSafeValue(manager, @"isOperating") boolValue];

    if (MRMyrtleHostedKeyboardVisible || bundleID.length == 0 ||
        ![hostView isKindOfClass:UIView.class] || hostView.window != window) {
        MRRestoreMyrtleHostWindowGeometry();
        MRResetMyrtleHostWindowGeometryCandidate();
        return;
    }

    // Myrtle creates and animates the card in the full-screen host context.
    // Cropping that context while a cold-launch splash or an open/drag/resize
    // operation is active freezes the gesture coordinate space at an
    // intermediate frame. Leave Myrtle completely native until its own
    // lifecycle reports a settled host.
    if (isOperating || [splashContainer isKindOfClass:UIView.class]) {
        MRRestoreMyrtleHostWindowGeometry();
        MRResetMyrtleHostWindowGeometryCandidate();
        MRScheduleMyrtleHostWindowGeometryFollowup();
        return;
    }

    CGRect screenBounds = UIScreen.mainScreen.bounds;
    CGRect hostRect = CGRectNull;
    CGRect cropRect = CGRectNull;
    if (MRMyrtleHostWindowCropApplied &&
        MRUsableMyrtleHostRect(MRMyrtleHostWindowActiveCropRect, screenBounds)) {
        // Once the card has been cropped, its hierarchy is expressed through
        // our compensated root coordinates. Re-reading that hierarchy as if it
        // were still native once caused a second crop to expand from
        // {46.6,66.6,381.4,792.8} to almost the whole screen. Keep the verified
        // native card rect immutable until Myrtle starts a real operation; the
        // setIsOperating:/splash/currentBundle hooks restore and invalidate it.
        hostRect = MRMyrtleHostWindowActiveCropRect;
        cropRect = MRMyrtleHostWindowActiveCropRect;
    } else {
        hostRect = MRVisibleMyrtleHostRectInScreen(hostView);
        cropRect = CGRectIntersection(hostRect, screenBounds);
    }
    if (!MRUsableMyrtleHostRect(cropRect, screenBounds)) {
        MRRestoreMyrtleHostWindowGeometry();
        MRResetMyrtleHostWindowGeometryCandidate();
        return;
    }

    // Require the visible card to be identical on two separated main-loop
    // observations before changing the WindowServer context. This filters the
    // one-frame cold-launch geometry without a permanent timer or poller.
    if (!MRMyrtleHostWindowCropApplied) {
        if (MRMyrtleHostWindowCandidateCount != 0 &&
            MRRectsNearlyEqual(MRMyrtleHostWindowCandidateRect, cropRect)) {
            MRMyrtleHostWindowCandidateCount++;
        } else {
            MRMyrtleHostWindowCandidateRect = cropRect;
            MRMyrtleHostWindowCandidateCount = 1;
        }
        if (MRMyrtleHostWindowCandidateCount < 2) {
            MRScheduleMyrtleHostWindowGeometryFollowup();
            return;
        }
    }

    MRSaveNativeMyrtleHostWindowGeometry(window);
    UIView *rootView = MRScopedMyrtleHostRootView ?: window.rootViewController.view;
    CGRect cropBounds = CGRectMake(0.0, 0.0,
                                   CGRectGetWidth(cropRect),
                                   CGRectGetHeight(cropRect));
    CGFloat offsetX = cropRect.origin.x - MRNativeMyrtleHostWindowFrame.origin.x;
    CGFloat offsetY = cropRect.origin.y - MRNativeMyrtleHostWindowFrame.origin.y;
    CGRect compensatedRootFrame = CGRectOffset(MRNativeMyrtleHostRootViewFrame,
                                               -offsetX, -offsetY);
    BOOL alreadyApplied = MRMyrtleHostWindowCropApplied &&
        MRRectsNearlyEqual(window.frame, cropRect) &&
        MRRectsNearlyEqual(window.bounds, cropBounds) &&
        window.clipsToBounds &&
        (![rootView isKindOfClass:UIView.class] ||
         (MRRectsNearlyEqual(rootView.frame, compensatedRootFrame) &&
          MRRectsNearlyEqual(rootView.bounds, MRNativeMyrtleHostRootViewBounds)));
    if (!alreadyApplied) {
        MRMyrtleHostWindowGeometrySyncing = YES;
        @try {
            [UIView performWithoutAnimation:^{
                // Keep UIWindow's context conventional and compensate inside
                // the root view. Myrtle's own full-screen coordinate system,
                // cold-launch layout, drag and resize math remain unchanged.
                window.bounds = cropBounds;
                window.frame = cropRect;
                // A genuinely card-sized host context lets
                // WindowServer route touches outside the card to the full-screen
                // app. Later root-coordinate compensation repaired the visual
                // position but allowed the full-screen root subtree to extend
                // beyond the cropped UIWindow again. Clip at the UIWindow
                // boundary so that compensation cannot enlarge its hit region.
                window.clipsToBounds = YES;
                if ([rootView isKindOfClass:UIView.class]) {
                    rootView.autoresizingMask = UIViewAutoresizingNone;
                    rootView.bounds = MRNativeMyrtleHostRootViewBounds;
                    rootView.frame = compensatedRootFrame;
                }
            }];
        } @finally {
            MRMyrtleHostWindowGeometrySyncing = NO;
        }
        MRMyrtleHostWindowActiveCropRect = cropRect;
        MRMyrtleHostWindowCropApplied = YES;
    }
}

static void MRScheduleMyrtleHostWindowGeometrySync(void)
{
    if (MRMyrtleHostWindowGeometrySyncScheduled) return;
    MRMyrtleHostWindowGeometrySyncScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        MRMyrtleHostWindowGeometrySyncScheduled = NO;
        MRApplyMyrtleHostWindowGeometry();
    });
}

static void MRScheduleMyrtleHostWindowGeometryFollowup(void)
{
    if (MRMyrtleHostWindowGeometryFollowupScheduled) return;
    MRMyrtleHostWindowGeometryFollowupScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        MRMyrtleHostWindowGeometryFollowupScheduled = NO;
        MRScheduleMyrtleHostWindowGeometrySync();
    });
}

static void MRHookMyrtleHostWindowLayoutSubviews(id self, SEL selector)
{
    MROriginalMyrtleHostWindowLayoutSubviews(self, selector);
    if (MRMyrtleHostWindowGeometrySyncing) return;
    // UIWindow may reset its controller view to bounds during layout. When a
    // crop is already active, repair the root compensation before this layout
    // is committed on screen; the asynchronous path is only for discovering a
    // not-yet-cropped card.
    if (MRMyrtleHostWindowCropApplied)
        MRApplyMyrtleHostWindowGeometry();
    else
        MRScheduleMyrtleHostWindowGeometrySync();
}

static void MRHookMyrtleHostGesture(id self, SEL selector,
                                    UIGestureRecognizer *gesture)
{
    UIGestureRecognizerState stateBefore = gesture.state;

    // Myrtle's window drag/resize path does not toggle isOperating. Restore the
    // native full-screen coordinate space before it captures gestureStartFrame
    // so its own movement math remains unchanged and no stale card clip limits
    // the gesture to the previous position.
    if (stateBefore == UIGestureRecognizerStateBegan) {
        MRInvalidateMyrtleSnapTransition();
        MRRestoreMyrtleHostWindowGeometry();
        MRResetMyrtleHostWindowGeometryCandidate();
    }

    MROriginalMyrtleHostGesture(self, selector, gesture);

    UIGestureRecognizerState stateAfter = gesture.state;
    if (stateAfter == UIGestureRecognizerStateEnded ||
        stateAfter == UIGestureRecognizerStateCancelled ||
        stateAfter == UIGestureRecognizerStateFailed) {
        MRResetMyrtleHostWindowGeometryCandidate();
        MRScheduleMyrtleHostWindowGeometrySync();
        MRScheduleMyrtleHostWindowGeometryFollowup();
    }
}

static void MRHookMyrtleSnapTransition(id self, SEL selector, BOOL upward)
{
    // Verified Myrtle 1.4.1 handle-snap path: it reads currentSnapStatus,
    // calculates a destination host frame and commits UIView animations.
    NSUInteger generation = ++MRMyrtleSnapTransitionGeneration;
    MRMyrtleSnapTransitionInFlight = YES;
    MRRestoreMyrtleHostWindowGeometry();
    MRResetMyrtleHostWindowGeometryCandidate();

    MROriginalMyrtleSnapTransition(self, selector, upward);

    // The method contains both standard and spring animations. Preserve the
    // native coordinate space until they settle, then run the existing
    // two-observation stability gate at the destination.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.70 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != MRMyrtleSnapTransitionGeneration) return;
        MRMyrtleSnapTransitionInFlight = NO;
        MRResetMyrtleHostWindowGeometryCandidate();
        MRScheduleMyrtleHostWindowGeometrySync();
        MRScheduleMyrtleHostWindowGeometryFollowup();
    });
}

static UIView *MRHookMyrtleHostWindowHitTest(id self, SEL selector,
                                             CGPoint point, UIEvent *event)
{
    UIView *result = MROriginalMyrtleHostWindowHitTest(self, selector, point, event);
    // While the hosted keyboard is visible, retain Myrtle's complete native
    // outside-touch route.  It consumes the touch and invokes the gated close
    // action without activating the application underneath.
    if (MRMyrtleHostedKeyboardVisible) return result;

    // On the verified Myrtle 1.4.1 implementation, its own hitTest method has
    // already observed TapOutsideAction=0 at the exact preference branch. Use
    // its native result unchanged so the touch can reach either SpringBoard or
    // a full-screen application behind the split window.
    if (MRMyrtleTapOutsidePreferenceOverrideInstalled) return result;

    id manager = MRSendClassNoArgs(@"MyrtleHostManager", @"sharedManager");
    UIView *hostView = MRSafeValue(manager, @"hostView");
    CGRect hostRect = MRVisibleMyrtleHostRectInScreen(hostView);
    CGPoint screenPoint = [(UIView *)self convertPoint:point
                                    toCoordinateSpace:UIScreen.mainScreen.fixedCoordinateSpace];

    // With no hosted keyboard, only the visible hosted card may keep the hit.
    // The hosted scene can retain full-screen logical bounds while a parent
    // container scales/clips it into the card, so pointInside: on hostView is
    // insufficient.  Derive the live visible card from Myrtle's own view tree.
    if (CGRectIsNull(hostRect)) return result;
    return CGRectContainsPoint(hostRect, screenPoint) ? result : nil;
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
typedef void (*MRSetManagerOperatingIMP)(id, SEL, BOOL);
static MRSetManagerOperatingIMP MROriginalSetManagerOperating = NULL;
typedef void (*MRSetManagerSplashIMP)(id, SEL, UIView *);
static MRSetManagerSplashIMP MROriginalSetManagerSplash = NULL;

static void MRHookSetManagerOperating(id self, SEL selector, BOOL operating)
{
    // Myrtle's native full-screen context is required throughout every open,
    // close, drag and resize transaction. Restore it before the transaction
    // starts, then crop only after Myrtle commits its settled geometry.
    if (operating) {
        MRInvalidateMyrtleSnapTransition();
        MRRestoreMyrtleHostWindowGeometry();
        MRResetMyrtleHostWindowGeometryCandidate();
    }
    MROriginalSetManagerOperating(self, selector, operating);
    if (!operating) {
        MRResetMyrtleHostWindowGeometryCandidate();
        MRScheduleMyrtleHostWindowGeometrySync();
        MRScheduleMyrtleHostWindowGeometryFollowup();
    }
}

static void MRHookSetManagerSplash(id self, SEL selector, UIView *splash)
{
    MROriginalSetManagerSplash(self, selector, splash);
    if (splash == nil) {
        MRResetMyrtleHostWindowGeometryCandidate();
        MRScheduleMyrtleHostWindowGeometrySync();
        MRScheduleMyrtleHostWindowGeometryFollowup();
    }
}

static void MRHookSetCurrentBundle(id self, SEL selector, NSString *bundleID)
{
    NSString *previousBundleID = [MRSafeValue(self, @"currentBundleID") copy];
    BOOL hostSessionChanged = !((previousBundleID == bundleID) ||
        [previousBundleID isEqualToString:bundleID]);
    if (hostSessionChanged) MRInvalidateMyrtleSnapTransition();
    // Keyboard visibility belongs to one concrete Myrtle host session.  Drop
    // it synchronously when that host closes or switches applications so a
    // delayed/native outside tap can never act on the next window.
    if (MRMyrtleKeyboardOwnerBundleID.length != 0 &&
        ![MRMyrtleKeyboardOwnerBundleID isEqualToString:bundleID]) {
        MRClearMyrtleHostedKeyboardState();
    }
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
    if (bundleID.length == 0 && previousBundleID.length != 0)
        MRRestoreMyrtleHostWindowGeometry();
    MRResetMyrtleHostWindowGeometryCandidate();
    MROriginalSetCurrentBundle(self, selector, bundleID);
    MRScheduleMyrtleHostWindowGeometrySync();
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
    MRUpdateMyrtleHostedKeyboardState(self, keyboardFrame);
}

static void MRHookKeyboardWillHide(id self, SEL selector, NSNotification *notification)
{
    MRClearMyrtleHostedKeyboardState();
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
    Class cls = NSClassFromString(@"MyrtleHostManager");
    if (cls == Nil) return NO;

    if (MROriginalSetCurrentBundle == NULL) {
        SEL selector = NSSelectorFromString(@"setCurrentBundleID:");
        Method method = class_getInstanceMethod(cls, selector);
        if (method == NULL || method_getNumberOfArguments(method) != 3) return NO;
        MSHookMessageEx(cls, selector, (IMP)MRHookSetCurrentBundle,
                        (IMP *)&MROriginalSetCurrentBundle);
    }
    if (MROriginalSetManagerOperating == NULL) {
        SEL selector = NSSelectorFromString(@"setIsOperating:");
        Method method = class_getInstanceMethod(cls, selector);
        if (method == NULL || method_getNumberOfArguments(method) != 3) return NO;
        MSHookMessageEx(cls, selector, (IMP)MRHookSetManagerOperating,
                        (IMP *)&MROriginalSetManagerOperating);
    }
    if (MROriginalSetManagerSplash == NULL) {
        SEL selector = NSSelectorFromString(@"setSplashContainer:");
        Method method = class_getInstanceMethod(cls, selector);
        if (method == NULL || method_getNumberOfArguments(method) != 3) return NO;
        MSHookMessageEx(cls, selector, (IMP)MRHookSetManagerSplash,
                        (IMP *)&MROriginalSetManagerSplash);
    }
    MRLog(@"installed direct MyrtleHostManager hook");
    return MROriginalSetCurrentBundle != NULL &&
        MROriginalSetManagerOperating != NULL &&
        MROriginalSetManagerSplash != NULL;
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

static BOOL MRInstallMyrtleOutsideActionGateHook(void)
{
    if (MROriginalMyrtleOutsideAction != NULL) return YES;

    Class cls = NSClassFromString(@"MyrtleViewController");
    SEL selector = NSSelectorFromString(@"MT_IlllIIIIlIlIIIIIlIll");
    Method method = class_getInstanceMethod(cls, selector);
    if (cls == Nil || method == NULL || method_getNumberOfArguments(method) != 2)
        return NO;

    char returnType[16] = {};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (returnType[0] != 'v') return NO;

    MSHookMessageEx(cls, selector, (IMP)MRHookMyrtleOutsideAction,
                    (IMP *)&MROriginalMyrtleOutsideAction);
    return MROriginalMyrtleOutsideAction != NULL;
}

static BOOL MRInstallMyrtleHostWindowPassThroughHook(void)
{
    if (MROriginalMyrtleHostWindowHitTest != NULL)
        return MRMyrtleTapOutsidePreferenceOverrideInstalled;

    Class cls = NSClassFromString(@"MyrtleHostWindow");
    SEL selector = @selector(hitTest:withEvent:);
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

    IMP nativeImplementation = method_getImplementation(method);
    if (!MRConfigureMyrtleTapOutsidePreferenceOverride(nativeImplementation))
        return NO;
    MSHookMessageEx(cls, selector, (IMP)MRHookMyrtleHostWindowHitTest,
                    (IMP *)&MROriginalMyrtleHostWindowHitTest);
    return MROriginalMyrtleHostWindowHitTest != NULL;
}

static BOOL MRInstallMyrtleHostWindowGeometryHook(void)
{
    if (MROriginalMyrtleHostWindowLayoutSubviews != NULL) return YES;

    Class cls = NSClassFromString(@"MyrtleHostWindow");
    SEL selector = @selector(layoutSubviews);
    Method method = class_getInstanceMethod(cls, selector);
    if (cls == Nil || method == NULL || method_getNumberOfArguments(method) != 2)
        return NO;
    char returnType[16] = {};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (returnType[0] != 'v') return NO;

    IMP inheritedOrDirect = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (class_addMethod(cls, selector,
                        (IMP)MRHookMyrtleHostWindowLayoutSubviews, types)) {
        MROriginalMyrtleHostWindowLayoutSubviews =
            (MRWindowLayoutSubviewsIMP)inheritedOrDirect;
    } else {
        MSHookMessageEx(cls, selector,
                        (IMP)MRHookMyrtleHostWindowLayoutSubviews,
                        (IMP *)&MROriginalMyrtleHostWindowLayoutSubviews);
    }
    BOOL installed = MROriginalMyrtleHostWindowLayoutSubviews != NULL;
    if (installed) MRScheduleMyrtleHostWindowGeometrySync();
    return installed;
}

static BOOL MRInstallMyrtleHostGestureHook(void)
{
    if (MROriginalMyrtleHostGesture != NULL) return YES;

    Class cls = NSClassFromString(@"MyrtleHostManager");
    SEL selector = NSSelectorFromString(@"MT_IllIllllIllIIlIlIlIl:");
    Method method = class_getInstanceMethod(cls, selector);
    if (cls == Nil || method == NULL || method_getNumberOfArguments(method) != 3)
        return NO;

    char returnType[16] = {};
    char argumentType[16] = {};
    method_getReturnType(method, returnType, sizeof(returnType));
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    if (returnType[0] != 'v' || argumentType[0] != '@') return NO;

    MSHookMessageEx(cls, selector, (IMP)MRHookMyrtleHostGesture,
                    (IMP *)&MROriginalMyrtleHostGesture);
    return MROriginalMyrtleHostGesture != NULL;
}

static BOOL MRInstallMyrtleSnapTransitionHook(void)
{
    if (MROriginalMyrtleSnapTransition != NULL) return YES;

    Class cls = NSClassFromString(@"MyrtleViewController");
    SEL selector = NSSelectorFromString(@"MT_llIIIIlllllllllIIIll:");
    Method method = class_getInstanceMethod(cls, selector);
    if (cls == Nil || method == NULL || method_getNumberOfArguments(method) != 3)
        return NO;

    char returnType[16] = {};
    char argumentType[16] = {};
    method_getReturnType(method, returnType, sizeof(returnType));
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    if (returnType[0] != 'v' || argumentType[0] != 'B') return NO;

    MSHookMessageEx(cls, selector, (IMP)MRHookMyrtleSnapTransition,
                    (IMP *)&MROriginalMyrtleSnapTransition);
    return MROriginalMyrtleSnapTransition != NULL;
}

static BOOL __attribute__((unused)) MRInstallSelectorAlphaStripHooks(void)
{
    if (MROriginalSelectorAlphaBuildOverlay != NULL &&
        MROriginalSelectorAlphaPointer != NULL &&
        MROriginalSelectorAlphaFinish != NULL) return YES;

    Class cls = NSClassFromString(@"MyrtleViewController");
    if (cls == Nil) return NO;

    if (MROriginalSelectorAlphaBuildOverlay == NULL) {
        SEL buildSelector = NSSelectorFromString(@"MT_IllIlIlllIIllllIIlII:");
        Method buildMethod = class_getInstanceMethod(cls, buildSelector);
        if (buildMethod == NULL || method_getNumberOfArguments(buildMethod) != 3)
            return NO;
        char returnType[16] = {};
        char argumentType[16] = {};
        method_getReturnType(buildMethod, returnType, sizeof(returnType));
        method_getArgumentType(buildMethod, 2, argumentType, sizeof(argumentType));
        if (returnType[0] != 'v' || argumentType[0] != '@') return NO;
        MSHookMessageEx(cls, buildSelector,
                        (IMP)MRHookSelectorAlphaBuildOverlay,
                        (IMP *)&MROriginalSelectorAlphaBuildOverlay);
    }

    if (MROriginalSelectorAlphaPointer == NULL) {
        SEL pointerSelector = NSSelectorFromString(@"MT_lllIIIIlIllIIIIIIlll:");
        Method pointerMethod = class_getInstanceMethod(cls, pointerSelector);
        if (pointerMethod == NULL || method_getNumberOfArguments(pointerMethod) != 3)
            return NO;
        char returnType[16] = {};
        char argumentType[32] = {};
        method_getReturnType(pointerMethod, returnType, sizeof(returnType));
        method_getArgumentType(pointerMethod, 2, argumentType, sizeof(argumentType));
        if (returnType[0] != 'v' || argumentType[0] != '{') return NO;
        MSHookMessageEx(cls, pointerSelector,
                        (IMP)MRHookSelectorAlphaPointer,
                        (IMP *)&MROriginalSelectorAlphaPointer);
    }

    if (MROriginalSelectorAlphaFinish == NULL) {
        SEL finishSelector = NSSelectorFromString(@"MT_lllIllIllIIIIlllIIII:");
        Method finishMethod = class_getInstanceMethod(cls, finishSelector);
        if (finishMethod == NULL || method_getNumberOfArguments(finishMethod) != 3)
            return NO;
        char returnType[16] = {};
        char argumentType[16] = {};
        method_getReturnType(finishMethod, returnType, sizeof(returnType));
        method_getArgumentType(finishMethod, 2, argumentType, sizeof(argumentType));
        if (returnType[0] != 'v' || (argumentType[0] != 'B' && argumentType[0] != 'c'))
            return NO;
        MSHookMessageEx(cls, finishSelector,
                        (IMP)MRHookSelectorAlphaFinish,
                        (IMP *)&MROriginalSelectorAlphaFinish);
    }

    return MROriginalSelectorAlphaBuildOverlay != NULL &&
        MROriginalSelectorAlphaPointer != NULL &&
        MROriginalSelectorAlphaFinish != NULL;
}

static BOOL MRInstallStandaloneAlphaLauncherHooks(void)
{
    if (MROriginalAlphaLauncherViewDidLoad != NULL &&
        MROriginalAlphaLauncherViewDidLayoutSubviews != NULL) return YES;

    Class cls = NSClassFromString(@"MyrtleAlphaAppLauncherViewController");
    if (cls == Nil) {
        MRAlphaLauncherDiagnostic(@"install: MyrtleAlphaAppLauncherViewController unavailable");
        return NO;
    }

    if (MROriginalAlphaLauncherViewDidLoad == NULL) {
        Method method = class_getInstanceMethod(cls, @selector(viewDidLoad));
        if (method == NULL || method_getNumberOfArguments(method) != 2) {
            MRAlphaLauncherDiagnostic(@"install: viewDidLoad signature mismatch");
            return NO;
        }
        MSHookMessageEx(cls, @selector(viewDidLoad),
                        (IMP)MRHookAlphaLauncherViewDidLoad,
                        (IMP *)&MROriginalAlphaLauncherViewDidLoad);
    }

    if (MROriginalAlphaLauncherViewDidLayoutSubviews == NULL) {
        Method method = class_getInstanceMethod(cls, @selector(viewDidLayoutSubviews));
        if (method == NULL || method_getNumberOfArguments(method) != 2) {
            MRAlphaLauncherDiagnostic(@"install: viewDidLayoutSubviews signature mismatch");
            return NO;
        }
        MSHookMessageEx(cls, @selector(viewDidLayoutSubviews),
                        (IMP)MRHookAlphaLauncherViewDidLayoutSubviews,
                        (IMP *)&MROriginalAlphaLauncherViewDidLayoutSubviews);
    }

    BOOL installed = MROriginalAlphaLauncherViewDidLoad != NULL &&
        MROriginalAlphaLauncherViewDidLayoutSubviews != NULL;
    MRAlphaLauncherDiagnostic([NSString stringWithFormat:
        @"install: class=%@ viewDidLoad=%d viewDidLayoutSubviews=%d result=%d",
        NSStringFromClass(cls), MROriginalAlphaLauncherViewDidLoad != NULL,
        MROriginalAlphaLauncherViewDidLayoutSubviews != NULL, installed]);
    return installed;
}

/*
 * Keep this installer deliberately exact: both selectors belong to
 * MyrtleViewController's selector long-press A-Z path in Myrtle 1.4.1. A
 * similarly named standalone alpha-launcher controller is a different action
 * and must not be hooked here.
 */
static BOOL __attribute__((unused)) MRValidateSelectorAlphaStripHooks(void)
{
    if (MROriginalSelectorAlphaBuildOverlay == NULL ||
        MROriginalSelectorAlphaPointer == NULL ||
        MROriginalSelectorAlphaFinish == NULL) return NO;
    Class cls = NSClassFromString(@"MyrtleViewController");
    if (cls == Nil) return NO;
    Method buildMethod = class_getInstanceMethod(
        cls, NSSelectorFromString(@"MT_IllIlIlllIIllllIIlII:"));
    Method pointerMethod = class_getInstanceMethod(
        cls, NSSelectorFromString(@"MT_lllIIIIlIllIIIIIIlll:"));
    Method finishMethod = class_getInstanceMethod(
        cls, NSSelectorFromString(@"MT_lllIllIllIIIIlllIIII:"));
    if (buildMethod == NULL || pointerMethod == NULL || finishMethod == NULL) return NO;
    char returnType[16] = {};
    method_getReturnType(buildMethod, returnType, sizeof(returnType));
    if (returnType[0] != 'v') return NO;
    method_getReturnType(pointerMethod, returnType, sizeof(returnType));
    if (returnType[0] != 'v') return NO;
    method_getReturnType(finishMethod, returnType, sizeof(returnType));
    return returnType[0] == 'v';
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
    BOOL outsideActionGateInstalled = MRInstallMyrtleOutsideActionGateHook();
    BOOL hostPassThroughInstalled = MRInstallMyrtleHostWindowPassThroughHook();
    BOOL hostGeometryInstalled = MRInstallMyrtleHostWindowGeometryHook();
    BOOL hostGestureInstalled = MRInstallMyrtleHostGestureHook();
    BOOL hostSnapInstalled = MRInstallMyrtleSnapTransitionHook();
    BOOL standaloneAlphaLauncherInstalled = MRInstallStandaloneAlphaLauncherHooks();
    BOOL handleBoundaryInstalled = MRInstallMyrtleHandleBoundaryHooks();
    BOOL selectorCenterInstalled = MRInstallMyrtleSelectorCenterHook();
    BOOL actionDispatcherInstalled = MRInstallMyrtleActionDispatcherHook();
    if (managerInstalled && fullscreenInstalled && hostCoreLaunchInstalled &&
        keyboardAvoidanceInstalled && outsideActionGateInstalled && hostPassThroughInstalled &&
        hostGeometryInstalled && hostGestureInstalled && hostSnapInstalled &&
        standaloneAlphaLauncherInstalled && handleBoundaryInstalled &&
        selectorCenterInstalled && actionDispatcherInstalled) {
        return;
    }
    if (attempt >= 60) {
        MRLog(@"Myrtle hooks unavailable after 60 seconds manager=%d fullscreen=%d hostCoreLaunch=%d keyboard=%d outsideAction=%d hostPassThrough=%d boundary=%d selectorCenter=%d",
              managerInstalled, fullscreenInstalled, hostCoreLaunchInstalled,
              keyboardAvoidanceInstalled, outsideActionGateInstalled, hostPassThroughInstalled,
              handleBoundaryInstalled, selectorCenterInstalled);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ MRInstallMyrtleWhenReady(attempt + 1); });
}

%ctor
{
    @autoreleasepool {
        [[NSFileManager defaultManager] removeItemAtPath:
            @"/var/mobile/Library/Preferences/com.moxuan.myrtleswitcherfix.alpha-launcher.log"
                                                   error:nil];
        MRAlphaLauncherDiagnostic(@"0.5.5 beta4 diagnostic start");
        dispatch_async(dispatch_get_main_queue(), ^{
            MRInstallSwitcherRemoveHook();
            MRInstallSwitcherReconciliationHooks();
            MRInstallUserDeletionHook();
            MRInstallRootIconScrollHooks();
            MRInstallMyrtleWhenReady(0);
        });
    }
}

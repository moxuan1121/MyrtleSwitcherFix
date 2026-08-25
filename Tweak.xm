#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <substrate.h>

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

typedef id (*MRHostInitIMP)(id, SEL, id, id);
typedef struct {
    Class cls;
    MRHostInitIMP original;
} MRHostHookRecord;

static MRHostHookRecord MRHostHooks[64];
static NSUInteger MRHostHookCount = 0;

static MRHostInitIMP MROriginalForObject(id object)
{
    Class cls = object_getClass(object);
    while (cls != Nil) {
        for (NSUInteger index = 0; index < MRHostHookCount; index++) {
            if (MRHostHooks[index].cls == cls) return MRHostHooks[index].original;
        }
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static id MRHookHostInit(id self, SEL selector, id scene, id description)
{
    MRHostInitIMP original = MROriginalForObject(self);
    id result = original != NULL ? original(self, selector, scene, description) : nil;
    if (result != nil) {
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
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return NO;

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)classCount, sizeof(Class));
    classCount = objc_getClassList(classes, classCount);
    for (int classIndex = 0; classIndex < classCount && MRHostHookCount < 64; classIndex++) {
        Class cls = classes[classIndex];
        BOOL alreadyHooked = NO;
        for (NSUInteger index = 0; index < MRHostHookCount; index++) {
            if (MRHostHooks[index].cls == cls) {
                alreadyHooked = YES;
                break;
            }
        }
        if (alreadyHooked) continue;

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        BOOL definesSelector = NO;
        for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex++) {
            if (method_getName(methods[methodIndex]) == selector) {
                definesSelector = YES;
                break;
            }
        }
        free(methods);

        if (definesSelector) {
            MRHostHooks[MRHostHookCount].cls = cls;
            MSHookMessageEx(cls, selector, (IMP)MRHookHostInit,
                            (IMP *)&MRHostHooks[MRHostHookCount].original);
            MRHostHookCount++;
        }
    }
    free(classes);
    return MRHostHookCount > 0;
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

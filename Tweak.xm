#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <string.h>
#if __has_include(<ptrauth.h>)
#import <ptrauth.h>
#endif

static NSString *const MRLogPath = @"/var/mobile/Library/Logs/MyrtleSwitcherFix.log";
static os_unfair_lock MRLogLock = OS_UNFAIR_LOCK_INIT;

static void MRLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void MRLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSLog(@"[MyrtleSwitcherFix] %@", message);

    os_unfair_lock_lock(&MRLogLock);
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *directory = MRLogPath.stringByDeletingLastPathComponent;
        [fm createDirectoryAtPath:directory
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];

        if (![fm fileExistsAtPath:MRLogPath]) {
            [line writeToFile:MRLogPath
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:nil];
        } else {
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:MRLogPath];
            if (handle != nil) {
                [handle seekToEndOfFile];
                [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [handle closeFile];
            }
        }
    }
    os_unfair_lock_unlock(&MRLogLock);
}

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
        if ([value isKindOfClass:NSString.class] && [value length] != 0) {
            return value;
        }
    }
    return nil;
}

static NSString *MRBundleIdentifierForScene(id scene)
{
    NSString *bundleID = MRFirstString(scene, @[
        @"applicationBundleIdentifier", @"bundleIdentifier", @"identifier"
    ]);
    if ([bundleID containsString:@"."]) return bundleID;

    id process = MRSafeValue(scene, @"clientProcess");
    bundleID = MRFirstString(process, @[
        @"applicationBundleID", @"applicationBundleIdentifier",
        @"bundleIdentifier", @"bundleID"
    ]);
    if ([bundleID containsString:@"."]) return bundleID;

    id identity = MRSafeValue(process, @"identity");
    bundleID = MRFirstString(identity, @[
        @"embeddedApplicationIdentifier", @"applicationIdentifier",
        @"bundleIdentifier"
    ]);
    return bundleID;
}

static NSString *MRCallerImage(void *address)
{
#if __has_include(<ptrauth.h>)
    address = ptrauth_strip(address, ptrauth_key_return_address);
#endif
    Dl_info info = {0};
    if (address != NULL && dladdr(address, &info) != 0 && info.dli_fname != NULL) {
        return [NSString stringWithUTF8String:info.dli_fname];
    }
    return @"<unknown>";
}

static void MRLogMethodsForClass(Class cls)
{
    if (cls == Nil) return;

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    MRLog(@"class=%s instanceMethodCount=%u", class_getName(cls), count);
    for (unsigned int i = 0; i < count; i++) {
        SEL selector = method_getName(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);
        MRLog(@"  -[%s %s] types=%s", class_getName(cls), sel_getName(selector), types ?: "<null>");
    }
    free(methods);

    Class meta = object_getClass(cls);
    methods = class_copyMethodList(meta, &count);
    MRLog(@"class=%s classMethodCount=%u", class_getName(cls), count);
    for (unsigned int i = 0; i < count; i++) {
        SEL selector = method_getName(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);
        MRLog(@"  +[%s %s] types=%s", class_getName(cls), sel_getName(selector), types ?: "<null>");
    }
    free(methods);
}

static id (*MROriginalHostInit)(id, SEL, id, id) = NULL;

static id MRHookHostInit(id self, SEL _cmd, id scene, id description)
{
    void *caller = __builtin_return_address(0);
    id result = MROriginalHostInit != NULL
        ? MROriginalHostInit(self, _cmd, scene, description)
        : nil;

    NSString *image = MRCallerImage(caller);
    NSString *bundleID = MRBundleIdentifierForScene(scene) ?: @"<unknown>";
    MRLog(@"SceneHost init class=%@ selector=%@ caller=%@ sceneClass=%@ bundleID=%@ description=%@",
          NSStringFromClass([self class]), NSStringFromSelector(_cmd), image,
          NSStringFromClass([scene class]), bundleID, description);
    return result;
}

static BOOL MRInstallHostHook(void)
{
    NSArray<NSString *> *classNames = @[
        @"FBSceneLayerHostContainerView",
        @"FBSceneHostView"
    ];
    SEL selector = NSSelectorFromString(@"initWithScene:debugDescription:");

    for (NSString *className in classNames) {
        Class cls = NSClassFromString(className);
        Method method = cls != Nil ? class_getInstanceMethod(cls, selector) : NULL;
        if (method != NULL) {
            MSHookMessageEx(cls, selector, (IMP)MRHookHostInit, (IMP *)&MROriginalHostInit);
            MRLog(@"installed host hook on -[%@ %@]", className, NSStringFromSelector(selector));
            return YES;
        }
        MRLog(@"host candidate unavailable: -[%@ %@]", className, NSStringFromSelector(selector));
    }
    return NO;
}

static void MRInventoryRuntime(void)
{
    MRLog(@"===== runtime inventory begin =====");
    MRLog(@"system=%@ process=%@ pid=%d", UIDevice.currentDevice.systemVersion,
          NSProcessInfo.processInfo.processName, NSProcessInfo.processInfo.processIdentifier);

    NSArray<NSString *> *importantClasses = @[
        @"MyrtleHostManager", @"MyrtleHostCore", @"MyrtleHostWindowController",
        @"MyrtleHostWindow", @"FBSceneLayerHostContainerView", @"FBSceneHostView",
        @"SBAppSwitcherModel", @"SBAppLayout", @"SBDisplayLayout", @"SBDisplayItem",
        @"SBMainSwitcherViewController", @"SBFluidSwitcherViewController"
    ];
    for (NSString *name in importantClasses) {
        Class cls = NSClassFromString(name);
        MRLog(@"lookup %@ => %@", name, cls != Nil ? @"present" : @"missing");
        if (cls != Nil) MRLogMethodsForClass(cls);
    }

    int classCount = objc_getClassList(NULL, 0);
    if (classCount > 0) {
        Class *classes = (__unsafe_unretained Class *)calloc((size_t)classCount, sizeof(Class));
        classCount = objc_getClassList(classes, classCount);
        for (int i = 0; i < classCount; i++) {
            const char *name = class_getName(classes[i]);
            if (name != NULL && strncmp(name, "Myrtle", 6) == 0) {
                MRLogMethodsForClass(classes[i]);
            }
        }
        free(classes);
    }
    MRLog(@"===== runtime inventory end =====");
}

%ctor
{
    @autoreleasepool {
        if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;

        MRLog(@"diagnostic tweak loaded; no App Switcher or Myrtle state will be modified");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            MRInventoryRuntime();
            if (!MRInstallHostHook()) {
                MRLog(@"no supported Scene Host initializer was found");
            }
        });
    }
}

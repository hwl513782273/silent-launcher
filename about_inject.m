#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#include <objc/runtime.h>
#include <dispatch/dispatch.h>

///  Resources/strings.txtUTF-8 key=value 
///  clang  -mmacosx-version-min=10.15  CFString
static NSDictionary *LoadStrings(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    @try {
        NSString *path = [[[NSBundle mainBundle] resourcePath]
            stringByAppendingPathComponent:@"strings.txt"];
        NSString *raw = [NSString stringWithContentsOfFile:path
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
        if (!raw) return d;
        for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
            NSRange r = [line rangeOfString:@"="];
            if (r.location == NSNotFound) continue;
            NSString *k = [line substringToIndex:r.location];
            NSString *v = [line substringFromIndex:r.location + 1];
            v = [v stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
            d[k] = v;
        }
    } @catch (NSException *e) {}
    return d;
}

static NSString *Str(NSDictionary *d, NSString *key, NSString *fallback) {
    NSString *v = d[key];
    return (v && v.length) ? v : fallback;
}

///    AppleScript display dialog App 
static void ShowCustomAbout(void) {
    @try {
        @autoreleasepool {
            NSDictionary *S = LoadStrings();
            NSBundle *bundle = [NSBundle mainBundle];
            NSString *appName = [bundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"SilentLauncher";
            NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"21";
            NSString *copyright = [bundle objectForInfoDictionaryKey:@"NSHumanReadableCopyright"] ?: @"";

            NSString *tpl = Str(S, @"about_body", @"%@ v%@\n\n%@\nMIT License");
            NSString *body = [NSString stringWithFormat:tpl, appName, version, copyright];
            body = [body stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

            NSString *okBtn = Str(S, @"ok_button", @"OK");
            NSString *title = [Str(S, @"about_title_prefix", @"About ") stringByAppendingString:appName];
            NSString *src = [NSString stringWithFormat:
                @"display dialog \"%@\" buttons {\"%@\"} with title \"%@\" default button 1",
                body, okBtn, title];
            [[[NSAppleScript alloc] initWithSource:src] executeAndReturnError:nil];
        }
    } @catch (NSException *e) { /*  */ }
}

/// 
static void ShowFirstLaunchGuide(void) {
    @try {
        @autoreleasepool {
            // 
            NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:
                @"Library/Application Support/com.silentlauncher"];
            NSString *flag = [dir stringByAppendingPathComponent:@".firstlaunch_permissions_v21"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:flag]) return;

            NSDictionary *S = LoadStrings();
            NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"] ?: @"SilentLauncher";

            //  UTF-8 
            NSString *tpl = Str(S, @"guide_body",
                @"This app needs Accessibility and Automation permissions. "
                @"After granting Accessibility, quit and reopen the app.");
            NSString *msg = [NSString stringWithFormat:tpl, appName];
            msg = [msg stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

            NSString *okBtn = Str(S, @"ok_button", @"OK");
            NSString *title = [Str(S, @"welcome_title_prefix", @"Welcome - ") stringByAppendingString:appName];
            NSString *src = [NSString stringWithFormat:
                @"display dialog \"%@\" buttons {\"%@\"} with title \"%@\" default button 1",
                msg, okBtn, title];
            @try { [[[NSAppleScript alloc] initWithSource:src] executeAndReturnError:nil]; }
            @catch (NSException *e) {}

            // macOS 
            @try {
                if (&AXIsProcessTrustedWithOptions != NULL) {
                    CFDictionaryRef opts = (__bridge CFDictionaryRef)@{
                        (__bridge id)kAXTrustedCheckOptionPrompt: @YES
                    };
                    AXIsProcessTrustedWithOptions(opts);
                }
            } @catch (NSException *e) {}

            //  System Events 
            @try {
                NSString *ae = @"tell application \"System Events\" to get name of first process";
                [[[NSAppleScript alloc] initWithSource:ae] executeAndReturnError:nil];
            } @catch (NSException *e) {}

            //  try
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
            [@"done" writeToFile:flag atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    } @catch (NSException *e) { /*  */ }
}

/// +
static void InsertAboutItem(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        NSMenu *mainMenu = [app mainMenu];
        if (!mainMenu || [mainMenu numberOfItems] == 0) return;

        NSMenuItem *appItem = [mainMenu itemAtIndex:0];
        NSMenu *appMenu = [appItem submenu];
        if (!appMenu) return;

        NSDictionary *S = LoadStrings();
        NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
        if (!appName || [appName length] == 0) appName = @"SilentLauncher";
        NSString *aboutTitle = [Str(S, @"about_title_prefix", @"About ") stringByAppendingString:appName];
        NSString *quitTitle  = [Str(S, @"quit_title_prefix", @"Quit ") stringByAppendingString:appName];

        // /
        BOOL hasAbout = NO, hasQuit = NO;
        for (NSMenuItem *it in appMenu.itemArray) {
            if (it.action == @selector(showCustomAbout)) hasAbout = YES;
            if (it.action == @selector(terminate:)) hasQuit = YES;
        }
        if (!hasAbout) {
            NSMenuItem *about = [[NSMenuItem alloc]
                initWithTitle:aboutTitle
                       action:@selector(showCustomAbout)
                keyEquivalent:@""];
            [about setTarget:app];
            [appMenu insertItem:about atIndex:0];
            [appMenu insertItem:[NSMenuItem separatorItem] atIndex:1];
        }
        if (!hasQuit) {
            NSMenuItem *quit = [[NSMenuItem alloc]
                initWithTitle:quitTitle
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
            [quit setTarget:app];
            [appMenu addItem:quit];
        }
    }
}

/// Global: new display name (set as early as possible)
static NSString *g_newName = nil;

/// Fix window title bar (old name hardcoded in original binary setTitle:)
static void FixWindowTitles(void) {
    @try {
        NSString *name = g_newName;
        if (!name) name = @"SilentLauncher";
        for (NSWindow *w in [NSApplication sharedApplication].windows) {
            if ([w.title containsString:@"\xe5\xbc\x80\xe6\x9c\xba"] ||
                [w.title containsString:@"\xe9\x9d\x99\xe9\xbb\x98"]) {
                w.title = name;
            }
        }
    } @catch (NSException *e) {}
}

/// Recursively replace old name in ALL text-holding views (backup for text set before swizzle)
static void FixAllTextInView(NSView *view, NSString *newName) {
    if (!view || ![view isKindOfClass:[NSView class]]) return;
    @try {
        // NSTextField / NSLabel stringValue
        if ([view respondsToSelector:@selector(stringValue)]) {
            NSString *txt = [(id)view stringValue];
            if (txt && ([txt containsString:@"\xe5\xbc\x80\xe6\x9c\xba"] ||
                       [txt containsString:@"\xe9\x9d\x99\xe9\xbb\x98"])) {
                [(id)view setStringValue:newName];
            }
        }
    } @catch (NSException *e) {}
    // Recurse subviews
    for (NSView *sub in [view subviews]) {
        FixAllTextInView(sub, newName);
    }
}

/// Intercept setStringValue: on NSTextField — replaces old name at call time
static void InstallSwizzles(void) {
    // --- Hook NSTextField.setStringValue: ---
    Method m1 = class_getInstanceMethod([NSTextField class], @selector(setStringValue:));
    if (m1) {
        IMP origImp = method_getImplementation(m1);
        IMP newImp = imp_implementationWithBlock(^(id self, NSString *value) {
            if (value && g_newName &&
                ([value containsString:@"\xe5\xbc\x80\xe6\x9c\xba"] ||
                 [value containsString:@"\xe9\x9d\x99\xe9\xbb\x98"])) {
                value = g_newName;
            }
            ((void(*)(id, SEL, NSString *))origImp)(self, @selector(setStringValue:), value);
        });
        method_setImplementation(m1, newImp);
    }

    // --- Hook NSTextField.setAttributedStringValue: ---
    Method m2 = class_getInstanceMethod([NSTextField class], @selector(setAttributedStringValue:));
    if (m2) {
        IMP origImp2 = method_getImplementation(m2);
        IMP newImp2 = imp_implementationWithBlock(^(id self, NSAttributedString *value) {
            if (value && g_newName) {
                NSString *str = [value string];
                if (str && ([str containsString:@"\xe5\xbc\x80\xe6\x9c\xba"] ||
                          [str containsString:@"\xe9\x9d\x99\xe9\xbb\x98"])) {
                    value = [[NSAttributedString alloc] initWithString:g_newName];
                }
            }
            ((void(*)(id, SEL, NSAttributedString *))origImp2)(self, @selector(setAttributedStringValue:), value);
        });
        method_setImplementation(m2, newImp2);
    }
}

__attribute__((constructor))
static void on_load(void) {
    // Cache new name ASAP (before any UI code runs)
    g_newName = [NSBundle mainBundle].infoDictionary[@"CFBundleName"];
    if (!g_newName || g_newName.length == 0) g_newName = @"SilentLauncher";
    [g_newName retain];

    // Install swizzles BEFORE nib loading (intercepts setStringValue: / setAttributedStringValue:)
    InstallSwizzles();

    // showCustomAbout  NSApplication
    IMP imp = imp_implementationWithBlock(^{ ShowCustomAbout(); });
    class_addMethod([NSApplication class], @selector(showCustomAbout), imp, "v@:");

    // App  +
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidFinishLaunchingNotification
                    object:nil queue:nil
                usingBlock:^(NSNotification *note){
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ShowFirstLaunchGuide();
                        InsertAboutItem();

                        // Backup: fix window titles (catches setTitle: before our swizzle)
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                            dispatch_get_main_queue(), ^{
                                FixWindowTitles();
                                // Deep scan: fix any text fields already set with old name
                                NSString *name = g_newName ?: @"SilentLauncher";
                                for (NSWindow *w in [NSApplication sharedApplication].windows) {
                                    FixAllTextInView(w.contentView, name);
                                }
                            });
                    });
                }];
}

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
            NSString *appName = [bundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"KaiJi JingMo";
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
            NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"] ?: @"KaiJi JingMo";

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
        if (!appName || [appName length] == 0) appName = @"KaiJi JingMo";
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

__attribute__((constructor))
static void on_load(void) {
    //  showCustomAbout  NSApplication
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
                    });
                }];
}

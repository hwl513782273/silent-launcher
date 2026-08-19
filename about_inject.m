#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#include <objc/runtime.h>
#include <dispatch/dispatch.h>

///  Resources/strings.txtUTF-8 key=value 
///  clang  -mmacosx-version-min=10.15  CFString

/// 诊断日志：写到 ~/Library/Logs/静默启动管理器-inject.log（追加）。
static void FileLog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *home = NSHomeDirectory();
    if (!home) { NSLog(@"%@", msg); return; }
    NSString *dir = [home stringByAppendingPathComponent:@"Library/Logs"];
    NSString *path = [dir stringByAppendingPathComponent:@"静默启动管理器-inject.log"];
    NSString *line = [NSString stringWithFormat:@"%@ [pid %d] %@\n", [NSDate date], getpid(), msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createFileAtPath:path contents:data attributes:nil];
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForUpdatingAtPath:path];
        if (fh) {
            @try { [fh seekToEndOfFile]; [fh writeData:data]; } @catch (NSException *e) {}
            [fh closeFile];
        }
    }
}

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

///    AppleScript display dialog — 唯一关于对话框（覆盖原版）
static void ShowCustomAbout(void) {
    @try {
        @autoreleasepool {
            NSBundle *bundle = [NSBundle mainBundle];
            NSString *appName = [bundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"SilentLauncher";
            NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"21";

            // 手工构建干净的关于内容（不依赖模板中的 %@ 防止展开异常）
            NSString *body = [NSString stringWithFormat:
                @"%@\n版本：%@\n\n"
                @"登录时自动隐藏指定应用窗口。\n"
                @"拖入即用，无需配置。\n\n"
                @"Copyright © 2026 banqiu.\n"
                @"Released under the MIT License.",
                appName, version];
            body = [body stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

            NSString *src = [NSString stringWithFormat:
                @"display dialog \"%@\" buttons {\"确定\"} with title \"关于 %@\" default button 1 "
                @"with icon note giving up after 120",
                body, appName];
            [[[NSAppleScript alloc] initWithSource:src] executeAndReturnError:nil];
        }
    } @catch (NSException *e) { /*  */ }
}

/// 
static void ShowFirstLaunchGuide(void) {
    // V25 起后台线程执行：AppleScript display dialog / AX 弹窗不阻塞主线程（避免彩虹球）
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
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
                @"本应用需要以下授权才能正常工作：\n\n"
                @"1. 辅助功能（必须）：用于自动隐藏指定 App 的窗口。点“确定”后系统会弹出授权窗口，请勾选「%@」并点“好”。\n"
                @"2. 自动化（必须）：用于向目标 App 发送指令关闭窗口。首次隐藏时系统会逐个弹窗，请全部点“允许”。\n"
                @"3. 登录项：开机自启无需密码，可在「系统设置 ▸ 通用 ▸ 登录项」中管理。\n\n"
                @"⚠️ 辅助功能授权后请【退出并重新打开本应用】才会生效。");
            NSString *msg = [NSString stringWithFormat:tpl, appName];
            msg = [msg stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

            NSString *src = [NSString stringWithFormat:
                @"display dialog \"%@\" buttons {\"确定\"} with title \"欢迎使用 %@\" default button 1",
                msg, appName];
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
    });
}

/// +
static void InsertAboutItem(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];

        NSDictionary *S = LoadStrings();
        NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
        if (!appName || [appName length] == 0) appName = @"SilentLauncher";
        NSString *aboutTitle = [@"关于 " stringByAppendingString:appName];
        NSString *quitTitle  = [@"退出 " stringByAppendingString:appName];

        __block NSMenuItem *aboutItem = nil;
        __block NSMenuItem *quitItem = nil;
        void (^makeItems)(void) = ^{
            if (!aboutItem) {
                aboutItem = [[NSMenuItem alloc] initWithTitle:aboutTitle action:@selector(showCustomAbout) keyEquivalent:@""];
                [aboutItem setTarget:app];
            }
            if (!quitItem) {
                quitItem = [[NSMenuItem alloc] initWithTitle:quitTitle action:@selector(terminate:) keyEquivalent:@"q"];
                [quitItem setTarget:app];
            }
        };

        // SwiftUI 应用的主菜单在启动完成后异步构建，Intel/10.15 慢速机器上更晚；
        // 轮询等待菜单就绪（最多 15 秒），就绪即插入「关于/退出」。
        for (int i = 0; i < 30; i++) {
            NSMenu *mainMenu = [app mainMenu];
            NSMenu *appMenu = nil;
            if (mainMenu) {
                NSInteger n = [mainMenu numberOfItems];
                // 找第一个带 submenu 的菜单项（通常是 App 菜单）
                for (NSInteger j = 0; j < n; j++) {
                    NSMenuItem *it = [mainMenu itemAtIndex:j];
                    if ([it submenu]) { appMenu = [it submenu]; break; }
                }
            }
            if (!mainMenu) { FileLog(@"InsertAboutItem: mainMenu 为 nil (i=%d)", i); }
            if (appMenu) {
                BOOL hasAbout = NO, hasQuit = NO;
                for (NSMenuItem *it in appMenu.itemArray) {
                    if (it.action == @selector(showCustomAbout)) hasAbout = YES;
                    if (it.action == @selector(terminate:)) hasQuit = YES;
                }
                if (!hasAbout || !hasQuit) {
                    makeItems();
                    if (!hasAbout) {
                        [appMenu insertItem:aboutItem atIndex:0];
                        [appMenu insertItem:[NSMenuItem separatorItem] atIndex:1];
                    }
                    if (!hasQuit) [appMenu addItem:quitItem];
                }
                FileLog(@"InsertAboutItem: 已插入 about/quit (appMenu=「%@」 items=%ld)", appMenu.title, (long)[appMenu numberOfItems]);
                return; // 插入成功
            }
            if (i < 29) usleep(500000);
        }

        // 兜底：始终无主菜单 → 创建全新主菜单（含关于/退出），确保关于一定存在
        makeItems();
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
        NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:appName action:nil keyEquivalent:@""];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
        [appMenu addItem:aboutItem];
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItem:quitItem];
        [appItem setSubmenu:appMenu];
        [menu addItem:appItem];
        [app setMainMenu:menu];
    }
}

/// 安装新版后迁移旧版配置：把旧名文件夹（开机静默启动器）里用户真实的
/// settings.json / config.json 继承到新名文件夹（静默启动管理器），
/// 随后把旧文件夹改名为 .old（保留可恢复，且不再被 App 读取）。
/// 这样改名后不会出现「读空配置 → 全天静默 / 不按时间段」的问题。
/// 幂等：迁移完成后旧文件夹已改名，再次启动 oldDir 不存在 → 直接返回。
static void MigrateOldConfig(void) {
    @try {
        @autoreleasepool {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *support = [NSSearchPathForDirectoriesInDomains(
                NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
            if (!support) return;

            NSString *oldDir = [support stringByAppendingPathComponent:@"开机静默启动器"];
            NSString *newDir = [support stringByAppendingPathComponent:@"静默启动管理器"];

            // 旧版文件夹不存在 → 无需迁移（全新安装，使用 App 默认配置）
            if (![fm fileExistsAtPath:oldDir]) return;

            // 确保新文件夹存在
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:newDir isDirectory:&isDir] || !isDir) {
                [fm createDirectoryAtPath:newDir withIntermediateDirectories:YES attributes:nil error:nil];
            }

            // 继承关键配置（覆盖新文件夹里可能错误的默认配置）
            for (NSString *f in @[@"settings.json", @"config.json"]) {
                NSString *src = [oldDir stringByAppendingPathComponent:f];
                NSString *dst = [newDir stringByAppendingPathComponent:f];
                if ([fm fileExistsAtPath:src]) {
                    [fm removeItemAtPath:dst error:nil];
                    [fm copyItemAtPath:src toPath:dst error:nil];
                }
            }

            // 标记迁移完成（便于自检 / 防重入）
            NSString *marker = [newDir stringByAppendingPathComponent:@".migrated_v21"];
            [@"done" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];

            // 清除旧文件夹（改名保留，可恢复；App 只识别新名，故不再被读取）
            NSString *oldArchived = [oldDir stringByAppendingString:@".old"];
            int i = 1;
            while ([fm fileExistsAtPath:oldArchived]) {
                oldArchived = [NSString stringWithFormat:@"%@.old.%d", oldDir, i];
                i++;
            }
            [fm moveItemAtPath:oldDir toPath:oldArchived error:nil];
        }
    } @catch (NSException *e) { /* 迁移失败不影响主功能 */ }
}

__attribute__((constructor))
static void on_load(void) {
    FileLog(@"=== dylib loaded (V30) ===");
    // 0) 安装新版后先迁移旧版配置（必须在 App 读取配置之前完成）
    MigrateOldConfig();

    // showCustomAbout  NSApplication
    IMP imp = imp_implementationWithBlock(^{ ShowCustomAbout(); });
    class_addMethod([NSApplication class], @selector(showCustomAbout), imp, "v@:");

    // App  + 
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidFinishLaunchingNotification
                    object:nil queue:nil
                usingBlock:^(NSNotification *note){
                    FileLog(@"=== NSApplicationDidFinishLaunching 收到 ===");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ShowFirstLaunchGuide();
                        InsertAboutItem();
                    });
                }];
}

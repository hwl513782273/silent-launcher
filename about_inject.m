#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#include <objc/runtime.h>
#include <dispatch/dispatch.h>

///  Resources/strings.txtUTF-8 key=value 
///  clang  -mmacosx-version-min=10.15  CFString

/// 日志串行队列：FileLog 可能被主线程（InsertAboutItem）与后台线程
/// （ShowFirstLaunchGuide）同时调用，串行化避免日志行交错/损坏。
static dispatch_queue_t LogQueue(void) {
    static dispatch_once_t once;
    static dispatch_queue_t q;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.silentlauncher.injectlog", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

/// 诊断日志：写到 ~/Library/Logs/静默启动管理器-inject.log（追加，串行队列异步写）。
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
    dispatch_async(LogQueue(), ^{
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
    });
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
            NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0";

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
/// 尝试把「关于/退出」插入现有主菜单；返回 YES 表示成功（幂等）。
/// 插入逻辑 = V30 验证有效的方式（找第一个带 submenu 的菜单项插入）。
/// V42 起每次调用都记录结果（成功/失败原因），用于诊断 macOS 12 菜单构建时序。
static BOOL TryInsertAbout(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
        if (!appName || [appName length] == 0) appName = @"SilentLauncher";
        NSString *aboutTitle = [@"关于 " stringByAppendingString:appName];
        NSString *quitTitle  = [@"退出 " stringByAppendingString:appName];

        NSMenu *mainMenu = [app mainMenu];
        if (!mainMenu) { FileLog(@"TryInsertAbout: FAIL mainMenu=nil"); return NO; }
        NSMenu *appMenu = nil;
        NSInteger n = [mainMenu numberOfItems];
        for (NSInteger j = 0; j < n; j++) {
            NSMenuItem *it = [mainMenu itemAtIndex:j];
            if ([it submenu]) { appMenu = [it submenu]; break; }
        }
        if (!appMenu) { FileLog(@"TryInsertAbout: FAIL 无 submenu (mainMenu items=%ld)", (long)n); return NO; }

        BOOL hasAbout = NO, hasQuit = NO;
        for (NSMenuItem *it in appMenu.itemArray) {
            if (it.action == @selector(showCustomAbout)) hasAbout = YES;
            if (it.action == @selector(terminate:)) hasQuit = YES;
        }
        if (hasAbout && hasQuit) {
            FileLog(@"TryInsertAbout: OK 已存在 (appMenu=「%@」 items=%ld)", appMenu.title, (long)[appMenu numberOfItems]);
            return YES;
        }
        NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:aboutTitle action:@selector(showCustomAbout) keyEquivalent:@""];
        [aboutItem setTarget:app];
        NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:quitTitle action:@selector(terminate:) keyEquivalent:@"q"];
        [quitItem setTarget:app];
        // 必须显式 Command 修饰键：默认 mask=0 会导致普通按键 "q" 直接触发退出
        [quitItem setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
        if (!hasAbout) {
            [appMenu insertItem:aboutItem atIndex:0];
            [appMenu insertItem:[NSMenuItem separatorItem] atIndex:1];
        }
        if (!hasQuit) [appMenu addItem:quitItem];
        FileLog(@"TryInsertAbout: INSERTED about/quit (appMenu=「%@」 items=%ld)", appMenu.title, (long)[appMenu numberOfItems]);
        return YES;
    }
}

/// V43 兜底：所有退避尝试都失败后，强制创建主菜单（含「关于/退出」）。
/// 基于 V34/V38 实测 macOS 12 上 SwiftUI 走我们未 hook 的 API 设菜单（hook 完全无效），
/// 唯一可靠路径就是 `[app setMainMenu:menu]` 强制建。V38 用户实测菜单稳定显示。
/// 主线程微秒级操作，不阻塞 → 不卡彩虹球。
static BOOL g_inserted = NO;
static void BuildFallbackMainMenu(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
        if (!appName || [appName length] == 0) appName = @"SilentLauncher";
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
        NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:appName action:nil keyEquivalent:@""];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
        NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:[@"关于 " stringByAppendingString:appName]
                                                           action:@selector(showCustomAbout)
                                                    keyEquivalent:@""];
        [aboutItem setTarget:app];
        NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:[@"退出 " stringByAppendingString:appName]
                                                          action:@selector(terminate:)
                                                   keyEquivalent:@"q"];
        [quitItem setTarget:app];
        [quitItem setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
        [appMenu addItem:aboutItem];
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItem:quitItem];
        [appItem setSubmenu:appMenu];
        [menu addItem:appItem];
        [app setMainMenu:menu];
        FileLog(@"BuildFallbackMainMenu: 已强制创建主菜单（含 about/quit）");
    }
}

/// V43 诊断：每 2 秒打印一次主菜单结构，持续约 60 秒（还原 macOS 12 时序）
static void DiagnoseMenuStructure(int seq) {
    if (seq >= 30) return; // 30 × 2s = 60s
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (g_inserted) { DiagnoseMenuStructure(seq + 1); return; }
        NSApplication *app = [NSApplication sharedApplication];
        NSMenu *mainMenu = [app mainMenu];
        if (!mainMenu) {
            FileLog(@"DIAG[%d]: mainMenu=nil", seq);
        } else {
            NSMutableString *sb = [NSMutableString stringWithFormat:@"DIAG[%d]: mainMenu items=%ld:", seq, (long)[mainMenu numberOfItems]];
            for (NSInteger j = 0; j < [mainMenu numberOfItems]; j++) {
                NSMenuItem *it = [mainMenu itemAtIndex:j];
                NSMenu *sub = [it submenu];
                [sb appendFormat:@" [%@ sub=%@ items=%ld]", it.title ?: @"(nil)", sub ? @"Y" : @"N", sub ? (long)[sub numberOfItems] : -1];
            }
            FileLog(@"%@", sb);
        }
        DiagnoseMenuStructure(seq + 1);
    });
}

/// V43：退避重插 + 兜底建主菜单。
/// 退避序列 1/2/3/4/5/6/8/10 = 39 秒（macOS 12 实测 mainMenu 约 16 秒才非 nil，覆盖常见情况）。
/// 全部失败 → BuildFallbackMainMenu 强制建主菜单（V38 实测可靠路径）。
/// 全程主线程微秒级操作，无 usleep → 不卡彩虹球。
static void ScheduleInsertAttempt(int step) {
    static const double delays[] = {1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0};
    int total = sizeof(delays) / sizeof(delays[0]);
    if (g_inserted) return;
    if (step >= total) {
        FileLog(@"ScheduleInsertAttempt: 全部尝试失败（macOS 12 上 SwiftUI 走我们未 hook 的路径）");
        BuildFallbackMainMenu();
        g_inserted = YES;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[step] * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (g_inserted) return;
        if (TryInsertAbout()) {
            g_inserted = YES;
            FileLog(@"ScheduleInsertAttempt: step %d 命中插入", step);
            return;
        }
        ScheduleInsertAttempt(step + 1);
    });
}

/// V43：菜单插入 = 立即试一次 + hook 自动补回（本机有效）+ 退避重插（40s 窗口）+ 兜底建主菜单。
/// 全程主线程微秒级操作（除 setMainMenu 一次性调用），无 usleep → 不卡彩虹球。
static void InsertAboutItem(void) {
    g_inserted = NO;
    if (TryInsertAbout()) { g_inserted = YES; return; }
    ScheduleInsertAttempt(0);
    DiagnoseMenuStructure(0);
}

/// V38-beta（实验）方案 A：hook NSMenu 修改方法，SwiftUI 每次重建菜单后自动补回
/// 「关于/退出」。核心思路：不猜 SwiftUI 的重建时机，而是监听其每次 add/insert/
/// remove 动作，若应用菜单缺项则立即幂等补回 → 菜单永远存在且主线程零阻塞。
/// 与 V34 的「1 秒先插 + 阻塞兜底」叠加为三层保险。

static BOOL g_reinserting = NO;

/// 确保指定菜单包含「关于/退出」（幂等；防递归通过 g_reinserting 标志）
static void EnsureAboutQuitInMenu(NSMenu *appMenu) {
    if (g_reinserting) return;
    g_reinserting = YES;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
        if (!appName || [appName length] == 0) appName = @"SilentLauncher";
        NSString *aboutTitle = [@"关于 " stringByAppendingString:appName];
        NSString *quitTitle  = [@"退出 " stringByAppendingString:appName];

        BOOL hasAbout = NO, hasQuit = NO;
        for (NSMenuItem *it in appMenu.itemArray) {
            if (it.action == @selector(showCustomAbout)) hasAbout = YES;
            if (it.action == @selector(terminate:)) hasQuit = YES;
        }
        if (!hasAbout || !hasQuit) {
            NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:aboutTitle action:@selector(showCustomAbout) keyEquivalent:@""];
            [aboutItem setTarget:app];
            NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:quitTitle action:@selector(terminate:) keyEquivalent:@"q"];
            [quitItem setTarget:app];
            [quitItem setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
            if (!hasAbout) {
                [appMenu insertItem:aboutItem atIndex:0];
                [appMenu insertItem:[NSMenuItem separatorItem] atIndex:1];
            }
            if (!hasQuit) [appMenu addItem:quitItem];
            FileLog(@"EnsureAboutQuit: 自动补回 about/quit (items=%ld)", (long)[appMenu numberOfItems]);
        }
    }
    g_reinserting = NO;
}

/// V40：任意 NSMenu 被修改后回调。
/// macOS 15（就地更新）：被改的 menu == 当前 mainMenu 的 submenu → 直接补回。
/// macOS 12（SwiftUI 构建全新菜单树再 setMainMenu 整体替换）：被改的 menu 是
/// 新树中的菜单（还不是 mainMenu）——用「标题 == appName」识别它并补回，
/// 配合 setMainMenu: hook（下方）在整树替换后再次兜底。
static void MenuDidMutate(NSMenu *menu) {
    if (g_reinserting) return; // 我们自己补回时不再触发
    NSApplication *app = [NSApplication sharedApplication];
    NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
    if (!appName || [appName length] == 0) appName = @"SilentLauncher";

    // 1) 被修改的菜单自身就是应用菜单（标题 == appName）→ 补回
    if ([menu.title isEqualToString:appName]) {
        FileLog(@"HOOK: mutate 「%@」 items=%ld → 补回", menu.title, (long)[menu numberOfItems]);
        EnsureAboutQuitInMenu(menu);
        return;
    }
    // 2) 被修改的是当前 mainMenu 或其第一个 submenu → 定位应用菜单补回
    NSMenu *mainMenu = [app mainMenu];
    if (!mainMenu) return;
    if (menu == mainMenu) {
        FileLog(@"HOOK: mutate mainMenu items=%ld → 定位补回", (long)[mainMenu numberOfItems]);
        for (NSMenuItem *it in mainMenu.itemArray) {
            if ([it submenu]) { EnsureAboutQuitInMenu([it submenu]); return; }
        }
        return;
    }
    for (NSMenuItem *it in mainMenu.itemArray) {
        if ([it submenu] == menu) { EnsureAboutQuitInMenu(menu); return; }
    }
}

// 保存原实现
static void (*orig_menu_addItem)(id, SEL, id);
static void (*orig_menu_insertItem)(id, SEL, id, NSInteger);
static void (*orig_menu_removeItemAtIndex)(id, SEL, NSInteger);
static void (*orig_menu_removeAllItems)(id, SEL);
static void (*orig_menu_setSubmenu)(id, SEL, NSMenu *, NSMenuItem *);
static void (*orig_app_setMainMenu)(id, SEL, NSMenu *);

static void my_menu_addItem(id self, SEL _cmd, id item) {
    orig_menu_addItem(self, _cmd, item);
    MenuDidMutate(self);
}
static void my_menu_insertItem(id self, SEL _cmd, id item, NSInteger index) {
    orig_menu_insertItem(self, _cmd, item, index);
    MenuDidMutate(self);
}
static void my_menu_removeItemAtIndex(id self, SEL _cmd, NSInteger index) {
    orig_menu_removeItemAtIndex(self, _cmd, index);
    MenuDidMutate(self);
}
static void my_menu_removeAllItems(id self, SEL _cmd) {
    orig_menu_removeAllItems(self, _cmd);
    MenuDidMutate(self);
}
static void my_menu_setSubmenu(id self, SEL _cmd, NSMenu *submenu, NSMenuItem *item) {
    orig_menu_setSubmenu(self, _cmd, submenu, item);
    MenuDidMutate(self);
}

/// V40：hook NSApplication.setMainMenu:——macOS 12 的 SwiftUI 会整体替换主菜单树，
/// 替换后对新树立即补回（延迟一个 runloop，确保树已填完）。
static void my_app_setMainMenu(id self, SEL _cmd, NSMenu *menu) {
    orig_app_setMainMenu(self, _cmd, menu);
    if (menu) {
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSMenuItem *it in menu.itemArray) {
                if ([it submenu]) { EnsureAboutQuitInMenu([it submenu]); return; }
            }
        });
    }
}

/// swizzle NSMenu 修改方法 + NSApplication.setMainMenu:；失败静默（不影响主功能）
static void SwizzleMenuMethods(void) {
    Class cls = [NSMenu class];
    Method m;
#define SWZ(SELNAME, VAR, FUNC) \
    m = class_getInstanceMethod(cls, @selector(SELNAME)); \
    if (m) { VAR = (void *)method_getImplementation(m); \
             class_replaceMethod(cls, @selector(SELNAME), (IMP)FUNC, method_getTypeEncoding(m)); }
    SWZ(addItem:, orig_menu_addItem, my_menu_addItem)
    SWZ(insertItem:atIndex:, orig_menu_insertItem, my_menu_insertItem)
    SWZ(removeItemAtIndex:, orig_menu_removeItemAtIndex, my_menu_removeItemAtIndex)
    SWZ(removeAllItems, orig_menu_removeAllItems, my_menu_removeAllItems)
    SWZ(setSubmenu:forItem:, orig_menu_setSubmenu, my_menu_setSubmenu)
#undef SWZ
    // NSApplication.setMainMenu:（self 是 NSApplication）
    Class appCls = [NSApplication class];
    m = class_getInstanceMethod(appCls, @selector(setMainMenu:));
    if (m) {
        orig_app_setMainMenu = (void *)method_getImplementation(m);
        class_replaceMethod(appCls, @selector(setMainMenu:), (IMP)my_app_setMainMenu, method_getTypeEncoding(m));
    }
    FileLog(@"SwizzleMenuMethods: NSMenu+setMainMenu 已 hook (2.0)");
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
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    FileLog(@"=== dylib loaded (v%@) ===", ver ?: @"?");
    // 0) 安装新版后先迁移旧版配置（必须在 App 读取配置之前完成）
    MigrateOldConfig();

    // showCustomAbout  NSApplication
    IMP imp = imp_implementationWithBlock(^{ ShowCustomAbout(); });
    class_addMethod([NSApplication class], @selector(showCustomAbout), imp, "v@:");

    // V38-beta：hook NSMenu 修改方法，SwiftUI 重建菜单后自动补回关于/退出
    SwizzleMenuMethods();

    // App  + 
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidFinishLaunchingNotification
                    object:nil queue:nil
                usingBlock:^(NSNotification *note){
                    (void)note;
                    FileLog(@"=== NSApplicationDidFinishLaunching 收到 ===");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ShowFirstLaunchGuide();
                        InsertAboutItem();
                    });
                }];
}

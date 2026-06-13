#import "IOSMCPRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import "../IOSMCPPreferences.h"

@interface IOSMCPRootListController ()

@property (nonatomic, assign) BOOL serverRunning;
@property (nonatomic, assign) BOOL viewVisible;
@property (nonatomic, assign) NSUInteger serverStatusCheckGeneration;
@property (nonatomic, strong) NSURLSession *serverStatusSession;
@property (nonatomic, strong) NSURLSessionDataTask *serverStatusTask;
@property (nonatomic, strong) PSSpecifier *addressGroupSpecifier;
@property (nonatomic, strong) PSSpecifier *lanAddressSpecifier;
@property (nonatomic, strong) PSSpecifier *localAddressSpecifier;

@end

@implementation IOSMCPRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        self.addressGroupSpecifier = [self specifierForID:@"mcpAddressGroup"];
        self.lanAddressSpecifier = [self specifierForID:@"lanAddressButton"];
        self.localAddressSpecifier = [self specifierForID:@"localAddressButton"];
        [self updateAddressTitles];
    }

    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillEnterForeground:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.viewVisible = YES;
    [self scheduleServerStatusRefreshAfterDelay:0.8];
}

- (NSString *)localMCPURLString {
    return [NSString stringWithFormat:@"http://localhost:%d/mcp", IOS_MCP_DEFAULT_PORT];
}

- (void)copyLANAddress:(PSSpecifier *)specifier {
    NSString *url = IOSMCPServiceURLString();
    [UIPasteboard generalPasteboard].string = url;
}

- (void)copyLocalAddress:(PSSpecifier *)specifier {
    NSString *url = [self localMCPURLString];
    [UIPasteboard generalPasteboard].string = url;
}

- (void)copyPrompt:(PSSpecifier *)specifier {
    [UIPasteboard generalPasteboard].string = [self codexPrompt];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.viewVisible = NO;
    [self cancelServerStatusRefresh];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    self.viewVisible = NO;
    [self cancelServerStatusRefresh];
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
    if (!self.isViewLoaded || !self.view.window) {
        return;
    }

    self.viewVisible = YES;
    [self scheduleServerStatusRefreshAfterDelay:0.8];
}

- (void)toggleServer:(PSSpecifier *)specifier {
    BOOL shouldStart = !self.serverRunning;
    [self updateEnabledPreference:shouldStart];
    [self postNotification:shouldStart ? IOS_MCP_DARWIN_NOTIFICATION_START : IOS_MCP_DARWIN_NOTIFICATION_STOP];
    [self updateControlStatusText:shouldStart ? @"当前状态：正在启动..." : @"当前状态：正在关闭..."
                      buttonTitle:shouldStart ? @"正在启动..." : @"正在关闭..."
                    buttonEnabled:NO];
    [self updateAddressSpecifiersVisible:NO];

    [self scheduleServerStatusRefreshAfterDelay:0.8];
}

- (void)scheduleServerStatusRefreshAfterDelay:(NSTimeInterval)delay {
    [self cancelServerStatusRefresh];
    NSUInteger generation = ++self.serverStatusCheckGeneration;

    [self updateControlStatusText:@"当前状态：正在获取..."
                      buttonTitle:@"正在获取..."
                    buttonEnabled:NO];
    [self updateAddressSpecifiersVisible:NO];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.viewVisible || generation != self.serverStatusCheckGeneration) {
            return;
        }

        [self refreshServerStatusWithGeneration:generation];
    });
}

- (void)cancelServerStatusRefresh {
    self.serverStatusCheckGeneration++;
    [self.serverStatusTask cancel];
    [self.serverStatusSession invalidateAndCancel];
    self.serverStatusTask = nil;
    self.serverStatusSession = nil;
}

- (void)refreshServerStatusWithGeneration:(NSUInteger)generation {
    if (!self.viewVisible || generation != self.serverStatusCheckGeneration) {
        return;
    }

    [self updateControlStatusText:@"当前状态：检测中..."
                      buttonTitle:@"检测中..."
                    buttonEnabled:NO];

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/health", IOS_MCP_DEFAULT_PORT]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 1.0;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 1.0;
    configuration.timeoutIntervalForResource = 1.0;

    __weak typeof(self) weakSelf = self;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    self.serverStatusSession = session;
    self.serverStatusTask = [session dataTaskWithRequest:request
                                       completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            [session finishTasksAndInvalidate];
            return;
        }

        BOOL running = [self isHealthyServerResponseData:data response:response error:error];
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL isCurrentRequest = (session == self.serverStatusSession);
            if (!self.viewVisible || generation != self.serverStatusCheckGeneration) {
                if (isCurrentRequest) {
                    self.serverStatusTask = nil;
                    self.serverStatusSession = nil;
                }
                [session finishTasksAndInvalidate];
                return;
            }

            self.serverRunning = running;
            if (isCurrentRequest) {
                self.serverStatusTask = nil;
                self.serverStatusSession = nil;
            }
            [self updateControlStatusText:running ? @"当前状态：运行中" : @"当前状态：未运行"
                              buttonTitle:running ? @"关闭 iOS MCP" : @"启动 iOS MCP"
                            buttonEnabled:YES];
            [self updateAddressSpecifiersVisible:running];
            [session finishTasksAndInvalidate];
        });
    }];
    [self.serverStatusTask resume];
}

- (BOOL)isHealthyServerResponseData:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error {
    if (error || !data) {
        return NO;
    }

    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    if (httpResponse.statusCode != 200) {
        return NO;
    }

    NSError *jsonError = nil;
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError) {
        return NO;
    }

    if (![payload isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    NSString *status = [payload[@"status"] isKindOfClass:[NSString class]] ? payload[@"status"] : nil;
    NSString *server = [payload[@"server"] isKindOfClass:[NSString class]] ? payload[@"server"] : nil;
    return [status isEqualToString:@"ok"] && [server isEqualToString:@"com.susu.mcp"];
}

- (void)updateControlStatusText:(NSString *)statusText buttonTitle:(NSString *)buttonTitle buttonEnabled:(BOOL)buttonEnabled {
    PSSpecifier *groupSpecifier = [self specifierForID:@"serviceControlGroup"];
    PSSpecifier *toggleSpecifier = [self specifierForID:@"toggleServerButton"];

    if (groupSpecifier) {
        [groupSpecifier setProperty:statusText forKey:PSFooterTextGroupKey];
        [self reloadSpecifier:groupSpecifier animated:NO];
    }

    if (toggleSpecifier) {
        toggleSpecifier.name = buttonTitle;
        [toggleSpecifier setProperty:buttonTitle forKey:PSTitleKey];
        [toggleSpecifier setProperty:@(buttonEnabled) forKey:PSEnabledKey];
        [self reloadSpecifier:toggleSpecifier animated:NO];
    }
}

- (void)updateAddressTitles {
    NSString *lanURL = IOSMCPServiceURLString();
    NSString *localURL = [self localMCPURLString];

    if (self.lanAddressSpecifier) {
        self.lanAddressSpecifier.name = lanURL;
        [self.lanAddressSpecifier setProperty:lanURL forKey:PSTitleKey];
    }

    if (self.localAddressSpecifier) {
        self.localAddressSpecifier.name = localURL;
        [self.localAddressSpecifier setProperty:localURL forKey:PSTitleKey];
    }
}

- (BOOL)hasSpecifier:(PSSpecifier *)specifier {
    return specifier && [[self specifiers] containsObject:specifier];
}

- (void)updateAddressSpecifiersVisible:(BOOL)visible {
    if (!self.addressGroupSpecifier || !self.lanAddressSpecifier || !self.localAddressSpecifier) {
        return;
    }

    if (visible) {
        [self updateAddressTitles];
        if (![self hasSpecifier:self.addressGroupSpecifier]) {
            [self insertSpecifier:self.addressGroupSpecifier afterSpecifierID:@"toggleServerButton" animated:NO];
        }
        if (![self hasSpecifier:self.lanAddressSpecifier]) {
            [self insertSpecifier:self.lanAddressSpecifier afterSpecifier:self.addressGroupSpecifier animated:NO];
        }
        if (![self hasSpecifier:self.localAddressSpecifier]) {
            [self insertSpecifier:self.localAddressSpecifier afterSpecifier:self.lanAddressSpecifier animated:NO];
        }
        return;
    }

    if ([self hasSpecifier:self.localAddressSpecifier]) {
        [self removeSpecifier:self.localAddressSpecifier animated:NO];
    }
    if ([self hasSpecifier:self.lanAddressSpecifier]) {
        [self removeSpecifier:self.lanAddressSpecifier animated:NO];
    }
    if ([self hasSpecifier:self.addressGroupSpecifier]) {
        [self removeSpecifier:self.addressGroupSpecifier animated:NO];
    }
}

- (void)updateEnabledPreference:(BOOL)enabled {
    CFPreferencesSetAppValue((__bridge CFStringRef)IOS_MCP_ENABLED_PREFERENCE_KEY,
                             enabled ? kCFBooleanTrue : kCFBooleanFalse,
                             (__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
}

- (void)postNotification:(CFStringRef)notificationName {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         notificationName,
                                         NULL,
                                         NULL,
                                         YES);
}

- (NSString *)codexPrompt {
    return [NSString stringWithFormat:
            @"你可以通过 com.susu.mcp 服务操作一台 iPhone 设备。\n\n"
            @"局域网 MCP 地址: %@\n"
            @"本机 MCP 地址: %@\n\n"
            @"支持的操作:\n"
            @"- 文件读取：列出文件、读取文本文件、搜索文件内容。\n"
            @"- Shell 命令执行：在设备上执行 shell 命令，默认超时 10 秒，最大 30 秒。\n"
            @"- 设备信息：获取型号、iOS 版本、电池、存储、内存、越狱方式等信息。\n"
            @"- 网页访问：使用 fetch_url 获取网页、接口或远程文本内容。\n"
            @"- 项目 Skill：使用 read_project_skill 读取项目根目录下的 skill.md 或 SKILL.md。\n\n"
            @"可用工具:\n"
            @"- list_files\n"
            @"- read_file\n"
            @"- search_files\n"
            @"- get_device_info\n"
            @"- run_command\n"
            @"- fetch_url\n"
            @"- read_project_skill\n\n"
            @"需要访问网页、接口、在线文档、远程文本内容时，优先使用 fetch_url，不要使用软件自带的网页读取或浏览器访问能力替代。\n\n"
            @"当用户提供项目主目录，并要求分析、修改或理解该项目时，应优先调用 read_project_skill 读取项目根目录下的 skill.md 或 SKILL.md；如果没有找到，可以继续按普通项目处理。不要在整个文件系统中搜索 skill 文件，不要猜测项目路径。\n\n"
            @"健康检查不要使用 for i in {1..30}，因为某些 /bin/sh 不展开花括号；请使用 while 或 seq，并设置请求超时，例如：i=0; while [ $i -lt 30 ]; do r=$(curl -sS --connect-timeout 3 --max-time 5 %@ 2>/dev/null || true); [ -n \"$r\" ] && echo \"$r\" && exit 0; i=$((i+1)); sleep 1; done; echo health_timeout; exit 1",
            IOSMCPServiceURLString(),
            [self localMCPURLString],
            IOSMCPHealthURLString()];
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self cancelServerStatusRefresh];
}


@end

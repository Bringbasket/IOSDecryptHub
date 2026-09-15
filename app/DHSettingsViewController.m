// DHSettingsViewController.m
//
// 软件更新按 iOS 惯例收进设置；版本号只在这里出现一次（关于）。
// 状态行只在"有话要说"时出现：正在检查 / 已是最新 / 发现新版本 / 更新失败。
// 恢复上一版本不是常驻功能，只在确实存在备份时作为"故障逃生门"出现。

#import "DHSettingsViewController.h"
#import "DHConfigStore.h"
#import "dh_shared.h"
#import "DHVersionsViewController.h"

typedef NS_ENUM(NSInteger, DHSection) {
    DHSectionUpdate = 0,
    DHSectionAbout,
    DHSectionCount,
};

static NSString *const kDHWeChatAccount = @"DecryptHub";

// 关于里的社群入口：公众号（图）在上面，这里是两个链接
static NSArray<NSArray<NSString *> *> *dh_social_rows(void) {
    return @[
        @[ @"Telegram", @"@decrypthubteam", @"https://t.me/decrypthubteam" ],
        @[ @"X", @"@decrypthub_", @"https://x.com/decrypthub_" ],
    ];
}

// 图比例从 bundle 里读（首次布局时 cell 还没建，不能依赖 followView）
static CGFloat dh_follow_aspect(void) {
    static CGFloat aspect = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:@"wechat-follow" ofType:@"png"];
        UIImage *image = path.length ? [UIImage imageWithContentsOfFile:path] : nil;
        aspect = (image.size.width > 0) ? image.size.height / image.size.width : 0.308;
    });
    return aspect;
}

@interface DHSettingsViewController ()
@property (nonatomic, copy) NSDictionary *updaterState;
@property (nonatomic, copy, nullable) NSString *latestVersion;   // 仅"发现新版本"时用于展示
@property (nonatomic, assign) BOOL working;
@property (nonatomic, copy, nullable) NSString *installingVersion;
@property (nonatomic, assign) NSTimeInterval installRequestTime;
@property (nonatomic, strong) UIImageView *followView;
@property (nonatomic, assign) BOOL hasUpdateRow;
@end

@implementation DHSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, dh_settings_state_changed,
        (__bridge CFStringRef)DH_NOTIFY_STATE, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void dh_settings_state_changed(__unused CFNotificationCenterRef center,
    __unused void *observer, __unused CFStringRef name,
    __unused const void *object, __unused CFDictionaryRef info) {
    DHSettingsViewController *vc = (__bridge DHSettingsViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{ [vc handleUpdaterStateChanged]; });
}

- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, (__bridge CFStringRef)DH_NOTIFY_STATE, NULL);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    self.updaterState = DHReadUpdaterState();
    [self refreshAvailability];
    [self.tableView reloadData];
}

- (void)refreshAvailability {
    NSString *pending = self.latestVersion ?: DHPendingUpdateVersion();
    self.latestVersion = pending;
    self.hasUpdateRow = (pending != nil);
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return DHSectionCount; }

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case DHSectionUpdate: return self.hasUpdateRow ? 3 : 2;   // 检查更新 /[安装新版本]/ 历史版本
        case DHSectionAbout:  return 3 + (NSInteger)dh_social_rows().count;   // 公众号 + 社群 + App/引擎版本
        default: return 0;
    }
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case DHSectionUpdate: return @"引擎更新";
        case DHSectionAbout:  return @"关于";
        default: return nil;
    }
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != DHSectionUpdate) return nil;
    if (self.working) {
        return self.installingVersion.length
            ? [NSString stringWithFormat:@"正在安装引擎 %@…", self.installingVersion]
            : @"正在检查更新…";
    }
    NSDictionary *last = self.updaterState[@"lastOp"];
    NSString *result = [last isKindOfClass:[NSDictionary class]] ? last[@"result"] : nil;
    if ([result isEqualToString:@"error"]) {
        NSString *reason = last[@"error"];
        return [reason isKindOfClass:[NSString class]] && reason.length
            ? [NSString stringWithFormat:@"上次更新失败：%@（已保留原版本）", reason]
            : @"上次更新失败，已保留原版本。";
    }
    // 有新版就在这里点出来（全 App 唯一一处按需出现的版本号）
    if (self.hasUpdateRow && self.latestVersion.length) {
        return [NSString stringWithFormat:@"发现新版本 %@，点上方安装。", self.latestVersion];
    }
    return nil;
}

- (UITableViewCell *)actionCell:(NSString *)title image:(nullable NSString *)systemImage enabled:(BOOL)enabled {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = title;
    cell.textLabel.textColor = enabled ? self.view.tintColor : [UIColor secondaryLabelColor];
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    if (systemImage) {
        cell.imageView.image = [UIImage systemImageNamed:systemImage];
        cell.textLabel.textAlignment = NSTextAlignmentLeft;
    }
    cell.userInteractionEnabled = enabled;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == DHSectionUpdate) {
        if (indexPath.row == 0) return [self actionCell:@"检查引擎更新" image:nil enabled:!self.working];
        if (self.hasUpdateRow && indexPath.row == 1) {
            NSString *title = self.latestVersion.length
                ? [NSString stringWithFormat:@"安装引擎 %@", self.latestVersion]
                : @"安装新引擎";
            return [self actionCell:title image:nil enabled:!self.working];
        }
        return [self actionCell:@"引擎历史版本" image:nil enabled:!self.working];
    }
    if (indexPath.row == 0) {   // 公众号：整行图，点一下复制账号名
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"follow"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"follow"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UIImageView *view = [[UIImageView alloc] init];
            view.contentMode = UIViewContentModeScaleAspectFit;
            view.userInteractionEnabled = YES;
            NSString *path = [[NSBundle mainBundle] pathForResource:@"wechat-follow" ofType:@"png"];
            if (path.length) view.image = [UIImage imageWithContentsOfFile:path];
            [view addGestureRecognizer:[[UITapGestureRecognizer alloc]
                initWithTarget:self action:@selector(copyAccount)]];
            cell.contentView.clipsToBounds = YES;
            [cell.contentView addSubview:view];
            self.followView = view;
        }
        return cell;
    }
    NSArray<NSArray<NSString *> *> *social = dh_social_rows();
    if (indexPath.row <= (NSInteger)social.count) {
        NSArray<NSString *> *entry = social[indexPath.row - 1];
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.textLabel.text = entry[0];
        cell.detailTextLabel.text = entry[1];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    NSInteger appVersionRow = 1 + (NSInteger)social.count;
    if (indexPath.row == appVersionRow) {
        NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        cell.textLabel.text = @"管理器版本";
        cell.detailTextLabel.text = [version isKindOfClass:[NSString class]] ? version : @"—";
    } else {
        NSString *version = DHReadEngineMeta()[@"version"];
        cell.textLabel.text = @"引擎版本";
        cell.detailTextLabel.text = [version isKindOfClass:[NSString class]] ? version : @"—";
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(__unused UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != DHSectionAbout || indexPath.row != 0 || !self.followView) return;
    // 图按宽度等比铺满整行（与设置面板里的观感一致）
    CGFloat width = CGRectGetWidth(cell.contentView.bounds);
    CGFloat height = MIN(floor(width * dh_follow_aspect()), 240);
    self.followView.frame = CGRectMake(0, 0, width, height);
    cell.frame = CGRectMake(cell.frame.origin.x, cell.frame.origin.y, cell.frame.size.width,
                            height + 8);
}

- (CGFloat)tableView:(__unused UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == DHSectionAbout && indexPath.row == 0) {
        CGFloat width = CGRectGetWidth(self.tableView.bounds);
        return MIN(floor(width * dh_follow_aspect()), 240) + 8;
    }
    return UITableViewAutomaticDimension;
}

- (void)copyAccount {
    [UIPasteboard generalPasteboard].string = kDHWeChatAccount;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:@"已复制公众号名称，微信里搜一搜即可关注。"
        preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [alert dismissViewControllerAnimated:YES completion:nil]; });
}

#pragma mark - 动作

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.working) return;
    if (indexPath.section == DHSectionAbout) {
        NSArray<NSArray<NSString *> *> *social = dh_social_rows();
        if (indexPath.row >= 1 && indexPath.row <= (NSInteger)social.count) {
            NSURL *url = [NSURL URLWithString:social[indexPath.row - 1][2]];
            if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
        return;
    }
    if (indexPath.section == DHSectionUpdate) {
        if (indexPath.row == 0) { [self checkUpdate]; return; }
        if (self.hasUpdateRow && indexPath.row == 1) { [self installUpdate]; return; }
        [self.navigationController pushViewController:[[DHVersionsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped] animated:YES];
    }
}

- (void)setWorking:(BOOL)working {
    _working = working;
    [self.tableView reloadData];
}

- (void)checkUpdate {
    [self setWorking:YES];
    DHFetchLatestRelease(^(NSDictionary *_Nullable info, NSError *_Nullable error) {
        self.working = NO;
        self.updaterState = DHReadUpdaterState();
        if (error) {
            self.latestVersion = nil;
            self.hasUpdateRow = NO;
            [self.tableView reloadData];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"检查失败"
                message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        NSString *latest = info[@"version"];
        NSString *installed = DHReadEngineMeta()[@"version"];
        BOOL available = [latest isKindOfClass:[NSString class]] && latest.length &&
            [installed isKindOfClass:[NSString class]] && installed.length &&
            DHCompareVersions(installed, latest) == NSOrderedAscending;
        self.latestVersion = available ? latest : nil;
        self.hasUpdateRow = available;
        [self.tableView reloadData];
        if (!available) {
            NSString *appVersion = [[NSBundle mainBundle]
                objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
            BOOL appBehind = [appVersion isKindOfClass:[NSString class]] && latest.length &&
                DHCompareVersions(appVersion, latest) == NSOrderedAscending;
            NSString *message = appBehind
                ? [NSString stringWithFormat:
                    @"运行时引擎已是最新；管理器 App 仍为 %@。界面和后台服务需安装完整 DEB 才能更新。",
                    appVersion]
                : nil;
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"引擎已是最新"
                message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    });
}

- (void)installUpdate {
    NSString *version = self.latestVersion ?: @"";
    NSString *message = version.length
        ? [NSString stringWithFormat:@"将在后台安装 %@。已启用的 App 会被自动重启，无需手动操作。", version]
        : @"将在后台安装新版本。已启用的 App 会被自动重启，无需手动操作。";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"安装新引擎"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"安装" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        self.installingVersion = version.length ? version : @"最新版";
        self.installRequestTime = [[NSDate date] timeIntervalSince1970];
        if (DHWriteUpdateRequest(DH_REQ_INSTALL, nil)) {
            [self setWorking:YES];
            [self scheduleInstallPoll];
        } else {
            self.installingVersion = nil;
            UIAlertController *fail = [UIAlertController alertControllerWithTitle:@"提交失败"
                message:@"请确认插件已正确安装。" preferredStyle:UIAlertControllerStyleAlert];
            [fail addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:fail animated:YES completion:nil];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)handleUpdaterStateChanged {
    self.updaterState = DHReadUpdaterState();
    if (![self finishInstallIfReady]) {
        [self refreshAvailability];
        [self.tableView reloadData];
    }
}

- (BOOL)finishInstallIfReady {
    if (!self.installingVersion.length) return NO;
    NSDictionary *op = self.updaterState[@"lastOp"];
    if (![op isKindOfClass:[NSDictionary class]] ||
        ![op[@"kind"] isEqualToString:@"install"] ||
        [op[@"time"] doubleValue] + 0.5 < self.installRequestTime) return NO;

    NSString *result = op[@"result"];
    NSString *error = op[@"error"];
    NSString *version = op[@"version"];
    self.installingVersion = nil;
    self.working = NO;
    self.latestVersion = nil;
    self.hasUpdateRow = NO;

    BOOL ok = [result isEqualToString:@"ok"];
    NSString *title = ok ? @"引擎安装完成"
        : ([result isEqualToString:@"skipped"] ? @"无需安装" : @"引擎安装失败");
    NSString *message = error.length ? error
        : (version.length ? [NSString stringWithFormat:@"当前引擎版本：%@", version] : nil);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self reload];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
            message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
    return YES;
}

- (void)scheduleInstallPoll {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.installingVersion.length) return;
        self.updaterState = DHReadUpdaterState();
        if ([self finishInstallIfReady]) return;
        if ([[NSDate date] timeIntervalSince1970] - self.installRequestTime > 150) {
            self.installingVersion = nil;
            [self setWorking:NO];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"安装未响应"
                message:@"后台更新器没有返回结果，请重新安装完整 DEB 以修复更新服务。"
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        [self scheduleInstallPoll];
    });
}

@end

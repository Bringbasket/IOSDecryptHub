// DHRootViewController.m — 无 storyboard，纯代码静态表。
// 所有数据来自 DHConfigStore；越狱文件缺失时展示"未知"，不崩溃。

#import "DHRootViewController.h"
#import "DHConfigStore.h"
#import "DHAppEnumerator.h"
#import "dh_shared.h"

typedef NS_ENUM(NSInteger, DHSection) {
    DHSectionStatus = 0,
    DHSectionUpdate,
    DHSectionApps,
    DHSectionAbout,
    DHSectionCount,
};

static NSString *dh_time_ago(NSTimeInterval ts) {
    if (ts <= 0) return @"从未";
    NSTimeInterval delta = [[NSDate date] timeIntervalSince1970] - ts;
    if (delta < 0) return @"刚才";
    if (delta < 60) return @"刚才";
    if (delta < 3600) return [NSString stringWithFormat:@"%.0f 分钟前", delta / 60];
    if (delta < 86400) return [NSString stringWithFormat:@"%.0f 小时前", delta / 3600];
    return [NSString stringWithFormat:@"%.0f 天前", delta / 86400];
}

@interface DHRootViewController ()
@property (nonatomic, copy) NSDictionary *engineMeta;
@property (nonatomic, copy) NSDictionary *updaterState;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *apps;
@property (nonatomic, copy) NSArray<NSString *> *sortedBundleIDs;
@property (nonatomic, strong) NSMutableSet<NSString *> *enabled;
@property (nonatomic, copy, nullable) NSString *latestTag;
@property (nonatomic, assign) BOOL working;
@end

@implementation DHRootViewController

#pragma mark - lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"解密助手";
    self.enabled = [NSMutableSet set];
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(center, (__bridge const void *)self,
        dh_updater_state_changed, (__bridge CFStringRef)DH_NOTIFY_STATE, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void dh_updater_state_changed(__unused CFNotificationCenterRef center,
    __unused void *observer, __unused CFStringRef name,
    __unused const void *object, __unused CFDictionaryRef info) {
    DHRootViewController *vc = (__bridge DHRootViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{ [vc reloadAll]; });
}

- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, (__bridge CFStringRef)DH_NOTIFY_STATE, NULL);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadAll];
}

- (void)reloadAll {
    self.engineMeta = DHReadEngineMeta();
    self.updaterState = DHReadUpdaterState();
    self.apps = DHInstalledApps();
    self.sortedBundleIDs = [self.apps.allKeys sortedArrayUsingComparator:
        ^NSComparisonResult(NSString *l, NSString *r) {
            return [self.apps[l] localizedCaseInsensitiveCompare:self.apps[r]];
        }];
    self.enabled = [[DHReadEnabledBundles() mutableCopy] ?: [NSMutableSet set] mutableCopy];
    [self.tableView reloadData];
}

#pragma mark - helpers

- (NSString *)engineVersion {
    NSString *v = self.engineMeta[@"version"];
    return [v isKindOfClass:[NSString class]] && v.length ? v : @"未知";
}

- (BOOL)updateAvailable {
    NSString *latest = self.latestTag ?: self.updaterState[@"latestVersion"];
    if (![latest isKindOfClass:[NSString class]] || !latest.length) return NO;
    if ([self.engineVersion isEqualToString:@"未知"]) return NO;
    return DHCompareVersions(self.engineVersion, latest) == NSOrderedAscending;
}

- (void)dh_alert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)dh_confirm:(NSString *)title message:(NSString *)message action:(NSString *)action handler:(void (^)(void))handler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:action style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *a) { if (handler) handler(); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - table structure

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return DHSectionCount;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case DHSectionStatus: return @"状态";
        case DHSectionUpdate: return @"软件更新";
        case DHSectionApps: return @"注入应用";
        case DHSectionAbout: return @"关于";
        default: return nil;
    }
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == DHSectionUpdate) {
        NSDictionary *last = self.updaterState[@"lastOp"];
        if ([last isKindOfClass:[NSDictionary class]] && last[@"version"]) {
            NSString *kind = [last[@"kind"] isEqualToString:@"rollback"] ? @"回滚" : @"安装";
            NSString *result = [last[@"result"] isEqualToString:@"ok"] ? @"成功"
                : ([last[@"result"] isEqualToString:@"skipped"] ? @"跳过" : @"失败");
            NSString *err = last[@"error"];
            NSString *msg = [NSString stringWithFormat:@"上次%@ %@（%@）%@",
                kind, last[@"version"], result, dh_time_ago([last[@"time"] doubleValue])];
            if ([result isEqualToString:@"失败"] && [err isKindOfClass:[NSString class]] && err.length) {
                msg = [msg stringByAppendingFormat:@"：%@", err];
            }
            NSArray *restarted = last[@"restartedApps"];
            if ([restarted isKindOfClass:[NSArray class]] && restarted.count > 0) {
                msg = [msg stringByAppendingFormat:@"，已结束 %lu 个应用进程", (unsigned long)restarted.count];
            }
            return msg;
        }
        return @"后台服务每 12 小时自动检查一次；安装与回滚由后台服务执行，完成后目标 App 下次启动即生效。";
    }
    if (section == DHSectionApps) return @"开启后请完全退出并重新启动目标 App。";
    return nil;
}

- (NSInteger)updateRowCount {
    // 最新版本 / 检查更新 / 下载并安装 / 回滚上一版
    NSInteger n = 2;
    if ([self updateAvailable]) n += 1;
    if ([self.updaterState[@"backupAvailable"] boolValue]) n += 1;
    return n;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case DHSectionStatus: return 4;
        case DHSectionUpdate: return [self updateRowCount];
        case DHSectionApps: return MAX(self.sortedBundleIDs.count, 1);
        case DHSectionAbout: return 2;
        default: return 0;
    }
}

- (UITableViewCell *)statusCell:(NSString *)title value:(NSString *)value {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = title;
    cell.detailTextLabel.text = value;
    return cell;
}

- (UITableViewCell *)actionCell:(NSString *)title enabled:(BOOL)enabled {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = title;
    cell.textLabel.textColor = enabled ? self.view.tintColor : [UIColor grayColor];
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == DHSectionStatus) {
        switch (indexPath.row) {
            case 0: return [self statusCell:@"引擎版本" value:[self engineVersion]];
            case 1: return [self statusCell:@"已启用应用"
                value:[NSString stringWithFormat:@"%lu", (unsigned long)self.enabled.count]];
            case 2: {
                NSTimeInterval hb = [self.updaterState[@"daemonHeartbeat"] doubleValue];
                return [self statusCell:@"后台更新" value:hb > 0 ? [@"活跃（" stringByAppendingFormat:@"%@）", dh_time_ago(hb)] : @"尚未运行"];
            }
            default: {
                NSTimeInterval last = 0;
                last = MAX(last, [self.updaterState[@"lastCheck"] doubleValue]);
                NSDictionary *req = [NSDictionary dictionaryWithContentsOfFile:DH_REQUEST_PATH];
                last = MAX(last, [req[@"time"] doubleValue]);
                return [self statusCell:@"上次检查" value:dh_time_ago(last)];
            }
        }
    }
    if (indexPath.section == DHSectionUpdate) {
        NSString *latest = self.latestTag ?: self.updaterState[@"latestVersion"];
        if (![latest isKindOfClass:[NSString class]]) latest = nil;
        NSInteger row = indexPath.row;
        if (row == 0) {
            return [self statusCell:@"最新版本" value:latest ?: @"未知"];
        }
        row -= 1;
        if (row == 0) return [self actionCell:@"检查更新" enabled:!self.working];
        row -= 1;
        if ([self updateAvailable]) {
            if (row == 0) return [self actionCell:[NSString stringWithFormat:@"下载并安装 %@", latest] enabled:!self.working];
            row -= 1;
        }
        return [self actionCell:[NSString stringWithFormat:@"回滚到 %@", self.updaterState[@"backupVersion"] ?: @"上一版"] enabled:!self.working];
    }
    if (indexPath.section == DHSectionApps) {
        if (self.sortedBundleIDs.count == 0) {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = @"未能读取已安装应用";
            cell.textLabel.textColor = [UIColor grayColor];
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            return cell;
        }
        NSString *bundleID = self.sortedBundleIDs[indexPath.row];
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
        }
        cell.textLabel.text = self.apps[bundleID];
        cell.detailTextLabel.text = bundleID;
        cell.detailTextLabel.textColor = [UIColor grayColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [self.enabled containsObject:bundleID];
        sw.tag = indexPath.row;
        [sw addTarget:self action:@selector(appSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }
    // About
    if (indexPath.row == 0) {
        NSString *mgr = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        return [self statusCell:@"管理器版本" value:[mgr isKindOfClass:[NSString class]] ? mgr : @"未知"];
    }
    NSString *variant = self.engineMeta[@"variant"];
    NSString *arch = self.engineMeta[@"arch"];
    NSString *detail = @"未知";
    if ([variant isKindOfClass:[NSString class]] && variant.length) {
        detail = variant;
        if ([arch isKindOfClass:[NSString class]] && arch.length) detail = [detail stringByAppendingFormat:@" · %@", arch];
    }
    return [self statusCell:@"越狱类型" value:detail];
}

#pragma mark - actions

- (void)appSwitchChanged:(UISwitch *)sw {
    if (sw.tag < 0 || sw.tag >= (NSInteger)self.sortedBundleIDs.count) return;
    NSString *bundleID = self.sortedBundleIDs[sw.tag];
    NSMutableSet *next = [self.enabled mutableCopy];
    if (sw.on) [next addObject:bundleID]; else [next removeObject:bundleID];
    if (DHWriteEnabledBundles(next)) {
        self.enabled = next;
    } else {
        sw.on = !sw.on;
        [self dh_alert:@"写入失败" message:@"名单保存失败，请确认设备已越狱且插件正常安装。"];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.working || indexPath.section != DHSectionUpdate || indexPath.row == 0) return;
    // 行号映射与 cellForRow 保持一致
    NSInteger row = indexPath.row - 1;
    if (row == 0) { [self doCheckUpdate]; return; }
    row -= 1;
    if ([self updateAvailable]) {
        if (row == 0) { [self doInstallUpdate]; return; }
        row -= 1;
    }
    (void)row;
    [self doRollback];
}

- (void)setWorking:(BOOL)working {
    _working = working;
    [self.tableView reloadData];
}

- (void)doCheckUpdate {
    [self setWorking:YES];
    DHFetchLatestRelease(^(NSDictionary *_Nullable info, NSError *_Nullable error) {
        [self setWorking:NO];
        if (error) {
            [self dh_alert:@"检查失败" message:error.localizedDescription];
            return;
        }
        self.latestTag = info[@"tag"];
        [self.tableView reloadData];
        if ([self updateAvailable]) {
            [self dh_alert:@"发现新版本" message:[NSString stringWithFormat:@"最新 %@，当前 %@，可在下方点「下载并安装」。", info[@"version"], [self engineVersion]]];
        } else {
            [self dh_alert:@"已是最新" message:[NSString stringWithFormat:@"当前 %@ 已是最新版本。", [self engineVersion]]];
        }
    });
}

- (void)doInstallUpdate {
    NSString *latest = self.latestTag ?: self.updaterState[@"latestVersion"];
    [self dh_confirm:@"下载并安装" message:[NSString stringWithFormat:@"后台服务将下载 %@ 并替换引擎，完成后已启用的目标 App 会被自动结束进程，下次打开即生效。继续吗？", latest] action:@"安装" handler:^{
        if (DHWriteUpdateRequest(DH_REQ_INSTALL)) {
            [self dh_alert:@"已提交" message:@"后台服务正在安装，稍后下拉或重新进入本页查看进度。"];
            [self reloadAll];
        } else {
            [self dh_alert:@"提交失败" message:@"更新请求写入失败，请确认设备已越狱且插件正常安装。"];
        }
    }];
}

- (void)doRollback {
    NSString *bak = self.updaterState[@"backupVersion"];
    [self dh_confirm:@"回滚" message:[NSString stringWithFormat:@"将引擎恢复到 %@（本次安装前的备份），继续吗？", [bak isKindOfClass:[NSString class]] ? bak : @"上一版"] action:@"回滚" handler:^{
        if (DHWriteUpdateRequest(DH_REQ_ROLLBACK)) {
            [self dh_alert:@"已提交" message:@"后台服务正在回滚，稍后回来查看结果。"];
            [self reloadAll];
        } else {
            [self dh_alert:@"提交失败" message:@"回滚请求写入失败，请确认设备已越狱且插件正常安装。"];
        }
    }];
}

@end

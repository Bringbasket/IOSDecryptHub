// DHVersionsViewController.m — 历史版本：列出已发布版本，可安装指定版本
//
// 不做"恢复到上一个版本"这种常驻按钮：那是把内部机制当功能卖。用户要的是
// "我想回到某个具体版本" —— 给列表，让他自己挑。

#import "DHVersionsViewController.h"
#import "DHConfigStore.h"
#import "dh_shared.h"

@interface DHVersionsViewController ()
@property (nonatomic, copy) NSArray<NSDictionary *> *releases;
@property (nonatomic, copy, nullable) NSString *currentVersion;
@property (nonatomic, copy, nullable) NSString *errorText;
@property (nonatomic, copy, nullable) NSString *installingVersion;
@property (nonatomic, assign) NSTimeInterval installRequestTime;
@end

@implementation DHVersionsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"历史版本";
    self.tableView.rowHeight = 52;
    NSDictionary *meta = DHReadEngineMeta();
    NSString *current = meta[@"version"];
    self.currentVersion = [current isKindOfClass:[NSString class]] ? current : nil;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, dh_versions_state_changed,
        (__bridge CFStringRef)DH_NOTIFY_STATE, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    [self load];
}

static void dh_versions_state_changed(__unused CFNotificationCenterRef center,
    __unused void *observer, __unused CFStringRef name,
    __unused const void *object, __unused CFDictionaryRef info) {
    DHVersionsViewController *vc = (__bridge DHVersionsViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{ [vc finishInstallIfReady]; });
}

- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, (__bridge CFStringRef)DH_NOTIFY_STATE, NULL);
}

- (void)load {
    self.errorText = nil;
    [self.tableView reloadData];
    DHFetchReleases(^(NSArray<NSDictionary *> *_Nullable releases, NSError *_Nullable error) {
        if (error) self.errorText = error.localizedDescription;
        self.releases = releases ?: @[];
        [self.tableView reloadData];
    });
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.errorText) return 1;
    return MAX(self.releases.count, 1);
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.releases.count > 0 ? @"选择要安装的版本" : nil;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.errorText) return nil;
    if (self.installingVersion.length) {
        return [NSString stringWithFormat:@"正在安装引擎 %@…", self.installingVersion];
    }
    return self.releases.count > 0
        ? @"这里只切换运行时引擎；管理器 App 与后台服务需安装完整 DEB 更新。" : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.errorText || self.releases.count == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = self.errorText
            ? [NSString stringWithFormat:@"读取版本列表失败\n%@", self.errorText]
            : @"正在读取版本列表…";
        return cell;
    }
    NSDictionary *item = self.releases[indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"v"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"v"];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
    }
    NSString *version = item[@"version"];
    cell.textLabel.text = version;
    cell.detailTextLabel.text = item[@"date"];
    BOOL isCurrent = self.currentVersion.length && [version isEqualToString:self.currentVersion];
    cell.accessoryType = isCurrent ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    BOOL selectable = !isCurrent && !self.installingVersion.length;
    cell.selectionStyle = selectable ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.textLabel.textColor = selectable ? [UIColor labelColor] : [UIColor secondaryLabelColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.installingVersion.length) return;
    if (self.releases.count == 0 || indexPath.row >= (NSInteger)self.releases.count) return;
    NSDictionary *item = self.releases[indexPath.row];
    NSString *version = item[@"version"];
    if (self.currentVersion.length && [version isEqualToString:self.currentVersion]) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@"安装 %@", version]
        message:@"切换后已启用的 App 会被自动重启。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"安装" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        weakSelf.installingVersion = version;
        weakSelf.installRequestTime = [[NSDate date] timeIntervalSince1970];
        if (DHWriteUpdateRequest(DH_REQ_INSTALL, version)) {
            [weakSelf showInstallSpinner];
            [weakSelf.tableView reloadData];
            [weakSelf scheduleInstallPoll];
        } else {
            weakSelf.installingVersion = nil;
            UIAlertController *fail = [UIAlertController alertControllerWithTitle:@"提交失败"
                message:@"无法写入更新请求，请确认插件已正确安装。"
                preferredStyle:UIAlertControllerStyleAlert];
            [fail addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [weakSelf presentViewController:fail animated:YES completion:nil];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showInstallSpinner {
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spinner startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
}

- (BOOL)finishInstallIfReady {
    if (!self.installingVersion.length) return NO;
    NSDictionary *state = DHReadUpdaterState();
    NSDictionary *op = state[@"lastOp"];
    if (![op isKindOfClass:[NSDictionary class]] ||
        ![op[@"kind"] isEqualToString:@"install"] ||
        [op[@"time"] doubleValue] + 0.5 < self.installRequestTime) return NO;

    NSString *result = op[@"result"];
    NSString *error = op[@"error"];
    NSString *version = op[@"version"] ?: self.installingVersion;
    self.installingVersion = nil;
    self.navigationItem.rightBarButtonItem = nil;
    BOOL ok = [result isEqualToString:@"ok"];
    NSString *title = ok ? @"引擎安装完成"
        : ([result isEqualToString:@"skipped"] ? @"无需安装" : @"引擎安装失败");
    NSString *message = error.length ? error
        : (version.length ? [NSString stringWithFormat:@"当前引擎版本：%@", version] : nil);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSString *current = DHReadEngineMeta()[@"version"];
        self.currentVersion = [current isKindOfClass:[NSString class]] ? current : version;
        [self.tableView reloadData];
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
        if ([self finishInstallIfReady]) return;
        if ([[NSDate date] timeIntervalSince1970] - self.installRequestTime > 150) {
            self.installingVersion = nil;
            self.navigationItem.rightBarButtonItem = nil;
            [self.tableView reloadData];
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

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
@end

@implementation DHVersionsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"历史版本";
    self.tableView.rowHeight = 52;
    NSDictionary *meta = DHReadEngineMeta();
    NSString *current = meta[@"version"];
    self.currentVersion = [current isKindOfClass:[NSString class]] ? current : nil;
    [self load];
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
    return self.releases.count > 0
        ? @"安装历史版本只切换引擎，App 与后台服务保持当前版本。" : nil;
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
    cell.selectionStyle = isCurrent ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    cell.textLabel.textColor = isCurrent ? [UIColor secondaryLabelColor] : [UIColor labelColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
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
        if (DHWriteUpdateRequest(DH_REQ_INSTALL, version)) {
            [weakSelf.navigationController popViewControllerAnimated:YES];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

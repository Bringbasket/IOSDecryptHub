// DHRootViewController.m — 主界面
//
// 设计取向（按使用逻辑，不按实现）：
//   - 打开就是"我开了哪些 App"，不是引擎状态、不是版本号
//   - 顶部搜索：App 多了也能立刻找到
//   - 已启用置顶，随时知道自己注入了什么、一键关掉
//   - 每行只有图标 + 名称 + 开关（bundle id 作次要信息，便于反馈问题时对照）
//   - 提示文案只留真正需要用户做动作的那一句

#import "DHRootViewController.h"
#import "DHSettingsViewController.h"
#import "DHConfigStore.h"
#import "DHAppEnumerator.h"

@interface DHRootViewController () <UISearchResultsUpdating>
@property (nonatomic, copy) NSArray<DHAppInfo *> *allApps;
@property (nonatomic, copy) NSArray<DHAppInfo *> *enabledApps;
@property (nonatomic, copy) NSArray<DHAppInfo *> *matchedApps;   // 搜索结果
@property (nonatomic, strong) NSMutableSet<NSString *> *enabled;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, assign) BOOL searching;
@end

@implementation DHRootViewController

#pragma mark - lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"IOSDecryptHub";
    self.tableView.rowHeight = 56;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"gearshape"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(openSettings)];

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"搜索 App";
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    self.allApps = DHInstalledApps();
    self.enabled = [[DHReadEnabledBundles() mutableCopy] ?: [NSMutableSet set] mutableCopy];

    NSMutableArray<DHAppInfo *> *enabledApps = [NSMutableArray array];
    for (DHAppInfo *app in self.allApps) {
        if ([self.enabled containsObject:app.bundleID]) [enabledApps addObject:app];
    }
    self.enabledApps = enabledApps;
    [self updateSearchResultsForSearchController:self.search];
    [self.tableView reloadData];
}

- (void)openSettings {
    DHSettingsViewController *settings = [[DHSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    [self.navigationController pushViewController:settings animated:YES];
}

#pragma mark - 搜索

- (void)updateSearchResultsForSearchController:(__unused UISearchController *)controller {
    NSString *query = [self.search.searchBar.text
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.searching = query.length > 0;
    if (!self.searching) {
        self.matchedApps = @[];
        return;
    }
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(DHAppInfo *app, __unused NSDictionary *bindings) {
        return [app.name localizedCaseInsensitiveContainsString:query] ||
               [app.bundleID localizedCaseInsensitiveContainsString:query];
    }];
    self.matchedApps = [self.allApps filteredArrayUsingPredicate:predicate];
    [self.tableView reloadData];
}

#pragma mark - 数据源

- (NSArray<DHAppInfo *> *)appsInSection:(NSInteger)section {
    if (self.searching) return self.matchedApps;
    if (section == 0 && self.enabledApps.count > 0) return self.enabledApps;
    return self.allApps;
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    if (self.searching) return 1;
    return self.enabledApps.count > 0 ? 2 : 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (!self.searching && section == 0 && self.enabledApps.count > 0) return self.enabledApps.count;
    return MAX(self.allApps.count, 1);
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.searching) return nil;
    if (section == 0 && self.enabledApps.count > 0) {
        return [NSString stringWithFormat:@"已启用 %lu", (unsigned long)self.enabledApps.count];
    }
    return @"全部应用";
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    // 只留一句真正需要用户做动作的话
    if (!self.searching && section == 0 && self.enabledApps.count > 0) {
        return @"开启后需完全退出并重新打开目标 App 才会生效。";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<DHAppInfo *> *apps = [self appsInSection:indexPath.section];
    if (apps.count == 0) {   // 空状态
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = self.allApps.count == 0 ? @"未能读取已安装应用" : @"没有匹配的 App";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    DHAppInfo *app = apps[indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
        UISwitch *toggle = [[UISwitch alloc] init];
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
    }
    cell.textLabel.text = app.name;
    cell.detailTextLabel.text = app.bundleID;
    cell.imageView.image = DHAppIcon(app.bundleID, app.bundlePath) ?: [UIImage systemImageNamed:@"app"];
    UISwitch *toggle = (UISwitch *)cell.accessoryView;
    toggle.on = [self.enabled containsObject:app.bundleID];
    toggle.tag = indexPath.section * 10000 + indexPath.row;   // 仅用于回查位置
    return cell;
}

#pragma mark - 开关

- (DHAppInfo *)appForSwitch:(UISwitch *)toggle {
    NSInteger section = toggle.tag / 10000;
    NSInteger row = toggle.tag % 10000;
    NSArray<DHAppInfo *> *apps = [self appsInSection:section];
    if (row < 0 || row >= (NSInteger)apps.count) return nil;
    return apps[row];
}

- (void)toggleChanged:(UISwitch *)toggle {
    DHAppInfo *app = [self appForSwitch:toggle];
    if (!app) return;
    NSMutableSet<NSString *> *next = [self.enabled mutableCopy];
    if (toggle.on) [next addObject:app.bundleID]; else [next removeObject:app.bundleID];
    if (!DHWriteEnabledBundles(next)) {
        toggle.on = !toggle.on;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"保存失败"
            message:@"写入启用名单失败。请确认插件已正确安装。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    // 名单变了就重建分区：新启用的立刻出现在「已启用」里
    [self reload];
}

@end

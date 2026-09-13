// DHRootViewController.m — 主界面：管理与查看注入的 App
//
// 设计取向（按使用逻辑，不按实现）：
//   - 打开就是"我开了哪些 App"；顶部可过滤出「已启用」
//   - 全部应用按首字母分组，右侧有快速导航索引（中文按拼音首字母）
//   - 每行只有图标（R 角）+ 名称 + 开关；取不到图标时用首字母默认图标，绝不空着
//   - 提示文案只留一句真正需要用户做动作的

#import "DHRootViewController.h"
#import "DHSettingsViewController.h"
#import "DHConfigStore.h"
#import "DHAppEnumerator.h"

typedef NS_ENUM(NSInteger, DHFilter) {
    DHFilterAll = 0,
    DHFilterEnabled,
};

@interface DHRootViewController () <UISearchResultsUpdating>
@property (nonatomic, copy) NSArray<DHAppInfo *> *allApps;
@property (nonatomic, strong) NSMutableSet<NSString *> *enabled;
@property (nonatomic, copy) NSArray<NSArray<DHAppInfo *> *> *sections;
@property (nonatomic, copy) NSArray<NSString *> *sectionHeaders;
@property (nonatomic, copy) NSArray<NSString *> *sectionIndexes;
@property (nonatomic, copy) NSArray<DHAppInfo *> *matched;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, strong) UISegmentedControl *filter;
@property (nonatomic, assign) BOOL searching;
@property (nonatomic, assign) BOOL enabledOnly;
@end

@implementation DHRootViewController

#pragma mark - lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 56;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.sectionIndexMinimumDisplayRowCount = 12;

    self.filter = [[UISegmentedControl alloc] initWithItems:@[ @"全部", @"已启用" ]];
    self.filter.selectedSegmentIndex = 0;
    [self.filter addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.filter;

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

- (void)openSettings {
    DHSettingsViewController *settings = [[DHSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    [self.navigationController pushViewController:settings animated:YES];
}

- (void)filterChanged {
    self.enabledOnly = (self.filter.selectedSegmentIndex == DHFilterEnabled);
    [self rebuild];
    [self.tableView reloadData];
}

#pragma mark - 数据

- (void)reload {
    self.allApps = DHInstalledApps();
    self.enabled = [[DHReadEnabledBundles() mutableCopy] ?: [NSMutableSet set] mutableCopy];
    [self rebuild];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(__unused UISearchController *)controller {
    [self rebuild];
    [self.tableView reloadData];
}

/// 按「过滤 → 搜索 → 首字母分组」重建分区
- (void)rebuild {
    NSString *query = [self.search.searchBar.text
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.searching = query.length > 0;

    NSMutableArray<DHAppInfo *> *pool = [NSMutableArray array];
    for (DHAppInfo *app in self.allApps) {
        if (self.enabledOnly && ![self.enabled containsObject:app.bundleID]) continue;
        if (self.searching &&
            ![app.name localizedCaseInsensitiveContainsString:query] &&
            ![app.bundleID localizedCaseInsensitiveContainsString:query]) continue;
        [pool addObject:app];
    }

    if (self.searching) {   // 搜索结果不分组，直接平铺
        self.sections = @[ pool ];
        self.sectionHeaders = @[ @"" ];
        self.sectionIndexes = @[];
        return;
    }

    NSMutableArray<NSArray<DHAppInfo *> *> *sections = [NSMutableArray array];
    NSMutableArray<NSString *> *headers = [NSMutableArray array];
    NSMutableArray<NSString *> *indexes = [NSMutableArray array];

    // 按（首字母, 名称）排序后分组；中文名字用拼音首字母
    NSArray<DHAppInfo *> *sorted = [pool sortedArrayUsingComparator:^NSComparisonResult(DHAppInfo *l, DHAppInfo *r) {
        NSComparisonResult byLetter = [DHAppIndexLetter(l.name) compare:DHAppIndexLetter(r.name)];
        return byLetter != NSOrderedSame ? byLetter : [l.name localizedCaseInsensitiveCompare:r.name];
    }];
    NSString *current = nil;
    NSMutableArray<DHAppInfo *> *bucket = nil;
    for (DHAppInfo *app in sorted) {
        NSString *letter = DHAppIndexLetter(app.name);
        if (![letter isEqualToString:current]) {
            if (bucket) { [sections addObject:bucket]; [headers addObject:current]; [indexes addObject:current]; }
            bucket = [NSMutableArray array];
            current = letter;
        }
        [bucket addObject:app];
    }
    if (bucket) { [sections addObject:bucket]; [headers addObject:current]; [indexes addObject:current]; }

    self.sections = sections;
    self.sectionHeaders = headers;
    self.sectionIndexes = indexes;
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return self.sections.count; }

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sections.count == 0 ? 1 : self.sections[section].count;   // 空态占一行
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.sections.count == 0) return nil;
    NSString *header = self.sectionHeaders[section];
    return self.searching ? @"搜索结果" : header;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    // 只留一句真正需要用户做动作的话，放在"已启用"页（管理开关的地方）
    if (!self.searching && self.enabledOnly && section == 0) {
        return @"改动会在目标 App 重启后生效：若它正在运行，我们会自动帮你重启。";
    }
    return nil;
}

- (NSArray<NSString *> *)sectionIndexTitlesForTableView:(__unused UITableView *)tableView {
    return self.searching ? @[] : self.sectionIndexes;
}

- (NSInteger)tableView:(__unused UITableView *)tableView sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index {
    return index;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.sections.count == 0) {   // 空态
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (self.allApps.count == 0) {
            cell.textLabel.text = @"未能读取已安装应用";
        } else if (self.searching) {
            cell.textLabel.text = @"没有匹配的 App";
        } else {
            cell.textLabel.text = @"还没有启用任何 App\n在上面搜索，或从列表里打开开关";
        }
        return cell;
    }

    DHAppInfo *app = self.sections[indexPath.section][indexPath.row];
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
    cell.imageView.image = DHAppListIcon(app.bundleID, app.bundlePath, app.name);
    UISwitch *toggle = (UISwitch *)cell.accessoryView;
    toggle.on = [self.enabled containsObject:app.bundleID];
    toggle.tag = indexPath.section * 10000 + indexPath.row;
    return cell;
}

#pragma mark - 左滑重启

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.sections.count == 0 || indexPath.section >= (NSInteger)self.sections.count) return nil;
    NSArray<DHAppInfo *> *apps = self.sections[indexPath.section];
    if (indexPath.row >= (NSInteger)apps.count) return nil;
    DHAppInfo *app = apps[indexPath.row];
    if (![self.enabled containsObject:app.bundleID]) return nil;   // 没启用就没什么可生效的

    __weak typeof(self) weakSelf = self;
    UIContextualAction *restart = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                          title:@"重启"
                                                                        handler:^(__unused UIContextualAction *action,
                                                                                  __unused UIView *source,
                                                                                  void (^completion)(BOOL)) {
        completion(DHWriteRestartRequest(app.bundleID));
        [weakSelf watchRestartResultFor:app.bundleID];
    }];
    restart.backgroundColor = self.view.tintColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[ restart ]];
}

// 重启由 daemon 异步执行；只在"没能自动打开"这类需要用户接手的情况下提示一句。
- (void)watchRestartResultFor:(NSString *)bundleID {
    [self watchRestartResultFor:bundleID tellOnSuccess:NO];
}

- (void)watchRestartResultFor:(NSString *)bundleID tellOnSuccess:(BOOL)tell {
    // 轮询必须在后台：这个方法是滑动动作/开关回调直接调的，睡在主线程会把界面冻住
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self pollRestartResultFor:bundleID tellOnSuccess:tell];
    });
}

- (void)flashRestarted:(NSString *)name {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:[NSString stringWithFormat:@"已重启 %@ 以应用改动", name]
        preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [alert dismissViewControllerAnimated:YES completion:nil]; });
}

- (void)pollRestartResultFor:(NSString *)bundleID tellOnSuccess:(BOOL)tell {
    for (int i = 0; i < 12; i++) {
        [NSThread sleepForTimeInterval:0.5];
        NSDictionary *op = DHReadUpdaterState()[@"lastOp"];
        if (![op isKindOfClass:[NSDictionary class]]) continue;
        if (![op[@"bundle"] isEqualToString:bundleID]) continue;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([op[@"relaunched"] boolValue]) {
                // 已自动打开；只有开关触发的才给一条会自己消失的提示，滑动的不用
                if (tell) [self flashRestarted:bundleID];
                return;
            }
            NSString *message = [op[@"result"] isEqualToString:@"skipped"]
                ? @"该 App 当前没有在运行。"
                : @"已结束它，请手动打开以让改动生效。";
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
        return;
    }
}

#pragma mark - 开关

- (void)toggleChanged:(UISwitch *)toggle {
    NSInteger section = toggle.tag / 10000;
    NSInteger row = toggle.tag % 10000;
    if (section >= (NSInteger)self.sections.count) return;
    NSArray<DHAppInfo *> *apps = self.sections[section];
    if (row < 0 || row >= (NSInteger)apps.count) return;
    DHAppInfo *app = apps[row];

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
    self.enabled = next;
    [self rebuild];
    [self.tableView reloadData];

    // 关掉/打开都只有重启目标 App 才生效。用户不知道这一点，所以由我们来判断：
    // 目标正在运行时自动重启它；没在运行时什么都不做（下次打开自然是新状态）。
    // 这样批量开关多个 App 时不会弹一堆确认框。
    // 例外：本 App 自己。用户此刻正在用它，唯一必然在运行的就是它 —— 自杀式重启很荒唐，
    // 而且它本来也不需要"重启生效"（改动下次打开自然是新状态）。
    NSString *selfBundle = [[NSBundle mainBundle] bundleIdentifier];
    BOOL isSelf = [app.bundleID isEqualToString:selfBundle];
    if (!isSelf && DHAppProcessRunning(app)) {
        if (DHWriteRestartRequest(app.bundleID)) {
            [self watchRestartResultFor:app.bundleID tellOnSuccess:YES];
        }
    }
}

@end

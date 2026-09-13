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
        return @"开关改动后需完全退出并重新打开目标 App 才会生效。";
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
    [self rebuild];              // 新启用的立刻出现在置顶分区
    [self.tableView reloadData];
}

@end

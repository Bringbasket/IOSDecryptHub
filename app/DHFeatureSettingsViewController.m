// DHFeatureSettingsViewController.m

#import "DHFeatureSettingsViewController.h"
#import "DHConfigStore.h"
#import "dh_shared.h"

@interface DHFeatureSwitch : UISwitch
@property (nonatomic, copy) NSString *featureKey;
@end

@implementation DHFeatureSwitch
@end

static NSArray<NSDictionary *> *dh_feature_sections(void) {
    static NSArray<NSDictionary *> *sections;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sections = @[
            @{
                @"title": @"核心",
                @"footer": @"WebKit 网络进程使用同一主引擎的轻量模式，只安装低层网络 Hook，不启动悬浮窗、Dump 或完整分析模块。此开关会影响所有 WebView，默认关闭。",
                @"rows": @[
                    @{ @"key": DH_FEATURE_MASTER, @"title": @"总开关",
                       @"detail": @"控制所有运行时捕获功能" },
                    @{ @"key": DH_FEATURE_WEBKIT_PROCESS, @"title": @"WebKit 网络进程",
                       @"detail": @"注入 com.apple.WebKit.Networking，捕获跨进程流量" },
                ],
            },
            @{
                @"title": @"网络",
                @"footer": @"WebKit 网络进程开关需要同时开启“网络抓包”。修改后请完全退出并重新打开目标 App；若仍未生效，请结束现有 WebKit 网络进程或注销桌面。已加载的进程不会热卸载引擎。",
                @"rows": @[
                    @{ @"key": DH_FEATURE_NETWORK, @"title": @"网络抓包",
                       @"detail": @"记录 NSURLSession、TLS、Socket 与 Network.framework 调用" },
                    @{ @"key": DH_FEATURE_WEBKIT_JS, @"title": @"WebKit JS 探针",
                       @"detail": @"记录目标 App 内 WKWebView 导航、脚本与消息桥" },
                ],
            },
            @{
                @"title": @"加密算法",
                @"rows": @[
                    @{ @"key": DH_FEATURE_DIGEST, @"title": @"摘要捕获",
                       @"detail": @"记录 MD5、SHA 等摘要算法调用" },
                    @{ @"key": DH_FEATURE_HMAC, @"title": @"HMAC 捕获",
                       @"detail": @"记录 HMAC 密钥、输入与输出" },
                    @{ @"key": DH_FEATURE_SYMMETRIC, @"title": @"对称加密捕获",
                       @"detail": @"记录 AES、DES、3DES、RC4 等调用" },
                    @{ @"key": DH_FEATURE_EVP, @"title": @"OpenSSL EVP 捕获",
                       @"detail": @"记录 EVP 流式加解密、AAD 与认证标签" },
                    @{ @"key": DH_FEATURE_ASYMMETRIC, @"title": @"非对称加密捕获",
                       @"detail": @"记录 RSA、EC 签名、验签与加解密" },
                    @{ @"key": DH_FEATURE_KDF, @"title": @"密钥派生捕获",
                       @"detail": @"记录 PBKDF2 等密钥派生调用" },
                ],
            },
            @{
                @"title": @"数据与环境",
                @"footer": @"全局开关与目标 App Web 控制台里的本地捕获开关同时生效；任意一层关闭，该类日志都不会记录。",
                @"rows": @[
                    @{ @"key": DH_FEATURE_KEYCHAIN, @"title": @"Keychain 捕获",
                       @"detail": @"记录 SecItem 查询、添加、更新与删除" },
                    @{ @"key": DH_FEATURE_FILE, @"title": @"文件行为",
                       @"detail": @"记录当前 App 沙盒内的文件访问行为" },
                    @{ @"key": DH_FEATURE_ENVIRONMENT, @"title": @"环境观测",
                       @"detail": @"记录 sysctl、uname、getenv、dlopen 等调用" },
                ],
            },
        ];
    });
    return sections;
}

@interface DHFeatureSettingsViewController ()
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *flags;
@end

@implementation DHFeatureSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"功能开关";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68;
    self.flags = DHReadFeatureFlags();
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.flags = DHReadFeatureFlags();
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (NSInteger)dh_feature_sections().count;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSDictionary *group = dh_feature_sections()[section];
    NSArray *rows = group[@"rows"];
    return (NSInteger)rows.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return dh_feature_sections()[section][@"title"];
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return dh_feature_sections()[section][@"footer"];
}

- (NSDictionary *)rowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *group = dh_feature_sections()[indexPath.section];
    NSArray *rows = group[@"rows"];
    return rows[indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"feature";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.numberOfLines = 1;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    }

    NSDictionary *row = [self rowAtIndexPath:indexPath];
    NSString *key = row[@"key"];
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = row[@"detail"];

    DHFeatureSwitch *toggle = [[DHFeatureSwitch alloc] initWithFrame:CGRectZero];
    toggle.featureKey = key;
    toggle.on = [self.flags[key] boolValue];
    BOOL masterOn = [self.flags[DH_FEATURE_MASTER] boolValue];
    toggle.enabled = [key isEqualToString:DH_FEATURE_MASTER] || masterOn;
    [toggle addTarget:self action:@selector(featureChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    cell.textLabel.enabled = toggle.enabled;
    cell.detailTextLabel.enabled = toggle.enabled;
    return cell;
}

- (void)featureChanged:(DHFeatureSwitch *)sender {
    BOOL requested = sender.isOn;
    NSError *error = nil;
    if (!DHWriteFeatureFlag(sender.featureKey, requested, &error)) {
        [sender setOn:!requested animated:YES];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"保存失败"
            message:error.localizedDescription ?: @"写入功能配置失败，请确认插件已正确安装。"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    self.flags = DHReadFeatureFlags();
    [self.tableView reloadData];
}

@end

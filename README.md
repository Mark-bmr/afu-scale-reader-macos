# AFU Scale Reader for macOS

AFU Scale Reader 是一个原生 macOS 后台读取器，用于连接兼容的阿福体脂秤，保存实时称重和秤实际返回的历史记录，并生成 Markdown 或 JSON 文件。

项目不需要厂商 App、手动蓝牙配对、Python 或第三方运行库。应用没有账户、遥测或网络上传功能；配置、日志和测量记录均由当前 macOS 用户管理。

> 本项目是社区维护的非官方兼容工具，与 AFU、Welland 或相关厂商没有隶属、授权或背书关系。体重之外的体成分结果均为消费级估算，仅供趋势参考，属于非医疗用途，不可用于诊断、治疗或用药决策。

## 功能与边界

- 自动发现并连接名称以 `AFU-WL` 开头的兼容设备。
- 默认实时会话在订阅通知后发送一次启用抗阻功能的 D0 配置，不依赖厂商 App 保持绑定。
- 在后台等待稳定测量，并保持当前 BLE 会话以接收连续称重；连接由秤自然结束。
- 默认实时模式只保存实时结果，不会把秤内旧历史误写成当前称重。
- 支持 Markdown 表格和结构化 JSON 输出。
- 显式历史同步使用秤内时间区分记录，并抑制同一记录的重复上报。
- 在本机维护受保护的测量副本，用户输出丢失时可以安全恢复。

历史同步取决于体脂秤固件实际发送的数据。读取器会保存收到的每一条不同历史记录，但不能读取设备没有通过蓝牙公开的数据；部分固件可能只返回最近一条缓存记录。Mac 睡眠时也无法保证捕获短暂的蓝牙广播。

## 系统要求

- macOS 13 Ventura 或更高版本
- 支持 Bluetooth Low Energy 的 Mac
- Xcode Command Line Tools 和 Swift 6 工具链
- 一台使用 FFB0/FFB1/FFB2 服务特征的兼容体脂秤

如尚未安装命令行工具，可运行：

```bash
xcode-select --install
```

## 兼容型号

- 已验证：`AFU-WL-TZ-A1`
- 可能兼容：广播名称以 `AFU-WL` 开头，并采用 FFB0 服务、FFB1 写入特征和 FFB2 通知特征的型号

同一品牌的其他型号可能使用不同协议。程序会忽略名称或蓝牙特征不匹配的设备。

## 安装

在“终端”中运行：

```bash
git clone https://github.com/Mark-bmr/afu-scale-reader-macos.git
cd afu-scale-reader-macos
./scripts/install.sh
```

首次安装会询问：

1. 生理性别
2. 身高
3. 出生日期
4. 输出格式（`md` 或 `json`）
5. 输出文件路径
6. 是否启用 debug 日志

建议保持 debug 关闭。路径输入会按普通文本处理，不要额外加入引号或用于 shell 转义的反斜杠；不确定时直接回车使用默认路径。

macOS 首次提示时，请允许 “AFU Scale Reader” 使用蓝牙。如果选择了受保护目录，请同时允许该 App 访问对应文件夹。安装器若提示无法注册后台任务，请在普通“终端”App 中重新运行 `./scripts/install.sh`。

更新已安装版本：

```bash
git pull --ff-only
./scripts/install.sh
```

安装脚本会保留现有配置和测量记录。

## 使用

安装完成后无需保持终端窗口打开。确保 Mac 已登录且蓝牙已开启，然后完成一次完整称重；读取器会在结果稳定后写入记录。

常用位置：

- App：`~/Applications/AFU Scale Reader.app`
- 配置、私有测量副本和日志：`~/Library/Application Support/AFUScaleReader/`
- 用户输出：首次配置时选择的 `.md` 或 `.json` 文件

查看后台任务：

```bash
launchctl print "gui/$(id -u)/io.github.mark-bmr.afuscalereader"
```

实时查看日志：

```bash
tail -f "$HOME/Library/Application Support/AFUScaleReader/AFUScaleReader.log"
```

普通日志不会记录健康数值、文件路径、设备标识或原始蓝牙数据。debug 日志可能包含敏感排障信息，不要直接上传到公开 Issue。

### 手动同步秤内历史

历史握手与实时称重分开，避免后台读取器在每次称重时反复请求旧记录。需要同步秤内历史时，先停止后台任务，再以前台模式运行：

```bash
launchctl bootout "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/io.github.mark-bmr.afuscalereader.plist" 2>/dev/null || true
"$HOME/Applications/AFU Scale Reader.app/Contents/MacOS/AFUReader" --sync-history
```

完成后按 `Control-C` 退出，并恢复后台实时读取器：

```bash
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/io.github.mark-bmr.afuscalereader.plist"
```

## 输出格式

Markdown 输出适合直接阅读或导入 Obsidian；JSON 输出适合后续脚本处理。记录包含：

- 测量时间和体重
- BMI 与消费级体成分估算
- 秤提供的原始阻抗码
- 算法版本和必要的去重元数据

输出不会保存完整蓝牙帧、设备名称、peripheral UUID 或 RSSI。体成分算法、适用范围和局限见 [体成分算法说明](docs/body-composition-algorithm.md)。

## 隐私

应用仅在本机处理数据，没有网络请求或自动上传功能。默认日志不包含测量细节，配置和测量文件仅对当前用户开放。

如果输出路径位于 iCloud Drive、Dropbox、OneDrive、NAS 或其他同步目录，文件可能按照对应服务的规则离开本机。详细的数据字段、日志范围、保留和删除说明见 [PRIVACY.md](PRIVACY.md)。

仓库中的 `config.example.json` 只包含明确标记的合成示例，不能作为真实配置使用。请勿把真实配置、测量文件或 debug 日志提交到仓库或公开 Issue。

## 卸载与删除数据

卸载 App 和后台任务：

```bash
./scripts/uninstall.sh
```

卸载脚本会保留配置和健康数据，避免误删历史记录。若要彻底删除数据，请先确认用户输出位置，再按照 [PRIVACY.md](PRIVACY.md) 的清理清单分别删除应用私有目录、用户输出和同步服务中的副本。

## 开发与验证

```bash
swift test --disable-sandbox
swift build --disable-sandbox -c release
bash scripts/check-public-repo.sh
```

项目使用 Swift、Foundation 和 macOS CoreBluetooth，不包含第三方包依赖。安全问题请通过 [GitHub 私密安全报告](https://github.com/Mark-bmr/afu-scale-reader-macos/security/advisories/new) 提交，不要附带真实健康数据。

## 许可证

代码以 [MIT License](LICENSE) 发布；独立实现与第三方参考说明见 [NOTICE](NOTICE)。

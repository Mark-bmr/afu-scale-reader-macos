# AFU Scale Reader for macOS

一个原生、开源的 macOS 后台读取器：自动连接名称以 `AFU-WL` 开头的兼容体脂秤，读取稳定称重，计算消费级体成分趋势，并保存为 Markdown 或 JSON。

项目不需要厂商 App、手动蓝牙配对、Python 或第三方运行库。应用本身没有网络请求、遥测或云端账户；配置、日志和测量记录都由当前 macOS 用户控制。

> 本项目是社区维护的非官方兼容工具，与 AFU、Welland 或相关厂商没有隶属、授权或背书关系。所有体成分结果仅供非医疗用途，不可用于诊断、治疗或用药决策。

## 系统要求

- macOS 13 Ventura 或更高版本
- 带有 Bluetooth Low Energy 的 Mac
- Xcode Command Line Tools（提供 Swift 6 工具链）
- 一台广播名称以 `AFU-WL` 开头、使用 FFB0/FFB1/FFB2 服务特征的兼容体脂秤

## 兼容型号

- 已验证：`AFU-WL-TZ-A1`
- 可能兼容但尚未逐台验证：广播名称以 `AFU-WL` 开头，并采用 FFB0 服务、FFB1 写入特征和 FFB2 通知特征的型号

同一品牌的其他型号不一定使用相同协议。若设备名称或 GATT 特征不同，程序会忽略它，不会仅因附近设备也提供 FFB0 服务就连接。

## 安装

在“终端”中运行：

```bash
git clone https://github.com/Mark-bmr/afu-scale-reader-macos.git
cd afu-scale-reader-macos
./scripts/install.sh
```

安装器会先构建 release 可执行文件。如果是第一次安装，它会询问：

1. 生理性别（`male` / `female`）
2. 身高（厘米）
3. 出生日期（`YYYY-MM-DD`，当前年龄须为 18–80 岁）
4. 输出格式（`md` / `json`）
5. 输出文件路径（可直接回车使用默认位置）
6. 是否开启包含测量细节的 debug 日志（默认关闭）

任何输入中断、字段非法、扩展名不匹配或目标文件不属于本程序，安装都会停止；现有 App 和登录任务不会被替换。配置通过重新加载和存储归属校验后，安装器才会组装临时签名的 App、注册 LaunchAgent 并启动。

macOS 首次询问时，请允许 “AFU Scale Reader” 使用蓝牙。如果后台任务因调用环境的沙箱限制无法注册，请在普通“终端”App 中重新执行安装命令。

## 使用

安装后无需保持终端窗口打开。确保 Mac 已登录、蓝牙开启，然后站上体脂秤；读取器会等待连续稳定样本并写入一次记录。Mac 睡眠期间不能保证捕获秤的短暂广播。

常用位置：

- App：`~/Applications/AFU Scale Reader.app`
- 私有配置：`~/Library/Application Support/AFUScaleReader/config.json`
- 私有镜像：同目录下的 `measurements.md` 或 `measurements.json`
- 轮转日志：同目录下的 `AFUScaleReader.log`，最多 1 MiB，保留 3 个备份
- 用户输出：首次配置时选择的 `.md` 或 `.json` 文件

配置、镜像、日志和输出文件都以 `0600` 权限写入。输出与私有镜像包含相同的随机 `store_id`；程序不会覆盖没有正确管理标记的非空文件。

查看后台任务和日志：

```bash
launchctl print "gui/$(id -u)/io.github.mark-bmr.afuscalereader"
tail -f "$HOME/Library/Application Support/AFUScaleReader/AFUScaleReader.log"
```

手动校验配置与存储归属：

```bash
"$HOME/Applications/AFU Scale Reader.app/Contents/MacOS/AFUReader" \
  --validate-config \
  --config "$HOME/Library/Application Support/AFUScaleReader/config.json"
```

## 输出格式

Markdown 是便于直接阅读或导入 Obsidian 的表格；JSON 使用带版本的 `{schema, store_id, measurements}` 结构，适合后续脚本处理。两种格式都包含时间、体重、原始阻抗码、算法版本和计算出的体成分指标，但不会持久化蓝牙原始帧、设备名、peripheral UUID 或 RSSI。

下面是完全合成的 Markdown 示例，不对应任何真实人物或设备采集：

| 时间 | 体重 (kg) | BMI | 内脏脂肪 | 体脂率 (%) | 脂肪量 (kg) | 肌肉率 (%) | 肌肉量 (kg) | 体水分率 (%) | 体水分量 (kg) | 蛋白质占比 (%) | 蛋白质含量 (kg) | 骨量占比 (%) | 骨量 (kg) | 骨骼肌量 (kg) | 骨骼肌率 (%) | 皮下脂肪率 (%) | 皮下脂肪量 (kg) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2025-01-02 08:00:00 | 70.00 | 22.86 | 10.40 | 19.38 | 13.56 | 76.52 | 53.57 | 58.86 | 41.20 | 17.67 | 12.37 | 4.10 | 2.87 | 28.18 | 40.25 | 13.95 | 9.77 |

体脂率采用 `afu-cun-bae-v2` 的 CUN-BAE 成人统计模型；原始阻抗码目前不作为物理欧姆值参与计算。公式、适用年龄和局限见 [体成分算法说明](docs/body-composition-algorithm.md)。

## 隐私

应用仅在本机处理数据。默认日志只写固定流程事件，不记录路径、体重、阻抗、原始帧或设备标识。只有在配置时明确选择 debug，日志才可能包含排障所需的测量和设备细节。

如果把输出路径选在 iCloud Drive、Dropbox、OneDrive 或其他同步目录，文件会按照该服务的规则离开本机；这是用户选择的同步边界，不是本应用发起的上传。完整字段、保留和删除说明见 [PRIVACY.md](PRIVACY.md)。

`config.example.json` 只含合成值并带有 `synthetic_example: true`，程序会明确拒绝把它当作真实配置。

## 卸载与删除数据

移除 App 和登录任务，同时保留健康数据：

```bash
./scripts/uninstall.sh
```

如需彻底删除，请先查看配置中的 `output_path` 并确认目标，再分别删除：

```bash
rm -rf "$HOME/Library/Application Support/AFUScaleReader"
rm -f "/你在配置时选择的/measurements.md"
```

JSON 用户把最后一条命令改为自己的 `.json` 输出路径。卸载器故意不自动删除这些文件，避免误删健康历史。

## 开发与验证

```bash
swift test --disable-sandbox
swift build --disable-sandbox -c release
bash scripts/check-public-repo.sh
```

项目只使用 Swift 标准库、Foundation 和 macOS CoreBluetooth，无第三方包依赖。安全问题请按 [SECURITY.md](SECURITY.md) 私密报告。

## 许可证

代码以 [MIT License](LICENSE) 发布；独立实现与第三方参考说明见 [NOTICE](NOTICE)。

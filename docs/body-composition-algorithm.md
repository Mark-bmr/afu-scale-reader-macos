# 体成分算法评估与 v2 口径

## 结论

AFU 帧第 8-9 字节当前只能确认是一个无符号原始码，不能确认单位是 Ω。项目不会把该原始码直接代入要求物理阻抗的通用 BIA 公式。

`afu-cun-bae-v2` 使用不依赖 ADC 的 CUN-BAE 成人体脂公式。该数值用于个人趋势观察，不代替医院检查，也不保证与厂商 App 完全一致。

## 协议与算法参考

下列项目用于核对 BLE 协议事实和候选算法输入契约：

- [carl-chang/afu_scale](https://github.com/carl-chang/afu_scale)
- [QINZY8/afu-ha](https://github.com/QINZY8/afu-ha)
- [maoziban/smart-body-scale-IOS](https://github.com/maoziban/smart-body-scale-IOS)
- [maoziban/smart-body-scale-android](https://github.com/maoziban/smart-body-scale-android)
- [BodyMiScale](https://github.com/dckiller51/bodymiscale)
- [openScale](https://github.com/oliexdev/openScale)

本项目没有复制 openScale 的 GPL 源码表达；v2 依据公开论文中的数学式独立实现。协议常量、字段偏移和观测到的字节含义作为互操作事实记录。

## CUN-BAE 主公式

来源为 Gómez-Ambrosi 等人的 CUN-BAE 研究：开发队列 6,510 人，另有 1,149 人验证队列，年龄范围 18-80 岁。论文入口：[PubMed PMID 22179957](https://pubmed.ncbi.nlm.nih.gov/22179957/)，DOI：[10.2337/dc11-1334](https://doi.org/10.2337/dc11-1334)。

令 `S = 0` 表示男性、`S = 1` 表示女性：

```text
体脂率 = -44.988
       + 0.503 × 年龄
       + 10.689 × S
       + 3.172 × BMI
       - 0.026 × BMI²
       + 0.181 × BMI × S
       - 0.020 × BMI × 年龄
       - 0.005 × BMI² × S
       + 0.00021 × BMI² × 年龄
```

程序把输出限制在 5%-55%，并拒绝为 18 岁以下或 80 岁以上用户生成这套体成分估算。研究人群以白人成人为主，这是已知局限。

## 合成算例

以下输入完全为文档构造，不对应任何真实人物或设备记录：男性、35 岁、175 cm、70.00 kg、原始码 800。BMI 为 22.8571，CUN-BAE 体脂率为 19.38%。原始码不参与 v2 体成分计算。

## 其余字段的 v2 定义

体脂率确定后，其他字段采用同一条质量守恒链：

```text
脂肪量 = 体重 × 体脂率
去脂体重 = 体重 − 脂肪量
体水分量 = 去脂体重 × 0.73
骨量估算 = 体重 × 男 0.041 / 女 0.036，限制到 1.5-5.5 kg
肌肉量 = 去脂体重 − 骨量
蛋白质含量 = 去脂体重 − 体水分量 − 骨量
骨骼肌量 = 肌肉量 × 0.526
皮下脂肪率 = 体脂率 × 0.72
```

脂肪量、体水分量、蛋白质含量和骨量之和恒等于体重。骨量、骨骼肌、皮下脂肪、蛋白质及内脏脂肪指数仍是消费级估算。

## 数据与版本策略

- 新记录写入 `algorithm = afu-cun-bae-v2`、`mode = anthropometric`。
- 原始码只用于协议研究和去重，不参与 v2 计算。
- 已有记录不自动重算；算法版本用于区分历史口径。
- 如果未来取得厂商标定曲线或物理阻抗，将新增算法版本，不静默改变 v2。

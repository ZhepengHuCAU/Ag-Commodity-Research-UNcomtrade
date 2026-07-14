# UN Comtrade 自动下载 skill：使用说明

这个 skill 用于自动下载 UN Comtrade 的商品贸易数据，并同时生成核验用的国家排名图与指定国家进出口时间序列图。适合研究者按 HS 编码、年份或月份、报告国、伙伴国和贸易流向批量提取数据。

## 安装

将文件夹 `uncomtrade-downloader` 复制到 Codex 的 skills 目录：

```text
%USERPROFILE%\.codex\skills\uncomtrade-downloader
```

重新打开 Codex 或新建一个任务后，可直接在对话中提及 `$uncomtrade-downloader`。

如不安装，也可以在 Windows PowerShell 中直接运行：

```powershell
& '.\uncomtrade-downloader\scripts\Download-UnComtrade.ps1' -HsCode 151800 -Period '2024,2025' -Frequency A -Reporters 'CHN,USA' -Partners all -Flows 'M,X'
```

## 对话示例

```text
使用 $uncomtrade-downloader 下载 HS 151800 在 2020-2025 年的年度数据，报告国为中国、美国和马来西亚，伙伴国为全部，下载进口和出口，并为中国生成进出口时间序列图。
```

```text
使用 $uncomtrade-downloader 下载 HS 271019 的 2025 年月度数据，报告国为中国，伙伴国为美国和欧盟，下载进口数据。
```

## 参数

| 参数 | 含义 | 示例 |
| --- | --- | --- |
| `HsCode` | 一个或多个 HS 商品编码，以逗号分隔 | `151800`、`151800,151790` |
| `Period` | 年度用 `YYYY`；月度用 `YYYYMM`，以逗号分隔 | `2023,2024,2025`、`202501,202502` |
| `Frequency` | `A`=年度；`M`=月度 | `A` |
| `Reporters` | 报告国：`all`、ISO3 代码、名称或 M49 代码 | `CHN,USA`、`EUR`、`all` |
| `Partners` | 伙伴国：`all`、`world`、ISO3 代码或 M49 代码 | `all`、`USA`、`EUR`、`world` |
| `Flows` | `M`=进口；`X`=出口；可同时选择 | `M,X` |
| `TimeSeriesReporter` | 为一个国家额外生成进出口时间序列图 | `CHN` |
| `IncludeLatestChinaValidationPeriod` | 默认中国核验图排除最新请求年份；此开关用于明确要求纳入最新年 | 不填；或加上该开关 |
| `QualityFilter` | 质量筛选：建议使用默认的 `reported-nonaggregate` | `reported-nonaggregate` |

报告国是提供统计数据的国家，伙伴国是该报告国申报的来源地或目的地。`World` 表示该报告国对全世界的总额。`EUR`（也可写 `EU` 或 `EU27`）表示 UN Comtrade 当前的 European Union 报告方代码。国家总量和前 10 排名图只使用 `partner=World` 记录，避免把双边明细相加后重复计算。UN Comtrade 常将 World 总额标记为 `IsAggregate=True` 或 `IsReported=False`；这并不表示该国没有报告，而是平台生成/标记总额的方式。脚本会保留该官方总额，并在 `reporter_world_total_summary.csv` 标出这两个字段。

## 输出文件

每次运行会新建一个带时间戳的结果文件夹，主要包括：

- `uncomtrade_raw_records.csv`：UN Comtrade 原始返回记录。
- `uncomtrade_standardized_records.csv`：统一列名后的可分析数据。
- `data_availability.csv`：本次提取前 UN Comtrade 已发布的数据集清单。
- `reporter_world_total_summary.csv`：报告国对世界总额的年度/月度汇总。
- `reporter_total_summary.csv`：作图与排名实际使用的报告国总额；优先采用 World 总额，若某指标为零或缺失则使用同国、同年、同流向的高质量双边记录之和，并注明方法。
- `top10_importers_*.csv` 与 `top10_exporters_*.csv`：前 10 大进口/出口国排行榜。
- `top10_importers_*.svg` 与 `top10_exporters_*.svg`：按重量和金额生成的柱状图。
- `selected_reporter_import_export_validation_timeseries.csv`：指定国家用于核验的进出口时间序列。
- `chn_import_export_validation_timeseries_*.svg`：以中国为例的重量和金额核验图；默认自动排除最新请求年份并在图上说明。其他国家会改用对应 ISO3 文件名。
- `run_metadata.json`：提取日期、参数、记录数和质量筛选条件。
- `download_errors.csv`：未成功下载的报告国；若文件存在，不能将其误认为零贸易。
- `empty_result_reporter_periods.csv`：重试后仍返回空结果的报告国-时期；可能是真正无该 HS 数据，也可能是网站暂时未返回，不能直接视为零贸易。

## 与其他来源核对时的原则

先核对“口径”，再比较数字：报告国、进口或出口、伙伴国范围、HS 分类版本、年度/月度、净重或数量、贸易金额口径都要一致。时间序列图采用 `partner=World` 的报告国总额，最适合与海关统计、政府年报或另一套数据库的同口径序列逐年比对。

UN Comtrade 可能在后续补报或修订数据，所以应保存原始文件和 `run_metadata.json`，并在论文或报告中记录下载日期。无数据、下载错误或空结果不等于贸易额为零。脚本默认在各国请求之间暂停 0.5 秒，并对空结果重试一次；同时每 20 次请求刷新一次网站会话令牌。大范围下载时不要把该间隔调得过低。

若前十图上方出现覆盖提示，图仅代表“成功回传的报告国-时期”中的前十，而不是完整世界排名。应按照 `empty_result_reporter_periods.csv` 对关键国家单独重新下载，再做正式全球比较。

## 使用范围与限制

该工具使用当前 UN Comtrade Plus 网站的数据服务，无需个人 API key 即可完成针对性下载。`Reporters=all` 会逐国发送请求，可能需要几分钟；大规模、长期生产性下载应优先使用 UN Comtrade 的订阅 API 或 Bulk files。UN Comtrade 的网站接口和可用数据会更新，重复运行时应以新输出的 `data_availability.csv` 和 `run_metadata.json` 为准。

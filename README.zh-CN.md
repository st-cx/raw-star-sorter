# RAW Star Sorter · RAW 星级归档工具

简体中文 · [English](README.md)

在 Adobe Bridge、Lightroom 或 Camera Raw 中给 JPG 打星，自动将对应的 RAW 文件归入星级文件夹。

这是一个面向 Windows 的 PowerShell 选片工具包。JPG 始终留在 `matched_jpg` 中，对应的 RAW 和 XMP 自动进入 `0～5` 文件夹。默认处理尼康 NEF，也可以通过参数指定其他 RAW 扩展名。

## 功能

- 按基本文件名匹配 RAW 与 JPG/JPEG，扩展名不区分大小写。
- 优先读取 Adobe 的 `XMP:Rating`，缺失时兼容 `EXIF:Rating`。
- 根据照片星级自动移动对应 RAW/XMP，无需手动搬动 JPG。
- 改星并保存后重新运行，自动调整已经归类的 RAW 文件。
- 提供执行前预览和整批冲突检查；单张照片移动失败时尝试撤回该张照片的操作。
- 可选：将 JPG 的指定标签同步到 RAW 和已有 XMP 侧车文件。

照片处理全部在本机完成。脚本不会上传照片，也不会连接在线服务。

## 环境与安装

- Windows，使用 **Windows PowerShell 5.1** 或 **PowerShell 7**。BAT 入口调用 Windows PowerShell 5.1。
- 读取星级、写入元数据需要 **ExifTool**。日常使用不需要 Python；Python 3.10 及以上版本仅用于运行测试。

1. [下载源码 ZIP](https://github.com/st-cx/raw-star-sorter/archive/refs/heads/main.zip) 并解压，或克隆仓库：

   ```powershell
   git clone https://github.com/st-cx/raw-star-sorter.git
   ```

2. 从 [ExifTool 官网](https://exiftool.org/) 下载工具。使用 Windows 便携版时，将 `exiftool(-k).exe` 改名为 `exiftool.exe`，保留旁边的整个 `exiftool_files` 文件夹，按以下结构放置：

   ```text
   toolkit/
     00-选片工具.bat
     tools/
       exiftool/
         exiftool.exe
         exiftool_files/
   ```

   也可以使用系统 `PATH` 中的 `exiftool`。直接运行 PowerShell 脚本时，可通过 `-ExifToolPath 'D:\ExifTool\exiftool.exe'` 指定工具位置。ExifTool 独立分发并使用其自身许可证，本仓库不包含它的程序文件。详见[依赖安装说明](toolkit/tools/README.md)。

3. 移动照片或写入元数据前，保留一份独立备份。首次使用先运行预览。

## 快速上手

把**照片批次的根目录**拖到 `toolkit/00-选片工具.bat` 上。菜单及处理提示为中文。

1. 选择 **2：匹配分类**。同名 RAW 与 JPG/JPEG 分别进入 `matched_nef`、`matched_jpg`；没有对应 JPG 的 RAW 进入 `unmatched_nef`。XMP 跟随 RAW。只扫描所选目录的这一层。
2. 在 Adobe Bridge / Lightroom / Camera Raw 中打开 `matched_jpg`，给其中的 **JPG** 打星，并**把星级保存到照片元数据**。Lightroom 使用“元数据 → 将元数据保存到文件”（Windows 通常为 `Ctrl+S`）。只保存在 Lightroom 目录数据库中的评分无法被读取。
3. 选择 **3：预览按 JPG 星级自动归类**，检查各星级数量、缺失 RAW 和冲突。
4. 选择 **4：按 JPG 星级自动归类 NEF/XMP**。同名 RAW 与 XMP 自动进入 `0～5` 文件夹，需要的文件夹会自动创建。JPG 全程留在 `matched_jpg`。
5. 如需把星级和其他标签写入 RAW，先选 **5：预览标签同步**，再选 **6：执行标签同步**。已有 XMP 侧车也会同步。

菜单 **1** 用于提前创建六个星级文件夹，可跳过。

```text
照片批次根目录/
  0/ ... 5/       按 JPG 星级归类的 RAW 和 XMP
  matched_jpg/    用于打星的 JPG，始终留在这里
  matched_nef/    尚未归类的 RAW，包括被标记为“拒绝”的照片
  unmatched_nef/  没有对应 JPG 的 RAW
```

### 星级规则

| JPG 元数据 | 处理方式 |
| --- | --- |
| 未评分，或 `0` | 对应 RAW/XMP 进入 `0` |
| 整数 `1～5` | 对应 RAW/XMP 进入该数字文件夹 |
| Adobe“拒绝”标记 `-1` | 跳过，RAW/XMP 保持当前位置 |
| 其他星级值、JPG 无法读取，或存在同名冲突 | 在移动前停止整批操作 |

Adobe XMP 星级优先于 EXIF 星级。自动归类只读取 **JPG 文件内部已保存的星级**，不会采用 RAW、XMP 侧车、外部目录数据库中的评分，也不会把旗标或颜色标签当作星级。

改星并保存后，再运行 **3 → 4** 即可。工具会同时查找 `matched_nef` 和 `0～5` 中的 RAW，调整归类并跳过位置已正确的文件，不扫描 `unmatched_nef`。

## PowerShell 用法

在 `toolkit` 目录运行，使用 `-Path` 指定照片批次：

```powershell
# 预览匹配，再执行分类
.\photo-sort.ps1 -Path 'D:\Photos\Trip' -DryRun
.\photo-sort.ps1 -Path 'D:\Photos\Trip' -NoConfirm

# 读取 JPG 星级，预览后自动归类 RAW/XMP
.\sort-by-rating.ps1 -Path 'D:\Photos\Trip' -DryRun
.\sort-by-rating.ps1 -Path 'D:\Photos\Trip'

# 可选：预览标签同步；写入时保留修改前副本
.\sync-tags-to-nef.ps1 -Path 'D:\Photos\Trip' -RatingFromFolder -DryRun
.\sync-tags-to-nef.ps1 -Path 'D:\Photos\Trip' -RatingFromFolder -KeepBackup
```

如果本机限制脚本执行，可以仅对本次进程指定执行策略：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\sort-by-rating.ps1 -Path 'D:\Photos\Trip' -DryRun
```

不传 `-Path` 时，脚本默认处理自身所在目录。工具包与照片分开放置时，使用主菜单的拖入目录方式，或显式指定 `-Path`。

### 常用参数

| 脚本 | 参数 |
| --- | --- |
| `photo-sort.ps1` | `-Copy`、`-IncludeUnmatchedRef`、`-NoConfirm`、`-SourceExt arw`、`-SidecarExt ''` |
| `sort-by-rating.ps1` | `-RawExt arw -RawSourceDir matched_arw`、`-JpgSourceDir`、`-SidecarExt ''`、`-ExifToolPath` |
| `sync-tags-to-nef.ps1` | `-RawExt`、`-BatchSize 100`、`-KeepBackup`、`-KeepMissingTags`、`-SkipSidecars`、`-RatingFromFolder`、`-ExifToolPath` |

各脚本均支持 `-DryRun` 预览和 `-PassThru` 返回统计对象；`-Verbose` 显示详细操作。使用其他 RAW 格式时，匹配、归类、标签同步三个步骤的扩展名和来源目录需保持一致。

旧 `star-folder-swap.ps1` 保留为兼容入口，适合处理此前已经手动放进星级文件夹的 JPG。主菜单 **3/4** 使用新的自动归类逻辑。

## 标签同步

自动归类只移动文件，不改写照片元数据。标签同步是单独的可选步骤。

同步范围为星级、颜色标签、普通/层次关键字、标题、描述、作者、版权及 IPTC 关键字；不复制相机、曝光或 Camera Raw 调色参数。已有 XMP 侧车也会更新，可用 `-SkipSidecars` 关闭。

菜单使用 `-RatingFromFolder`：由 `0～5` 文件夹确定星级，其他指定标签来自对应 JPG。直接运行脚本且不传此参数时，星级也来自 JPG 元数据。

默认情况下，JPG 缺失的指定字段会清除目标中的相应旧值；加 `-KeepMissingTags` 可保留它们。默认原地更新，不保留 `_original` 副本；加 `-KeepBackup` 可保留修改前副本。确认成功后恢复原文件修改时间，并生成逐张记录结果的 CSV。失败或未确认的写入会返回错误。

## 行为与边界

- 不用不同内容覆盖同名文件。多个同名 RAW、多个同名 JPG/JPEG 来源或目标冲突，会在移动前阻止执行。
- 移动失败时尝试撤回当前照片组；此前已完成的照片保留归类结果。处理问题后可重跑，整批操作并非一次不可分割的事务。
- “拒绝”表示跳过，不会删除照片，也不会把已经归类的 RAW 自动移回。
- RAW、JPG 和 XMP 应保持相同基本文件名；工具不按拍摄时间或图像内容匹配。
- 星级文件夹固定使用数字 `0～5`，不依赖 Windows 的显示语言。

## 运行测试

在 Windows 中安装测试依赖，并准备 ExifTool：

```powershell
python -m pip install -r requirements-test.txt
python tests/test_workflow.py --exiftool 'D:\ExifTool\exiftool.exe'

# 可选：用 PowerShell 7 运行直接脚本调用
python tests/test_workflow.py --shell pwsh.exe --exiftool 'D:\ExifTool\exiftool.exe'
```

测试会在临时目录生成 JPG、用于核对字节的 RAW 占位文件，以及 TIFF/XMP 元数据样本，检查 0～5 星、未评分/拒绝、XMP 跟随、改星、重复运行、预览不变、缺失/重复文件、冲突、文件占用撤回、BAT 退出码和 PowerShell 5.1/7 兼容性。生成的 TIFF 样本也用于检查星级同步，不能代替所有相机型号的 RAW 标签写入验证。测试数据在运行时生成，不随仓库分发。

## 许可证

本工具包和测试使用 [MIT License](LICENSE)。ExifTool 等依赖保留各自的许可证。本项目与 Adobe、尼康没有隶属关系。

# RAW Star Sorter · RAW 星级归档工具

简体中文 · [English](README.md) · [下载最新版](https://github.com/st-cx/raw-star-sorter/releases/latest)

在 Adobe Bridge、Lightroom 或 Camera Raw 中给 JPG 打星，将对应 RAW 和 XMP 自动整理到 `0～5` 星级文件夹。JPG 留在原处，改星后可以重新整理。

Windows 本地工具；默认尼康 NEF，支持指定其他 RAW 扩展名。照片不会上传，脚本不连接在线服务。

## v1.1 更方便的选片流程

- **引导菜单**：双击选择照片目录，或把目录拖到入口；执行前先预览，再输入 Y 确认。
- **统一整理与同步**：使用同一次读取的 JPG 星级进行归类和可选标签同步，避免旧文件夹星级覆盖新评分。
- **撤销星级归类**：保存本地操作记录，支持逐次撤销与中断后的恢复。
- **完整清单**：导出 CSV，列出所有照片、星级来源、当前位置、计划目标和跳过原因。
- **区分未评分和 0 星**：菜单默认跳过没有星级标签的照片，也可切换为归入 0 星。
- **复制精选**：按最低星级导出 JPG、RAW+XMP 或两者，源照片保持原位。

## 安装

需要 Windows PowerShell 5.1 或 PowerShell 7，以及 [ExifTool](https://exiftool.org/)。日常使用不需要 Python。BAT 入口使用 Windows PowerShell 5.1。

1. [下载发行版 ZIP](https://github.com/st-cx/raw-star-sorter/releases/latest)，解压整个文件夹。
2. 下载 Windows 版 ExifTool，把 `exiftool(-k).exe` 改名为 `exiftool.exe`，保留完整的 `exiftool_files`，放置如下：

   ```text
   toolkit/
     00-选片工具.bat
     tools/exiftool/
       exiftool.exe
       exiftool_files/
   ```

   也可安装到 PATH，或为脚本指定 `-ExifToolPath 'D:\ExifTool\exiftool.exe'`。本仓库不分发 ExifTool，详见[依赖说明](toolkit/tools/README.md)。
3. 双击 `toolkit/00-选片工具.bat` 选择**照片批次根目录**。也可以将该目录拖到 BAT 上。

已有 v1.0 用户：用新版 `toolkit` 中的脚本更新原工具目录，保留 `tools/exiftool` 和照片；主菜单编号已重新安排。旧编号的独立 BAT 仍可用，05/06 现在预览或执行“归类并同步”，07 用于撤销。

## 日常使用

1. **首次匹配**：菜单 **1**。将同名 RAW、JPG/JPEG 分别移入 `matched_nef`、`matched_jpg`，没有对应 JPG 的 RAW 进入 `unmatched_nef`；XMP 跟随 RAW。只扫描这一层。
2. **打星并保存**：在 Adobe 软件中打开 `matched_jpg`，给 JPG 打星，然后保存到文件元数据。Lightroom 中使用“元数据 → 将元数据保存到文件”。仅存在目录数据库中的评分无法读取。
3. **整理**：菜单 **2** 查看预览，**3** 按星级移动 RAW/XMP；也可直接选 **3**，仍会先预览并确认。改星后重新执行即可。
4. **可选同步**：菜单 **4** 先整理，再将同一批照片的星级和指定标签写入 RAW 及已有 XMP。拒绝、缺失 RAW、按策略跳过的未评分照片不参与。
5. **后续操作**：**5** 导出完整 CSV；**6** 撤销上次归类；**7** 复制精选；**8** 切换未评分策略；**9** 更换目录；**0** 退出。

```text
照片批次/
  matched_jpg/       打星的 JPG，始终留在这里
  matched_nef/       待整理或跳过的 RAW/XMP
  unmatched_nef/     没有对应 JPG 的 RAW
  0/ ... 5/         按星级整理的 RAW/XMP
  .raw-star-sorter/  本批次操作记录（保留它才能撤销）
```

菜单及控制台提示为中文。匹配依赖相同基本文件名，不按拍摄时间或图像内容猜测。

## 星级与清单

| JPG 内部元数据 | 处理 |
| --- | --- |
| 没有星级字段 | 菜单默认跳过；可选 `Zero` 归入 0 |
| 明确 `0` | 归入 `0`，与没有评分分开统计 |
| 整数 `1～5` | 归入对应数字文件夹 |
| 拒绝 `-1` | 跳过，不删除，也不撤回先前归类 |
| 非法星级、损坏 JPG、同名歧义或目标冲突 | 移动前停止 |

优先读取 `XMP-xmp:Rating`，缺失时读取 `IFD0:Rating`。只读取 JPG/JPEG 内部保存的星级，不读取 Lightroom 数据库、RAW 或外部 XMP 的评分。旗标、颜色标签不能代替星级。

CSV 中的 `Status`：`Planned` 待归类、`AlreadySorted` 已在正确目录、`UnratedSkipped` 未评分跳过、`Rejected` 拒绝、`MissingRaw` 缺 RAW。`RatingSource` 说明 Adobe XMP、EXIF 或未评分。CSV 是**执行前计划**；不是每次移动的完成凭证。普通预览不写任何文件；显式导出清单时只新增 CSV，不覆盖已有文件。

## 撤销与中断

菜单 **6** 撤销最近一次尚未撤销的星级归类；再次使用可继续撤销上一轮。先检查全部路径，原位置被占用、文件丢失或路径越界时停止，不覆盖文件。撤销过程中被中断，可以重试。

- 撤销仅恢复 **RAW/XMP 的位置**，保留当前内容和后来做过的编辑。
- 不撤回首次匹配分类、标签编辑或精选复制；新建的空星级文件夹会保留。
- 同步产生的 `_original` 副本留在同步当时的目录，不跟随撤销移动。它们保存首次备份时的内容，已有副本不会被刷新。
- 归类失败时尝试撤回当前照片组，此前完成的照片可通过撤销恢复；整个批次不是一次不可分割的事务。
- 不要编辑 `.raw-star-sorter` 操作记录。照片根目录改名或搬家后，旧记录不能直接自动撤销。
- 同一批次的新整理/撤销互斥；使用期间不要同时在其他软件中移动文件。拒绝通过目录链接、联接点或符号链接处理照片。

操作记录不是照片备份，重要原片仍应保留独立备份。

## 精选导出

菜单 **7** 选择最低星级（默认 4）、JPG / RAW+XMP / 两者，以及一个**尚不存在**的新目标文件夹。必须先创建目标的上级目录。先预览、确认后复制，不要求先完成星级归类。仅导出已经保存明确星级的照片；JPG 模式允许没有 RAW 的照片。

复制先写到独立临时目录，全部成功后才出现最终目录。失败时说明临时目录位置供检查和清理，源文件不变。该功能不转格式、不缩图、不加水印。

## PowerShell 用法

在 `toolkit` 中运行：

```powershell
# 预览及整理；直接脚本默认 Zero，菜单默认 Skip
.\sort-by-rating.ps1 -Path 'D:\Photos\Trip' -UnratedAction Skip -DryRun
.\sort-by-rating.ps1 -Path 'D:\Photos\Trip' -UnratedAction Skip

# 使用同一次读取的星级整理并同步（保留缺失字段、_original 副本）
.\sort-by-rating.ps1 -Path 'D:\Photos\Trip' -UnratedAction Skip -SyncTags

# 完整计划；不移动照片，CSV 必须尚不存在
.\sort-by-rating.ps1 -Path 'D:\Photos\Trip' -DryRun -ReportPath 'D:\Photos\plan.csv'

# 撤销预览及执行
.\undo-last-sort.ps1 -Path 'D:\Photos\Trip' -DryRun
.\undo-last-sort.ps1 -Path 'D:\Photos\Trip'

# 复制 4 星以上的 RAW、XMP、JPG
.\export-selected.ps1 -Path 'D:\Photos\Trip' -Destination 'D:\Photos\精选' -MinRating 4 -Format Both
```

脚本支持 `-PassThru` 返回结果、`-Verbose` 显示更多详情。不指定 `-Path` 时，处理脚本所在目录；主菜单不指定目录时弹出选择框。执行策略受限时，可使用 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start.ps1`，不改变系统设置。

其他 RAW：首次匹配使用 `photo-sort.ps1 -SourceExt arw`；整理和导出使用 `-RawExt arw -RawSourceDir matched_arw`。菜单默认 NEF，其他格式使用脚本参数。

`-SidecarExt ''` 不处理侧车，联合同步时也不会写入 XMP。`-SyncTags` 仅接受 XMP 或关闭侧车；其他侧车扩展名可单独归类，但不能与联合同步一起使用。

## 标签同步的兼容选项

整理默认只移动；`-SyncTags` 才写标签。同步范围为星级、颜色标签、普通/层次关键字、标题、描述、作者、版权及 IPTC 关键字，不复制相机、曝光和 Camera Raw 调色设置。同步写入非事务操作，失败可能已经修改部分文件；检查结果 CSV 和备份后重试。

新统一入口默认保留源图中缺失字段对应的目标旧值、保留 `_original` 副本，生成逐张结果 CSV。成功后保留原修改时间。`sync-tags-to-nef.ps1` 作为高级兼容入口仍保留旧默认：缺失字段清除、无备份。可加 `-KeepMissingTags -KeepBackup`；另有 `-SkipSidecars`、`-BatchSize`、`-RatingFromFolder`。**只有显式使用 `-RatingFromFolder` 才让旧文件夹名称决定星级。**

`star-folder-swap.ps1` 保留为旧式手工 JPG 文件夹流程的兼容脚本，不参与新主菜单。

## 测试

```powershell
python -m pip install -r requirements-test.txt
python tests/test_workflow.py --exiftool 'D:\ExifTool\exiftool.exe'
python tests/test_workflow.py --shell pwsh.exe --exiftool 'D:\ExifTool\exiftool.exe'
```

测试生成临时 JPG、RAW 字节占位文件、TIFF/XMP 元数据样本，覆盖星级读取、改星、预览、冲突、文件占用、撤销/中断、路径边界、同步一致性、CSV、精选复制及菜单确认/取消。TIFF 写入验证不能代替所有相机型号的真实 RAW 写入验证。目录选择对话框由 Windows 提供，控制台流程以输入驱动测试。

## 许可证

[MIT](LICENSE)。ExifTool 保留自身许可证。本项目与 Adobe、尼康没有隶属关系。

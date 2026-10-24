# ExifTool dependency / ExifTool 依赖

ExifTool is not bundled in this repository. Download the Windows package from
[exiftool.org](https://exiftool.org/) and follow its
[installation instructions](https://exiftool.org/install.html).

Rename `exiftool(-k).exe` to `exiftool.exe` and keep the accompanying
`exiftool_files` directory intact. The expected portable layout is:

```text
toolkit/tools/exiftool/
  exiftool.exe
  exiftool_files/
```

Alternatively, use an `exiftool` application on `PATH` or pass
`-ExifToolPath 'D:\ExifTool\exiftool.exe'` to the rating sorter or metadata sync
script. The portable directory above takes precedence over `PATH`.

The toolkit was tested locally with ExifTool 13.59. ExifTool and its runtime
retain their own licenses; keep the license files from its distribution with
any copy you make.

---

本仓库不附带 ExifTool。从[官网](https://exiftool.org/)下载 Windows 版本，
将 `exiftool(-k).exe` 改名为 `exiftool.exe`，保留完整 `exiftool_files`，
按上面的目录结构放置。也可以使用 `PATH` 中的工具，或通过
`-ExifToolPath` 指定位置。本机使用 ExifTool 13.59 验证。
ExifTool 及运行时采用各自许可证，复制其程序时应保留原发行包的许可证文件。

# RAW Star Sorter

[简体中文](README.zh-CN.md) · English

Rate JPEGs in Adobe Bridge, Lightroom, or Camera Raw, then automatically sort the matching RAW files into star folders.

RAW Star Sorter is a Windows PowerShell toolkit for a JPEG-first photo workflow. JPEGs stay in `matched_jpg`; matching RAW files and XMP sidecars move into `0`–`5`. Nikon NEF is the default RAW format. Other RAW extensions can be configured.

## What it does

- Match RAW and JPG/JPEG files by their base filename, with case-insensitive extensions.
- Read saved Adobe `XMP:Rating`, falling back to `EXIF:Rating`.
- Move corresponding RAW/XMP files into their star folders without manually moving JPEGs.
- Reorganize previously sorted RAW files after you change a JPEG's rating.
- Preview the plan before changing files, check conflicts across the batch, and attempt to roll back the current photo's moves if an operation fails.
- Optionally copy selected JPEG metadata to RAW and existing XMP sidecars.

All photo processing runs locally. The scripts do not upload photos or contact a service.

## Requirements and setup

- Windows with Windows PowerShell **5.1**, or PowerShell **7**. The BAT launchers use Windows PowerShell 5.1.
- **ExifTool** for reading ratings and writing metadata. Python 3.10+ is only needed to run the tests.

1. [Download the repository](https://github.com/st-cx/raw-star-sorter/archive/refs/heads/main.zip) and extract it, or clone it:

   ```powershell
   git clone https://github.com/st-cx/raw-star-sorter.git
   ```

2. Get ExifTool from its [official website](https://exiftool.org/). For its Windows portable package, rename `exiftool(-k).exe` to `exiftool.exe` and keep `exiftool_files` beside the executable. Place them here:

   ```text
   toolkit/
     00-选片工具.bat
     tools/
       exiftool/
         exiftool.exe
         exiftool_files/
   ```

   An `exiftool` executable on `PATH` also works. Direct PowerShell calls accept `-ExifToolPath 'D:\ExifTool\exiftool.exe'`. ExifTool is distributed separately under its own license; it is not included in this repository. See [dependency setup](toolkit/tools/README.md).

3. Keep an independent backup of your photo batch before moving files or writing metadata. Start with the preview commands.

## Quick start

Drag your **photo batch folder** onto `toolkit/00-选片工具.bat`. The menu and console messages are in Chinese; the numbered steps are described below.

1. Choose **2** to match files. Paired RAW/JPEG files go into `matched_nef` and `matched_jpg`; RAW files without a matching JPEG go into `unmatched_nef`. XMP sidecars follow their RAW files. Only the selected folder's top level is classified.
2. Open `matched_jpg` in Adobe Bridge, Lightroom, or Camera Raw. Rate the **JPEG files** and save the ratings into the files' metadata. In Lightroom, use **Metadata → Save Metadata to File** (`Ctrl+S` on Windows). A rating kept only in a Lightroom catalog cannot be read by this tool.
3. Choose **3** to preview automatic sorting. Check the rating counts, missing RAW files, and conflicts.
4. Choose **4** to move matching RAW/XMP files into `0`–`5`. Required folders are created automatically. The JPEG files remain in `matched_jpg` throughout.
5. Optionally choose **5** to preview metadata synchronization, then **6** to write metadata to the RAW files and existing XMP sidecars.

Menu **1** creates all six star folders in advance and is optional.

```text
Photo batch/
  0/ ... 5/       RAW files and XMP sidecars, sorted by JPEG rating
  matched_jpg/    JPEGs used for rating; they stay here
  matched_nef/    RAW files not yet sorted, including rejected photos
  unmatched_nef/  RAW files without a matching JPEG
```

### Rating rules

| JPEG metadata | Result |
| --- | --- |
| No rating, or `0` | Move matching RAW/XMP to `0` |
| Integer `1`–`5` | Move matching RAW/XMP to that numbered folder |
| Adobe rejection marker `-1` | Skip; keep RAW/XMP at their current location |
| Other values, unreadable JPEGs, or conflicting filenames | Stop before moving any file in the batch |

Adobe XMP rating takes priority over EXIF rating. The automatic sorting step reads ratings embedded in JPEGs; it does not use ratings from RAW files, XMP sidecars, external catalogs, flags, or color labels.

After changing ratings and saving metadata, run **3 → 4** again. The sorter looks in both `matched_nef` and the star folders and skips files already in the right place. It does not scan `unmatched_nef`.

## PowerShell commands

Run from the `toolkit` directory. Use an explicit `-Path` for the photo batch:

```powershell
# Preview matching, then classify files
.\photo-sort.ps1 -Path 'D:\Photos\Trip' -DryRun
.\photo-sort.ps1 -Path 'D:\Photos\Trip' -NoConfirm

# Preview saved JPEG ratings, then sort matching RAW/XMP
.\sort-by-rating.ps1 -Path 'D:\Photos\Trip' -DryRun
.\sort-by-rating.ps1 -Path 'D:\Photos\Trip'

# Preview optional metadata synchronization; keep backups when writing
.\sync-tags-to-nef.ps1 -Path 'D:\Photos\Trip' -RatingFromFolder -DryRun
.\sync-tags-to-nef.ps1 -Path 'D:\Photos\Trip' -RatingFromFolder -KeepBackup
```

If local script execution is restricted, you can invoke a script using a process-scoped execution policy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\sort-by-rating.ps1 -Path 'D:\Photos\Trip' -DryRun
```

Without `-Path`, scripts target their own directory. When the toolkit stays separate from the photos, use drag-and-drop on the main menu or pass `-Path`.

### Options

| Script | Useful parameters |
| --- | --- |
| `photo-sort.ps1` | `-Copy`, `-IncludeUnmatchedRef`, `-NoConfirm`, `-SourceExt arw`, `-SidecarExt ''` |
| `sort-by-rating.ps1` | `-RawExt arw -RawSourceDir matched_arw`, `-JpgSourceDir`, `-SidecarExt ''`, `-ExifToolPath` |
| `sync-tags-to-nef.ps1` | `-RawExt`, `-BatchSize 100`, `-KeepBackup`, `-KeepMissingTags`, `-SkipSidecars`, `-RatingFromFolder`, `-ExifToolPath` |

All scripts support `-DryRun` and `-PassThru`. `-Verbose` displays more detail. With a different RAW extension, configure the classification, sorting, and metadata steps consistently.

The older `star-folder-swap.ps1` remains available for batches whose JPEGs were already moved into star folders by hand. The main menu's **3/4** entries use the automatic sorter.

## Metadata synchronization

Automatic sorting only moves files; it does not rewrite photo metadata. Metadata synchronization is a separate, optional step.

Synchronization copies ratings, color labels, keywords, hierarchical keywords, title, description, creator, copyright, and IPTC keywords. It does not copy camera/exposure tags or Camera Raw adjustment settings. Existing XMP sidecars are also updated unless `-SkipSidecars` is used.

The menu uses `-RatingFromFolder`: the `0`–`5` folder determines the rating, while the JPEG provides the other selected tags. Calling the script without this switch copies ratings from JPEG metadata.

By default, source fields that are missing are cleared from the destination's selected fields. Use `-KeepMissingTags` to retain them. By default, ExifTool updates files in place without `_original` backups; use `-KeepBackup` to keep those backups. The script restores file modification timestamps after confirmed success and writes a per-photo CSV result report. Failed or unconfirmed writes return an error.

## Behavior and limits

- Same-name files are never overwritten with different data. Ambiguous duplicate RAW files, duplicate JPG/JPEG sources, and conflicting destinations stop sorting before any moves.
- If a move fails, the tool attempts to undo that photo's moves. Photos completed earlier in the batch remain sorted; fix the problem and rerun. This is not a transaction across the entire batch.
- A rejection marker skips a photo; it does not delete it or move it back from a previous star folder.
- Keep the same base filename for each RAW, JPEG, and XMP pair. This toolkit does not match by capture time or image content.
- Star folders use names `0` through `5`. Their numeric names are independent of the Windows display language.

## Tests

On Windows, install the test dependency, make ExifTool available, and run:

```powershell
python -m pip install -r requirements-test.txt
python tests/test_workflow.py --exiftool 'D:\ExifTool\exiftool.exe'

# Optionally run the direct script calls with PowerShell 7
python tests/test_workflow.py --shell pwsh.exe --exiftool 'D:\ExifTool\exiftool.exe'
```

Tests generate temporary JPEGs, RAW byte sentinels, and TIFF/XMP metadata fixtures. They check ratings `0`–`5`, ungraded/rejected photos, XMP movement, changed ratings, repeated runs, preview preservation, missing/duplicate files, conflicts, file-lock rollback, BAT exit codes, and PowerShell 5.1/7 compatibility. Generated TIFF fixtures also check rating synchronization. They do not validate RAW metadata writes for every camera model. Test data is generated locally and is not included in the repository.

## License

The toolkit and tests are released under the [MIT License](LICENSE). ExifTool and other dependencies retain their respective licenses. This project is independent of Adobe and Nikon.

# RAW Star Sorter

English · [简体中文](README.zh-CN.md) · [Download](https://github.com/st-cx/raw-star-sorter/releases/latest)

Rate JPEGs in Adobe Bridge, Lightroom, or Camera Raw, then organize their matching RAW files and XMP sidecars into `0`–`5` star folders. JPEGs stay in place. Change ratings, save, and run again to update the organization.

A local Windows toolkit, defaulting to Nikon NEF with other RAW extensions available through script options. Photos never leave your computer; the scripts make no network requests.

## What's new in v1.1

- **Guided menu:** double-click to select a folder, or drag a folder onto the launcher. Preview changes and type Y to proceed.
- **One rating snapshot:** organization and optional metadata synchronization use the same JPEG ratings, so an old folder name cannot override a new rating.
- **Undo:** persistent local move history, successive undo, and recovery after interruption.
- **Complete CSV plan:** all photos, rating sources, current paths, planned destinations, and skip reasons.
- **Missing versus zero ratings:** the menu skips missing ratings by default; explicit zero remains a valid rating.
- **Selected copies:** export JPEGs, RAW+XMP, or both above a chosen star threshold without moving originals.

## Setup

Requires Windows PowerShell 5.1 or PowerShell 7 and [ExifTool](https://exiftool.org/). Python is only needed for tests. BAT launchers use Windows PowerShell 5.1.

1. [Download the release ZIP](https://github.com/st-cx/raw-star-sorter/releases/latest) and extract the entire folder.
2. Download ExifTool for Windows. Rename `exiftool(-k).exe` to `exiftool.exe`, keep the complete `exiftool_files` folder alongside it, and place both here:

   ```text
   toolkit/
     00-选片工具.bat
     tools/exiftool/
       exiftool.exe
       exiftool_files/
   ```

   Alternatively, put ExifTool on PATH or pass `-ExifToolPath 'D:\ExifTool\exiftool.exe'`. ExifTool is not bundled. See [dependency setup](toolkit/tools/README.md).
3. Double-click `toolkit/00-选片工具.bat` and select the **photo batch root**, or drag that folder onto the BAT file.

Upgrading from v1.0: replace toolkit scripts, preserving `tools/exiftool` and all photos. Main menu numbers have changed. Older numbered BAT launchers remain available; 05/06 now preview or execute organization plus synchronization, and 07 undoes the last organization.

## Everyday workflow

The menu and console messages are in Chinese. The menu numbers are:

1. **Initial matching:** preview, then move matching RAW/JPEG files into `matched_nef` / `matched_jpg`. RAW files without matching JPEGs go to `unmatched_nef`. XMP follows RAW. Only the selected directory level is scanned.
2. **Preview organization:** rate the JPEGs in `matched_jpg` using Adobe software and save metadata to the files first. Lightroom catalog-only ratings cannot be read.
3. **Organize RAW/XMP:** preview, confirm, and move files into the appropriate star folders. Repeat after saving new JPEG ratings.
4. **Organize and sync tags:** first organize, then write the captured ratings and selected JPEG metadata to eligible RAW files and existing sidecars. Rejected, missing-RAW, and skipped unrated photos are excluded.
5. **Export the complete CSV plan.**
6. **Undo the last star organization**, after preview.
7. **Copy selected photos** to a new destination.
8. **Toggle missing-rating handling:** skip / treat as zero.
9. **Choose another photo folder.** Use **0** to exit.

```text
photo-batch/
  matched_jpg/       JPEG rating sources, kept in place
  matched_nef/       RAW/XMP awaiting organization or skipped
  unmatched_nef/     RAW files without a JPEG match
  0/ ... 5/         Organized RAW/XMP files
  .raw-star-sorter/  Local move history; keep it for undo
```

Matching uses the same base filename, not capture time or image similarity.

## Ratings and reports

| Embedded JPEG rating | Behavior |
| --- | --- |
| Missing tag | Menu default: skip. Optional `Zero` policy sends it to `0`. |
| Explicit `0` | Move to `0`; counted separately from missing ratings. |
| Integer `1`–`5` | Move to that numeric folder. |
| Rejected `-1` | Skip; never delete or reverse an earlier organization. |
| Invalid rating, corrupt JPEG, ambiguous filename, destination conflict | Stop before moving. |

`XMP-xmp:Rating` takes precedence, with `IFD0:Rating` as fallback. Only embedded JPEG metadata is read. Lightroom catalogs, RAW ratings, external XMP ratings, flags, and color labels are not rating sources.

CSV `Status` values: `Planned`, `AlreadySorted`, `UnratedSkipped`, `Rejected`, and `MissingRaw`. `RatingSource` distinguishes Adobe XMP, EXIF, and missing metadata (`未评分`). This CSV is a **pre-execution plan**, not a completion receipt. Ordinary previews do not write files. Explicit report export creates only a new CSV and refuses to overwrite an existing file.

## Undo and interruption

Menu **6** reverses the most recent star organization that has not been undone. Repeat to step back through older operations. All reverse destinations are checked first; occupied original paths, missing files, or paths outside the batch stop undo without overwriting. Interrupted undo can be retried.

- Undo restores **RAW/XMP locations only**, retaining current contents and later edits.
- Initial matching, metadata edits, and selected copies are not undone. Newly created empty star folders remain.
- Synchronization's `_original` backups stay in the directory where they were created, including after undo. Existing backups are not refreshed; they retain the content from their first creation.
- A failed move attempts to roll back the current photo group. Earlier completed groups can be undone afterward; the whole batch is not one atomic transaction.
- Do not edit `.raw-star-sorter` history. Renaming or relocating the batch root prevents automatic use of its older history.
- New organization/undo operations are mutually exclusive per batch. Avoid moving files from other software during an operation. Linked directories, junctions, and symbolic links are refused.

Move history is not a photo backup. Keep independent backups of important originals.

## Export selected copies

Menu **7** asks for the minimum rating (default 4), JPEG / RAW+XMP / both, and a **new, nonexistent** destination folder. Its parent folder must already exist. Preview, confirm, and copy; prior star organization is not required. Only explicitly rated photos qualify. JPEG-only mode can export photos without a RAW match.

Copies are staged in a unique sibling directory; the final destination appears only after every copy succeeds. On failure, the temporary copy directory is reported for inspection and cleanup. Source files are unchanged. This feature does not resize, convert, or watermark images.

## PowerShell commands

Run from `toolkit`:

```powershell
# Direct sorter default is Zero for compatibility; the menu defaults to Skip
.\sort-by-rating.ps1 -Path 'D:\Photos\Trip' -UnratedAction Skip -DryRun
.\sort-by-rating.ps1 -Path 'D:\Photos\Trip' -UnratedAction Skip

# One rating snapshot for organization and sync; keeps missing fields and backups
.\sort-by-rating.ps1 -Path 'D:\Photos\Trip' -UnratedAction Skip -SyncTags

# Complete plan; no photo moves, CSV must not exist
.\sort-by-rating.ps1 -Path 'D:\Photos\Trip' -DryRun -ReportPath 'D:\Photos\plan.csv'

# Undo preview and execution
.\undo-last-sort.ps1 -Path 'D:\Photos\Trip' -DryRun
.\undo-last-sort.ps1 -Path 'D:\Photos\Trip'

# Copy 4- and 5-star RAW, XMP, and JPEG files
.\export-selected.ps1 -Path 'D:\Photos\Trip' -Destination 'D:\Photos\Selected' -MinRating 4 -Format Both
```

Scripts support `-PassThru` for result objects and `-Verbose` for details. Without `-Path`, processing scripts target their own directory; the main menu opens a folder picker. If execution policy blocks the launcher, use `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start.ps1` for that process only.

Other RAW formats: initial matching supports `photo-sort.ps1 -SourceExt arw`; organization/export support `-RawExt arw -RawSourceDir matched_arw`. The menu defaults to NEF; use script options for other formats.

`-SidecarExt ''` disables sidecar handling, including XMP writes during integrated synchronization. `-SyncTags` accepts XMP sidecars or disabled sidecars only; other extensions can be organized separately but cannot be combined with integrated synchronization.

## Metadata compatibility options

Organization moves files only unless `-SyncTags` is specified. Synchronization copies ratings, color labels, ordinary/hierarchical keywords, title, description, creator, copyright, and IPTC keywords. It does not copy camera/exposure tags or Camera Raw adjustments. Writes are not transactional: failures can leave some files modified. Inspect the result CSV and backups before retrying.

The new integrated entry preserves target values for fields absent in the JPEG, keeps `_original` backups, writes a per-photo result CSV, and retains modification timestamps after confirmed success. The advanced `sync-tags-to-nef.ps1` retains its legacy defaults: clear missing fields and omit backups. Add `-KeepMissingTags -KeepBackup` to change those defaults. Other options include `-SkipSidecars`, `-BatchSize`, and `-RatingFromFolder`. **Only explicit `-RatingFromFolder` uses folder names as ratings.**

`star-folder-swap.ps1` remains available for the old workflow with manually relocated JPEGs; the new menu does not use it.

## Tests

```powershell
python -m pip install -r requirements-test.txt
python tests/test_workflow.py --exiftool 'D:\ExifTool\exiftool.exe'
python tests/test_workflow.py --shell pwsh.exe --exiftool 'D:\ExifTool\exiftool.exe'
```

Tests generate temporary JPEGs, RAW byte sentinels, and TIFF/XMP fixtures. Coverage includes ratings, rerating, previews, conflicts, file locks, undo/interruption, path boundaries, sync consistency, CSV, selected copies, and menu confirmation/cancellation. TIFF metadata tests do not establish genuine RAW write compatibility for every camera model. The folder picker is supplied by Windows; console flows are tested with scripted input.

## License

[MIT](LICENSE). ExifTool retains its own license. This project is independent of Adobe and Nikon.

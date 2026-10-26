from __future__ import annotations

import argparse
import ctypes
import csv
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from PIL import Image


PROJECT_ROOT = Path(__file__).resolve().parents[1]
TOOLKIT = PROJECT_ROOT / 'toolkit'
EXIFTOOL = None
RUN_ROOT = None
SHELL = 'powershell.exe'


def ps_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def run_ps(script, root, *extra, check=True, shell=None):
    command = '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); & ' + ps_quote(script)
    command += ' -Path ' + ps_quote(root)
    if Path(script).name in ('sort-by-rating.ps1', 'sync-tags-to-nef.ps1', 'export-selected.ps1') and not (TOOLKIT / 'tools' / 'exiftool' / 'exiftool.exe').is_file():
        command += ' -ExifToolPath ' + ps_quote(EXIFTOOL)
    command += ''.join(' ' + (item if str(item).startswith('-') else ps_quote(item)) for item in extra)
    command += ' -PassThru | ConvertTo-Json -Compress'
    result = subprocess.run([shell or SHELL, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command],
                            capture_output=True, encoding='utf-8', errors='replace', timeout=45)
    if check and result.returncode:
        raise AssertionError(f'Command failed ({result.returncode}):\n{result.stdout}\n{result.stderr}')
    stats = [line for line in result.stdout.splitlines() if line.startswith('{')]
    return result, json.loads(stats[-1]) if stats else None


def run_exiftool(path, *options):
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', suffix='.args', delete=False) as arguments:
        arguments.write('\n'.join(['-charset', 'filename=UTF8', *options, str(path)]))
        argument_path = arguments.name
    try:
        environment = dict(os.environ, LC_ALL='C')
        result = subprocess.run([str(EXIFTOOL), '-@', argument_path], capture_output=True,
                                encoding='utf-8', errors='replace', env=environment, timeout=20)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result.stdout
    finally:
        Path(argument_path).unlink()


def write_tags(path, *tags):
    run_exiftool(path, '-overwrite_original', *tags)


def read_tags(path, *tags):
    return json.loads(run_exiftool(path, '-json', '-n', '-G1', *tags))[0]


def snapshot(root):
    return {str(path.relative_to(root)): (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mtime_ns)
            for path in root.rglob('*') if path.is_file()}


def photo_snapshot(root):
    return {path: data for path, data in snapshot(root).items() if '.raw-star-sorter' not in Path(path).parts}


def set_hidden(path):
    kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
    set_attributes = kernel32.SetFileAttributesW
    set_attributes.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32]
    set_attributes.restype = ctypes.c_int
    if not set_attributes(str(path), path.stat().st_file_attributes | 0x2):
        raise ctypes.WinError(ctypes.get_last_error())


def run_bat(filename, root):
    # A small CMD file follows the same quoting rules as the toolkit menu.
    launcher = RUN_ROOT / 'launcher-probe.cmd'
    tool_argument = '' if (TOOLKIT / 'tools' / 'exiftool' / 'exiftool.exe').is_file() else f' -ExifToolPath "{EXIFTOOL}"'
    command = ('@echo off\r\nchcp 65001 >nul\r\nsetlocal DisableDelayedExpansion\r\n'
               f'call "{TOOLKIT / filename}" -Path "{root}"{tool_argument}\r\n'
               'exit /b %errorlevel%\r\n')
    launcher.write_bytes(command.encode('utf-8'))
    return subprocess.run(['cmd.exe', '/d', '/c', 'launcher-probe.cmd'],
                          input=b'\r\n', capture_output=True, cwd=RUN_ROOT, timeout=45)


class RatingWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.root = RUN_ROOT / self._testMethodName / '照片 [测试] ! batch'
        (self.root / 'matched_jpg').mkdir(parents=True)
        (self.root / 'matched_nef').mkdir()

    def photo(self, name, rating=None, *, raw_dir='matched_nef', sidecar=True, extension='.jpg', tags=()):
        jpg = self.root / 'matched_jpg' / (name + extension)
        Image.new('RGB', (16, 12), (35, 82, 143)).save(jpg)
        extra_tags = list(tags)
        if rating is not None:
            extra_tags.append(f'-XMP-xmp:Rating={rating}')
        if extra_tags:
            write_tags(jpg, *extra_tags)
        if raw_dir is not None:
            directory = self.root / raw_dir
            directory.mkdir(exist_ok=True)
            # The production operation moves bytes, so this sentinel verifies RAW identity without editing real photos.
            (directory / (name + '.NEF')).write_bytes(b'NEF identity sentinel\x00' + name.encode('utf-8'))
            if sidecar:
                (directory / (name + '.xmp')).write_text(
                    '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
                    '<rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" '
                    'xmp:Rating="1" crs:Exposure2012="0.35"/></rdf:RDF></x:xmpmeta>', encoding='utf-8')
        return jpg

    def run_sort(self, *args, **kwargs):
        return run_ps(TOOLKIT / 'sort-by-rating.ps1', self.root, *args, **kwargs)

    def metadata_photo(self, name, rating=None, *, raw_dir='3', tags=()):
        jpg = self.photo(name, rating, raw_dir=None, tags=tags)
        directory = self.root / raw_dir
        directory.mkdir(exist_ok=True)
        # Valid generated TIFF fixtures exercise metadata writes; these are not Nikon NEF files.
        raw = directory / (name + '.tif')
        Image.new('RGB', (16, 12), (35, 82, 143)).save(raw)
        sidecar = directory / (name + '.xmp')
        for target in (raw, sidecar):
            write_tags(target, '-XMP-xmp:Rating=1', '-XMP-xmp:Label=Old', '-XMP-crs:Exposure2012=0.35')
        return jpg, raw, sidecar

    def run_sync(self, *args, **kwargs):
        return run_ps(TOOLKIT / 'sync-tags-to-nef.ps1', self.root, '-RawExt', 'tif', *args, **kwargs)

    def assert_no_mutation(self, before, directories):
        self.assertEqual(snapshot(self.root), before)
        self.assertEqual({str(p.relative_to(self.root)) for p in self.root.rglob('*') if p.is_dir()}, directories)

    def test_ratings_0_to_5_preview_move_and_repeat(self):
        for star in range(6):
            self.photo(f'星级 {star} [!]', star, extension='.JPEG' if star % 2 else '.JPG')
        self.photo('未打星')
        rejected = self.photo('拒绝', -1)
        (self.root / 'unmatched_nef').mkdir()
        (self.root / 'unmatched_nef' / '未匹配.NEF').write_bytes(b'untouched')
        before = snapshot(self.root)
        directories = {str(p.relative_to(self.root)) for p in self.root.rglob('*') if p.is_dir()}
        _, preview = self.run_sort('-DryRun')
        self.assertEqual(preview['Planned'], 7)
        self.assertEqual(preview['Rejected'], 1)
        self.assert_no_mutation(before, directories)
        _, result = self.run_sort()
        self.assertEqual(result['MovedPhotos'], 7)
        self.assertEqual(result['FilesMoved'], 14)
        for star in range(6):
            for extension in ('.NEF', '.xmp'):
                self.assertTrue((self.root / str(star) / (f'星级 {star} [!]' + extension)).is_file())
        self.assertTrue((self.root / '0' / '未打星.NEF').is_file())
        self.assertTrue((self.root / 'matched_nef' / '拒绝.NEF').is_file())
        self.assertTrue(rejected.is_file())
        after = photo_snapshot(self.root)
        self.assertCountEqual([item[0] for item in before.values()], [item[0] for item in after.values()])
        for path, original in before.items():
            if path.startswith('matched_jpg') or path.startswith('unmatched_nef'):
                self.assertEqual(after[path], original)
        moved_state = snapshot(self.root)
        _, repeated = self.run_sort()
        self.assertEqual(repeated['Planned'], 0)
        self.assertEqual(repeated['AlreadySorted'], 7)
        self.assertEqual(snapshot(self.root), moved_state)

    def test_changed_rating_moves_existing_raw_and_sidecar(self):
        jpg = self.photo('改星', 2)
        self.run_sort()
        raw_bytes = (self.root / '2' / '改星.NEF').read_bytes()
        xmp_bytes = (self.root / '2' / '改星.xmp').read_bytes()
        write_tags(jpg, '-XMP-xmp:Rating=5')
        _, result = self.run_sort()
        self.assertEqual(result['MovedPhotos'], 1)
        self.assertFalse((self.root / '2' / '改星.NEF').exists())
        self.assertEqual((self.root / '5' / '改星.NEF').read_bytes(), raw_bytes)
        self.assertEqual((self.root / '5' / '改星.xmp').read_bytes(), xmp_bytes)
        write_tags(jpg, '-XMP-xmp:Rating=')
        self.run_sort()
        self.assertTrue((self.root / '0' / '改星.NEF').is_file())

    def test_adobe_rating_has_priority_and_exif_fallback(self):
        self.photo('Adobe优先', 4, tags=('-IFD0:Rating=1',))
        self.photo('EXIF兼容', tags=('-IFD0:Rating=3',))
        self.run_sort()
        self.assertTrue((self.root / '4' / 'Adobe优先.NEF').is_file())
        self.assertTrue((self.root / '3' / 'EXIF兼容.NEF').is_file())

    def test_sync_exif_only_rating_and_xmp_precedence(self):
        fixtures = [
            (self.metadata_photo('EXIF同步', tags=('-IFD0:Rating=3', '-XMP-xmp:Label=Blue')), 3),
            (self.metadata_photo('XMP同步优先', 4, tags=('-IFD0:Rating=1',)), 4),
            (self.metadata_photo('XMP零星优先', 0, tags=('-IFD0:Rating=5',)), 0),
        ]
        source_tags = read_tags(fixtures[0][0][0], '-XMP-xmp:Rating', '-IFD0:Rating')
        self.assertNotIn('XMP-xmp:Rating', source_tags)
        self.assertEqual(source_tags['IFD0:Rating'], 3)
        original_jpgs = {jpg: jpg.read_bytes() for (jpg, _, _), _ in fixtures}
        original_times = {target: target.stat().st_mtime_ns
                          for (_, raw, sidecar), _ in fixtures for target in (raw, sidecar)}
        _, result = self.run_sync()
        self.assertEqual(result['Successful'], 3)
        self.assertEqual(result['Failed'], 0)
        for (jpg, raw, sidecar), expected in fixtures:
            self.assertEqual(jpg.read_bytes(), original_jpgs[jpg])
            self.assertEqual(read_tags(raw, '-FileType')['File:FileType'], 'TIFF')
            for target in (raw, sidecar):
                actual = read_tags(target, '-XMP-xmp:Rating', '-XMP-crs:Exposure2012')
                self.assertEqual(actual['XMP-xmp:Rating'], expected)
                self.assertEqual(actual['XMP-crs:Exposure2012'], 0.35)
                self.assertEqual(target.stat().st_mtime_ns, original_times[target])
                self.assertFalse(target.with_name(target.name + '_original').exists())
        for target in fixtures[0][0][1:]:
            self.assertEqual(read_tags(target, '-XMP-xmp:Label')['XMP-xmp:Label'], 'Blue')

    def test_sync_missing_rating_clears_existing_fields(self):
        _, raw, sidecar = self.metadata_photo('无源标签')
        _, result = self.run_sync()
        self.assertEqual(result['Successful'], 1)
        for target in (raw, sidecar):
            actual = read_tags(target, '-XMP-xmp:Rating', '-XMP-xmp:Label', '-XMP-crs:Exposure2012')
            self.assertNotIn('XMP-xmp:Rating', actual)
            self.assertNotIn('XMP-xmp:Label', actual)
            self.assertEqual(actual['XMP-crs:Exposure2012'], 0.35)

    def test_sync_keep_missing_tags_and_skip_sidecars(self):
        _, raw, sidecar = self.metadata_photo('保留缺失标签')
        original_sidecar = sidecar.read_bytes()
        _, result = self.run_sync('-KeepMissingTags', '-SkipSidecars')
        self.assertEqual(result['Successful'], 1)
        actual = read_tags(raw, '-XMP-xmp:Rating', '-XMP-xmp:Label')
        self.assertEqual(actual['XMP-xmp:Rating'], 1)
        self.assertEqual(actual['XMP-xmp:Label'], 'Old')
        self.assertEqual(sidecar.read_bytes(), original_sidecar)

    def test_sync_folder_rating_overrides_metadata_and_keeps_backups(self):
        fixtures = [self.metadata_photo('文件夹覆盖EXIF', raw_dir='2', tags=('-IFD0:Rating=3',)),
                    self.metadata_photo('文件夹覆盖XMP', 4, raw_dir='2', tags=('-IFD0:Rating=1',))]
        originals = {target: target.read_bytes() for _, raw, sidecar in fixtures for target in (raw, sidecar)}
        _, result = self.run_sync('-RatingFromFolder', '-KeepBackup')
        self.assertEqual(result['Successful'], 2)
        for target, original in originals.items():
            actual = read_tags(target, '-XMP-xmp:Rating', '-XMP-microsoft:RatingPercent')
            self.assertEqual(actual['XMP-xmp:Rating'], 2)
            self.assertEqual(actual['XMP-microsoft:RatingPercent'], 25)
            self.assertEqual(target.with_name(target.name + '_original').read_bytes(), original)

    def test_missing_raw_does_not_move_jpg(self):
        jpg = self.photo('没有RAW', 3, raw_dir=None)
        self.photo('有效', 1)
        original = jpg.read_bytes()
        _, result = self.run_sort()
        self.assertEqual(result['RawMissing'], 1)
        self.assertEqual(result['MovedPhotos'], 1)
        self.assertEqual(jpg.read_bytes(), original)
        self.assertFalse((self.root / '3').exists())

    def test_target_conflict_stops_entire_batch(self):
        self.photo('a正常', 1)
        self.photo('z冲突', 4)
        (self.root / '4').mkdir()
        (self.root / '4' / 'z冲突.xmp').write_bytes(b'different existing XMP')
        # Remove the source sidecar so the destination conflict is checked against a directory occupying the RAW name.
        (self.root / 'matched_nef' / 'z冲突.xmp').unlink()
        (self.root / '4' / 'z冲突.NEF').mkdir()
        before = snapshot(self.root)
        result, _ = self.run_sort(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(snapshot(self.root), before)
        self.assertFalse((self.root / '1').exists())

    def test_duplicate_raw_stops_before_changes(self):
        self.photo('重复RAW', 3)
        (self.root / '2').mkdir()
        (self.root / '2' / '重复RAW.NEF').write_bytes(b'other RAW')
        before = snapshot(self.root)
        result, _ = self.run_sort(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(snapshot(self.root), before)

    def test_duplicate_jpg_jpeg_stops_before_changes(self):
        jpg = self.photo('重复JPG', 3)
        shutil.copyfile(jpg, jpg.with_suffix('.jpeg'))
        before = snapshot(self.root)
        result, _ = self.run_sort(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(snapshot(self.root), before)

    def test_corrupt_jpg_stops_entire_batch(self):
        self.photo('a有效', 2)
        (self.root / 'matched_jpg' / 'z损坏.jpg').write_bytes(b'not a JPEG')
        before = snapshot(self.root)
        result, _ = self.run_sort(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(snapshot(self.root), before)
        self.assertFalse((self.root / '2').exists())

    def test_invalid_rating_stops_entire_batch(self):
        self.photo('a有效', 2)
        self.photo('z无效', 2.5)
        before = snapshot(self.root)
        result, _ = self.run_sort(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(snapshot(self.root), before)
        self.assertFalse((self.root / '2').exists())

    def test_locked_sidecar_rolls_back_raw(self):
        self.photo('文件占用', 5)
        before = snapshot(self.root)
        kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
        create_file = kernel32.CreateFileW
        create_file.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                                ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
        create_file.restype = ctypes.c_void_p
        close_handle = kernel32.CloseHandle
        close_handle.argtypes = [ctypes.c_void_p]
        sidecar = self.root / 'matched_nef' / '文件占用.xmp'
        handle = create_file(str(sidecar), 0x80000000, 1, None, 3, 0x80, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value)
        try:
            result, _ = self.run_sort(check=False)
        finally:
            close_handle(handle)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(photo_snapshot(self.root), before)
        _, retry = self.run_sort()
        self.assertEqual(retry['MovedPhotos'], 1)

    def test_root_sidecar_follows_already_sorted_raw(self):
        self.photo('根目录XMP', 3, raw_dir='3', sidecar=False)
        sidecar = self.root / '根目录XMP.xmp'
        sidecar.write_bytes(b'root sidecar unchanged')
        set_hidden(sidecar)
        _, result = self.run_sort()
        self.assertEqual(result['FilesMoved'], 1)
        self.assertEqual((self.root / '3' / '根目录XMP.xmp').read_bytes(), b'root sidecar unchanged')
        self.assertTrue((self.root / '3' / '根目录XMP.xmp').stat().st_file_attributes & 0x2)

    def test_root_sidecar_symlink_rejected_before_sort_or_export(self):
        self.photo('链接侧车', 5, sidecar=False)
        outside = self.root.parent / 'outside.xmp'
        outside.write_bytes(b'external sidecar must remain untouched')
        sidecar = self.root / '链接侧车.xmp'
        try:
            os.symlink(outside, sidecar)
        except OSError as error:
            if error.winerror in (5, 50, 1314):
                self.skipTest(f'Windows cannot create a file symlink in this environment: {error}')
            raise
        before = snapshot(self.root)
        directories = {str(p.relative_to(self.root)) for p in self.root.rglob('*') if p.is_dir()}
        original_outside = (outside.read_bytes(), outside.stat().st_mtime_ns)
        destination = self.root.parent / 'exported'
        for script, arguments in (
            ('sort-by-rating.ps1', ()),
            ('export-selected.ps1', ('-Destination', str(destination))),
        ):
            with self.subTest(script=script):
                result, _ = run_ps(TOOLKIT / script, self.root, *arguments, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('不能通过链接处理照片', result.stderr)
                self.assert_no_mutation(before, directories)
                self.assertTrue(sidecar.is_symlink())
                self.assertEqual((outside.read_bytes(), outside.stat().st_mtime_ns), original_outside)
                self.assertFalse(destination.exists())

    def test_full_classification_then_auto_rating_no_manual_jpg_move(self):
        jpg = self.photo('直接流程', 4)
        for source in list((self.root / 'matched_nef').iterdir()) + [jpg]:
            source.rename(self.root / source.name)
        run_ps(TOOLKIT / 'photo-sort.ps1', self.root, '-NoConfirm')
        self.assertTrue((self.root / 'matched_jpg' / '直接流程.jpg').is_file())
        self.run_sort()
        self.assertTrue((self.root / '4' / '直接流程.NEF').is_file())
        self.assertTrue((self.root / '4' / '直接流程.xmp').is_file())
        self.assertTrue((self.root / 'matched_jpg' / '直接流程.jpg').is_file())

    def test_bat_preview_execute_and_failure_exit_codes(self):
        self.photo('入口测试', 3)
        before = snapshot(self.root)
        for filename in ['03-预览星级替换.bat', '04-执行星级替换.bat']:
            result = run_bat(filename, self.root)
            self.assertEqual(result.returncode, 0, result.stdout.decode('utf-8', 'replace') + result.stderr.decode('utf-8', 'replace'))
            if filename.startswith('03'):
                self.assertEqual(snapshot(self.root), before)
        self.assertTrue((self.root / '3' / '入口测试.NEF').is_file())
        (self.root / 'matched_jpg' / '损坏.jpg').write_bytes(b'not JPEG')
        failed = run_bat('04-执行星级替换.bat', self.root)
        self.assertNotEqual(failed.returncode, 0)

    @unittest.skipUnless(shutil.which('pwsh.exe'), 'PowerShell 7 is optional and pwsh.exe is not installed.')
    def test_powershell_7_compatibility(self):
        self.photo('PS7', 2)
        _, result = self.run_sort(shell='pwsh.exe')
        self.assertEqual(result['MovedPhotos'], 1)
        self.assertTrue((self.root / '2' / 'PS7.NEF').is_file())

    def test_empty_batch(self):
        _, result = self.run_sort()
        self.assertEqual(result['PickFilesSeen'], 0)
        self.assertEqual(result['MovedPhotos'], 0)
        self.assertFalse((self.root / '0').exists())

    def test_unrated_skip_zero_and_complete_report(self):
        self.photo('明确零星', 0)
        self.photo('尚未评分')
        self.photo('拒绝', -1)
        self.photo('缺RAW', 5, raw_dir=None)
        for index in range(21):
            self.photo(f'照片{index:02}', 4)
        report = self.root / 'preview.csv'
        before = snapshot(self.root)
        _, preview = self.run_sort('-UnratedAction', 'Skip', '-DryRun', '-ReportPath', str(report))
        self.assertEqual(preview['Unrated'], 1)
        self.assertEqual(preview['ExplicitZero'], 1)
        with report.open(encoding='utf-8-sig', newline='') as stream:
            rows = {row['BaseName']: row for row in csv.DictReader(stream)}
        self.assertEqual(len(rows), 25)
        self.assertEqual(rows['尚未评分']['Status'], 'UnratedSkipped')
        self.assertEqual(rows['拒绝']['Status'], 'Rejected')
        self.assertEqual(rows['缺RAW']['Status'], 'MissingRaw')
        self.assertEqual(rows['照片20']['Rating'], '4')
        report.unlink()
        self.assertEqual(snapshot(self.root), before)
        self.run_sort('-UnratedAction', 'Skip')
        self.assertTrue((self.root / '0' / '明确零星.NEF').is_file())
        self.assertTrue((self.root / 'matched_nef' / '尚未评分.NEF').is_file())

    def test_report_refuses_overwrite_and_formula_cells_are_escaped(self):
        self.photo('=1+1', 4)
        report = self.root / 'preview.csv'
        self.run_sort('-DryRun', '-ReportPath', str(report))
        with report.open(encoding='utf-8-sig', newline='') as stream:
            self.assertEqual(next(csv.DictReader(stream))['BaseName'], "'=1+1")
        before = snapshot(self.root)
        result, _ = self.run_sort('-ReportPath', str(report), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(snapshot(self.root), before)

    def test_undo_moves_and_rerating_in_reverse_order(self):
        jpg = self.photo('可撤销', 3)
        before = photo_snapshot(self.root)
        self.run_sort()
        write_tags(jpg, '-XMP-xmp:Rating=5')
        self.run_sort()
        current = snapshot(self.root)
        _, preview = run_ps(TOOLKIT / 'undo-last-sort.ps1', self.root, '-DryRun')
        self.assertEqual(preview['Planned'], 2)
        self.assertEqual(snapshot(self.root), current)
        _, undo = run_ps(TOOLKIT / 'undo-last-sort.ps1', self.root)
        self.assertEqual(undo['Restored'], 2)
        self.assertTrue((self.root / '3' / '可撤销.NEF').is_file())
        run_ps(TOOLKIT / 'undo-last-sort.ps1', self.root)
        after = photo_snapshot(self.root)
        self.assertEqual(after['matched_nef\\可撤销.NEF'], before['matched_nef\\可撤销.NEF'])
        self.assertEqual(after['matched_nef\\可撤销.xmp'], before['matched_nef\\可撤销.xmp'])
        self.assertEqual(read_tags(jpg, '-XMP-xmp:Rating')['XMP-xmp:Rating'], 5)

    def test_undo_preflights_all_conflicts(self):
        self.photo('a照片', 3)
        self.photo('z照片', 4)
        self.run_sort()
        (self.root / 'matched_nef' / 'a照片.NEF').write_bytes(b'never overwrite')
        before = snapshot(self.root)
        result, _ = run_ps(TOOLKIT / 'undo-last-sort.ps1', self.root, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(snapshot(self.root), before)

    def test_undo_recovers_interrupted_move_and_truncated_log(self):
        self.photo('断点', 4)
        self.run_sort()
        history = next((self.root / '.raw-star-sorter').glob('*.jsonl'))
        events = [json.loads(line) for line in history.read_text(encoding='utf-8').splitlines()]
        # Simulate power loss after final move, before the completion event was flushed.
        last_move = max(i for i, event in enumerate(events) if event['Type'] == 'Move')
        history.write_text('\n'.join(json.dumps(e) for e in events[:last_move + 1]) + '\n{"Type":', encoding='utf-8')
        _, result = run_ps(TOOLKIT / 'undo-last-sort.ps1', self.root)
        self.assertEqual(result['Restored'], 2)
        self.assertTrue((self.root / 'matched_nef' / '断点.NEF').is_file())
        result, _ = run_ps(TOOLKIT / 'undo-last-sort.ps1', self.root, check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_undo_rejects_history_path_escape(self):
        self.photo('路径检查', 3)
        self.run_sort()
        history = next((self.root / '.raw-star-sorter').glob('*.jsonl'))
        events = [json.loads(line) for line in history.read_text(encoding='utf-8').splitlines()]
        for event in events:
            if event['Type'] == 'Move':
                event['From'] = str(self.root.parent / 'outside.NEF')
                break
        history.write_text('\n'.join(json.dumps(e) for e in events), encoding='utf-8')
        before = snapshot(self.root)
        result, _ = run_ps(TOOLKIT / 'undo-last-sort.ps1', self.root, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(snapshot(self.root), before)

    def test_undo_recovers_interrupted_hidden_moves(self):
        self.photo('隐藏断点', 4)
        sources = [self.root / 'matched_nef' / ('隐藏断点' + extension) for extension in ('.NEF', '.xmp')]
        for source in sources:
            set_hidden(source)
        before = photo_snapshot(self.root)
        self.run_sort()
        history = next((self.root / '.raw-star-sorter').glob('*.jsonl'))
        events = [json.loads(line) for line in history.read_text(encoding='utf-8').splitlines()]
        last_move = max(i for i, event in enumerate(events) if event['Type'] == 'Move')
        history.write_text('\n'.join(json.dumps(e) for e in events[:last_move + 1]) + '\n{"Type":', encoding='utf-8')
        moved = snapshot(self.root)
        _, preview = run_ps(TOOLKIT / 'undo-last-sort.ps1', self.root, '-DryRun')
        self.assertEqual(preview['Planned'], 2)
        self.assertEqual(snapshot(self.root), moved)
        _, result = run_ps(TOOLKIT / 'undo-last-sort.ps1', self.root)
        self.assertEqual(result['Restored'], 2)
        self.assertEqual(photo_snapshot(self.root), before)
        for source in sources:
            self.assertTrue(source.stat().st_file_attributes & 0x2)

    def test_organize_sync_uses_current_rating_and_skips_unrated_rejected(self):
        jpg, raw, sidecar = self.metadata_photo('改成五星', 5, raw_dir='3')
        _, rejected_raw, rejected_sidecar = self.metadata_photo('拒绝保留', -1, raw_dir='2')
        _, unrated_raw, unrated_sidecar = self.metadata_photo('未评分保留', raw_dir='1')
        original = {p: p.read_bytes() for p in (raw, sidecar, rejected_raw, rejected_sidecar, unrated_raw, unrated_sidecar)}
        _, result = self.run_sort('-RawExt', 'tif', '-SyncTags', '-UnratedAction', 'Skip')
        self.assertEqual(result['Sync']['Successful'], 1)
        for previous in (raw, sidecar):
            target = self.root / '5' / previous.name
            self.assertEqual(read_tags(target, '-XMP-xmp:Rating')['XMP-xmp:Rating'], 5)
            self.assertEqual(target.with_name(target.name + '_original').read_bytes(), original[previous])
            self.assertEqual(read_tags(target, '-XMP-xmp:Label')['XMP-xmp:Label'], 'Old')
        for target in (rejected_raw, rejected_sidecar, unrated_raw, unrated_sidecar):
            self.assertEqual(target.read_bytes(), original[target])
        # Undo keeps the synchronized contents; backups remain where synchronization created them.
        run_ps(TOOLKIT / 'undo-last-sort.ps1', self.root)
        self.assertEqual(read_tags(raw, '-XMP-xmp:Rating')['XMP-xmp:Rating'], 5)

    def test_organize_sync_empty_sidecar_extension_leaves_all_xmp_untouched(self):
        _, raw, sidecar = self.metadata_photo('禁用侧车', 5, raw_dir='matched_nef')
        destination = self.root / '5'
        destination.mkdir()
        existing_sidecar = destination / sidecar.name
        root_sidecar = self.root / sidecar.name
        for target in (existing_sidecar, root_sidecar):
            shutil.copyfile(sidecar, target)
        original = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in (sidecar, existing_sidecar, root_sidecar)}
        _, result = self.run_sort('-RawExt', 'tif', '-SidecarExt', '', '-SyncTags')
        self.assertEqual(result['FilesMoved'], 1)
        self.assertEqual(result['Sidecars'], 0)
        self.assertEqual(result['Sync']['Successful'], 1)
        self.assertEqual(read_tags(destination / raw.name, '-XMP-xmp:Rating')['XMP-xmp:Rating'], 5)
        for target, expected in original.items():
            self.assertEqual((target.read_bytes(), target.stat().st_mtime_ns), expected)
            self.assertFalse(target.with_name(target.name + '_original').exists())

    def test_organize_sync_custom_sidecar_extension_rejected_before_changes(self):
        _, _, sidecar = self.metadata_photo('自定义侧车', 5, raw_dir='matched_nef')
        sidecar.rename(sidecar.with_suffix('.pp3'))
        before = snapshot(self.root)
        directories = {str(p.relative_to(self.root)) for p in self.root.rglob('*') if p.is_dir()}
        result, _ = self.run_sort('-RawExt', 'tif', '-SidecarExt', 'pp3', '-SyncTags', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('-SyncTags', result.stderr)
        self.assertIn('-SidecarExt', result.stderr)
        self.assert_no_mutation(before, directories)

    def test_organize_sync_moves_and_synchronizes_hidden_raw_and_xmp(self):
        _, raw, sidecar = self.metadata_photo('隐藏照片', 5, raw_dir='matched_nef', tags=('-XMP-xmp:Label=New',))
        original = {p: p.read_bytes() for p in (raw, sidecar)}
        for target in (raw, sidecar):
            set_hidden(target)
        _, result = self.run_sort('-RawExt', 'tif', '-SyncTags')
        self.assertEqual(result['FilesMoved'], 2)
        self.assertEqual(result['Sync']['Successful'], 1)
        self.assertEqual(result['Sync']['MissingRaw'], 0)
        for previous in (raw, sidecar):
            target = self.root / '5' / previous.name
            self.assertFalse(previous.exists())
            self.assertTrue(target.stat().st_file_attributes & 0x2, f'Hidden attribute lost: {target}')
            tags = read_tags(target, '-XMP-xmp:Rating', '-XMP-xmp:Label')
            self.assertEqual(tags['XMP-xmp:Rating'], 5)
            self.assertEqual(tags['XMP-xmp:Label'], 'New')
            self.assertEqual(target.with_name(target.name + '_original').read_bytes(), original[previous])

    def test_sync_synchronizes_hidden_raw_and_xmp_without_backups(self):
        _, raw, sidecar = self.metadata_photo('隐藏同步', 4, tags=('-XMP-xmp:Label=New',))
        for target in (raw, sidecar):
            set_hidden(target)
        _, result = self.run_sync()
        self.assertEqual(result['Successful'], 1)
        self.assertEqual(result['MissingRaw'], 0)
        for target in (raw, sidecar):
            self.assertTrue(target.stat().st_file_attributes & 0x2, f'Hidden attribute lost: {target}')
            tags = read_tags(target, '-XMP-xmp:Rating', '-XMP-xmp:Label')
            self.assertEqual(tags['XMP-xmp:Rating'], 4)
            self.assertEqual(tags['XMP-xmp:Label'], 'New')
            self.assertFalse(target.with_name(target.name + '_original').exists())

    def test_export_selected_copies_only_threshold_and_preserves_sources(self):
        self.photo('五星', 5)
        self.photo('四星', 4)
        self.photo('三星', 3)
        self.photo('拒绝', -1)
        self.photo('无评分')
        destination = self.root.parent / '精选 [!]'
        before = snapshot(self.root)
        _, preview = run_ps(TOOLKIT / 'export-selected.ps1', self.root, '-Destination', str(destination), '-DryRun')
        self.assertEqual(preview['Planned'], 6)
        self.assertFalse(destination.exists())
        _, result = run_ps(TOOLKIT / 'export-selected.ps1', self.root, '-Destination', str(destination))
        self.assertEqual(result['Copied'], 6)
        self.assertEqual(len(list(destination.iterdir())), 6)
        self.assertEqual(snapshot(self.root), before)
        self.assertEqual((destination / '五星.NEF').read_bytes(), (self.root / 'matched_nef' / '五星.NEF').read_bytes())
        result, _ = run_ps(TOOLKIT / 'export-selected.ps1', self.root, '-Destination', str(destination), check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_menu_preview_cancel_then_execute(self):
        self.photo('菜单操作', 5)
        self.photo('菜单未打星')
        command = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(TOOLKIT / 'start.ps1'),
                   '-Path', str(self.root), '-ExifToolPath', str(EXIFTOOL)]
        before = snapshot(self.root)
        result = subprocess.run(command, input='2\n3\n\n0\n', capture_output=True, encoding='utf-8', errors='replace', timeout=45)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(snapshot(self.root), before)
        result = subprocess.run(command, input='3\nY\n0\n', capture_output=True, encoding='utf-8', errors='replace', timeout=45)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / '5' / '菜单操作.NEF').is_file())
        self.assertTrue((self.root / 'matched_nef' / '菜单未打星.NEF').is_file())


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--toolkit', type=Path)
    parser.add_argument('--exiftool', default=os.environ.get('EXIFTOOL_PATH'))
    parser.add_argument('--shell', choices=['powershell.exe', 'pwsh.exe'], default='powershell.exe')
    args, remaining = parser.parse_known_args()
    if args.toolkit:
        TOOLKIT = args.toolkit.resolve()
    SHELL = args.shell
    if os.name != 'nt':
        parser.error('These integration tests require Windows.')
    if args.exiftool:
        EXIFTOOL = Path(args.exiftool).resolve()
    else:
        portable = TOOLKIT / 'tools' / 'exiftool' / 'exiftool.exe'
        command = shutil.which('exiftool') or shutil.which('exiftool.exe')
        EXIFTOOL = portable if portable.is_file() else Path(command) if command else None
    if EXIFTOOL is None or not EXIFTOOL.is_file():
        parser.error('ExifTool is required. Install it or pass --exiftool PATH.')
    if not shutil.which(SHELL):
        parser.error(f'PowerShell executable not found: {SHELL}')
    with tempfile.TemporaryDirectory(prefix='raw-star-sorter-tests-') as temporary_directory:
        RUN_ROOT = Path(temporary_directory)
        print('Using temporary generated fixtures.', flush=True)
        outcome = unittest.main(argv=[__file__, *remaining], verbosity=2, exit=False)
    raise SystemExit(0 if outcome.result.wasSuccessful() else 1)

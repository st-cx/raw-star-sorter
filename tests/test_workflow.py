from __future__ import annotations

import argparse
import ctypes
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
    if Path(script).name in ('sort-by-rating.ps1', 'sync-tags-to-nef.ps1') and not (TOOLKIT / 'tools' / 'exiftool' / 'exiftool.exe').is_file():
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
        after = snapshot(self.root)
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
        self.assertEqual(snapshot(self.root), before)
        _, retry = self.run_sort()
        self.assertEqual(retry['MovedPhotos'], 1)

    def test_root_sidecar_follows_already_sorted_raw(self):
        self.photo('根目录XMP', 3, raw_dir='3', sidecar=False)
        (self.root / '根目录XMP.xmp').write_bytes(b'root sidecar unchanged')
        _, result = self.run_sort()
        self.assertEqual(result['FilesMoved'], 1)
        self.assertEqual((self.root / '3' / '根目录XMP.xmp').read_bytes(), b'root sidecar unchanged')

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

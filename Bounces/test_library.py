import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import wave

SPEC = importlib.util.spec_from_file_location('library', Path(__file__).with_name('library.py'))
library = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(library)


class Archives(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name); self.pool = self.root / '_Media'; self.pool.mkdir()
        self.source = self.root / "recording 'one'.wav"
        with wave.open(str(self.source), 'wb') as f:
            f.setparams((1, 2, 48000, 0, 'NONE', 'not compressed')); f.writeframes(b'\0\0' * 4800)
        self.version = self.root / 'version'; self.version.mkdir()
        self.snapshot = self.version / 'Session.RPP'
        self.text = '<REAPER_PROJECT\n<TRACK\n<VST\nFILE "do not touch plugin data"\n>\n<ITEM\n<SOURCE WAVE\nFILE "' + str(self.source) + '" 1\n>\n>\n>\n>\n'
        self.snapshot.write_text(self.text)

    def tearDown(self):
        self.temp.cleanup()

    def test_snapshot_survives_original_deletion(self):
        library.archive_session(self.snapshot, self.pool, {})
        self.source.unlink()
        text = self.snapshot.read_text()
        self.assertIn('FILE "do not touch plugin data"', text)
        _, _, name = next(library.source_files(text))
        self.assertTrue((self.version / name).is_file())
        self.assertTrue(text.endswith('>\n'))
        self.assertIn('.wav" 1', text)

    def test_identical_recordings_share_an_immutable_copy(self):
        first = library.preserve_source(self.source, self.pool)
        again = library.preserve_source(self.source, self.pool)
        self.assertEqual(first, again); self.assertNotEqual(first.stat().st_ino, self.source.stat().st_ino)
        original_bytes = first.read_bytes(); self.source.write_bytes(b'changed')
        self.assertEqual(first.read_bytes(), original_bytes)

    def test_archiving_is_retryable_after_rewrite(self):
        library.archive_session(self.snapshot, self.pool, {})
        first = self.snapshot.read_bytes()
        library.archive_session(self.snapshot, self.pool, {})
        self.assertEqual(self.snapshot.read_bytes(), first)
        self.assertEqual(len(list(self.pool.iterdir())), 1)

    def test_missing_recording_does_not_publish_broken_snapshot(self):
        self.source.unlink()
        with self.assertRaisesRegex(ValueError, 'missing'):
            library.archive_session(self.snapshot, self.pool, {})
        self.assertEqual(self.snapshot.read_text(), self.text)

    def test_only_source_paths_are_rewritten_with_nested_sections(self):
        self.snapshot.write_text(self.text.replace('<SOURCE WAVE', '<SOURCE SECTION\n<SOURCE WAVE').replace('FILE "' + str(self.source) + '" 1', 'FILE "' + str(self.source) + '" 1\n>'))
        self.assertEqual(library.archive_session(self.snapshot, self.pool, {}), 1)

    def test_missing_encoder_marks_export_failed_without_discarding_wavs(self):
        manifest = {'state': 'packaging', 'project_title': 'Song', 'title': 'One', 'bounds': [0, .1]}
        library.write(self.version / 'bounce.json', manifest)
        (self.version / 'Instrumental session.RPP').write_text(self.text)
        for name in ['Full mix.wav', 'Instrumental.wav']:
            (self.version / name).write_bytes(self.source.read_bytes())
        with patch.object(library, 'ffmpeg_path', side_effect=ValueError('Install FFmpeg')):
            with self.assertRaisesRegex(ValueError, 'FFmpeg'):
                library.archive(self.version)
        self.assertEqual(library.read(self.version / 'status.json')['state'], 'failed')
        self.assertTrue((self.version / 'Full mix.wav').is_file())


if __name__ == '__main__':
    unittest.main()

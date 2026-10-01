import json
from pathlib import Path
import tempfile
import unittest
import worker


class DiagnosticTests(unittest.TestCase):
    def test_failure_retains_phase_and_append_only_log_across_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            worker.write(path / 'config.json', {'bounds': [0, 8], 'visual_analysis': False})
            session = worker.Session(path)
            def failed_bridge(name, args):
                session.phase('waiting_for_reaper', tool=name)
                raise RuntimeError('Stop playback before continuing the mixing pass.')
            session.bridge = failed_bridge
            self.assertEqual(session.run(), 'error')
            status = worker.read(path / 'status.json')
            self.assertEqual(status['failure']['activity']['tool'], 'inspect_project')
            rows = [json.loads(line) for line in (path / 'events.jsonl').read_text().splitlines()]
            self.assertEqual(rows[-1]['kind'], 'pass_finished')
            self.assertEqual(next(r for r in rows if r['kind'] == 'pass_failed')['type'], 'RuntimeError')
            second = worker.Session(path); second.publish('Next pass')
            after = [json.loads(line) for line in (path / 'events.jsonl').read_text().splitlines()]
            self.assertEqual(after[:-1], rows)
            self.assertNotEqual(after[-1]['pass_id'], rows[0]['pass_id'])

    def test_running_worker_lock_prevents_second_pass(self):
        import fcntl
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            with (path / 'worker.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaisesRegex(RuntimeError, 'already owns'):
                    worker.run_session(path)
            self.assertFalse((path / 'status.json').exists())


if __name__ == '__main__':
    unittest.main()

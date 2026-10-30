#Billing cleanup must not destroy the only copy of a completed result.
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / 'tools/art/cloud/run_vast_job.py'
SPEC = importlib.util.spec_from_file_location('boss_cloud', PATH)
JOB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(JOB)


class CloudJobTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.args = SimpleNamespace(instance=123, minutes=1,
                                    bundle=self.root/'job.tar.gz',
                                    ssh_key=self.root/'key')
        self.instance = {'ssh_host': 'example.invalid', 'ssh_port': 2222}

    def tearDown(self):
        self.tmp.cleanup()

    def test_verify_precedes_destroy(self):
        events = []
        with patch.object(JOB, 'ROOT', self.root), \
             patch.object(JOB, 'run'), \
             patch.object(JOB, 'verify', side_effect=lambda _: events.append('verified')), \
             patch.object(JOB, 'release', side_effect=lambda *_: events.append('destroyed')):
            JOB.execute(self.instance, self.args, 'test')
        self.assertEqual(events, ['verified', 'destroyed'])

    def test_bad_download_keeps_remote_files(self):
        with patch.object(JOB, 'ROOT', self.root), \
             patch.object(JOB, 'run'), \
             patch.object(JOB, 'verify', side_effect=ValueError('bad hash')), \
             patch.object(JOB, 'api') as api, \
             patch.object(JOB, 'release') as release:
            with self.assertRaises(ValueError):
                JOB.execute(self.instance, self.args, 'test')
            api.assert_called_once_with('PUT', 123, 'test', {'state': 'stopped'})
            release.assert_not_called()

    def test_failed_worker_releases_after_collecting_logs(self):
        events = []
        def run(cmd, *args):
            events.append(cmd[0])
            if cmd[0] == 'ssh' and 'bash run_job.sh' in cmd[-1]:
                raise subprocess.CalledProcessError(1, cmd)
        with patch.object(JOB, 'ROOT', self.root), \
             patch.object(JOB, 'run', side_effect=run), \
             patch.object(JOB, 'verify') as verify, \
             patch.object(JOB, 'release', side_effect=lambda *_: events.append('destroy')):
            with self.assertRaises(subprocess.CalledProcessError):
                JOB.execute(self.instance, self.args, 'test')
            verify.assert_not_called()
        self.assertEqual(events[-2:], ['scp', 'destroy'])

    def test_foreign_instance_is_never_modified(self):
        with patch('sys.argv', ['run_vast_job.py', '123']), \
             patch.dict('os.environ', {'VAST_API_KEY': 'test'}), \
             patch.object(JOB, 'api', return_value={'instances': {'label': 'other-work'}}) as api:
            with self.assertRaises(SystemExit):
                JOB.main()
        api.assert_called_once_with('GET', 123, 'test')


if __name__ == '__main__':
    unittest.main()

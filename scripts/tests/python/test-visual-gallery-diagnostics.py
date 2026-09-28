"""Exercise the diagnostic shell entrypoint with inert build and Wine fixtures."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from tooling_test_paths import SCRIPT_ROOT


class VisualGalleryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='darkrenamer-gallery-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / 'repo'
        (self.repo / 'scripts' / 'diagnostics').mkdir(parents=True)
        for relative in ('capture-local-visual-gallery.sh', 'diagnostics/capture-local-visual-gallery.sh'):
            shutil.copyfile(SCRIPT_ROOT / relative, self.repo / 'scripts' / relative)
        self.command = self.repo / 'scripts' / 'capture-local-visual-gallery.sh'
        self.git('init', '-q')
        self.git('add', 'scripts')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        self.binary = self.root / 'fixture.exe'
        self.binary.write_bytes(b'inert test executable')
        self.output = self.root / 'output'
        self.env = {**os.environ, 'PATH': str(self.tools) + os.pathsep + os.environ['PATH'],
                    'RC': shutil.which('true'), 'GALLERY_FIXTURE_EXE': str(self.binary),
                    'GALLERY_BUILD_PATH': str(self.root / 'build-path')}
        self.stub('cargo', '''import os, signal
from pathlib import Path
Path(os.environ['GALLERY_BUILD_PATH']).write_text(os.readlink('/proc/self/fd/1'))
print('{}', flush=True)
if os.environ.get('GALLERY_SIGNAL'):
    os.kill(os.getppid(), signal.SIGTERM)
''')
        self.stub('jq', "import os\nprint(os.environ['GALLERY_FIXTURE_EXE'])\n")
        for name in ('wineboot', 'wineserver'):
            self.stub(name, 'pass\n')
        self.stub('winepath', 'import sys\nprint(sys.argv[-1])\n')
        self.stub('xvfb-run', 'import os, sys\nos.execvp(sys.argv[4], sys.argv[4:])\n')
        self.stub('wine', '''import json, os
from pathlib import Path
root = Path(os.environ['DARKRENAMER_VISUAL_OUTPUT_DIR'])
(root / 'fixture.bmp').write_bytes(b'inert bitmap')
(root / 'visual-gallery.json').write_text(json.dumps({
    'source_state': os.environ['DARKRENAMER_VISUAL_SOURCE_STATE'],
    'source_sha': os.environ['DARKRENAMER_VISUAL_SOURCE_SHA']}))
''')
        self.stub('ffmpeg', 'import sys\nfrom pathlib import Path\nPath(sys.argv[-1]).write_bytes(b"inert PNG")\n')

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.repo, check=True,
                              capture_output=True, text=True, timeout=10).stdout.strip()

    def stub(self, name, body):
        path = self.tools / name
        path.write_text(f'#!{sys.executable}\n{body}', encoding='utf-8')
        path.chmod(0o755)

    def run_gallery(self, *, cwd=None, args=None):
        return subprocess.run(['bash', str(self.command), *(args if args is not None else [str(self.output)])],
                              cwd=cwd or self.repo, env=self.env,
                              capture_output=True, text=True, timeout=15)

    def test_foreign_repository_is_rejected_before_build(self):
        foreign = self.root / 'foreign'
        foreign.mkdir()
        subprocess.run(['git', 'init', '-q', str(foreign)], check=True, timeout=10)
        completed = self.run_gallery(cwd=foreign)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn('its DarkReNamer repository root', completed.stderr)
        self.assertFalse((self.root / 'build-path').exists())
        self.assertFalse(self.output.exists())

    def test_untracked_source_is_recorded_as_dirty(self):
        (self.repo / 'untracked-source.rs').write_text('// source fixture\n')
        completed = self.run_gallery()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        observation = json.loads((self.output / 'visual-gallery.json').read_text())
        self.assertEqual(observation, {'source_state': 'dirty', 'source_sha': self.git('rev-parse', 'HEAD')})
        self.assertFalse(Path((self.root / 'build-path').read_text()).exists())

    def test_clean_source_and_help(self):
        help_result = self.run_gallery(cwd=self.root, args=['--help'])
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn('Usage:', help_result.stdout)
        completed = self.run_gallery()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads((self.output / 'visual-gallery.json').read_text())['source_state'], 'clean')

    def test_signal_cleans_once_and_stops_before_wine(self):
        self.env['GALLERY_SIGNAL'] = 'term'
        completed = self.run_gallery()
        self.assertEqual(completed.returncode, 143, completed.stderr)
        self.assertFalse((self.output / 'visual-gallery.json').exists())
        self.assertFalse(Path((self.root / 'build-path').read_text()).exists())


if __name__ == '__main__':
    unittest.main()

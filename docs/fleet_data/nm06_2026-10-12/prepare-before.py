"""Materialize a new isolated pre-NM-06 benchmark context; never edit the checkout."""
import hashlib
import json
from pathlib import Path
import shutil
import sys

root = Path(__file__).resolve().parents[3]
artifact = Path(__file__).resolve().parent
assert len(sys.argv) == 2, "Usage: prepare-before.py .stack-work/nm06/reproduce-before"
target = (root / sys.argv[1]).resolve()
assert target.is_relative_to(root / '.stack-work'), "Context must stay inside this workspace's .stack-work"
assert not target.exists(), "Choose a new context directory to preserve previous runs"
files = []
for folder in ['src', 'app', 'test', 'bench']:
    files.extend((root / folder).rglob('*.hs'))
files.extend((root / 'docs').glob('*.md'))
files.extend(root / name for name in ['package.yaml', 'stack.yaml', 'stack.yaml.lock', '.dockerignore', 'README.md'])
target.mkdir(parents=True)
for file in files:
    destination = target / file.relative_to(root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(file, destination)
for file in (artifact / 'before-source').rglob('*'):
    if file.is_file():
        destination = target / file.relative_to(artifact / 'before-source')
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(file, destination)
# Build-relevant common modules must still match the captured baseline.
for line in (artifact / 'before-image-source-sha256.txt').read_text(encoding='utf-8-sig').splitlines():
    digest, relative = line.split(None, 1)
    assert hashlib.sha256((target / relative).read_bytes()).hexdigest() == digest, "Common source changed: " + relative
hashes = {str(file.relative_to(target)).replace('\\', '/'): hashlib.sha256(file.read_bytes()).hexdigest()
          for file in target.rglob('*') if file.is_file()}
(target / 'source-hashes.json').write_text(json.dumps(hashes, indent=2) + '\n', encoding='utf-8')
print(str(target))

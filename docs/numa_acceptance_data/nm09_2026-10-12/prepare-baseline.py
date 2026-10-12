"""Reconstruct NM-03 in a NEW context; retain the known cached-harness mismatch."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

artifact = Path(__file__).resolve().parent
root = artifact.parents[2]
snapshot = artifact / 'baseline-source'
baseline = json.loads((root / 'docs/performance_data/nm03_2026-10-11/manifest.json').read_text(encoding='utf-8'))
assert len(sys.argv) == 2, 'Usage: prepare-baseline.py .stack-work/nm09/baseline-new'
target = (root / sys.argv[1]).resolve()
assert target.is_relative_to(root / '.stack-work'), 'Context must remain inside workspace .stack-work'
assert not target.exists(), 'Use a new directory; preserve previous runs'
expected = baseline['source']['sourceHashes']
actual = {name: hashlib.sha256((snapshot / name).read_bytes()).hexdigest() for name in expected}
mismatches = [name for name in expected if actual[name] != expected[name]]
assert mismatches == ['scripts/benchmark-runtime.mjs'], 'Unexpected snapshot mismatch: ' + str(mismatches)
assert actual[mismatches[0]] == 'd9473b16ed3bd37badd1a085736cf46462d755cbdb49bc5ffeaba02d8e1162d4'
# Only the historical tree's modules/tests; copying today's extra modules would change the build.
ref = baseline['source']['head']
names = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', ref], cwd=root).decode().splitlines()
target.mkdir(parents=True)
for name in names:
    if (name.endswith('.hs') and name.startswith(('src/', 'app/', 'test/'))) or name.startswith('docs/') and name.endswith('.md') or name in ['README.md', '.dockerignore']:
        dest = target / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(subprocess.check_output(['git', 'show', f'{ref}:{name}'], cwd=root))
for name in expected:
    dest = target / name
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(snapshot / name, dest)
new_runner = 'scripts/remeasure-baseline.mjs'
shutil.copyfile(root / 'scripts/benchmark-runtime.mjs', target / new_runner)
actual[new_runner] = hashlib.sha256((target / new_runner).read_bytes()).hexdigest()
source = {**baseline['source'], 'sourceHashes': actual,
          'dirty': 'NM-09 reconstructed source; cached CLI harness differs from measured NM-03 harness',
          'snapshotMismatches': mismatches,
          'activeHarness': new_runner, 'remeasurement': True}
(target / 'provenance.json').write_text(json.dumps(source, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'context': str(target), 'matchingFiles': len(expected) - len(mismatches),
                  'mismatches': mismatches, 'exactHistoricalHarness': False}, indent=2))

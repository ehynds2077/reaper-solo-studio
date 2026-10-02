"""Verify actual audio from Run advanced mix checks.lua, not just API readback."""
import json
from pathlib import Path
import subprocess
import sys
import numpy as np


def main(folder):
    rows = json.loads((folder / 'signal-results.json').read_text()); levels = {}
    for point, row in rows.items():
        path = row['path']
        info = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries',
                                                  'stream=codec_name', '-of', 'json', path]))
        if point != 'mix': assert info['streams'][0]['codec_name'] == 'pcm_f32le', info
        data = subprocess.check_output(['ffmpeg', '-nostdin', '-v', 'error', '-i', path,
                                        '-f', 'f32le', '-c:a', 'pcm_f32le', '-'])
        samples = np.frombuffer(data, dtype='<f4').astype(np.float64)
        assert len(samples) == 8 * 48000 * 2
        levels[point] = float(20 * np.log10(np.sqrt(np.mean(samples ** 2))))
    for measured, expected in [
        (levels['post_fx'] - levels['pre_fx'], 6),
        (levels['post_fader'] - levels['post_fx'], 20 * np.log10(.25)),
        (levels['mix'] - levels['post_fader'], 20 * np.log10(.5))]:
        assert abs(measured - expected) < .05, (measured, expected)
    gr = json.loads((folder / 'gain-reduction.json').read_text())
    assert gr['effects'][0]['sample_count'] > 5 and gr['effects'][0]['max_db'] > 1
    assert not gr['effects'][1]['supported']
    print('PASS Float taps preserve +6 dB FX, -12.04 dB fader, and separate -6.02 dB master gain')
    print('PASS ReaComp reports actual nonzero GR; unsupported processor remains unknown')


if __name__ == '__main__': main(Path(sys.argv[1]))

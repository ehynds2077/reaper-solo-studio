"""Local reference analysis. Inputs are read-only; profiles contain no audio."""
import argparse
import hashlib
import json
import math
import re
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

VERSION = 1
RATE = 48000
FFT_SIZE = 16384
EDGES = np.geomspace(20, 20000, 31)
BANDS = [(20, 60), (60, 150), (150, 400), (400, 2000),
         (2000, 5000), (5000, 10000), (10000, 20000)]
NUMBER = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+|inf)"


def command(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr[-3000:])
    return result


def db(power):
    return 10 * math.log10(power) if power > 0 else None


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    # Identical sources analyzed by two workers may share a cache key.
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, prefix=path.stem,
                                     suffix='.tmp', delete=False) as file:
        file.write(json.dumps(value, indent=2, allow_nan=False) + '\n')
        temporary = Path(file.name)
    temporary.replace(path)


def loudness(log):
    summary = log.rsplit('Summary:', 1)[-1]
    def field(pattern):
        match = re.search(pattern, summary)
        if not match:
            raise ValueError('FFmpeg did not report the expected loudness measurement')
        value = float(match.group(1))
        return value if math.isfinite(value) else None
    result = {
        'integrated_lufs': field(r'\bI:\s*(' + NUMBER + r')\s*LUFS'),
        'loudness_range_lu': field(r'\bLRA:\s*(' + NUMBER + r')\s*LU'),
        'true_peak_dbtp': field(r'\bPeak:\s*(' + NUMBER + r')\s*dBFS'),
    }
    series = []
    pattern = r't:\s*(' + NUMBER + r').*?\bM:\s*(' + NUMBER + r')\s+S:\s*(' + NUMBER + r')'
    for match in re.finditer(pattern, log):
        t, momentary, short = map(float, match.groups())
        # Drop filter warm-up; its initial -120.7 reading is not measured silence.
        if t >= .399:
            series.append({'seconds': round(t, 3),
                           'momentary_lufs': momentary if math.isfinite(momentary) else None,
                           'short_term_lufs': short if t >= 2.999 and math.isfinite(short) else None})
    result['timeline'] = series
    return result


def signal_metrics(audio, source_rate):
    frames, channels = audio.shape
    if frames < RATE:
        raise ValueError('Choose an excerpt of at least one second')
    sums = np.zeros(channels)
    squares = np.zeros(channels)
    cross = 0.0
    peak = 0.0
    mid_energy = side_energy = 0.0
    envelope = []
    for start in range(0, frames, RATE):
        block = np.asarray(audio[start:start + RATE], dtype=np.float64)
        if not np.isfinite(block).all():
            raise ValueError('Decoded audio contains non-finite samples')
        sums += block.sum(axis=0)
        squares += (block * block).sum(axis=0)
        local_peak = float(np.abs(block).max())
        local_power = float(np.mean(block * block))
        peak = max(peak, local_peak)
        rms = db(local_power)
        local_peak_db = db(local_peak * local_peak)
        envelope.append({'seconds': start / RATE, 'rms_dbfs': rms,
                         'peak_dbfs': local_peak_db,
                         'crest_db': local_peak_db - rms if rms is not None else None})
        if channels == 2:
            cross += float(np.sum(block[:, 0] * block[:, 1]))
            mid_energy += float(np.sum(((block[:, 0] + block[:, 1]) / 2) ** 2))
            side_energy += float(np.sum(((block[:, 0] - block[:, 1]) / 2) ** 2))
    rms_db = db(float(squares.sum()) / (frames * channels))
    peak_db = db(peak * peak)
    correlation = None
    side_fraction = None
    if channels == 2:
        variances = np.maximum(0, squares - sums * sums / frames)
        denominator = float(np.sqrt(np.prod(variances)))
        if denominator > 0:
            correlation = float(np.clip((cross - np.prod(sums) / frames) / denominator, -1, 1))
        if mid_energy + side_energy > 0:
            side_fraction = side_energy / (mid_energy + side_energy)

    window = np.hanning(FFT_SIZE)[:, None]
    power = np.zeros(FFT_SIZE // 2 + 1)
    mid_power = np.zeros_like(power)
    side_power = np.zeros_like(power)
    count = 0
    starts = list(range(0, frames - FFT_SIZE + 1, FFT_SIZE // 2))
    if starts[-1] != frames - FFT_SIZE:
        starts.append(frames - FFT_SIZE)
    for start in starts:
        spectrum = np.fft.rfft(np.asarray(audio[start:start + FFT_SIZE]) * window, axis=0)
        # Sum channel powers, never a mono fold-down: anti-phase energy must survive.
        power += np.mean(np.abs(spectrum) ** 2, axis=1)
        if channels == 2:
            mid_power += np.abs((spectrum[:, 0] + spectrum[:, 1]) / 2) ** 2
            side_power += np.abs((spectrum[:, 0] - spectrum[:, 1]) / 2) ** 2
        count += 1
    # One-sided periodogram scaling. Exclude DC and Nyquist below when integrating.
    scale = 2 / (RATE * float(np.sum(window * window)) * count)
    power *= scale
    mid_power *= scale
    side_power *= scale
    hz = np.fft.rfftfreq(FFT_SIZE, 1 / RATE)
    coverage = min(20000, source_rate / 2)
    total = float(power[(hz >= 20) & (hz < coverage)].sum())
    def bands(edges):
        result = []
        for low, high in edges:
            mask = (hz >= low) & (hz < min(high, coverage))
            energy = float(power[mask].sum())
            m, s = float(mid_power[mask].sum()), float(side_power[mask].sum())
            valid = high <= coverage and total > 0
            fraction = energy / total if valid else None
            result.append({'low_hz': float(low), 'high_hz': float(high),
                           'energy_fraction': fraction,
                           'relative_db': db(fraction) if fraction is not None else None,
                           'side_fraction': s / (m + s) if valid and channels == 2 and m + s > total * 1e-10 else None})
        return result
    active_crests = [row['crest_db'] for row in envelope
                     if row['rms_dbfs'] is not None and row['rms_dbfs'] > -60]
    return {'duration_seconds': frames / RATE, 'channels': channels,
            'rms_dbfs': rms_db, 'sample_peak_dbfs': peak_db,
            'crest_db': peak_db - rms_db if rms_db is not None else None,
            'median_1s_crest_db': float(np.median(active_crests)) if active_crests else None,
            'lr_correlation': correlation, 'side_energy_fraction': side_fraction,
            'spectrum_coverage_hz': coverage, 'bands': bands(BANDS),
            'spectrum': bands(zip(EDGES[:-1], EDGES[1:])), 'envelope_1s': envelope}


def analyze(entry, output):
    path = Path(entry['path']).expanduser().resolve(strict=True)
    start = float(entry.get('start_seconds', 0))
    duration = entry.get('duration_seconds')
    if not math.isfinite(start) or start < 0:
        raise ValueError('Start must be finite and nonnegative')
    if duration is not None and (not math.isfinite(float(duration)) or float(duration) < 1):
        raise ValueError('Duration must be finite and at least one second')
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    tool_version = command(['ffmpeg', '-version']).stdout.splitlines()[0]
    identity = {'source_sha256': digest.hexdigest(), 'start_seconds': start,
                'requested_duration_seconds': duration, 'analysis_version': VERSION,
                'ffmpeg_version': tool_version}
    key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()[:24]
    cache = output / 'profiles' / (key + '.json')
    label = entry.get('title', path.stem)
    group = entry.get('group', 'References')
    if cache.exists():
        result = json.loads(cache.read_text())
        result.update(title=label, group=group)
        return result, cache
    probe = json.loads(command(['ffprobe', '-v', 'error', '-select_streams', 'a:0',
                               '-show_entries', 'stream=sample_rate,channels', '-of', 'json', str(path)]).stdout)
    stream = probe['streams'][0]
    channels = int(stream['channels'])
    source_rate = int(stream['sample_rate'])
    if channels not in (1, 2):
        raise ValueError('Reference must be mono or stereo; multichannel audio is not silently downmixed')
    with tempfile.TemporaryDirectory(prefix='solo-reference-') as temporary:
        pcm = Path(temporary) / 'analysis.f32'
        args = ['ffmpeg', '-hide_banner', '-nostdin', '-nostats', '-threads', '1', '-i', str(path)]
        # atrim precedes the meter; output -ss alone would meter the wrong excerpt.
        trim = 'atrim=start=' + str(start)
        if duration is not None:
            trim += ':duration=' + str(float(duration))
        args += ['-map', '0:a:0', '-vn', '-sn', '-dn', '-af',
                 trim + ',asetpts=PTS-STARTPTS,aresample=48000,ebur128=peak=true:framelog=info',
                 '-c:a', 'pcm_f32le', '-f', 'f32le', str(pcm)]
        rendered = command(args)
        if pcm.stat().st_size < RATE * channels * 4:
            raise ValueError('The requested excerpt contains less than one second of audio')
        audio = np.memmap(pcm, dtype='<f4', mode='r').reshape(-1, channels)
        result = signal_metrics(audio, source_rate)
        del audio
        measured = loudness(rendered.stderr)
    if result['rms_dbfs'] is None:
        measured.update(integrated_lufs=None, loudness_range_lu=None, true_peak_dbtp=None)
    elif measured['integrated_lufs'] is not None and measured['integrated_lufs'] <= -70:
        measured.update(integrated_lufs=None, loudness_range_lu=None)
    if result['duration_seconds'] < 3:
        measured['loudness_range_lu'] = None
    result['loudness'] = measured
    peak, integrated = measured['true_peak_dbtp'], measured['integrated_lufs']
    result['peak_to_loudness_db'] = peak - integrated if peak is not None and integrated is not None else None
    result.update(identity, source_name=path.name, source_sample_rate=source_rate,
                  analysis_sample_rate=RATE, title=label, group=group,
                  provenance='Measured local audio; no model-generated metrics')
    write_json(cache, result)
    return result, cache


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path, help='Local JSON array: path, title, group; optional start_seconds/duration_seconds')
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parent / 'Local')
    parser.add_argument('--jobs', type=int, choices=range(1, 5), default=2)
    args = parser.parse_args()
    entries = json.loads(args.manifest.read_text())
    if not isinstance(entries, list) or not entries:
        parser.error('Manifest must contain at least one reference')
    identities = [(str(Path(e['path']).expanduser().resolve()), e.get('start_seconds', 0), e.get('duration_seconds')) for e in entries]
    if len(set(identities)) != len(identities):
        parser.error('The same source excerpt appears more than once')
    args.output.mkdir(parents=True, exist_ok=True)
    def work(entry):
        result, profile = analyze(entry, args.output)
        print('Analyzed: ' + result['title'], flush=True)
        return result, profile
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        completed = list(pool.map(work, entries))
    results = [item[0] for item in completed]
    write_json(args.output / 'comparison.json', {'analysis_version': VERSION, 'references': results})
    from report import make_report
    make_report(results, args.output)
    print('Report: ' + str(args.output / 'comparison.md'))


if __name__ == '__main__':
    main()

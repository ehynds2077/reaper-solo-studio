"""Small, measured evidence charts for model vision. No screenshots or audio uploads."""
import math
from pathlib import Path
import wave

import numpy as np
from charts import plt


def waveform(path, bins=1200):
    """Read our PCM render in bounded chunks; preserve peaks instead of decimating."""
    lows, highs = [], []
    with wave.open(str(path), 'rb') as source:
        channels, width = source.getnchannels(), source.getsampwidth()
        frames, rate = source.getnframes(), source.getframerate()
        if channels not in (1, 2) or width not in (2, 3, 4) or frames < 1:
            raise ValueError('Visual waveform requires mono/stereo PCM audio')
        stride = max(1, math.ceil(frames / bins))
        while True:
            raw = source.readframes(stride * 32)
            if not raw:
                break
            if width == 3:
                b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
                samples = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
                samples = (samples ^ 0x800000) - 0x800000
            else:
                samples = np.frombuffer(raw, dtype='<i%d' % width)
            samples = samples.reshape(-1, channels)
            for start in range(0, len(samples), stride):
                block = samples[start:start + stride]
                lows.append(float(block.min()) / 2 ** (width * 8 - 1))
                highs.append(float(block.max()) / 2 ** (width * 8 - 1))
    return np.arange(len(lows)) * stride / rate, np.array(lows), np.array(highs)


def label(value, size=70):
    # User track names remain data; prevent mathtext/line breaks from changing plots.
    return str(value).replace('$', '').replace('\n', ' ').replace('\r', ' ')[:size]


def save(fig, output):
    try:
        fig.savefig(output, dpi=110)
    finally:
        plt.close(fig)
    return Path(output)


def arrangement_chart(data, output):
    rows = data['tracks']; start, end = data['bounds']
    fig, axes = plt.subplots(len(rows), 1, figsize=(12, max(3, len(rows) * .46 + 1.4)),
                             sharex=True, squeeze=False, constrained_layout=True)
    for row, ax in zip(rows, axes[:, 0]):
        values = np.asarray(row['peaks'], dtype=float)
        maximum = float(values.max()) if len(values) else 0
        x = np.linspace(start, end, len(values), endpoint=False)
        color = '#999999' if row['muted'] else '#287eab'
        if maximum > 0:
            ax.fill_between(x, -values / maximum, values / maximum, color=color, linewidth=0)
        for clip in row['clips']:
            if clip['kind'] not in ('audio',):
                ax.axvspan(clip['start_seconds'], clip['end_seconds'], alpha=.2,
                           color='#ca982c' if clip['kind'] == 'midi' else '#c64747')
        flags = (' [muted]' if row['muted'] else '')
        if row['midi']: flags += ' [MIDI]'
        if row['unavailable']: flags += ' [peaks unavailable]'
        if row['truncated']: flags += ' [partial overview]'
        if not row['clips']: flags += ' [no active items; may be a bus]'
        ax.set_ylabel(label(row['name'] + flags, 60), rotation=0, ha='right', va='center', fontsize=8)
        ax.set_ylim(-1.1, 1.1); ax.set_yticks([]); ax.grid(axis='x', alpha=.2)
    axes[-1, 0].set(xlim=(start, end), xlabel='Project time (seconds)')
    first = data['start_track'] + 1
    fig.suptitle('Source clips · tracks %d–%d of %d\n'
                 'Each track scaled independently · NOT processed mix levels · '
                 'Gold: MIDI · Red: unavailable peaks%s' % (
                     first, first + len(rows) - 1, data['total_tracks'],
                     ' · Overview incomplete' if data['truncated'] else ''), fontsize=10)
    return save(fig, output)


def processed_chart(path, profile, references, regions, output):
    start, end = profile['measurement_bounds']
    x, low, high = waveform(path)
    fig, axes = plt.subplots(2, 2, figsize=(12, 7.3), constrained_layout=True)
    axes[0, 0].fill_between(x + start, low, high, color='#287eab', linewidth=0)
    axes[0, 0].set(title='Processed waveform · channel peak envelope',
                   xlabel='Project time (seconds)', ylabel='Amplitude (full scale = ±1)',
                   ylim=(-1.05, 1.05), xlim=(start, end))
    env = profile.get('envelope_1s', [])
    for key, name, color in [('rms_dbfs', 'RMS', '#287eab'), ('peak_dbfs', 'Peak', '#d28b21')]:
        axes[0, 1].plot([start + p['seconds'] for p in env],
                        [p.get(key) if p.get(key) is not None else float('nan') for p in env],
                        color=color, label=name)
    axes[0, 1].set(title='Processed level envelope', xlabel='Project time (seconds)',
                   ylabel='dBFS', ylim=(-72, 3), xlim=(start, end))
    axes[0, 1].legend(fontsize=8)
    for region in regions[:64]:
        t = region.get('start_seconds', -1)
        if start < t < end:
            for ax in axes[0]: ax.axvline(t, color='#777777', alpha=.3, linewidth=.6)
            axes[0, 0].text(t, .98, label(region.get('name', ''), 18), rotation=90,
                            fontsize=6, va='top', color='#555555')
    curves = [(profile, '#287eab')] + list(zip(references[:2], ['#d28b21', '#9266a9']))
    for row, color in curves:
        spectrum = row.get('spectrum', [])
        axes[1, 0].semilogx([(b['low_hz'] * b['high_hz']) ** .5 for b in spectrum],
                            [b['relative_db'] for b in spectrum], color=color,
                            label=label(row.get('title', 'Reference'), 42))
        bands = row.get('bands', [])
        axes[1, 1].plot([(b['low_hz'] * b['high_hz']) ** .5 for b in bands],
                        [100 * b['side_fraction'] if b.get('side_fraction') is not None else float('nan') for b in bands],
                        color=color)
    axes[1, 0].set(title='Tonal distribution · independently level-normalized',
                   xlabel='Frequency (Hz)', ylabel='Relative band energy (dB)', xlim=(20, 20000))
    axes[1, 0].legend(fontsize=8)
    axes[1, 1].set(title='Stereo side energy by band', xlabel='Frequency (Hz)',
                   ylabel='Side energy (%)', xscale='log', xlim=(20, 20000), ylim=(0, 100))
    for ax in axes.flat: ax.grid(alpha=.2)
    loudness = profile['loudness']
    def metric(value):
        return '—' if value is None else '%.1f' % value
    fig.suptitle('%s · %s · %.1f–%.1fs\n%s LUFS · %s dBTP · %s LU LRA · %s dB crest\n%s' % (
        label(profile['title']), 'Full selected passage' if profile['measurement_kind']=='full_passage' else 'Diagnostic window', start, end,
        metric(loudness.get('integrated_lufs')), metric(loudness.get('true_peak_dbtp')),
        metric(loudness.get('loudness_range_lu')), metric(profile.get('crest_db')),
        label(profile.get('scope', 'Full mix through routing and master FX'), 110)), fontsize=10)
    return save(fig, output)

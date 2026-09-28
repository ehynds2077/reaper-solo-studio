"""Comparison artifacts for measured reference profiles, with equal track weights."""
import csv
import json
import math
import os
import tempfile
from pathlib import Path

import numpy as np

os.environ.setdefault('MPLCONFIGDIR', str(Path(tempfile.gettempdir()) / 'solo-studio-matplotlib'))
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages

METRICS = [('integrated_lufs', 'Integrated loudness', 'LUFS'),
           ('true_peak_dbtp', 'True peak', 'dBTP'),
           ('loudness_range_lu', 'Loudness range', 'LU'),
           ('peak_to_loudness_db', 'Peak-to-loudness gap', 'dB'),
           ('median_1s_crest_db', 'Median 1-second crest factor', 'dB'),
           ('lr_correlation', 'L/R correlation', ''),
           ('side_energy_fraction', 'Side energy', '%')]
PALETTE = ['#ac641c', '#276aa4', '#398373', '#a34f6a']


def metric(row, key):
    value = row['loudness'][key] if key in row['loudness'] else row[key]
    return value * 100 if value is not None and key == 'side_energy_fraction' else value


def summary(values):
    values = [v for v in values if v is not None and math.isfinite(v)]
    if not values:
        return {'median': None, 'min': None, 'max': None}
    return {'median': float(np.median(values)), 'min': min(values), 'max': max(values)}


def aggregate(rows):
    groups = {}
    for row in rows:
        groups.setdefault(row['group'], []).append(row)
    result = {}
    for name, group in groups.items():
        result[name] = {
            'tracks': len(group),
            'metrics': {key: summary([metric(row, key) for row in group]) for key, _, _ in METRICS},
            'bands': [dict(low_hz=band['low_hz'], high_hz=band['high_hz'],
                           energy_percent=summary([100 * r['bands'][i]['energy_fraction']
                                                   if r['bands'][i]['energy_fraction'] is not None else None for r in group]),
                           relative_db=summary([r['bands'][i]['relative_db'] for r in group]),
                           side_percent=summary([100 * r['bands'][i]['side_fraction']
                                                 if r['bands'][i]['side_fraction'] is not None else None for r in group]))
                      for i, band in enumerate(group[0]['bands'])]
        }
    return groups, result


def number(value, digits=1):
    return 'n/a' if value is None else f'{value:.{digits}f}'


def md_name(value):
    return str(value).replace('|', '/').replace('\n', ' ')


def make_report(rows, output):
    output.mkdir(parents=True, exist_ok=True)
    groups, aggregates = aggregate(rows)
    (output / 'group-summary.json').write_text(json.dumps(aggregates, indent=2, allow_nan=False) + '\n')
    with (output / 'measurements.csv').open('w', newline='') as file:
        writer = csv.writer(file)
        writer.writerow(['Artist/group', 'Track', 'Duration seconds'] + [label + (' (' + unit + ')' if unit else '') for _, label, unit in METRICS])
        for row in rows:
            writer.writerow([row['group'], row['title'], row['duration_seconds']] + [metric(row, key) for key, _, _ in METRICS])
    lines = ['# Reference mix comparison', '',
             f'{len(rows)} measured audio files. Groups receive separate summaries; each track has equal weight within its group.', '',
             'The original audio was not changed. Spectral energy is normalized to each track’s total 20 Hz–20 kHz energy, separating tonal distribution from overall level. Raw loudness is retained separately.', '',
             '## Artist/group summaries', '',
             'Cells show median [minimum, maximum]. These are descriptive ranges for the selected files, not targets or confidence intervals.', '',
             '| Measurement | ' + ' | '.join(md_name(name) + f' (n={len(group)})' for name, group in groups.items()) + ' |',
             '|---|' + '---|' * len(groups)]
    for key, label, unit in METRICS:
        values = []
        for name in groups:
            s = aggregates[name]['metrics'][key]
            digits = 2 if key == 'lr_correlation' else 1
            values.append(f"{number(s['median'], digits)} [{number(s['min'], digits)}, {number(s['max'], digits)}]")
        lines.append('| ' + label + (' (' + unit + ')' if unit else '') + ' | ' + ' | '.join(values) + ' |')
    lines += ['', '## Tonal distribution', '',
              'Broad-band energy percentages are computed from L/R powers without folding to mono. They are not perceived loudness percentages or recommended EQ gains.', '',
              '| Band (Hz) | ' + ' | '.join(md_name(name) + ' median energy % [range]' for name in groups) + ' |',
              '|---|' + '---|' * len(groups)]
    for i, band in enumerate(rows[0]['bands']):
        values = []
        for name in groups:
            s = aggregates[name]['bands'][i]['energy_percent']
            values.append(f"{number(s['median'])} [{number(s['min'])}, {number(s['max'])}]")
        lines.append(f"| {band['low_hz']:g}–{band['high_hz']:g} | " + ' | '.join(values) + ' |')
    lines += ['', '## Individual tracks', '',
              '| Group / track | Seconds | LUFS-I | True peak dBTP | LRA LU | Peak−LUFS dB | L/R correlation | Side % |',
              '|---|---:|---:|---:|---:|---:|---:|---:|']
    for row in rows:
        values = [row['duration_seconds']] + [metric(row, k) for k in
                  ['integrated_lufs', 'true_peak_dbtp', 'loudness_range_lu', 'peak_to_loudness_db', 'lr_correlation', 'side_energy_fraction']]
        lines.append('| ' + md_name(row['group'] + ' / ' + row['title']) + ' | ' +
                     ' | '.join(number(v, 2 if i == 5 else 1) for i, v in enumerate(values)) + ' |')
    lines += ['', '## Reading the comparison', '',
              '- Within-album similarities can reflect common mastering as well as mixing. Tracks from one album are not independent examples of all good mixes.',
              '- Full-song averages depend on arrangement. Compare labeled verse/chorus excerpts before translating these into automation or EQ targets.',
              '- Loudness range (LRA), crest factor, and peak-to-loudness gap measure different aspects of dynamics; none directly measures how much compression was used.',
              '- Side energy is S²/(M²+S²), where M=(L+R)/2 and S=(L−R)/2. It is a stereo difference measure, not a quality score. Mono references have no L/R or side measurement.',
              '- Spectral bands use a 16,384-sample Hann window, 50% overlap, and channel-averaged powers at 48 kHz. Log bands contain equal frequency ratios. Absolute level cancels in the energy fractions.',
              '- Peak/RMS envelope points summarize one second, not individual waveform samples. Short-term LUFS uses 3-second windows; momentary LUFS uses 400 ms. Startup windows are omitted.',
              '- Audio is decoded to floating-point 48 kHz PCM; true peak is measured on that analysis signal with FFmpeg ebur128. Profiles record the decoder version and source fingerprint.',
              '- References below 40 kHz sample rate have incomplete high-frequency coverage; affected bands are marked unavailable. Silence has undefined level ratios.', '',
              '[FFmpeg ebur128 measurement documentation](https://ffmpeg.org/ffmpeg-filters.html#ebur128)', '',
              'Files: `overview.png`, `details.pdf`, `measurements.csv`, `group-summary.json`, `comparison.json`, and reusable `profiles/*.json`.', '']
    (output / 'comparison.md').write_text('\n'.join(lines))
    draw(rows, groups, output)


def draw(rows, groups, output):
    plt.rcParams.update({'font.family': 'DejaVu Sans', 'font.size': 9, 'axes.spines.top': False,
                         'axes.spines.right': False, 'axes.titleweight': 'bold', 'figure.facecolor': '#fbfaf7',
                         'axes.facecolor': '#fbfaf7', 'grid.color': '#dedbd4'})
    colors = {name: PALETTE[i % len(PALETTE)] for i, name in enumerate(groups)}
    fig, axes = plt.subplots(2, 2, figsize=(14, 10.5), gridspec_kw={'height_ratios': [1, 1.4]})
    fig.suptitle('What these reference mixes share — and where they differ', fontsize=18, x=.06, ha='left')
    scope = 'full-song measurements' if all(r.get('start_seconds', 0) == 0 and r.get('requested_duration_seconds') is None for r in rows) else 'selected excerpts'
    fig.text(.06, .935, f'{len(rows)} tracks · {scope} · lines = group medians · shading = observed min–max', fontsize=10)
    for name, group in groups.items():
        centers = np.array([math.sqrt(b['low_hz'] * b['high_hz']) for b in group[0]['spectrum']])
        for ax, field, factor in [(axes[0, 0], 'relative_db', 1), (axes[0, 1], 'side_fraction', 100)]:
            data = np.array([[b[field] if b[field] is not None else np.nan for b in row['spectrum']] for row in group]) * factor
            valid = np.isfinite(data).any(axis=0)
            if not valid.any():
                continue
            selected = data[:, valid]
            ax.fill_between(centers[valid], np.nanmin(selected, axis=0), np.nanmax(selected, axis=0), color=colors[name], alpha=.12)
            ax.plot(centers[valid], np.nanmedian(selected, axis=0), color=colors[name], lw=2, label=f'{name} (n={len(group)})')
    for ax in axes[0]:
        ax.set_xscale('log');ax.set_xlim(20, 20000)
        ax.set_xticks([30, 100, 300, 1000, 3000, 10000], ['30', '100', '300', '1k', '3k', '10k'])
        ax.set_xlabel('Frequency (Hz)');ax.grid(alpha=.65)
    axes[0, 0].set_title('Tonal balance, with overall level factored out', loc='left')
    axes[0, 0].set_ylabel('Band energy / total audible energy (dB)')
    axes[0, 0].legend(frameon=False, fontsize=9)
    axes[0, 1].set_title('Stereo difference by frequency', loc='left')
    axes[0, 1].set_ylabel('Side energy (%)');axes[0, 1].set_ylim(0, 100)
    labels = [row['title'] for row in rows]
    y = np.arange(len(rows))
    for ax, key, title in [(axes[1, 0], 'integrated_lufs', 'Original mastered loudness (LUFS-I)'),
                            (axes[1, 1], 'loudness_range_lu', 'Loudness variation within each song (LRA, LU)')]:
        for i, row in enumerate(rows):
            value = metric(row, key)
            if value is not None:
                ax.scatter(value, i, color=colors[row['group']], s=38, zorder=3)
        ax.set_yticks(y, labels if ax is axes[1, 0] else [''] * len(rows), fontsize=8)
        ax.invert_yaxis();ax.set_title(title, loc='left');ax.grid(axis='x', alpha=.65)
    fig.text(.06, .02, 'Mastered stereo references describe outcomes, not the settings that created them. These ranges are not an “ideal mix” target.', fontsize=9, color='#555555')
    fig.subplots_adjust(left=.20, right=.97, bottom=.07, top=.87, hspace=.34, wspace=.28)
    fig.savefig(output / 'overview.png', dpi=160)
    with PdfPages(output / 'details.pdf') as pdf:
        pdf.savefig(fig)
        plt.close(fig)
        for row in rows:
            fig, axes = plt.subplots(2, 1, figsize=(11.7, 8.3), sharex=True)
            fig.suptitle(row['group'] + ' — ' + row['title'], fontsize=16)
            timeline = row['loudness']['timeline']
            t = [v['seconds'] for v in timeline]
            axes[0].plot(t, [v['momentary_lufs'] for v in timeline], color=colors[row['group']], alpha=.25, lw=.7, label='Momentary (400 ms)')
            axes[0].plot(t, [v['short_term_lufs'] for v in timeline], color=colors[row['group']], lw=1.2, label='Short-term (3 s)')
            axes[0].set_ylabel('LUFS');axes[0].set_ylim(-45, 0);axes[0].legend(frameon=False)
            envelope = row['envelope_1s']
            t = [v['seconds'] for v in envelope]
            axes[1].plot(t, [v['peak_dbfs'] for v in envelope], label='Sample peak in each second', color=colors[row['group']], lw=1)
            axes[1].plot(t, [v['rms_dbfs'] for v in envelope], label='RMS in each second', color='#555555', lw=1)
            axes[1].set_ylabel('dBFS');axes[1].set_ylim(-60, 3);axes[1].set_xlabel('Seconds into analyzed song/excerpt');axes[1].legend(frameon=False)
            for ax in axes:
                ax.grid(alpha=.65);ax.set_xlim(0, row['duration_seconds'])
            fig.text(.10, .02, 'Peak/RMS envelopes summarize 1-second windows. Full measurement timelines are available in the saved JSON profile.', fontsize=9)
            fig.tight_layout(rect=[0, .04, 1, .95]);pdf.savefig(fig);plt.close(fig)

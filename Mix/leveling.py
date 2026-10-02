"""Full-passage level evidence, using locally measured one-second envelopes.

These are activity and balance proxies, not dry stems or perceptual judgments.
The agent chooses musical rides; this module never generates or applies gain.
"""
import math
import re
from statistics import median


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def percentile(values, fraction):
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lo = math.floor(position); hi = math.ceil(position)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (position - lo)


def targets(project):
    """Prioritize named, contributing vocals/guitars; do not double-count buses."""
    tracks = project.get('tracks', [])
    by_id = {row['id']: row for row in tracks}

    def ancestors(row):
        seen = set()
        while row.get('parent') in by_id and row['parent'] not in seen:
            seen.add(row['parent']); row = by_id[row['parent']]
            yield row

    def silent_fader(row):
        # Native zero gain, not a quiet dB threshold. Automation or a pre-fader
        # send can still contribute; retain those sources for measurement.
        return row.get('fader_silent') is True and not row.get('volume_automated') and not row.get('sends')

    audible = [row for row in tracks if not row.get('muted') and not silent_fader(row) and
               not any(parent.get('muted') for parent in ancestors(row))]
    candidates = []
    for row in audible:
        name = row.get('name', '').lower()
        role = ('vocal' if re.search(r'\b(vocals?|vox|vo[xc]|sing(?:er|ing)?|bgvs?)\b', name) else
                'guitar' if re.search(r'\b(guitars?|gtrs?|acoustic|electric)\b', name) else None)
        populated = row.get('playing_items_in_passage', row.get('items', 0)) > 0 or any(
            child.get('playing_items_in_passage', child.get('items', 0)) > 0 and row['id'] in {p['id'] for p in ancestors(child)}
            for child in audible)
        if role and populated:
            candidates.append({'track': row['id'], 'name': row.get('name', ''), 'role': role})
    return [row for row in candidates if not any(
        row['track'] in {p['id'] for p in ancestors(by_id[other['track']])}
        for other in candidates if other is not row)]


def level_report(track, mix, bounds, regions):
    start, end = bounds
    duration = end - start
    samples = {float(row['seconds']): row.get('rms_dbfs') for row in track.get('envelope_1s', [])
               if finite(row.get('seconds')) and 0 <= row['seconds'] < duration}
    levels = [value for value in samples.values() if finite(value) and value > -60]
    if len(levels) < 2:
        raise ValueError('Insufficient active level evidence; inspect activity/routing, never boost silence.')
    gate = max(-60, percentile(levels, .95) - 30)
    active = {seconds: value for seconds, value in samples.items() if finite(value) and value > gate}
    if len(active) < 2:
        raise ValueError('Too little active audio for a level review.')
    mix_levels = {float(row['seconds']): row.get('rms_dbfs') for row in mix.get('envelope_1s', [])
                  if finite(row.get('seconds'))}
    baseline = median(active.values())
    relative = {seconds: value - mix_levels[seconds] for seconds, value in active.items()
                if finite(mix_levels.get(seconds)) and mix_levels[seconds] > -60}
    relative_baseline = median(relative.values()) if relative else None

    def summarize(lo, hi):
        values = [value for seconds, value in active.items() if lo <= start + seconds < hi]
        ratios = [value for seconds, value in relative.items() if lo <= start + seconds < hi]
        row = {'start_seconds': round(lo, 3), 'end_seconds': round(hi, 3),
               'active_samples': len(values),
               'active_fraction': round(min(1, len(values) / max(1, hi - lo)), 3)}
        if values:
            row.update(active_rms_median_dbfs=round(median(values), 2),
                       level_delta_db=round(median(values) - baseline, 2))
        if ratios:
            row.update(track_minus_mix_db=round(median(ratios), 2),
                       balance_delta_db=round(median(ratios) - relative_baseline, 2))
        row['review_level_change'] = len(values) >= 2 and (
            abs(row.get('level_delta_db', 0)) >= 3 or abs(row.get('balance_delta_db', 0)) >= 3)
        return row

    # Keep short phrases visible without sending an unbounded per-sample table.
    window = max(4, math.ceil(duration / 80))
    windows = [summarize(start + i * window, min(end, start + (i + 1) * window))
               for i in range(math.ceil(duration / window))]
    sections = []
    for region in regions:
        lo, hi = region.get('start_seconds'), region.get('end_seconds')
        if finite(lo) and finite(hi) and min(end, hi) > max(start, lo):
            sections.append({'name': region.get('name', ''), **summarize(max(start, lo), min(end, hi))})
    return {'measurement_bounds': list(bounds), 'time_units': 'absolute project seconds',
            'activity_gate_dbfs': round(gate, 2), 'active_samples': len(active),
            'active_rms_median_dbfs': round(baseline, 2),
            'active_rms_p90_minus_p10_db': round(percentile(list(active.values()), .9) - percentile(list(active.values()), .1), 2),
            'window_seconds': window, 'windows': windows, 'sections': sections[:64],
            'sections_truncated': len(sections) > 64,
            'review_windows': sum(row['review_level_change'] for row in windows),
            'interpretation': 'Positive deltas mean louder/more prominent than this track\'s active median; negative means quieter. '
                'Flags are review candidates, not required gain corrections. Activity gating excludes gaps and very low noise, '
                'but cannot distinguish quiet playing from bleed. Compare like musical roles/sections. '
                'Track-minus-mix is a solo-in-place proxy affected by shared returns and nonlinear master processing; '
                'never subtract powers, normalize all instruments to equal RMS, or treat it as audibility.'}

"""Local planning helpers. No audio edits, provider calls or file access."""
import copy
import math
import json


def model_evidence(value):
    """Only shorten timelines at the model boundary; local analysis keeps every second."""
    if isinstance(value, list):
        return [model_evidence(row) for row in value]
    if not isinstance(value, dict):
        return value
    result = {key: model_evidence(row) for key, row in value.items() if key != 'envelope_1s'}
    if 'envelope_1s' in value:
        rows = value['envelope_1s']
        step = max(1, math.ceil(len(rows) / 90))
        result['envelope_1s'] = copy.deepcopy(rows[::step])
        result['envelope_summary_stride_seconds'] = (rows[1]['seconds'] - rows[0]['seconds']) * step if len(rows) > 1 else None
    return result


def compact_history(messages, keep=6):
    """Retain tool-call linkage and outcomes; retire older dense numeric tables."""
    evidence = []
    for message in messages:
        if message.get('role') != 'tool' or not isinstance(message.get('content'), str):
            continue
        try:
            result = json.loads(message['content'])
        except (ValueError, TypeError):
            continue
        if isinstance(result, dict) and any(key in result for key in ('envelope_1s', 'reports', 'profiles')):
            evidence.append((message, result))
    def reduced(value):
        if isinstance(value, list):
            return [reduced(row) for row in value]
        if isinstance(value, dict):
            return {key: reduced(row) for key, row in value.items() if key not in ('envelope_1s', 'spectrum', 'windows')}
        return value
    for message, result in evidence[:-keep]:
        result = reduced(result)
        result['detail_omitted'] = 'Older dense tables omitted; summary metrics and tool outcomes retained. Use recent evidence for current edits.'
        message['content'] = json.dumps(result, allow_nan=False)


def trim_value(points, seconds):
    if not points:
        return 0.0
    if seconds <= points[0]['seconds']:
        return points[0]['db']
    for left, right in zip(points, points[1:]):
        if seconds <= right['seconds']:
            fraction = (seconds - left['seconds']) / (right['seconds'] - left['seconds'])
            return left['db'] + fraction * (right['db'] - left['db'])
    return points[-1]['db']


def phrase_envelope(existing, rides, bounds):
    """Absolute gain plateaus, short linear transitions, preserving other owned rides."""
    lo, hi = bounds
    points = copy.deepcopy(existing) or [{'seconds': lo, 'db': 0}, {'seconds': hi, 'db': 0}]
    previous = lo - 1
    for point in points:
        if not lo <= point['seconds'] <= hi or point['seconds'] <= previous or not -12 <= point['db'] <= 6:
            raise ValueError('Existing trim envelope cannot be safely merged; inspect its full points.')
        previous = point['seconds']
    if points[0] != {'seconds': lo, 'db': 0} or points[-1] != {'seconds': hi, 'db': 0}:
        raise ValueError('Existing trim must have zero-dB selected-passage endpoints.')
    spans = []
    for ride in sorted(rides, key=lambda row: row['start_seconds']):
        start, end = ride['start_seconds'], ride['end_seconds']
        ramp = ride.get('ramp_seconds', .5)
        # Gain is held throughout [start,end]. Passage endpoints stay at zero;
        # require room for the transition instead of silently shortening a phrase.
        if not lo < start < end < hi:
            raise ValueError('Phrase start/end must be inside the selected passage, with room for zero-dB endpoints.')
        a, b = max(lo, start - ramp), min(hi, end + ramp)
        if spans and a < spans[-1][1]:
            raise ValueError('Phrase rides including ramps must not overlap; combine adjacent phrases into one ride.')
        spans.append((a, b))
        left, right = trim_value(points, a), trim_value(points, b)
        points = [p for p in points if not a <= p['seconds'] <= b]
        points.extend([{'seconds': a, 'db': left}, {'seconds': start, 'db': ride['gain_db']},
                       {'seconds': end, 'db': ride['gain_db']}, {'seconds': b, 'db': right}])
        points = sorted({p['seconds']: p for p in points}.values(), key=lambda p: p['seconds'])
    if len(points) > 256:
        raise ValueError('Merged envelope exceeds 256 points; simplify existing rides before adding more.')
    return points


def changed_trim_spans(before, after, bounds):
    times = sorted({bounds[0], bounds[1]} | {p['seconds'] for p in before + after})
    spans = []
    for start, end in zip(times, times[1:]):
        if max(abs(trim_value(before, t) - trim_value(after, t)) for t in (start, end)) > .01:
            if spans and start == spans[-1][1]:
                spans[-1][1] = end
            else:
                spans.append([start, end])
    return spans


def check_windows(spans, bounds, maximum=3):
    """Context around changed phrases, bounded to 3 x 24 seconds for quick checks."""
    lo, hi = bounds
    windows = []
    expanded = []
    for start, end in spans:
        if end - start > 24:
            expanded.extend([[start, min(end, start + 12)],
                             [(start + end) / 2 - 6, (start + end) / 2 + 6],
                             [max(start, end - 12), end]])
        else:
            expanded.append([start, end])
    for start, end in sorted(expanded):
        center = (start + end) / 2
        width = min(24, max(12, end - start + 8), hi - lo)
        a = max(lo, min(center - width / 2, hi - width))
        # Align to the baseline's one-second sample grid for fair comparisons.
        a = lo + math.floor(a - lo)
        b = min(hi, a + math.ceil(width))
        if windows and a <= windows[-1][1] and b - windows[-1][0] <= 24:
            windows[-1][1] = max(b, windows[-1][1])
        elif not any(a >= x and b <= y for x, y in windows):
            windows.append([a, b])
    if len(windows) > maximum:
        indexes = [round(i * (len(windows) - 1) / (maximum - 1)) for i in range(maximum)] if maximum > 1 else [len(windows) // 2]
        return [windows[i] for i in indexes]
    return windows


def active_check_window(profile, bounds):
    """Choose a 24-second source-active window, even when the mix's chorus has no vocals."""
    rows = [row for row in profile.get('envelope_1s', [])
            if isinstance(row.get('rms_dbfs'), (int, float)) and math.isfinite(row['rms_dbfs'])]
    if not rows:
        return check_windows([[bounds[0], bounds[0]]], bounds, 1)[0]
    # A median active time avoids locking every tonal check to one transient peak.
    active = [row['seconds'] for row in rows if row['rms_dbfs'] > max(-60, max(r['rms_dbfs'] for r in rows) - 24)]
    center = bounds[0] + sorted(active or [rows[0]['seconds']])[len(active) // 2 if active else 0]
    return check_windows([[center - 8, center + 8]], bounds, 1)[0]


def slice_profile(profile, source_bounds, window):
    """Shift cached full-resolution envelopes into a diagnostic window's time origin."""
    offset = window[0] - source_bounds[0]
    return {'duration_seconds': window[1] - window[0], 'envelope_1s': [
        {**row, 'seconds': row['seconds'] - offset}
        for row in profile.get('envelope_1s', [])
        if offset <= row['seconds'] < window[1] - source_bounds[0]]}


def simplify_curve(points, tolerance=.1):
    """Bound vertical error in dB, retaining the segment endpoints."""
    if len(points) < 3:
        return points
    keep = {0, len(points) - 1}; pending = [(0, len(points) - 1)]
    while pending:
        a, b = pending.pop()
        if b <= a + 1:
            continue
        left, right = points[a], points[b]
        errors = [(abs(points[i]['db'] - (left['db'] + (right['db'] - left['db']) *
                   (points[i]['seconds'] - left['seconds']) / (right['seconds'] - left['seconds']))), i)
                  for i in range(a + 1, b)]
        error, index = max(errors)
        if error > tolerance:
            keep.add(index); pending.extend([(a, index), (index, b)])
    return [points[i] for i in sorted(keep)]


def level_curve(profile, existing, bounds, start=None, end=None, window_seconds=3,
                strength=.5, max_boost_db=3, max_cut_db=6, slew_db_per_second=1.5):
    """Partial inverse of activity-gated moving RMS; no transient peak normalization.

    Corrections are added to existing owned trim exactly once by the plan/apply
    protocol. Predicted levels are linear estimates, not rendered verification.
    """
    from statistics import median
    from leveling import finite, percentile
    start = bounds[0] if start is None else start
    end = bounds[1] if end is None else end
    if not bounds[0] <= start < end <= bounds[1] or end - start < 1:
        raise ValueError('Choose at least one second within the selected passage.')
    if existing:
        # Validate existing boundary/order/range invariants without changing them.
        phrase_envelope(existing, [], bounds)
    rows = []
    for row in profile.get('envelope_1s', []):
        if not finite(row.get('seconds')):
            continue
        seconds = bounds[0] + row['seconds'] + .5
        if bounds[0] < seconds < bounds[1]:
            rows.append({'seconds': seconds, 'rms_dbfs': row.get('rms_dbfs'), 'peak_dbfs': row.get('peak_dbfs')})
    values = [r['rms_dbfs'] for r in rows if finite(r['rms_dbfs']) and r['rms_dbfs'] > -60]
    if len(values) < 3:
        raise ValueError('Too little active audio for a continuous level curve; do not boost silence.')
    gate = max(-60, percentile(values, .95) - 30)
    for row in rows:
        row['active'] = finite(row['rms_dbfs']) and row['rms_dbfs'] > gate
    active = [r for r in rows if r['active']]
    for row in rows:
        nearby = [r['rms_dbfs'] for r in active if abs(r['seconds'] - row['seconds']) <= window_seconds / 2]
        row['smoothed_rms_dbfs'] = 10 * math.log10(sum(10 ** (v / 10) for v in nearby) / len(nearby)) if row['active'] and nearby else None
    smoothed = [r['smoothed_rms_dbfs'] for r in rows if r['smoothed_rms_dbfs'] is not None]
    if len(smoothed) < 3:
        raise ValueError('Too little active audio above the gate for a level curve.')
    target = median(smoothed)
    # A short quiet selection must be compared with the performance, not with
    # itself. Keep full-passage smoothing/target context, then restrict edits.
    rows = [row for row in rows if start < row['seconds'] < end]
    active = [row for row in rows if row['active']]
    if not active:
        raise ValueError('No active audio in this range; do not boost silence.')
    smoothed = [row['smoothed_rms_dbfs'] for row in active]
    values = [{'seconds': start, 'correction_db': 0, 'active': False}]
    for row in rows:
        correction = strength * (target - row['smoothed_rms_dbfs']) if row['active'] else 0
        values.append({**row, 'correction_db': max(-max_cut_db, min(max_boost_db, correction))})
    values.append({'seconds': end, 'correction_db': 0, 'active': False})
    # Forward/backward slew limiting anticipates transitions into silent gaps;
    # inactive frames stay exactly at zero correction and cannot lift noise.
    for sequence in (values, list(reversed(values))):
        for previous, row in zip(sequence, sequence[1:]):
            if row['active']:
                delta = slew_db_per_second * abs(row['seconds'] - previous['seconds'])
                row['correction_db'] = max(previous['correction_db'] - delta,
                                           min(previous['correction_db'] + delta, row['correction_db']))
    correction_points = [{'seconds': r['seconds'], 'db': r['correction_db']} for r in values]
    times = sorted({bounds[0], bounds[1]} | {p['seconds'] for p in existing + correction_points})
    points = []
    for seconds in times:
        correction = trim_value(correction_points, seconds) if start <= seconds <= end else 0
        total = max(-12, min(6, trim_value(existing, seconds) + correction))
        points.append({'seconds': seconds, 'db': total})
    outside = [p for p in points if p['seconds'] < start or p['seconds'] > end]
    inside = [p for p in points if start <= p['seconds'] <= end]
    # Keep every zero-correction anchor (including silent samples) so simplifying
    # a long curve cannot introduce a boost into a gap.
    anchors = {start, end} | {r['seconds'] for i, r in enumerate(values) if not r['active'] and
                             (i == 0 or i == len(values) - 1 or values[i - 1]['active'] or values[i + 1]['active'])}
    anchors.update(p['seconds'] for p in existing if start <= p['seconds'] <= end and
                   abs(trim_value(correction_points, p['seconds'])) < 1e-9)
    def simplify(tolerance):
        result = []; part = []
        for point in inside:
            part.append(point)
            if point['seconds'] in anchors and len(part) > 1:
                result.extend(simplify_curve(part, tolerance)[:-1]); part = [point]
        result.extend(simplify_curve(part, tolerance))
        return sorted(outside + result, key=lambda p: p['seconds'])
    tolerance = .1
    reduced = simplify(tolerance)
    while len(reduced) > 256 and tolerance < .4:
        tolerance *= 2; reduced = simplify(tolerance)
    if len(reduced) > 256:
        raise ValueError('Curve needs more than 256 points while preserving gaps/other rides. Choose a shorter range.')
    for row in values:
        row['applied_correction_db'] = trim_value(reduced, row['seconds']) - trim_value(existing, row['seconds'])
    predicted = [r['smoothed_rms_dbfs'] + r['applied_correction_db'] for r in values if r['active']]
    spread = lambda v: round(percentile(v, .9) - percentile(v, .1), 2)
    return {'range': [start, end], 'window_seconds': window_seconds, 'strength': strength,
            'activity_gate_dbfs': round(gate, 2), 'target_smoothed_rms_dbfs': round(target, 2),
            'max_boost_db': max_boost_db, 'max_cut_db': max_cut_db, 'slew_db_per_second': slew_db_per_second,
            'active_samples': len(active), 'before_spread_db': spread(smoothed),
            'predicted_spread_db': spread(predicted), 'curve_tolerance_db': tolerance,
            'correction_range_db': [round(min(r['applied_correction_db'] for r in values), 2),
                                    round(max(r['applied_correction_db'] for r in values), 2)],
            'points': reduced, 'curve': values,
            'interpretation': 'Partial inverse of moving, activity-gated RMS over actual processed track contribution. '
                'Peak/RMS values are one-second measurements, not note boundaries or perceived loudness. '
                'Predicted spread assumes linear gain; shared buses/master limiting may change the actual result. '
                'Existing owned trim is included; user envelopes and clips are untouched. Verify and audition.'}

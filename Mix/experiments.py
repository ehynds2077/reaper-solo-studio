"""Local checkpoint comparisons; preserve the candidate and never upload audio."""
import math
from pathlib import Path
import subprocess
import uuid


def compare(session, args):
    from worker import analyze_audio, compact, write
    ids = args['ids']
    if len(set(ids)) != len(ids):
        raise ValueError('Choose distinct checkpoints')
    listed = session.bridge('list_mix_checkpoints', {})
    if listed.get('error'):
        return listed
    known = {row['id']: row for row in listed['checkpoints']}
    if any(ident not in known for ident in ids):
        raise ValueError('Unknown checkpoint; list_mix_checkpoints first')
    session.batch_budget(4 + 2 * len(ids))
    bounds = session.measurement_window(args)
    saved = session.bridge('save_mix_checkpoint', {'name': 'Temporary comparison return'})
    if saved.get('error'):
        return saved
    profiles = []
    try:
        for ident in ids:
            restored = session.mix_edit('restore_mix_checkpoint', {'id': ident})
            if restored.get('error'):
                raise ValueError(restored['error'])
            rendered = session.bridge('measure_mix', {'start_seconds': bounds[0], 'duration_seconds': bounds[1] - bounds[0]})
            if rendered.get('error'):
                raise ValueError(rendered['error'])
            path = Path(rendered['path']).resolve()
            if path.parent != session.dir.resolve() or path.suffix.lower() != '.wav' or rendered['bounds'] != bounds:
                raise ValueError('Unexpected comparison render path/bounds')
            profile = analyze_audio(path, session.dir, known[ident]['name'])
            loudness = profile.get('loudness', {}).get('integrated_lufs')
            if not isinstance(loudness, (int, float)) or not math.isfinite(loudness):
                raise ValueError('An experiment has no measurable audio in this window')
            if abs(profile['duration_seconds'] - (bounds[1] - bounds[0])) > .1:
                raise ValueError('Incomplete experiment render')
            profiles.append({'id': ident, 'name': known[ident]['name'], 'profile': profile, 'path': path})
    finally:
        # Cancellation still has to return the session to the user's candidate.
        session.checkpoint_cleanup = True
        try:
            restored = session.mix_edit('restore_mix_checkpoint', {'id': saved['id']})
            if restored.get('error'):
                raise RuntimeError('Could not restore the starting candidate; use checkpoint %s: %s' % (saved['id'], restored['error']))
            session.bridge('delete_mix_checkpoint', {'id': saved['id']})
        finally:
            session.checkpoint_cleanup = False
    if session.cancelled():
        raise RuntimeError('Session cancelled; starting candidate restored')
    target = min(row['profile']['loudness']['integrated_lufs'] for row in profiles)
    ident = uuid.uuid4().hex[:16]; folder = session.dir / 'experiments'; folder.mkdir(exist_ok=True)
    rows = []
    for index, row in enumerate(profiles):
        gain = target - row['profile']['loudness']['integrated_lufs']
        output = folder / ('%s-%d-matched.wav' % (ident, index + 1))
        subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-i', str(row['path']),
                        '-af', 'volume=%.9fdB' % gain, '-c:a', 'pcm_s24le', str(output)], check=True, timeout=120)
        rows.append({'id': row['id'], 'name': row['name'], 'measurement': compact(row['profile']),
                     'display_gain_db': gain, 'audition_file': str(output.relative_to(session.dir))})
    result = {'bounds': bounds, 'matched_lufs': target, 'experiments': rows, 'candidate_restored': True,
              'note': 'Audition copies are attenuated to equal integrated loudness. Different dynamics/peaks remain. Restore your preferred checkpoint explicitly; no automatic winner.'}
    try:
        from charts import plt
        figure, axes = plt.subplots(2, 1, figsize=(11, 6), sharex=True)
        for source, row in zip(profiles, rows):
            env = source['profile'].get('envelope_1s', [])
            x = [bounds[0] + p['seconds'] for p in env]
            for ax, key, gain in [(axes[0], 'rms_dbfs', row['display_gain_db']), (axes[1], 'crest_db', 0)]:
                ax.plot(x, [p[key] + gain if p.get(key) is not None else float('nan') for p in env], label=row['name'])
        axes[0].set_ylabel('Matched RMS (dBFS)'); axes[1].set_ylabel('Peak / RMS (dB)'); axes[1].set_xlabel('Song time (seconds)')
        for ax in axes: ax.legend(); ax.grid(alpha=.2)
        figure.suptitle('Same passage, matched loudness — dynamics remain audible'); figure.tight_layout()
        visual_folder = session.dir / 'visuals'; visual_folder.mkdir(exist_ok=True)
        chart = visual_folder / ('experiments-' + ident + '.png'); figure.savefig(chart, dpi=130); plt.close(figure)
        result['chart'] = str(chart.relative_to(session.dir))
        if session.visuals_enabled: session.queue_image(chart, result['note'])
    except ImportError:
        result['chart_unavailable'] = True
    write(folder / (ident + '.json'), result)
    session.publish('Compared %d experiments at matched loudness; starting candidate restored.' % len(rows))
    return result

"""Export comparable measured curves without audio or project file paths."""
import os
import tempfile
os.environ.setdefault('MPLCONFIGDIR', tempfile.gettempdir() + '/solo-studio-matplotlib')
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt


def render_charts(measurements, references, output):
    fig, axes = plt.subplots(2, 2, figsize=(12, 7), constrained_layout=True)
    curves = [measurements[0], measurements[-1]] + references
    colors = ['#8a969c', '#398bb0', '#d49839', '#9468b3']
    for profile, color in zip(curves, colors):
        spectrum = profile.get('spectrum', [])
        x = [(b['low_hz'] * b['high_hz']) ** .5 for b in spectrum]
        axes[0, 0].semilogx(x, [b['relative_db'] for b in spectrum], label=profile['title'], color=color)
        bands = profile['bands']
        axes[0, 1].plot(range(len(bands)), [100 * b['side_fraction'] if b['side_fraction'] is not None else float('nan') for b in bands], color=color)
    axes[0, 0].set(title='Tonal balance · fraction of 20 Hz–20 kHz energy', xlabel='Frequency (Hz)', ylabel='Relative band energy (dB)')
    axes[0, 0].legend(fontsize=8)
    axes[0, 1].set(title='Stereo side energy by band', ylabel='Side fraction (%)', xticks=range(7), xticklabels=['20–60','60–150','150–400','400–2k','2–5k','5–10k','10–20k'])
    for profile, color in zip([measurements[0], measurements[-1]], colors):
        env = profile['envelope_1s']
        axes[1, 0].plot([e['seconds'] for e in env], [e['rms_dbfs'] for e in env], color=color, label=profile['title'])
        axes[1, 1].plot([e['seconds'] for e in env], [e['crest_db'] for e in env], color=color)
    axes[1, 0].set(title='Level envelope · one-second RMS', xlabel='Excerpt seconds', ylabel='dBFS')
    axes[1, 1].set(title='Transient crest · one-second peak minus RMS', xlabel='Excerpt seconds', ylabel='dB')
    for ax in axes.flat:
        ax.grid(alpha=.2)
    fig.suptitle('Solo Studio — measured original, candidate and references', fontsize=15)
    fig.savefig(output, dpi=160)
    plt.close(fig)

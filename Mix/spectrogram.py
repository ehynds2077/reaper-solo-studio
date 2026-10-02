"""Bounded-memory, channel-power STFT of existing PCM renders; no DAW operations."""
import math
import wave
import numpy as np


def decode(raw, width, channels):
    if width == 3:
        b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
        values = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        values = (values ^ 0x800000) - 0x800000
    else:
        values = np.frombuffer(raw, dtype='<i%d' % width)
    return values.reshape(-1, channels).astype(np.float64) / 2 ** (width * 8 - 1)


def spectrum_over_time(path, max_columns=900, fft_size=8192):
    """Mean stereo power, not L+R: anti-phase content remains visible.

    Every overlapping Hann frame contributes to a time bucket. Logarithmic
    frequency bands merge unresolved FFT bins. Values are band RMS power dBFS,
    not LUFS, gain reduction, or levels independently normalized per column.
    """
    if not 8 <= max_columns <= 2000 or fft_size < 256 or fft_size & (fft_size - 1):
        raise ValueError('Invalid spectrogram resolution')
    with wave.open(str(path), 'rb') as source:
        rate, frames = source.getframerate(), source.getnframes()
        channels, width = source.getnchannels(), source.getsampwidth()
        if channels not in (1, 2) or width not in (2, 3, 4) or frames < 1 or rate < 1000:
            raise ValueError('Spectrogram requires a nonempty mono/stereo PCM render')
        hop = fft_size // 2; duration = frames / rate
        bins = min(max_columns, max(1, math.ceil(frames / hop)))
        df = rate / fft_size
        indexes = np.unique(np.clip(np.round(np.geomspace(20, min(20000, rate / 2), 161) / df),
                                    1, fft_size // 2).astype(int))
        frequencies = np.maximum(.1, (indexes - .5) * df)
        sums = np.zeros((len(indexes) - 1, bins)); counts = np.zeros(bins)
        window = np.hanning(fft_size)
        normalization = fft_size * np.square(window).sum()
        for first in range(0, frames, hop * 32):
            centers = np.arange(first, min(frames, first + hop * 32), hop)
            lo = int(centers[0]) - fft_size // 2
            required = (len(centers) - 1) * hop + fft_size
            source.setpos(max(0, lo))
            samples = decode(source.readframes(required - max(0, -lo)), width, channels)
            samples = np.pad(samples, ((max(0, -lo), max(0, required - max(0, -lo) - len(samples))), (0, 0)))
            windows = np.lib.stride_tricks.sliding_window_view(samples, fft_size, axis=0)[::hop]
            fft = np.fft.rfft(windows * window, axis=-1)
            powers = np.mean(np.abs(fft) ** 2, axis=1) / normalization
            powers[:, 1:-1] *= 2
            prefix = np.pad(np.cumsum(powers, axis=1), ((0, 0), (1, 0)))
            bands = prefix[:, indexes[1:]] - prefix[:, indexes[:-1]]
            columns = np.minimum(bins - 1, (centers / frames * bins).astype(int))
            for column, values in zip(columns, bands):
                sums[:, column] += values; counts[column] += 1
        power = sums / np.maximum(1, counts)
        return {'time_edges': np.linspace(0, duration, bins + 1), 'frequency_edges': frequencies,
                'power': power, 'dbfs': 10 * np.log10(np.maximum(power, 1e-9)),
                'sample_rate': rate, 'fft_size': fft_size, 'hop_seconds': hop / rate,
                'duration_seconds': duration, 'units': 'Log-frequency band power, mean across channels (dBFS)'}

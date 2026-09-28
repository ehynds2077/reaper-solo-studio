"""Deterministic stimuli and an instrumented copy of the production JSFX.

Only the two extra diagnostic outputs differ from the production DSP. Channels
1/2 remain available to verify its pass-through or mute behavior sample by sample.
"""
from pathlib import Path
import json, wave
import numpy as np

HERE=Path(__file__).resolve().parent
ROOT=HERE.parent.parent
sr=48000
rng=np.random.default_rng(734)
cases=[];audio=[];cursor=0
def add(name,midi=None,cents=0,kind='sine',duration=.85,amp=.35):
    global cursor
    n=round(duration*sr);t=np.arange(n)/sr
    hz=440*2**(((midi-69)/12)+(cents/1200)) if midi is not None else 0
    if kind=='silence': x=np.zeros(n)
    elif kind=='noise': x=rng.normal(0,.08,n)
    elif kind=='below_gate': x=.00003*np.sin(2*np.pi*hz*t)
    else:
        amplitudes={'sine':[1],'pluck':[1,.7,.4,.2,.1], 'weak':[.08,1,.65,.35], 'noisy':[1,.4,.2]}[kind]
        x=sum(a*np.sin(2*np.pi*hz*h*t+.31*h) for h,a in enumerate(amplitudes,1))
        x*=amp/sum(amplitudes)
        if kind=='pluck': x*=np.exp(-t/.55)
        if kind=='noisy': x+=rng.normal(0,amp*.02,n)
        x*=np.minimum(1,t/.005)
    cases.append(dict(name=name,start=cursor,end=cursor+duration,hz=hz,kind=kind))
    # Opposite polarity catches accidental stereo-sum detection on a mono input.
    audio.append(np.column_stack([x,-x]));cursor+=duration
add('initial silence',kind='silence',duration=.5)
for midi in [40,45,50,55,59,64]:
    for cents in [-17,-.1,0,.1,13]: add(f'note {midi} {cents:+g} cents',midi,cents)
for midi in [23,28,33,38]:
    for cents in [-9,0,11]: add(f'bass {midi} {cents:+g}',midi,cents)
for midi in [76,83,88]: add(f'high note {midi}',midi,9)
for midi in [28,40,45,50,55,59,64]: add(f'pluck {midi}',midi,4,kind='pluck')
for midi in [28,40,45]: add(f'weak fundamental {midi}',midi,-5,kind='weak')
add('noisy E2',40,7,kind='noisy')
add('below gate',40,kind='below_gate')
add('noise rejection',kind='noise')
add('final silence',kind='silence')
data=np.concatenate(audio)
pcm=np.clip(np.round(data*8388607),-8388608,8388607).astype('<i4')
packed=pcm.view(np.uint8).reshape(-1,4)[:,:3].tobytes()
with wave.open(str(HERE/'stimuli.wav'),'wb') as w:
    w.setnchannels(2);w.setsampwidth(3);w.setframerate(sr);w.writeframes(packed)
(HERE/'cases.json').write_text(json.dumps(dict(sample_rate=sr,duration=cursor,cases=cases),indent=2))
source=(ROOT/'Effects/Solo Studio Strobe.jsfx').read_text()
qa=source.replace('desc:Solo Studio Strobe','desc:Solo Studio Strobe QA (test only)',1)
qa=qa.replace('out_pin:Right','out_pin:Right\nout_pin:Measured Hz divided by 2000\nout_pin:Confidence\nout_pin:Fundamental phase\nout_pin:Target Hz divided by 2000\nout_pin:Second harmonic phase\nout_pin:Fourth harmonic phase',1)
qa=qa.replace('\n@gfx 760 500','\n// Test harness telemetry; production analysis above is unchanged.\nspl2=slider13 ? slider10/2000 : 0;\nspl3=slider11;\nspl4=atan2(band1.i4,band1.q4)/(2*$pi);\nspl5=target_hz/2000;\nspl6=atan2(band2.i4,band2.q4)/(2*$pi);\nspl7=atan2(band4.i4,band4.q4)/(2*$pi);\n\n@gfx 760 500',1)
(HERE/'Strobe QA.jsfx').write_text(qa)
print(f'{len(cases)} cases, {cursor:.2f} seconds; wrote stimuli and instrumented plugin')

cases=[];audio=[];cursor=0
for midi in [40,64]:
    for cents in [-5,-.1,0,.1,5]: add(f'phase {midi} {cents:+g}',midi,cents,kind='weak',duration=1.4)
data=np.concatenate(audio)
pcm=np.clip(np.round(data*8388607),-8388608,8388607).astype('<i4')
with wave.open(str(HERE/'phase-stimuli.wav'),'wb') as w:
    w.setnchannels(2);w.setsampwidth(3);w.setframerate(sr)
    w.writeframes(pcm.view(np.uint8).reshape(-1,4)[:,:3].tobytes())
(HERE/'phase-cases.json').write_text(json.dumps(dict(sample_rate=sr,duration=cursor,cases=cases),indent=2))

# Standalone preview audio is also generated, never taken from a recording.
t=np.arange(12*sr)/sr
preview=np.round(.25*np.sin(2*np.pi*110*t)*8388607).astype('<i4')
preview=np.column_stack([preview,preview])
with wave.open(str(HERE/'demo-A2.wav'),'wb') as w:
    w.setnchannels(2);w.setsampwidth(3);w.setframerate(sr)
    w.writeframes(preview.view(np.uint8).reshape(-1,4)[:,:3].tobytes())

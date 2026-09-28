from pathlib import Path
import json,wave
import numpy as np

here=Path(__file__).resolve().parent
def read(p):
    with wave.open(str(p),'rb') as w:
        sr=w.getframerate();nc=w.getnchannels();b=w.readframes(w.getnframes());assert w.getsampwidth()==3
    u=np.frombuffer(b,dtype=np.uint8).reshape(-1,3).astype(np.int32)
    a=u[:,0]|(u[:,1]<<8)|(u[:,2]<<16)
    return sr,((a^8388608)-8388608).reshape(-1,nc)/8388608

report=[];failures=[];rows=[]
cases=json.loads((here/'cases.json').read_text())['cases']
src_sr,src=read(here/'stimuli.wav')
def check(ok,msg):
    report.append(('PASS ' if ok else 'FAIL ')+msg)
    if not ok:failures.append(msg)
for name in ['44100-left','48000-left','96000-left','48000-right','48000-sum','48000-muted']:
    sr,a=read(here/f'result-{name}.wav');errors=[];valid_cases=0
    for c in cases:
        hz=a[round((c['end']-.25)*sr):round((c['end']-.05)*sr),2]*2000
        rejection='sum' in name or c['kind'] in ('silence','noise','below_gate')
        if rejection:
            check(np.max(abs(hz))==0,f'{name}: rejects {c["name"]}')
        else:
            valid_cases+=1
            check(np.all(hz>0),f'{name}: tracks {c["name"]}')
            e=float(np.max(abs(1200*np.log2(np.maximum(hz,1e-9)/c['hz']))))
            errors.append(e);rows.append(dict(run=name,case=c['name'],maximum_cents_error=e))
            check(e<.5,f'{name}: {c["name"]} error {e:.5f} cents < 0.5')
    if errors:report.append(f'MAX {name}: {max(errors):.6f} cents across {valid_cases} pitched cases')
    if name.startswith('48000'):
        check(np.array_equal(a[:,:2],np.zeros_like(src) if 'muted' in name else src),f'{name}: audio is '+('exactly silent' if 'muted' in name else 'bit-identical pass-through'))

pcases=json.loads((here/'phase-cases.json').read_text())['cases']
for name in ['phase-440','phase-442-locked']:
    sr,a=read(here/f'result-{name}.wav')
    for c in pcases:
        sel=slice(round((c['end']-.35)*sr),round((c['end']-.05)*sr))
        target=float(np.median(a[sel,5])*2000)
        expected_target=(442*2**((40-69)/12)) if 'locked' in name else 440*2**((round(69+12*np.log2(c['hz']/440))-69)/12)
        check(abs(target-expected_target)<.0003,f'{name}: target correct for {c["name"]}')
        # Far-away manually locked notes are outside the phase filters' passband.
        if 'locked' in name and c['hz']>100:continue
        for col,harmonic in [(4,1),(6,2),(7,4)]:
            phase=np.unwrap(a[sel,col]*2*np.pi)
            t=np.arange(len(phase))/sr
            slope=np.polyfit(t,phase,1)[0]/(2*np.pi)
            expected=harmonic*(c['hz']-expected_target)
            error=abs(slope-expected)
            # Includes finite settling, phase quantization and 4-pole leakage.
            check(error<.015,f'{name}: {c["name"]}, harmonic {harmonic}, phase rate {slope:.6f} Hz vs {expected:.6f}')

(here/'results.txt').write_text('\n'.join(report)+'\n')
(here/'measurements.json').write_text(json.dumps(rows,indent=2))
print('\n'.join(x for x in report if x.startswith(('MAX','FAIL'))))
print(f'{len(report)} checks/measurements; {len(failures)} failures. Full report: {here/"results.txt"}')
raise SystemExit(bool(failures))

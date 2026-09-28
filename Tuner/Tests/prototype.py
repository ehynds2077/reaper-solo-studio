import numpy as np

def detect(x, fs):
    x=x-np.mean(x); n=len(x)
    r=np.fft.irfft(abs(np.fft.rfft(x,n*2))**2,n*2)[:n]
    p=np.r_[0,np.cumsum(x*x)]
    lag=np.arange(n//2)
    ns=2*r[:n//2]/np.maximum(p[n-lag]+p[n]-p[lag],1e-20)
    lo=int(fs/1400); hi=min(len(ns)-2,int(fs/30))
    peaks=[]; crossed=False
    for i in range(1,hi+1):
        if ns[i]<0: crossed=True
        if crossed and i>=lo and ns[i]>ns[i-1] and ns[i]>=ns[i+1]: peaks.append(i)
    if not peaks: return 0,0
    best=max(ns[i] for i in peaks)
    if best<.85:return 0,best
    peak=next(i for i in peaks if ns[i]>=max(.85,best*.94))
    def refine(i):
        return i+.5*(ns[i-1]-ns[i+1])/(ns[i-1]-2*ns[i]+ns[i+1])
    period=refine(peak)
    # Multi-period slope reduces interpolation bias at high notes.
    num=den=0
    for k in range(1,int((len(ns)-3)/period)+1):
        i=int(k*period+.5)
        i=max(range(max(1,i-1),min(len(ns)-1,i+2)), key=lambda j:ns[j])
        if abs(i-k*period)<=2 and ns[i]>=.8:
            v=refine(i)
            num+=k*v;den+=k*k
    if den: period=num/den
    return fs/period,ns[peak]

if __name__=='__main__':
    fs=12000;n=2048;t=np.arange(n)/fs
    for f in [30.8677,41.20344,73.41619,82.406889,110,146.8324,196,246.94165,329.62756,440,659.255,1318.51]:
        x=sum(a*np.sin(2*np.pi*f*h*t+.37*h) for h,a in enumerate([1,.6,.3,.2],1))
        for decay in [False,True]:
            y=x*np.exp(-t/.8) if decay else x
            got,quality=detect(y,fs)
            print(f,decay,round(1200*np.log2(got/f),4) if got else None,round(quality,4))

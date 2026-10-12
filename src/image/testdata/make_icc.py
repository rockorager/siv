import struct
def s15(v): return struct.pack('>i', int(round(v*65536)))
def xyz(x,y,z): return b'XYZ ' + b'\0'*4 + s15(x)+s15(y)+s15(z)
def curv_gamma(g): return b'curv' + b'\0'*4 + struct.pack('>I', 1) + struct.pack('>H', int(round(g*256))) + b'\0\0'
def desc(t):
    a=t.encode()+b'\0'
    return b'desc'+b'\0'*4+struct.pack('>I',len(a))+a+b'\0'*4+b'\0'*4+b'\0'*2+b'\0'+b'\0'*67
def text(t): return b'text'+b'\0'*4+t.encode()+b'\0'
tags=[(b'desc',desc('siv linear sRGB')),(b'cprt',text('public domain')),(b'wtpt',xyz(0.9642,1.0,0.8249)),
 (b'rXYZ',xyz(0.4360747,0.2225045,0.0139322)),(b'gXYZ',xyz(0.3850649,0.7168786,0.0971045)),(b'bXYZ',xyz(0.1430804,0.0606169,0.7141733)),
 (b'rTRC',curv_gamma(1.0)),(b'gTRC',curv_gamma(1.0)),(b'bTRC',curv_gamma(1.0))]
off=128+4+12*len(tags); table=b''; data=b''
for sig,d in tags:
    while (off+len(data))%4: data+=b'\0'
    table+=sig+struct.pack('>II',off+len(data),len(d)); data+=d
body=struct.pack('>I',len(tags))+table+data
size=128+len(body)
hdr=struct.pack('>I',size)+b'lcms'+struct.pack('>I',0x02100000)+b'mntr'+b'RGB '+b'XYZ '+b'\0'*12+b'acsp'+b'APPL'+b'\0'*4+b'\0'*4+b'\0'*4+b'\0'*8+struct.pack('>I',0)+s15(0.9642)+s15(1.0)+s15(0.8249)+b'\0'*4+b'\0'*16+b'\0'*28
assert len(hdr)==128,len(hdr)
open('linear.icc','wb').write(hdr+body)

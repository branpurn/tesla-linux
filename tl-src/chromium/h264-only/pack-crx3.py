#!/usr/bin/env python3
"""Pack tl-h264-only as a CRX3 for Google Chrome (policy force-install).

Branded Chrome >= 137 ignores --load-extension, so the same extension that the
Pi Chromium loads from /usr/share/chromium/extensions/ is shipped to Chrome as a
signed CRX + update manifest and force-installed by managed policy.

  pack-crx3.py SRC_DIR KEY.pem OUT_DIR [--base-url file:///usr/share/tesla-linux/chrome-ext]

Creates KEY.pem (RSA-2048, 0600) if missing, writes OUT_DIR/h264only.crx and
OUT_DIR/updates.xml, prints the extension id. Needs python3 + the openssl CLI.
"""
import hashlib, os, struct, subprocess, sys, zipfile, io


def varint(n):
    out = b''
    while True:
        b = n & 0x7F
        n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n:
            return out


def field(num, data):  # length-delimited
    return varint((num << 3) | 2) + varint(len(data)) + data


def openssl(*args, inp=None):
    return subprocess.run(['openssl', *args], input=inp, capture_output=True, check=True).stdout


def main():
    a = [x for x in sys.argv[1:] if not x.startswith('--')]
    src, key, out = a[:3]
    base = 'file://' + os.path.abspath(out)
    if '--base-url' in sys.argv:
        base = sys.argv[sys.argv.index('--base-url') + 1]
    if not os.path.exists(key):
        old = os.umask(0o077)
        openssl('genrsa', '-out', key, '2048')
        os.umask(old)
    pub = openssl('rsa', '-in', key, '-pubout', '-outform', 'DER')
    crx_id = hashlib.sha256(pub).digest()[:16]
    ext_id = ''.join(chr(ord('a') + int(c, 16)) for c in crx_id.hex())

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
        for name in sorted(os.listdir(src)):
            p = os.path.join(src, name)
            if os.path.isfile(p):
                zi = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))   # reproducible
                zi.compress_type = zipfile.ZIP_DEFLATED
                zi.external_attr = 0o644 << 16
                z.writestr(zi, open(p, 'rb').read())
    zipdata = buf.getvalue()

    signed_header = field(1, crx_id)                      # SignedData.crx_id
    to_sign = b'CRX3 SignedData\x00' + struct.pack('<I', len(signed_header)) + signed_header + zipdata
    sig = openssl('dgst', '-sha256', '-sign', key, inp=to_sign)
    proof = field(1, pub) + field(2, sig)                 # AsymmetricKeyProof
    header = field(2, proof) + field(10000, signed_header)
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, 'h264only.crx'), 'wb') as f:
        f.write(b'Cr24' + struct.pack('<II', 3, len(header)) + header + zipdata)
    version = __import__('json').load(open(os.path.join(src, 'manifest.json')))['version']
    with open(os.path.join(out, 'updates.xml'), 'w') as f:
        f.write("<?xml version='1.0' encoding='UTF-8'?>\n"
                "<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>\n"
                f"  <app appid='{ext_id}'><updatecheck codebase='{base}/h264only.crx' version='{version}'/></app>\n"
                "</gupdate>\n")
    print(ext_id)


if __name__ == '__main__':
    main()

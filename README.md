# tesla-linux

Tesla-Linux — Ubuntu + XFCE on Raspberry Pi 4 (8 GB). KISS replacement for tesla-android-kiss (kiss stays private).

WAVE 0 keep / drop / gaps: [docs/WAVE0-KEEP-DROP-GAPS.md](docs/WAVE0-KEEP-DROP-GAPS.md).

## Bake

```bash
sudo ./tl-src/build-image.sh
```

Pi 4 8 GB only. Ubuntu Server arm64 raspi → `.img.xz` (`UBUNTU_REL=26.04`). Then `tl-src/install-tesla-linux.sh` (xfce4). This repository does not ship a baked `.img`.

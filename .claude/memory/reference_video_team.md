---
name: Video team environment details
description: Hardware, software, and workflow details for the video production team that uses Copiatorul3000
type: reference
---

**Target machine**: Windows 11, single workstation
**SD card hub**: Kingston 9934534-003.AOOLF 5V (multi-slot USB hub)
**Staging drive**: External 14TB HDD via USB 3
**NAS**: Synology (uploads via Synology dashboard — out of scope for automation)
**Video formats**: .MOV, .MP4, 50-100 GB per file
**Compression**: HandBrake 1.11.1 with custom presets (HandBrakeCLI must be in PATH separately from GUI)
**Transfer tool**: robocopy (replaced TeraCopy — free, built-in, better CLI)
**Notifications**: Slack via incoming webhook (channel TBD — team needs to provide webhook URL)
**TeraCopy version they had**: 3.17 (no longer used)

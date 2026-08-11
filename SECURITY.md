# Security Policy

## Supported versions

| Version | Supported |
| ------- | --------- |
| latest main | yes |
| 0.1.x releases | yes |
| anything older | no |

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's security advisories. Open the Security tab
of this repository and choose "Report a vulnerability". Please do not open a public issue
for something exploitable.

This is a spare time project with one maintainer, so the honest promise is best effort. You
can expect an acknowledgment within a week and a fix as fast as severity warrants.

## Scope

The attack surface is file parsing and audio/UI glue. The player reads untrusted music
files (HSC, RAD, VGM/VGZ, DRO, RAW, CMF, IMF/WLF, AudioT), including files fetched over
http(s), and treats them with suspicion. Reads are bounds-checked,
input size is capped, and release builds default to ReleaseSafe so the safety checks stay
on. Malformed input should produce a clear refusal and a nonzero exit code, never memory
corruption or a runaway process. If you find an input that does otherwise, that is exactly
the report we want.

OPL synthesis is [opal](https://github.com/RealBitdancer/opal) via
[opal-zig](https://github.com/RealBitdancer/opal-zig). Audio device I/O goes through
[zaudio](https://github.com/zig-gamedev/zaudio) / miniaudio. The TUI is
[libvaxis](https://github.com/rockorager/libvaxis). Vulnerabilities in those projects
belong upstream, though a note here is welcome if this player is affected.

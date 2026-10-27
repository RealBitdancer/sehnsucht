# Third-Party Licenses

Project code is MIT. See [LICENSE](LICENSE). Runtime dependencies fetched by the Zig
package manager are listed below. opal-zig and libvaxis ship their full license texts
inside the fetched packages. The zaudio package ships no license file, so its terms
are recorded here.

## opal / opal-zig

- **Package:** [opal-zig](https://github.com/RealBitdancer/opal-zig) (wraps the
  [opal](https://github.com/RealBitdancer/opal) C core)
- **License:** MIT
- **Role:** OPL2/OPL3 FM synthesis

## libvaxis

- **Package:** [libvaxis](https://github.com/rockorager/libvaxis)
- **License:** MIT (Copyright (c) 2023 Tim Culverhouse)
- **Role:** Terminal UI

The pinned libvaxis package declares these transitive dependencies:

- [uucode](https://github.com/jacobsandlund/uucode), MIT (Copyright (c) 2026
  Jacob Sandlund). Unicode tables for grapheme segmentation and display width
- [zigimg](https://github.com/zigimg/zigimg), MIT. Image decoding for the
  terminal graphics protocols

## system_sdk (build time, macOS targets only)

- **Package:** [system_sdk](https://github.com/zig-gamedev/system_sdk)
- **License:** MIT for the packaging. The Apple framework stubs it carries are
  Apple's, redistributed by zig-gamedev for cross-compilation.
- **Role:** framework and library search paths for macOS targets, including
  cross-compilation from another host. sehnsucht declares its direct dependency
  lazily and adds these paths only for macOS targets

Nothing from this package is compiled into the binary. It supplies link-time
stubs, and the frameworks themselves are resolved by name from the user's own
macOS at load time.

## zaudio / miniaudio

- **Package:** [zaudio](https://github.com/zig-gamedev/zaudio) (Zig wrapper)
- **Upstream audio library:** [miniaudio](https://github.com/mackron/miniaudio)
- **License:** the zaudio wrapper code is MIT. Its
  [pinned license](https://github.com/zig-gamedev/zaudio/blob/44ea21152c67c8ba02de5441ac2a5d58c01ad591/LICENSE)
  credits Michal Ziulek (2022) and the zig-gamedev contributors (2024).
  miniaudio is dual-licensed public domain (Unlicense) or MIT No Attribution,
  with its text embedded in `miniaudio.h`.
- **Role:** Cross-platform audio device I/O

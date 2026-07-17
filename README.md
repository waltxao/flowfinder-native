# FlowFinder Native

Swift & AppKit native UI + Rust core engine via FFI.

## Architecture
- **Swift/AppKit Layer**: Native macOS UI (NSTableView, NSSplitView)
- **FFI Boundary**: C ABI manual export
- **Rust Core Layer**: File operations engine (bulk_read, cow_copy, scanner, dedup_engine)

## Requirements
- macOS 13.0+
- Xcode 15+
- Rust 1.75+

## Project Structure
```
flowfinder-native/
├── rust-core/          # Rust core library (cdylib)
│   ├── src/
│   │   ├── lib.rs
│   │   ├── ffi/
│   │   │   └── mod.rs
│   │   └── core/
│   │       ├── mod.rs
│   │       ├── bulk_read.rs
│   │       ├── cow_copy.rs
│   │       ├── scanner.rs
│   │       ├── dedup_engine.rs
│   │       ├── dir_cache.rs
│   │       ├── path_guard.rs
│   │       └── utils.rs
│   ├── Cargo.toml
│   └── include/
│       └── ff_ffi.h
├── FlowFinderNative/   # Swift Xcode project
│   ├── FlowFinderNative/
│   │   ├── App/
│   │   ├── UI/
│   │   ├── Model/
│   │   └── Bridge/
│   └── FlowFinderNative.xcodeproj/
└── README.md
```

## License
MIT

#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# FlowFinder Native — Rust Core Build Script
# ============================================================================
# Detects build mode (Debug/Release), runs cargo build, copies the resulting
# .dylib to the appropriate location, and handles errors gracefully.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$PROJECT_ROOT/rust-core"
OUTPUT_DIR="$PROJECT_ROOT/FlowFinderNative/FlowFinderNative/Libraries"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

die() {
    log_error "$1"
    exit 1
}

# ---------------------------------------------------------------------------
# Detect build mode
# ---------------------------------------------------------------------------

BUILD_MODE="${1:-Debug}"

if [[ "$BUILD_MODE" == "Release" || "$BUILD_MODE" == "release" ]]; then
    CARGO_FLAG="--release"
    BUILD_PROFILE="release"
    log_info "Building in Release mode..."
else
    CARGO_FLAG=""
    BUILD_PROFILE="debug"
    log_info "Building in Debug mode..."
fi

# ---------------------------------------------------------------------------
# Verify environment
# ---------------------------------------------------------------------------

if ! command -v cargo &> /dev/null; then
    die "Rust/Cargo not found. Please install Rust: https://rustup.rs"
fi

RUST_VERSION=$(rustc --version 2>/dev/null || echo "unknown")
log_info "Rust version: $RUST_VERSION"

if [[ ! -d "$RUST_DIR" ]]; then
    die "Rust core directory not found: $RUST_DIR"
fi

if [[ ! -f "$RUST_DIR/Cargo.toml" ]]; then
    die "Cargo.toml not found in: $RUST_DIR"
fi

# ---------------------------------------------------------------------------
# Determine target architecture
# ---------------------------------------------------------------------------

ARCH=$(uname -m)
TARGET=""
if [[ "$ARCH" == "arm64" ]]; then
    TARGET="aarch64-apple-darwin"
    log_info "Target architecture: Apple Silicon (arm64)"
elif [[ "$ARCH" == "x86_64" ]]; then
    TARGET="x86_64-apple-darwin"
    log_info "Target architecture: Intel (x86_64)"
else
    log_warn "Unknown architecture: $ARCH, using default target"
    TARGET=""
fi

# ---------------------------------------------------------------------------
# Build Rust core
# ---------------------------------------------------------------------------

cd "$RUST_DIR"

if [[ -n "$TARGET" ]]; then
    log_info "Running: cargo build $CARGO_FLAG --target $TARGET"
    if ! cargo build $CARGO_FLAG --target "$TARGET"; then
        die "Cargo build failed for target $TARGET"
    fi
    BUILD_TARGET_DIR="target/$TARGET/$BUILD_PROFILE"
else
    log_info "Running: cargo build $CARGO_FLAG"
    if ! cargo build $CARGO_FLAG; then
        die "Cargo build failed"
    fi
    BUILD_TARGET_DIR="target/$BUILD_PROFILE"
fi

log_success "Rust build completed successfully"

# ---------------------------------------------------------------------------
# Find and copy the built library
# ---------------------------------------------------------------------------

DYLIB_NAME="libflowfinder_core.dylib"
STATICLIB_NAME="libflowfinder_core.a"

DYLIB_PATH="$RUST_DIR/$BUILD_TARGET_DIR/$DYLIB_NAME"
STATICLIB_PATH="$RUST_DIR/$BUILD_TARGET_DIR/$STATICLIB_NAME"

if [[ ! -f "$DYLIB_PATH" ]]; then
    die "Built library not found: $DYLIB_PATH"
fi

log_info "Found library: $DYLIB_PATH"

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Copy dynamic library
if cp "$DYLIB_PATH" "$OUTPUT_DIR/"; then
    log_success "Copied $DYLIB_NAME to $OUTPUT_DIR"
else
    die "Failed to copy $DYLIB_NAME"
fi

# Copy static library if available (optional)
if [[ -f "$STATICLIB_PATH" ]]; then
    if cp "$STATICLIB_PATH" "$OUTPUT_DIR/"; then
        log_success "Copied $STATICLIB_NAME to $OUTPUT_DIR"
    else
        log_warn "Failed to copy static library (non-fatal)"
    fi
fi

# ---------------------------------------------------------------------------
# Set library permissions and codesign (for macOS)
# ---------------------------------------------------------------------------

chmod +x "$OUTPUT_DIR/$DYLIB_NAME"

# Fix install_name for portability — use @rpath so the dylib can be embedded in .app/Frameworks/
if command -v install_name_tool &> /dev/null; then
    log_info "Fixing dylib install_name to @rpath..."
    install_name_tool -id @rpath/libflowfinder_core.dylib "$OUTPUT_DIR/$DYLIB_NAME"
    log_success "install_name set to @rpath/libflowfinder_core.dylib"
fi

if command -v codesign &> /dev/null; then
    log_info "Codesigning library..."
    if codesign --sign - --force "$OUTPUT_DIR/$DYLIB_NAME" 2>/dev/null; then
        log_success "Library codesigned successfully"
    else
        log_warn "Codesigning failed (non-fatal, may work without it)"
    fi
fi

# ---------------------------------------------------------------------------
# Verify the library
# ---------------------------------------------------------------------------

if file "$OUTPUT_DIR/$DYLIB_NAME" | grep -q "Mach-O"; then
    log_success "Library verification: valid Mach-O dynamic library"
else
    log_warn "Library verification: may not be a valid Mach-O file"
fi

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------

echo ""
echo "========================================"
echo "  Build Summary"
echo "========================================"
echo "  Mode:        $BUILD_MODE"
echo "  Profile:     $BUILD_PROFILE"
echo "  Target:      ${TARGET:-default}"
echo "  Output:      $OUTPUT_DIR/$DYLIB_NAME"
echo "  Size:        $(du -h "$OUTPUT_DIR/$DYLIB_NAME" | cut -f1)"
echo "========================================"
echo ""

log_success "Rust core build completed successfully!"
exit 0

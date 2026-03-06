# Boehm-Demers-Weiser GC — WebAssembly / WASI Support

This document describes the WebAssembly (WASM) and WASI support in bdwgc,
covering the memory model, known limitations, build instructions for
[wasi-sdk](https://github.com/WebAssembly/wasi-sdk), and guidance for
writing GC-safe application code.

---

## Background: WebAssembly Memory Model

WebAssembly uses a flat, byte-addressable **linear memory** that grows in
64 KB increments.  The typical layout produced by the wasm-ld linker is:

```
Address 0  (null guard / reserved)
__global_base  ──►  data / BSS  ──►  __data_end
__stack_high   ──►  C shadow stack (grows DOWN toward __stack_low)
__heap_base    ──►  heap (grows UP as needed)
```

### Two distinct stacks

| Stack | Location | GC-visible? |
|-------|----------|-------------|
| **WebAssembly operand / value stack** | Inside the WASM VM; NOT in linear memory | ❌ Cannot be scanned |
| **C shadow stack** (managed by LLVM/clang) | In linear memory, `__stack_low` → `__stack_high` | ✅ Scanned by the GC |

The C shadow stack stores variables whose address is taken, values that
don't fit in WASM locals, and callee-saved state.  The current shadow-stack
pointer is the WASM global `$__stack_pointer`, which clang exposes via
`__builtin_frame_address(0)`.

---

## Linker Symbols Used by bdwgc

bdwgc depends on the following synthetic symbols exported by wasm-ld
(available in LLVM 11 / wasi-sdk 12 and later):

| Symbol | Type | Used for |
|--------|------|----------|
| `__global_base` | linear-memory address | `DATASTART` — start of data/BSS root scan |
| `__data_end`    | linear-memory address | `DATAEND`   — end of data/BSS root scan |
| `__stack_high`  | linear-memory address | `STACKBOTTOM` — cold (high) end of C shadow stack |
| `__stack_low`   | linear-memory address | `STACK_MIN_ADDR` — low bound guard for stack scan |
| `__heap_base`   | linear-memory address | Informational; heap region starts here |

When linking your application, ensure these symbols are exported from the
WASM module (wasm-ld does this automatically for linked executables).

---

## Known Limitations

### WASM operand stack is not scannable

Pointers that reside **only** in a WASM local variable (i.e., they have
never had their address taken and the optimizer kept them in a WASM
register) are **invisible to the collector**.  If the GC runs while the
sole reference to a heap object is in a WASM local, the object may be
collected prematurely.

**Mitigations:**

1. **Compile with `-O0`** (debug builds): LLVM spills all locals to the C
   shadow stack when optimisation is disabled.
2. **Store pointers in GC-tracked memory**: always keep at least one
   additional copy in a global variable, heap-allocated struct, or a local
   whose address has been taken.
3. **Use `GC_MALLOC_UNCOLLECTABLE`** for objects that must not be freed
   while a pointer to them might exist only in a register.
4. **Force stack spilling** with `-fno-omit-frame-pointer`; this increases
   the likelihood that the compiler allocates a shadow-stack frame that
   includes live pointers.

### No incremental / generational collection

`mprotect(2)` is a no-op on WASM, so write-barrier–based dirty-page
tracking is disabled.  Incremental and generational modes are not
available (`GC_DISABLE_INCREMENTAL` is defined automatically).

### No threads

Standard WASI (`wasm32-wasi`) does not support POSIX threads.
`enable_threads` must be set to `OFF` when building for WASI.

Thread support for WASIX or wasm32-wasi-threads is not yet implemented.

### No dynamic library loading

WASM modules are self-contained; `dlopen`/`dlsym` are not supported.
`IGNORE_DYNAMIC_LOADING` is defined automatically.

### Shared libraries

`wasm-ld` does not produce shared libraries in the traditional sense.
Always build with `-DBUILD_SHARED_LIBS=OFF`.

---

## Building bdwgc with wasi-sdk

### Prerequisites

* [wasi-sdk](https://github.com/WebAssembly/wasi-sdk) ≥ 12 (LLVM 11+)
  installed (default path `/opt/wasi-sdk`, or set `$WASI_SDK_PATH`).
* CMake ≥ 3.1.

### Quick start

```sh
mkdir build-wasi && cd build-wasi

cmake /path/to/bdwgc \
    -DCMAKE_TOOLCHAIN_FILE=/path/to/bdwgc/cmake/toolchains/wasi.cmake \
    -DWASI_SDK_PATH=/opt/wasi-sdk \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DBUILD_SHARED_LIBS=OFF \
    -Denable_threads=OFF \
    -Denable_munmap=OFF \
    -Denable_dynamic_loading=OFF \
    -Dbuild_cord=OFF

make -j$(nproc)
```

This produces `libgc.a` (and optionally `libgccpp.a`) that you can link
into your wasm32-wasi executable.

### Linking your application

```sh
/opt/wasi-sdk/bin/clang \
    -target wasm32-wasi \
    --sysroot /opt/wasi-sdk/share/wasi-sysroot \
    -O1 -fno-omit-frame-pointer \
    -o myapp.wasm myapp.c \
    -L /path/to/build-wasi -lgc \
    -I /path/to/bdwgc/include
```

> **Important:** Pass `-fno-omit-frame-pointer` (and prefer `-O1` or `-O0`
> over `-O2`/`-O3`) to maximise the amount of pointer data spilled to the
> C shadow stack, reducing the risk of premature collection.

---

## Writing GC-safe WASM Application Code

```c
#include <gc.h>
#include <stdio.h>

int main(void)
{
    GC_INIT();  /* must be called before any GC_MALLOC */

    /* Allocate a GC-managed buffer. */
    char *buf = GC_MALLOC(1024);

    /* Keep the pointer alive by storing it in a global or addressed
     * local before making another allocation that might trigger GC. */
    volatile char *anchor = buf;   /* address taken → lives on shadow stack */

    /* Further allocations may trigger collection. */
    char *buf2 = GC_MALLOC(2048);

    printf("buf=%p buf2=%p\n", (void *)buf, (void *)buf2);

    /* anchor is still live here, preventing buf from being collected. */
    (void)anchor;
    return 0;
}
```

---

## Running WASM Binaries

Use a WASI runtime such as [Wasmtime](https://wasmtime.dev/) or
[WAMR](https://github.com/bytecodealliance/wasm-micro-runtime):

```sh
wasmtime myapp.wasm
```

---

## Configuration Macros Set Automatically for WASM

| Macro | Effect |
|-------|--------|
| `WASM` | Master WASM guard macro |
| `OS_TYPE "WASI"` / `"WASM"` | OS identification |
| `MACH_TYPE "WASM"` | Architecture identification |
| `CPP_WORDSZ 32` (or `64`) | Word size for wasm32 / wasm64 |
| `STACK_GROWS_DOWN` | C shadow stack grows toward lower addresses |
| `STACKBOTTOM` = `&__stack_high` | Cold (high-address) end of C shadow stack |
| `STACK_MIN_ADDR` = `&__stack_low` | Hot (low-address) bound guard |
| `DATASTART` = `__global_base` | Start of data/BSS scanning range |
| `DATAEND` = `__data_end` | End of data/BSS scanning range |
| `GC_DISABLE_INCREMENTAL` | No mprotect-based dirty-page tracking |
| `IGNORE_DYNAMIC_LOADING` | No dlopen/dlsym support |
| `NO_EXECUTE_PERMISSION` | Memory never mapped executable |
| `_WASI_EMULATED_PROCESS_CLOCKS` | WASI clock emulation (WASI only) |
| `_WASI_EMULATED_SIGNAL` | WASI signal emulation (WASI only) |
| `_WASI_EMULATED_MMAN` | WASI mmap emulation (WASI only) |

For WASI targets, `GC_wasm_get_mem()` uses `mmap(MAP_ANONYMOUS)` via the
WASI mmap emulation layer for GC heap expansion.  For bare WASM targets
(no WASI), `posix_memalign` is used as a fallback.

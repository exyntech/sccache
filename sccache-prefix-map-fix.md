# sccache: `-fmacro-prefix-map` breaks `SCCACHE_BASEDIRS` cache sharing

## Problem

When using `SCCACHE_BASEDIRS` to share cache across different checkout paths,
any compiler flag containing an absolute path that sccache doesn't explicitly
recognize will be hashed as-is, breaking cache sharing. The most common
offenders are GCC/Clang's prefix-map flags:

- `-fmacro-prefix-map=/path/to/source=.`
- `-fdebug-prefix-map=/path/to/source=.`
- `-ffile-prefix-map=/path/to/source=.` (equivalent to the above two combined)

These flags are widely used for reproducible builds (stripping absolute paths
from `__FILE__` macros and DWARF debug info). CMake adds `-fmacro-prefix-map`
by default in some configurations.

## Root Cause

In sccache v0.14.0, the argument parser in `src/compiler/gcc.rs` classifies
arguments into categories:

- `PreprocessorArgumentPath` → goes to `preprocessor_args` → **not** included in hash key
- `PreprocessorArgumentFlag` → goes to `preprocessor_args` → **not** included in hash key
- `PassThrough` / `PassThroughFlag` → goes to `common_args` → **included** in hash key
- `UnknownFlag` (anything not in the ARGS table) → goes to `common_args` → **included** in hash key

The prefix-map flags are **not listed** in the ARGS table, so they fall through
to `UnknownFlag` → `common_args` → hashed raw, absolute path and all.

Meanwhile, `strip_basedirs()` is only called on **preprocessor output** (the
result of `gcc -E`), not on `common_args`:

```rust
// src/compiler/c.rs - HashKeyParams::compute()
pub fn compute(&self) -> String {
    let mut m = Digest::new();
    m.update(self.compiler_digest.as_bytes());
    m.update(&[self.plusplus as u8]);
    m.update(CACHE_VERSION);
    m.update(self.language.as_str().as_bytes());
    for arg in self.arguments {                          // <-- common_args, hashed raw
        arg.hash(&mut HashToDigest { digest: &mut m });
    }
    // ...
    let preprocessor_output_to_hash =
        strip_basedirs(self.preprocessor_output, self.basedirs);  // <-- only here
    m.update(&preprocessor_output_to_hash);
    m.finish()
}
```

So when CI compiles with `-fmacro-prefix-map=/builds/exyn/exyn/projects/foo=.`
and a developer compiles with `-fmacro-prefix-map=/home/dev/projects/foo=.`,
the hash keys differ even though BASEDIRS should normalize all paths.

## Empirical Evidence

Tested with sccache 0.14.0 in a clean Docker environment:

| Scenario | Cache hit rate |
|----------|:---:|
| Different paths, BASEDIRS set, no prefix-map flags | **99%** (only `SoftwareVersion.cpp` differs) |
| Different paths, BASEDIRS set, `-fmacro-prefix-map` present | **54%** (106/193 units mismatched) |

All 106 mismatched units were exyn-core library files compiled with
`-fmacro-prefix-map=${CMAKE_SOURCE_DIR}=.` — a pre-existing flag for
shortening `__FILE__` paths in log output.

## How ccache Handles This

ccache solved this in 2018 (PR [ccache/ccache#326](https://github.com/ccache/ccache/pull/326),
issue [ccache/ccache#325](https://github.com/ccache/ccache/issues/325)):

- **`-fmacro-prefix-map`**: Skipped entirely from the hash (`continue` in
  `calculate_object_hash`). Rationale: it affects preprocessed output (modifies
  `__FILE__` expansion), so its effect is already captured in the preprocessed
  source hash. Hashing it again in the argument list is redundant and harmful.

- **`-fdebug-prefix-map`** and **`-ffile-prefix-map`**: Also excluded from the
  hash, but their values are extracted and stored for debug prefix map tracking.
  Rationale: they only affect DWARF debug info, not compilation correctness.

Quote from the ccache issue:
> "-fmacro-prefix-map will affect preprocessed output, so can be ignored in
> command-line hash. -ffile-prefix-map is then equivalent to -fdebug-prefix-map."

## Proposed Fix for sccache

Add the three prefix-map flags to the ARGS tables in both `gcc.rs` and
`clang.rs`, classifying them as `PreprocessorArgumentFlag` so they route to
`preprocessor_args` instead of `common_args`:

### `src/compiler/gcc.rs`

Add to the `ARGS` array:

```rust
take_arg!("-fdebug-prefix-map", OsString, Concatenated(b'='), PreprocessorArgumentFlag),
take_arg!("-ffile-prefix-map", OsString, Concatenated(b'='), PreprocessorArgumentFlag),
take_arg!("-fmacro-prefix-map", OsString, Concatenated(b'='), PreprocessorArgumentFlag),
```

### `src/compiler/clang.rs`

Add to the Clang-specific `ARGS` array:

```rust
take_arg!("-fdebug-prefix-map", OsString, Concatenated(b'='), PreprocessorArgumentFlag),
take_arg!("-ffile-prefix-map", OsString, Concatenated(b'='), PreprocessorArgumentFlag),
take_arg!("-fmacro-prefix-map", OsString, Concatenated(b'='), PreprocessorArgumentFlag),
```

### Why `PreprocessorArgumentFlag`?

- These flags go into `preprocessor_args`, which are passed to `gcc -E` but
  **not** included in the hash key computation.
- Their effect on `__FILE__` expansion is already captured in the preprocessed
  output hash (with `strip_basedirs` applied).
- `-fdebug-prefix-map` only affects DWARF debug info, which doesn't affect
  compilation correctness or the preprocessed output at all.
- This matches ccache's approach.

### Alternative: `UnhashedFlag`

Another option is `UnhashedFlag` (like `-pipe`), which drops the flag entirely
from all argument lists. This is simpler but means the flag wouldn't be passed
to the preprocessor either. Since `-fmacro-prefix-map` does affect `gcc -E`
output (it changes `__FILE__` expansion), `PreprocessorArgumentFlag` is more
correct — it ensures the flag is passed to the preprocessor (so the output is
accurate) while keeping it out of the hash.

## References

- **sccache source** (v0.14.0):
  - [src/compiler/c.rs](https://github.com/mozilla/sccache/blob/v0.14.0/src/compiler/c.rs) — `HashKeyParams::compute()`, `strip_basedirs` call site
  - [src/compiler/gcc.rs](https://github.com/mozilla/sccache/blob/v0.14.0/src/compiler/gcc.rs) — GCC ARGS table, argument classification
  - [src/compiler/clang.rs](https://github.com/mozilla/sccache/blob/v0.14.0/src/compiler/clang.rs) — Clang ARGS table
  - [src/util.rs](https://github.com/mozilla/sccache/blob/v0.14.0/src/util.rs) — `strip_basedirs()` implementation
  - [PR #2521](https://github.com/mozilla/sccache/pull/2521) — SCCACHE_BASEDIRS implementation

- **ccache**:
  - [Issue #325](https://github.com/ccache/ccache/issues/325) — gcc-8 -ffile-prefix-map support
  - [PR #326](https://github.com/ccache/ccache/pull/326) — Implementation of prefix-map flag handling

- **GCC docs**:
  - `-ffile-prefix-map=old=new`: equivalent to `-fmacro-prefix-map` + `-fdebug-prefix-map`
  - `-fmacro-prefix-map=old=new`: remaps `__FILE__` and related macros
  - `-fdebug-prefix-map=old=new`: remaps paths in DWARF debug info

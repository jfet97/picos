# Picos Study Notes

Deep dives into concepts encountered while studying picos.

---

## Dune: how it works

### One directory = one compilation unit

Each directory can contain at most one `dune` file. That dune file can define one library, or one executable, or one test (or a few of the same kind). You can't have two `(library ...)` stanzas in the same directory.

"Stanza" is just the dune term for a top-level S-expression block in a dune file. Each `(...)` at the top level is a stanza:

```scheme
(library ...)       ;; a stanza
(rule ...)          ;; another stanza
(test ...)          ;; another one
```

This is why picos has a flat structure under `lib/` — each library gets its own directory:

```
lib/
├── picos/                  ← dune file → library "picos"
├── picos_aux.htbl/         ← dune file → library "picos_aux.htbl"
├── picos_aux.mpmcq/        ← dune file → library "picos_aux.mpmcq"
├── picos_std.sync/         ← dune file → library "picos_std.sync"
├── picos_mux.fifo/         ← dune file → library "picos_mux.fifo"
...
```

The directory name doesn't matter to dune — it's just convention. What matters is the `dune` file contents.

### `name` vs `public_name`

```scheme
(library
 (name picos_aux_htbl)        ;; internal name — OCaml module name
 (public_name picos_aux.htbl) ;; opam/public name — what the outside world sees
 (libraries backoff multicore-magic))
```

- **`name`** = the OCaml module name. In code: `open Picos_aux_htbl` or `Picos_aux_htbl.find_exn`. Must be a valid OCaml identifier (underscores only).
- **`public_name`** = the name used in `(libraries ...)` stanzas and installed via opam. Can contain dots.

The dot convention `picos_aux.htbl` means "sub-library `htbl` of opam package `picos_aux`". This is **just a naming convention** — it doesn't create a hierarchy. Dune doesn't nest libraries. It's flat. Think npm scoped packages: `@picos_aux/htbl`.

### `(modules ...)` — pre-filter for compilation

By default, dune takes **every `.ml` file** in the directory and compiles it as part of the library. `(modules ...)` restricts which files are included.

**You must list ALL modules, including the main module.** The main module (`name.ml`) is NOT implicit — if you don't list it, it won't be compiled.

The pipeline:

```
1. (modules ...) → filter which .ml files exist for this library
2. Does name.ml exist (after filtering)?
   ├── YES → it's the main module, you control visibility
   └── NO  → dune auto-generates a wrapper exposing everything from step 1
```

`(modules ...)` doesn't change HOW wrapping works — it changes WHAT gets wrapped.

**Example from picos core:** the `lib/picos/` directory has ~15 files (`picos.ocaml5.ml`, `intf.ocaml4.ml`, `trigger.ocaml4.ml`, etc.) but:

```scheme
(library
 (name picos)
 (modules picos intf))   ;; picos.ml (main module) + intf.ml — everything else ignored
```

Note that `picos` is explicitly listed — without it, dune would not compile `picos.ml` as the main module and would auto-generate a wrapper instead.

Everything else in the directory is invisible to the compiler — those files are just inputs for `(rule ...)` and `(select ...)` stanzas.

**`(modules)` with no arguments** = zero modules = empty phantom library. Used by `picos_thread_ocaml4` as a probe for the `(select ...)` stanza.

Also useful: **`(private_modules <modules>)`** marks modules as inaccessible from outside the library. But it doesn't merge with `(modules ...)` — you still need to list private modules in `(modules ...)` too.

### Concurrency guarantees (non-blocking, linearizable, lock-free)

Non-blocking operations in picos are **strictly linearizable** (linearizable + serializable). Lock-free operations avoid competing operations of widely different complexities to reduce starvation.

```
Wait-free  → EVERY thread finishes in bounded steps     (strongest)
Lock-free  → AT LEAST ONE thread makes progress          (picos default for writes)
```

- **Linearizable** = operation appears to happen at a single instant. Concurrent ops behave as if sequential.
- **Lock-free** = global progress guaranteed (if your CAS fails, someone else succeeded), but individual threads may retry.
- **Starvation mitigation** = picos designs competing operations to do similar work, so cheap O(1) ops don't starve expensive O(n) ones during CAS contention.
- In `picos_aux.htbl`: reads are **wait-free**, writes are **lock-free**, resize is cooperative across threads.

### The main module file (`name.ml`)

### With a `name.ml` file — you control the public API

If your library is `(name picos_std_sync)` and you have a `picos_std_sync.ml` in the directory, that file becomes the **main module** — the "front door" of the library. You decide exactly what users see:

```ocaml
(* picos_std_sync.ml — acts as a manifest *)
module Mutex = Mutex
module Condition = Condition
module Ivar = Ivar
(* internal_helper is NOT listed → invisible to users *)
```

Users write `Picos_std_sync.Mutex.lock`. Internal modules that aren't listed stay hidden.

### Without a `name.ml` file — dune exposes everything

If there's no matching file, dune **auto-generates** a wrapper that re-exports ALL `.ml` files in the directory as sub-modules. You have no control — everything is public.

### Summary

| | With `name.ml` | Without `name.ml` |
|---|---|---|
| Who controls the public API? | You, manually | Dune, automatically (everything exposed) |
| Can you hide internal modules? | Yes, don't list them | No |
| Can you add top-level values/types? | Yes | No |

### Two patterns in picos

**Multi-module library with manifest** — `picos_std_sync.ml` just lists `module X = X` for each public sub-module. See `lib/picos_std.sync/picos_std_sync.ml`.

**Single-module library** — `picos_aux_htbl.ml` IS the implementation. No sub-modules, just one file with all the code. Users write `Picos_aux_htbl.find_exn` directly. See `lib/picos_aux.htbl/picos_aux_htbl.ml`.

### `(libraries ...)` — declaring dependencies

```scheme
(library
 (name picos_std_sync)
 (public_name picos_std.sync)
 (libraries
  (re_export picos_std.event)   ;; re-exported: users of this lib also see picos_std.event
  picos_std.awaitable           ;; regular dep: stays private
  backoff
  multicore-magic))
```

This declares what the library can `open` and use. With `(implicit_transitive_deps false)` in `dune-project` (like this project), every library must list all its direct dependencies explicitly.

**`(re_export ...)`** = "my users also get access to this dependency without declaring it themselves." Needed when your public API exposes types from another library. If a function signature returns a `Picos_std_event.t`, callers need to see that type — `re_export` makes it automatic. Without it, users get confusing "unbound module" errors.

### `(select ...)` — conditional compilation

```scheme
(select
 select.ml                              ;; the file that gets produced
 from
 (picos_io.select -> select.some.ml)    ;; if picos_io.select is available → use this
 (-> select.none.ml))                   ;; fallback (bare arrow, no library) → use this
```

Picks a source file based on whether a library is available. The bare `(-> ...)` with no library name is the default branch. This is how `picos_mux.fifo` optionally gains I/O support — if `picos_io` is installed, it gets real select integration; otherwise it gets a no-op stub.

Also used for OCaml 4 vs 5 detection: the phantom library `picos_thread_ocaml4` (empty, only exists on OCaml 4) serves as a probe.

### `(enabled_if ...)` — conditional library/rule

```scheme
(library
 (name picos_mux_fifo)
 (enabled_if (>= %{ocaml_version} 5.0.0))  ;; only exists on OCaml 5+
 ...)
```

Disables the entire library/rule/test on configurations that don't match. The library simply doesn't exist.

### Packages vs libraries

```
dune-project defines:  (package (name picos_aux) ...)      ← opam package
dune files define:     (library (public_name picos_aux.htbl) ...)  ← library within that package
```

One **opam package** can contain **multiple libraries**. The `picos_aux` opam package contains:

- `picos_aux.htbl` (library)
- `picos_aux.mpmcq` (library)
- `picos_aux.mpscq` (library)
- `picos_aux.rc` (library)

When you `opam install picos_aux`, you get all four. The dot prefix determines which opam package a library belongs to.

### `(test ...)` and `(executable ...)`

```scheme
(test
 (package picos_meta)           ;; which opam package owns this test
 (name test_picos)              ;; produces test_picos.exe
 (modules test_picos)           ;; only compile this .ml file
 (libraries alcotest picos_std.finally ...))
```

Work like libraries but produce `.exe` files. `(package ...)` tells dune which opam package the test belongs to (used by `dune runtest`).

### Directories with only `(documentation ...)`

```scheme
;; lib/picos_aux/dune — no library, just docs
(documentation
 (package picos_aux)
 (mld_files index))
```

Some directories don't define a library — they just host odoc documentation entry points (`.mld` files). `lib/picos_aux/` and `lib/picos_std/` are like this.

### Why split one package into many directories/libraries?

Dune forces one library per directory. But the real reason for the split is **granular dependencies**.

If `picos_std` were one monolithic library, anyone who just needs `Mutex` would also pull in `Event`, `Bundle`, `Promise`, `Awaitable`, and all their transitive deps. By splitting into separate libraries:

```
picos_std.awaitable  → depends on picos only
picos_std.event      → depends on picos_std.awaitable
picos_std.finally    → depends on picos only
picos_std.sync       → depends on picos_std.awaitable, picos_std.event
picos_std.structured → depends on picos_std.finally, picos_std.sync
```

Users only pay for what they use. Changing `event.ml` doesn't recompile `finally`. Circular deps are impossible (dune enforces acyclicity between libraries). Same reasoning as `@angular/core` vs `@angular/forms` vs `@angular/router` in npm.

Directories without a dot (`picos_std/`, `picos_mux/`) are just odoc landing pages — no library code.

### Full picture of the project layout

```
dune-project
  └── defines 8 opam packages
        │
        ├── picos_aux (opam package)
        │     ├── lib/picos_aux/dune         → just docs, no library
        │     ├── lib/picos_aux.htbl/dune    → library picos_aux.htbl
        │     ├── lib/picos_aux.mpmcq/dune   → library picos_aux.mpmcq
        │     ├── lib/picos_aux.mpscq/dune   → library picos_aux.mpscq
        │     └── lib/picos_aux.rc/dune      → library picos_aux.rc
        │
        ├── picos (opam package)
        │     ├── lib/picos/dune             → library picos
        │     ├── lib/picos.thread/dune      → library picos.thread
        │     └── lib/picos.domain/dune      → library picos.domain
        │
        ├── picos_meta (opam package)
        │     └── test/dune                  → test executables
        ...
```

---

## Picos core: the four primitives

Picos has exactly four core modules. Everything else (`picos_std.*`, `picos_mux.*`, `picos_io.*`) is built on top of them.

- **Trigger** — one-shot "wake me up" signal. Create it, put it somewhere, `await` it. Someone else calls `signal` → you wake up.
- **Computation** — result container for a fiber's work. Finishes via `try_return value` (success) or `try_cancel exn` (canceled). Triggers can be attached — when the computation finishes, all attached triggers fire.
- **Fiber** — an independent thread of execution. Has exactly one Computation at any time. Can `forbid`/`permit` cancellation (deferred cancellation: the computation gets marked as canceled, but the fiber doesn't notice until it leaves the `forbid` section).
- **Handler** — how schedulers install themselves. Contains the effect handler that catches the 5 effects.

### The five effects (defined in `intf.ocaml5.ml`)

```
Trigger.Await          : trigger → (exn * bt) option    "suspend me until signaled"
Computation.Cancel_after : {seconds, exn, computation}  "cancel after timeout"
Fiber.Current          : fiber                           "give me the current fiber"
Fiber.Yield            : unit                            "let others run"
Fiber.Spawn            : {fiber, main}                   "create a new fiber"
```

Declared as `private` extensible effects — only picos can create them, any scheduler can pattern match on them.

`intf.ocaml5.ml` also provides `Fiber.continue_with` / `Fiber.resume_with` — helpers that check cancellation before resuming a fiber, so schedulers don't have to do it manually.

### Why shallow handlers, not deep

Picos uses `Effect.Shallow` exclusively. The difference:

- **Deep** — handler installed once, catches every effect for the fiber's lifetime. Baked into the continuation.
- **Shallow** — handler catches ONE effect, then you must re-install for the next one. The continuation is "naked" — no handler attached.

Picos uses shallow because fibers can **move between schedulers**. When a fiber is suspended, its continuation `k` is just a value in memory. Whoever picks it up and calls `continue_with k value their_handler` becomes the new scheduler:

```
Scheduler A running fiber F:
  1. F does Await → A's handler catches it
  2. A saves continuation k_F (e.g., attaches to a trigger)
  3. A goes back to its run loop

  ... trigger gets signaled by something on Scheduler B's side ...

  4. Signal callback puts k_F into B's ready queue
  5. B pops k_F, calls: continue_with k_F value handler_B
  6. F resumes under B's handler
```

Between steps 3 and 5, the fiber belongs to nobody — it's a suspended continuation sitting in memory. With deep handlers, `k_F` would carry handler_A permanently, making the swap impossible.

In practice, most fibers stay on one scheduler. But shallow handlers make the design **open** — which is the whole point of picos as an interop layer.

### Trigger: the wake-up mechanism

A trigger is a **one-shot doorbell**. Three states: `Initial → Awaiting → Signaled` (never goes back).

- **Does not carry a result.** It just says "wake up." The fiber checks the shared data structure itself after waking.
- **Idempotent signaling.** `Trigger.signal` on an already-signaled trigger is a no-op. No explosion risk from concurrent signals.
- **Put in data structures** so other fibers know where to signal. E.g., mutex keeps a queue of triggers — unlock pops one and signals it.
- **Attached to computations** for cancellation: if the computation is canceled, all attached triggers fire, waking all suspended fibers.

```
Mutex wait queue: [ trigger_A ; trigger_B ; trigger_C ]
                        ↑ signal this one → fiber A wakes up
```

After `await` returns, the fiber must clean up (remove trigger from data structure, detach from computation). Both the normal and canceled paths must do this.

### Computation: the cancellation unit

A computation is **not** the code — it's the **status box** for some work:

```
Running  { triggers: Trigger.t list }   ← work in progress, observers attached
Returned { value: 'a }                  ← completed successfully
Canceled { exn; bt }                    ← failed or externally canceled
```

Key properties:

- **Many fibers, one computation**: a parallel map spawns 4 fibers sharing one computation. Cancel it → all 4 stop.
- **One fiber, many computations**: `Flock.join_after` swaps the fiber's computation to the flock's, then back when done. Nesting = stacking computations.
- **Not hierarchical by itself**, but `Computation.attach_canceler ~from:parent ~into:child` chains them: canceling parent triggers a special trigger whose action cancels child. This cascades through the tree.
- **`Computation.check`**: polls cancellation status, raises if canceled. Called internally by sync primitives (mutex, semaphore) at suspension points. End users only need it in tight CPU loops with no effects.
- **`Computation.capture comp f x`**: runs `f x`, stores the result (or exception) in `comp`. Convenience for "run and complete."

### `type !'a t` — injectivity annotation

The `!` means the type parameter is **injective**: `int t ≠ string t` is guaranteed. Needed because the computation actually stores a value of type `'a` inside. Without `!`, certain GADT refinements and pattern matches wouldn't typecheck. Almost always correct for abstract types that use their parameter.

### Private effects

```ocaml
type _ Effect.t += private | Await : t -> (exn * bt) option Effect.t
```

`private` on an extensible variant: **you can match on it, but you can't construct it.**

- Schedulers can handle `Await` in their effect handler (pattern match: OK)
- Only picos itself can `Effect.perform (Await trigger)` (construction: only internal)
- Forces everyone to go through the public API (`Trigger.await`, `Fiber.spawn`, etc.) which does bookkeeping before/after performing the effect

---

## OCaml 5 concurrency model

### Domains vs Threads vs Fibers

```
Domains  = parallelism   (few, one per CPU core, expensive — own minor heap + GC state)
Threads  = OS concurrency (moderate count, shared GC within a domain)
Fibers   = cooperative    (thousands, near-zero cost, suspended/resumed via effect handlers)
```

- **Domains** are capped at `Domain.recommended_domain_count()` (typically 8-16). Each has its own minor heap and GC. They exist for CPU-bound parallelism.
- **Threads** (`Thread.create`) are OS threads within a domain. They share the domain's GC. Used for blocking I/O helpers, background tasks.
- **Fibers** are userspace — they only exist inside a scheduler. An effect handler suspends a fiber by capturing a continuation.

A single domain can host multiple threads. A single thread can run thousands of fibers (one at a time, cooperatively).

### DLS vs TLS

- **`Domain.DLS`** (Domain-Local Storage) = one value per domain. All threads within the same domain share it.
- **`Thread_local_storage`** (TLS) = one value per OS thread. Threads within the same domain get independent slots.

Picos uses TLS (not DLS) because a single domain may run multiple threads with different roles — e.g., a scheduler loop thread and an I/O select thread. Each needs its own "current fiber" reference without interfering with the other.

---

## How `thread-local-storage` works (the hack)

The `thread-local-storage` library by c-cube exploits an implementation detail of OCaml's `Thread.t`:

1. `Thread.t` is internally a record. Its **second field** is unused after thread startup (it originally held the closure to run).
2. The library casts `Thread.self()` via `Obj.magic` to a fake record type that exposes this field.
3. It **hijacks that field** to store a growable array of TLS values.
4. Each `TLS.create()` returns a unique integer index (from a global atomic counter).
5. `get`/`set` are just field access + array index — extremely fast, no locks, no hash tables.

The sentinel for "not set" slots is the `counter` atomic itself — a private module-level value whose physical address can never collide with user values.

```ocaml
(* simplified view of what happens on TLS.get_exn *)
let thread = Obj.magic (Thread.self ()) in   (* cast to fake record *)
let tls_array = thread.hijacked_field in      (* grab the stashed array *)
tls_array.(slot_index)                        (* direct array lookup *)
```

This is safe because each OS thread has its own `Thread.t` object — no sharing, no races on reads.

### Where picos uses TLS

Schedulers use `Picos_thread.TLS` to store per-thread state:

- `picos_mux.multififo` — stores per-thread scheduler context (`per_thread_key`)
- `picos_mux.random` — stores the current fiber reference (`fiber_key`)
- `picos_io.select` — stores interrupt request state (`intr_key`)

The `picos.thread` sub-library wraps this: `lib/picos.thread/picos_thread.posix.ml` just does `module TLS = Thread_local_storage`.

---

## Do you need TLS for an Effect-TS port?

Probably **not**, at least not early on. In Effect-TS, runtime context (`Runtime`, `FiberRef`, `Context`) flows **through the monad** — it's explicitly threaded as a parameter in the `Effect<A, E, R>` chain. There's no ambient state that needs TLS.

Two possible port architectures:

| Approach | How context flows | TLS needed? |
|----------|-------------------|-------------|
| **Monadic** (like Effect-TS) | `'a Effect.t` is a lazy description; the runtime interpreter threads context explicitly | No |
| **Direct-style** (like picos/eio) | Fibers run real code; effects suspend them; scheduler needs to know "which fiber is running on this thread?" | Yes, if multi-threaded |

The monadic approach is closer to Effect-TS's original design. The direct-style approach is more idiomatic OCaml 5. TLS is only a concern of the **runtime/scheduler layer** — start without it and add it only if you build a multi-domain scheduler.

---

## OCaml 4 compatibility in picos (skip this)

This section exists only for completeness. Since we're targeting OCaml 5, all of this can be ignored.

### What exists for OCaml 4

- `*.ocaml4.ml` files throughout `lib/picos/` — reimplements core concepts without effect handlers, using TLS-based handler context instead
- `generate_picos_ml_for_ocaml_4.exe` — code generator that stitches OCaml 5 source with OCaml 4-specific replacements
- `lib/picos.domain/picos_domain.ocaml4.ml` — fakes Domain API (`recommended_domain_count = 1`, DLS backed by plain refs)
- `lib/picos.thread/picos_thread.none.ml` — fallback TLS using DLS (which on OCaml 4 is just a ref)
- `domain_shims` — test dependency that provides `Domain`-like APIs on OCaml 4
- `picos_mux.thread` — the only scheduler that works on OCaml 4 (one OS thread per fiber)

### Libraries that are OCaml 5 only

Gated via `(enabled_if (>= %{ocaml_version} 5.0.0))` in their dune files:

- `picos_mux.fifo` — FIFO scheduler
- `picos_mux.multififo` — multi-domain FIFO
- `picos_mux.random` — work-stealing scheduler
- `picos_lwt` — Lwt bridge

### Files to ignore

All `*.ocaml4.ml`, `intf.ocaml4.ml`, `picos_domain.ocaml4.ml`, `picos_thread.none.ml`, `generate_picos_ml_for_ocaml_4.exe`, and anything involving `domain_shims`.

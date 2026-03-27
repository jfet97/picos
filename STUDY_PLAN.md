# Picos Study Plan

A file-by-file reading plan to understand picos, starting from scratch on lock-free programming and dune/opam.

---

## Phase 0 — Build system (dune/opam)

Before reading any code, understand how the project is organized.

### What to read

| # | File | Why |
|---|------|-----|
| 1 | `dune-project` | Entry point of every dune project. Defines dune version, project name, 8 opam packages, their dependencies. Everything in `.opam` files is generated from here |
| 2 | `picos.opam` | Example of a generated opam package. Look at `depends`, `build` commands, `depopts` |
| 3 | `dune` (root) | Root dune file. Minimal in this project: runs mdx tests on README |
| 4 | `lib/picos/dune` | Most interesting dune file in the project. Shows conditional compilation for OCaml 4 vs 5 with `(select ...)` and `(enabled_if ...)` |
| 5 | `lib/picos_aux.htbl/dune` | Typical sub-library example: `(library (name picos_aux_htbl) (public_name picos_aux.htbl))` |
| 6 | `lib/picos_mux.fifo/dune` | Shows optional dependencies via `select` for I/O support |
| 7 | `Makefile` | Just 4 lines, runs benchmarks. Nothing special |
| 8 | `.ocamlformat` | Project formatting style |

### Key dune concepts

- **`(library ...)`** = compilation unit. Has a `name` (used internally) and a `public_name` (what you write in `(libraries ...)`).
- **`(select ...)`** = conditional file selection based on available dependencies or OCaml version.
- **`(enabled_if ...)`** = enable/disable a library based on conditions (e.g. `%{ocaml_version}`)
- **`dune build`** compiles everything, **`dune runtest`** runs tests, **`dune build @doc`** generates documentation.
- Every directory with a `dune` file containing `(library ...)` is a separate module/package.

---

## Phase 1 — The core picos interface

Picos is a **contract between schedulers and concurrent libraries**. It is not a scheduler — it defines the interface that schedulers must implement. Think of it as a trait/typeclass.

### Conceptual prerequisites

- **Effect handlers (OCaml 5)**: picos uses `Effect.Shallow` to suspend/resume fibers. If you're not familiar, read [the official documentation](https://v2.ocaml.org/manual/effects.html) first.
- **Fiber**: a lightweight cooperative thread. Not an OS thread — it's a piece of computation that can be suspended and resumed.
- **CAS (Compare-And-Swap)**: fundamental atomic operation. `Atomic.compare_and_set ref old_val new_val` — succeeds only if the current value is `old_val`.

### What to read

| # | File | ~LOC | What you learn |
|---|------|------|----------------|
| 1 | `lib/picos/picos.mli` | — | The complete public API. Read the signatures of `Trigger`, `Computation`, `Fiber`, `Handler`. No need to understand the implementation — understand the contract first |
| 2 | `lib/picos/picos.ocaml5.ml` | ~1200 | The core implementation for OCaml 5. Here you see how Trigger, Computation and Fiber are implemented with effect handlers |
| 3 | `lib/picos/intf.ocaml5.ml` | — | Internal interface definitions for OCaml 5 |

### The three fundamental concepts

```
Trigger  →  "wake me up when X happens"
             A one-shot signal. Can be awaited (await) and signaled (signal).
             The basic building block for suspension.

Computation  →  "the result of some work"
                 Can complete with a value (try_return) or be canceled (try_cancel).
                 Has Triggers attached that get signaled on completion.

Fiber  →  "a cooperative thread"
           Has an associated Computation, can yield, spawn other fibers.
           Has a "forbid" flag to disable cancellation in critical sections.
```

### The five effects

These are the 5 effects a scheduler must handle:

1. **`Trigger.Await`** — suspend the current fiber until the trigger is signaled
2. **`Fiber.Current`** — give me the current fiber
3. **`Fiber.Yield`** — yield control to the scheduler
4. **`Fiber.Spawn`** — create a new fiber
5. **`Computation.Cancel_after`** — cancel this computation after a timeout

---

## Phase 2 — Lock-free building blocks

Now you need to understand the lock-free data structures used everywhere. Ordered from simplest to most complex.

### Lock-free prerequisites

- **`Atomic.t`**: a cell supporting `get`, `set`, `compare_and_set` (CAS). CAS is the fundamental building block.
- **Exponential backoff**: when a CAS fails (contention), wait a bit before retrying. `Backoff.once` doubles the wait time.
- **`multicore-magic`**: utility library providing `Transparent_atomic` (unboxed atomics), `fenceless_get` (reads without memory barrier), and `copy_as ~padded:true` (prevents false sharing between cache lines).
- **ABA problem**: risk of CAS succeeding "by mistake" because the value cycled back to the original. Counters in nodes prevent this.

### What to read

| # | File | ~LOC | What you learn |
|---|------|------|----------------|
| 1 | `lib/picos_aux.mpscq/picos_aux_mpscq.mli` | 65 | API of the simplest queue. Multi-producer, single-consumer |
| 2 | `lib/picos_aux.mpscq/picos_aux_mpscq.ml` | 155 | Implementation. Study the CAS + backoff retry loop pattern |
| 3 | `lib/picos_aux.mpmcq/picos_aux_mpmcq.mli` | 71 | Multi-consumer queue API |
| 4 | `lib/picos_aux.mpmcq/picos_aux_mpmcq.ml` | 212 | More complex: uses counters to version nodes, has head↔tail reversal logic |
| 5 | `lib/picos_aux.rc/intf.ml` | 94 | Reference counting interface |
| 6 | `lib/picos_aux.rc/picos_aux_rc.ml` | 91 | Implementation. Learn how to pack refcount + status bits into a single int |
| 7 | `lib/picos_aux.htbl/picos_aux_htbl.mli` | 303 | Lock-free hash table API. The most complex in the group |
| 8 | `lib/picos_aux.htbl/picos_aux_htbl.ml` | 693 | Implementation. Wait-free reads, cooperative resizing across threads |

### Recurring pattern in all lock-free code

```ocaml
(* basic CAS retry loop *)
let rec try_something t value =
  let before = Atomic.get t.state in
  let after = compute_new_state before value in
  if Atomic.compare_and_set t.state before after then
    (* success *)
  else
    (* someone else modified state → retry *)
    try_something t value
```

With backoff:

```ocaml
(* CAS retry with exponential backoff to reduce contention *)
let try_something t value =
  let backoff = ref Backoff.default in
  let rec loop () =
    let before = Atomic.get t.state in
    let after = compute_new_state before value in
    if not (Atomic.compare_and_set t.state before after) then begin
      backoff := Backoff.once !backoff;
      loop ()
    end
  in
  loop ()
```

---

## Phase 3 — Awaitable (the bridge between atomics and fibers)

This is the most important concept for understanding how sync primitives work. It's a "userspace futex": an atomic value on which you can also **suspend a fiber** waiting for a change.

| # | File | ~LOC | What you learn |
|---|------|------|----------------|
| 1 | `lib/picos_std.awaitable/picos_std_awaitable.mli` | 211 | Complete API. Two layers: atomic (get/CAS) + futex (signal/broadcast/await) |
| 2 | `lib/picos_std.awaitable/picos_std_awaitable.ml` | 444 | Implementation. State machine for waiters: Zero → One → Many. Lazy linking/reversal |

### Why this matters

All primitives in `picos_std.sync` (mutex, condition, semaphore...) are built on top of `awaitable`. The pattern is always:

1. Try to modify state with CAS
2. If the state isn't what you want, **suspend the fiber** with `await`
3. When someone changes the state, call `signal`/`broadcast` to wake up waiting fibers

---

## Phase 4 — Synchronization primitives

Now you have all the building blocks to understand mutexes, semaphores, etc.

### Reading order (simplest to most complex)

| # | File | ~LOC | What you learn |
|---|------|------|----------------|
| 1 | `lib/picos_std.sync/ivar.ml` | 25 | The simplest one. A single-assignment variable. Perfect to understand the base pattern |
| 2 | `lib/picos_std.sync/latch.ml` | ~50 | Countdown latch. Simple atomic counter + signaling |
| 3 | `lib/picos_std.sync/condition.ml` | 63 | Condition variable. Signal/broadcast/wait |
| 4 | `lib/picos_std.sync/sem.ml` | 91 | Counting semaphore |
| 5 | `lib/picos_std.sync/lock.ml` | 88 | Basic lock |
| 6 | `lib/picos_std.sync/mutex.ml` | 154 | Mutex with fairness. More elaborate state machine |
| 7 | `lib/picos_std.sync/rwlock.ml` | 176 | Reader-writer lock. Most complex: manages concurrent readers/writers |
| 8 | `lib/picos_std.sync/stream.ml` | 50 | Stream/channel communication |
| 9 | `lib/picos_std.sync/lazy.ml` | 85 | Fiber-safe lazy evaluation |
| 10 | `lib/picos_std.sync/picos_std_sync.mli` | — | Public interface of the aggregated module |

---

## Phase 5 — The FIFO scheduler (moment of truth)

Here you see how a **real scheduler** implements the picos contract. This is the simplest scheduler — single-threaded, FIFO ready queue.

| # | File | ~LOC | What you learn |
|---|------|------|----------------|
| 1 | `lib/picos_mux.fifo/picos_mux_fifo.mli` | 46 | API: `run`, `run_fiber` |
| 2 | `lib/picos_mux.fifo/picos_mux_fifo.ml` | 204 | **The most important implementation to read**. See how each effect is handled: Spawn enqueues a fiber, Yield suspends and re-enqueues, Await waits on a trigger, Cancel_after sets a timer |

### Anatomy of the FIFO scheduler

```
                    ┌─────────────┐
                    │  Ready Queue │  (MPSCQ)
                    │  ┌────────┐ │
     Spawn ────────►│  │ fiber1 │ │
     Yield ────────►│  │ fiber2 │ │
     Resume ───────►│  │ fiber3 │ │
                    │  └────────┘ │
                    └──────┬──────┘
                           │ pop
                           ▼
                    ┌─────────────┐
                    │  Run fiber  │  (effect handler)
                    │  until next │
                    │  effect     │
                    └─────────────┘
```

The scheduler loops: pop the next fiber from the queue, run it until it performs an effect, handle the effect, and repeat.

### After the FIFO

| # | File | ~LOC | What you learn |
|---|------|------|----------------|
| 3 | `lib/picos_mux.thread/picos_mux_thread.ml` | 100 | OS thread-based scheduler. Compare with FIFO to understand the difference |
| 4 | `lib/picos_mux.multififo/` | — | Multi-domain FIFO. Work distributed across multiple threads |
| 5 | `lib/picos_mux.random/` | — | Randomized work-stealing scheduler |

---

## Phase 6 — Structured concurrency and resource management

| # | File | ~LOC | What you learn |
|---|------|------|----------------|
| 1 | `lib/picos_std.finally/picos_std_finally.mli` | — | `let@` binding operator for resource management. Similar to `bracket` in Haskell or `Effect.acquireRelease` in Effect-TS |
| 2 | `lib/picos_std.finally/picos_std_finally.ml` | — | Implementation. Note how cancellation is disabled during cleanup |
| 3 | `lib/picos_std.structured/control.ml` | 95 | Basic operations: sleep, yield, terminate_after |
| 4 | `lib/picos_std.structured/bundle.ml` | 228 | **Scope management**. Groups fibers, collects errors, automatic cleanup. This is the closest piece to Effect-TS Scope |
| 5 | `lib/picos_std.structured/flock.ml` | 14 | Structured fork/join (wrapper around Bundle) |
| 6 | `lib/picos_std.structured/promise.ml` | 19 | Promise-like async result |
| 7 | `lib/picos_std.structured/run.ml` | 56 | Entry point for running fibers with a scheduler |

---

## Phase 7 — Async I/O and integrations

| # | File | ~LOC | What you learn |
|---|------|------|----------------|
| 1 | `lib/picos_io.select/picos_io_select.ml` | 593 | I/O multiplexing via `Unix.select`. How fibers suspend waiting for I/O |
| 2 | `lib/picos_io.fd/picos_io_fd.ml` | 34 | File descriptor wrapper |
| 3 | `lib/picos_lwt/picos_lwt.ml` | — | Picos↔Lwt bridge. If you know Lwt, this shows how the two worlds connect |
| 4 | `lib/picos_io_cohttp/picos_io_cohttp.ml` | — | HTTP server/client on top of picos I/O |

---

## Phase 8 — Tests and benchmarks

Tests are executable documentation. Read them alongside the code.

| # | File | What you learn |
|---|------|----------------|
| 1 | `test/test_picos.ml` | Core tests — see how Trigger/Computation/Fiber are used in practice |
| 2 | `test/test_sync.ml` (~22K LOC) | Stress tests for sync primitives. Huge but useful to skim |
| 3 | `test/test_schedulers.ml` (~7K LOC) | How schedulers are tested |
| 4 | `test/test_structured.ml` (~9K LOC) | Structured concurrency tests |
| 5 | `test/test_picos_dscheck.ml` | **Dscheck = model checker**. Tests lock-free properties by exploring all possible interleavings |
| 6 | `test/test_server_and_client.ml` | Echo server — complete end-to-end example |
| 7 | `bench/main.exe` via `make bench` | Benchmarks for data structures and schedulers |

---

## Dependency map

```
backoff, multicore-magic        ← external: CAS retry, atomics, padding
        │
        ▼
   picos_aux                    ← lock-free data structures
   (htbl, mpmcq, mpscq, rc)
        │
        ▼
   picos                        ← core interface: Trigger, Computation, Fiber, 5 effects
        │
        ▼
   picos_std.awaitable          ← futex-like atomic + fiber suspension
        │
        ▼
   picos_std.sync               ← mutex, condition, semaphore, rwlock, ivar...
   picos_std.event              ← CML-style events
   picos_std.finally            ← resource management (bracket)
   picos_std.structured         ← bundle, flock, promise, control
        │
        ├──────────┐
        ▼          ▼
   picos_mux    picos_io        ← scheduler implementations / async I/O
        │          │
        ▼          ▼
   picos_lwt    picos_io_cohttp ← integrations
```

---

## Effect-TS parallels

Since your goal is to port Effect-TS to OCaml, watch for these correspondences:

| Effect-TS | Picos | Notes |
|-----------|-------|-------|
| `Effect<A, E, R>` | `Computation.t` | But Computation has no types for error/environment |
| `Fiber` | `Fiber.t` | Similar, but picos is more low-level |
| `Scope` | `Bundle` / `Flock` | Structured concurrency scope |
| `acquireRelease` | `picos_std.finally` | Resource management |
| `Runtime` | `picos_mux.*` | The scheduler that runs fibers |
| `Deferred` / `Promise` | `Promise` in structured | Async result |
| `Queue`, `Ref`, `Semaphore` | `picos_std.sync.*` | Concurrent primitives |
| Interruption | `Computation.try_cancel` + `Fiber.forbid` | Cancellation model |

The fundamental difference: Effect-TS uses monads (lazy, compositional), picos uses effect handlers (direct style, imperative). Your port will need to decide which approach to take.

See also: [STUDY_NOTES.md](STUDY_NOTES.md) for deeper dives into OCaml 5 concurrency, TLS, and OCaml 4 compat details.

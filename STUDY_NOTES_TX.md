# Computation.Tx — Transactional Completion of Computations

A deep dive into the `Tx` module inside `Computation`, how it works, why it exists, and how it affects the entire computation state machine.

Source: `lib/picos/picos.ocaml5.ml`, lines 75–209.

---

## Table of contents

1. [Background: what is a computation?](#1-background-what-is-a-computation)
2. [The problem: completing multiple computations atomically](#2-the-problem-completing-multiple-computations-atomically)
3. [All the types, defined from scratch](#3-all-the-types-defined-from-scratch)
4. [How plain (non-transactional) completion works](#4-how-plain-non-transactional-completion-works)
5. [How transactional completion works](#5-how-transactional-completion-works)
6. [The `tx` field: visibility control](#6-the-tx-field-visibility-control)
7. [What happens when operations encounter tentative state](#7-what-happens-when-operations-encounter-tentative-state)
8. [Full trace: two domains racing](#8-full-trace-two-domains-racing)
9. [Overlapping transactions](#9-overlapping-transactions)
10. [Obstruction-freedom](#10-obstruction-freedom)
11. [Who uses Tx in practice?](#11-who-uses-tx-in-practice)

---

## 1. Background: what is a computation?

A `Computation.t` is a status box for some work. It's an `Atomic.t` holding one of three states (OCaml variant names):

- **`Continue`** — work in progress, triggers can be attached
- **`Returned`** — completed with a value
- **`Canceled`** — completed with an exception

The public API uses different words: `is_running` returns `true` when the state is `Continue`, and "completed" means either `Returned` or `Canceled`. In this document, we always use the actual variant names (`Continue`, `Returned`, `Canceled`) to avoid confusion.

A computation is NOT the code itself. It's the handle you use to observe or cancel some work. Multiple fibers can share one computation (e.g., parallel map). One fiber can switch between computations (e.g., structured concurrency nesting).

The normal API to complete a computation is:

```ocaml
Computation.try_return comp value       (* complete with success *)
Computation.try_cancel comp exn bt      (* complete with error/cancellation *)
```

These operate on a **single** computation. They're lock-free and are all you need in most cases.

---

## 2. The problem: completing multiple computations atomically

Sometimes you need to complete **two or more** computations at the same time, as a single atomic operation: either all complete, or none do.

### The motivating scenario: a race

Suppose you have two computations racing. Whichever finishes first should cancel the other:

```
comp_a: computing fib(100)
comp_b: sleeping for 1 second, then canceling
```

Two fibers try to resolve this simultaneously:

```
Fiber 1: "comp_a finished! I'll return comp_a and cancel comp_b"
Fiber 2: "comp_b finished! I'll return comp_b and cancel comp_a"
```

Without transactions, doing this in two steps creates a race:

```
Fiber 1:                          Fiber 2:
  try_return comp_a 101  ✓          try_return comp_b 42   ✓
  try_cancel comp_b Exit ✗          try_cancel comp_a Exit ✗
  (comp_b already returned!)        (comp_a already returned!)
```

Both computations returned. Nobody got canceled. **Wrong** — you wanted exactly one winner. The two-step sequence is not atomic: between step 1 and step 2, the other fiber can slip in.

With `Tx`, you can do both completions atomically:

```ocaml
let tx = Tx.create () in
if Tx.try_return tx comp_a 101
   && Tx.try_cancel tx comp_b Exit bt
   && Tx.try_commit tx
then (* both happened atomically *)
else (* someone else interfered, retry *)
```

---

## 3. All the types, defined from scratch

### `tx_state` — the lifecycle of a transaction

```ocaml
type tx_state = Stopped | Started | Aborted
```

This is stored inside an `Atomic.t` and represents where a transaction is in its lifecycle:

| Value | Meaning |
|-------|---------|
| `Started` | Transaction is alive. Tentative completions may exist but are not final. |
| `Stopped` | Transaction was committed successfully. All completions are permanent. Also used when no transaction is involved at all (plain `try_return`/`try_cancel`). |
| `Aborted` | Transaction was killed by someone else. All completions will be rolled back. |

Transitions (one-way, never go back):

```
Started ──try_commit──► Stopped   (success: completions become permanent)
Started ──try_abort───► Aborted   (failure: completions get rolled back)
```

### `tx` — the transaction handle

```ocaml
type _ tx =
  | Stopped : [> `Stopped ] tx
  | Running : {
      state : tx_state Atomic.t;
      mutable completions : [ `Nil | `Completion ] completions;
    } -> [> `Running ] tx
```

Two variants:

| Variant | What it is |
|---------|-----------|
| `Stopped` | A constant value (no allocation). Means "no transaction" or "already committed." This is what plain `try_return`/`try_cancel` use. |
| `Running { state; completions }` | An actual transaction in flight. `state` is the `tx_state` atomic. `completions` is the undo log (see below). |

Note: `Stopped` as a `tx` variant and `Stopped` as a `tx_state` value are different things but related. The `tx` variant `Stopped` is a constant used when there's no transaction at all. The `tx_state` value `Stopped` is what a `Running` transaction's `state` atomic transitions to upon commit.

### `completions` — the undo log

```ocaml
type _ completions =
  | Nil : [> `Nil ] completions
  | Completion : {
      computation : 'a t;                    (* which computation was changed *)
      before : ('a, [ `Continue ]) st;       (* its state BEFORE the change *)
      completions : [...] completions;       (* next entry in the list *)
    } -> [> `Completion ] completions
```

A linked list of "I changed computation X, and before my change it was in state Y." Each entry records one computation that the transaction tentatively completed, plus what it looked like before.

Used for rollback: walk the list, restore each computation to its `before` state.

Example after a transaction tentatively completed comp_a and comp_b:

```
completions = Completion {
  computation = comp_b;
  before = Continue { triggers = []; ... };
  completions = Completion {
    computation = comp_a;
    before = Continue { triggers = [t1; t2]; ... };
    completions = Nil
  }
}
```

### `st` — the computation state

This is the core type. Every computation is an `Atomic.t` holding one of these:

```ocaml
and ('a, _) st =
  | Continue : {
      balance_and_mode : int;
      triggers : Trigger.t list;
    } -> ('a, [> `Continue ]) st

  | Returned : {
      mutable tx : [ `Stopped | `Running ] tx;
      value : 'a;
    } -> ('a, [> `Returned ]) st

  | Canceled : {
      mutable tx : [ `Stopped | `Running ] tx;
      exn : exn;
      bt : Printexc.raw_backtrace;
    } -> ('a, [> `Canceled ]) st
```

| State | Meaning | Fields |
|-------|---------|--------|
| `Continue` | Computation is running | `triggers`: list of attached triggers (observers waiting for completion). `balance_and_mode`: bookkeeping for trigger GC + FIFO/LIFO ordering. |
| `Returned` | Completed with a value | `value`: the result. **`tx`**: is this completion final? |
| `Canceled` | Completed with an error | `exn`, `bt`: the exception and backtrace. **`tx`**: is this completion final? |

The crucial thing: **both `Returned` and `Canceled` carry a `tx` field.** This field is what makes the whole transactional mechanism work. More on this in [section 6](#6-the-tx-field-visibility-control).

### Putting it all together: `'a t`

```ocaml
and 'a state =
  | S : ('a, [< `Canceled | `Returned | `Continue ]) st -> 'a state
  [@@unboxed]

and 'a t = 'a state Atomic.t
```

A computation is just an atomic cell holding an `st` value wrapped in `S`. The `[@@unboxed]` means the `S` wrapper has zero runtime cost.

---

## 4. How plain (non-transactional) completion works

When you call `Computation.try_return comp value` without any transaction:

```ocaml
let try_return t value =
  try_terminate t (S (Returned { value; tx = Stopped })) Backoff.default
```

Notice: **`tx = Stopped`** (the constant, not a running transaction). The completion is final from birth. No undo log, no commit step.

`try_terminate` does a CAS:

```ocaml
let rec try_terminate t after backoff =
  match Atomic.get t with
  | S (Continue _ as before) ->
      if Atomic.compare_and_set t (S before) after then begin
        signal before;   (* signal ALL attached triggers *)
        true
      end
      else try_terminate t after (Backoff.once backoff)  (* CAS failed, retry *)
  | S (Returned { tx; _ }) | S (Canceled { tx; _ }) ->
      (* already completed — but is it final? see section 7 *)
      if Tx.try_abort tx then try_terminate t after backoff else false
```

If the computation is `Continue`, CAS it to `Returned{tx=Stopped}`, then signal all triggers. Done.

If the computation is already `Returned` or `Canceled`, it checks the `tx` field (see [section 7](#7-what-happens-when-operations-encounter-tentative-state)).

---

## 5. How transactional completion works

### Step 1: create a transaction

```ocaml
let tx = Tx.create ()
(* tx = Running { state = Atomic.make Started; completions = Nil } *)
```

### Step 2: tentatively complete computations

```ocaml
Tx.try_return tx comp_a 101
```

This calls `try_complete`, which:

1. Checks that `tx.state` is still `Started` (transaction alive)
2. Records `comp_a`'s current state in the undo log: `tx.completions <- Completion { computation=comp_a; before=Continue{...}; ... }`
3. CAS `comp_a`: `Continue{...}` → `Returned { value=101; tx=tx }`

The key: the new state embeds **a reference to the transaction** in the `tx` field. This means "this completion belongs to transaction `tx` and is not final yet."

You can add more computations:

```ocaml
Tx.try_cancel tx comp_b Exit bt
```

Same thing: record `comp_b`'s previous state, CAS `comp_b` to `Canceled { tx=tx; ... }`.

Now the undo log has two entries:

```
tx.completions = [ comp_b was Continue; comp_a was Continue ]
```

### Step 3: commit

```ocaml
Tx.try_commit tx
```

This does one CAS: `tx.state`: `Started` → `Stopped`.

If that CAS succeeds, the transaction is committed. Then it walks the completions list and for each computation:

1. Sets `r.tx <- Stopped` (the constant) — making the completion permanent
2. Calls `signal` on the old `Continue` state — firing all attached triggers

```ocaml
let try_commit (Running r : [ `Running ] tx) =
  let success = Atomic.compare_and_set r.state Started Stopped in
  if not success then success else commit r.completions

let rec commit = function
  | Nil -> true
  | Completion r ->
      begin match Atomic.get r.computation with
      | S (Canceled r) -> r.tx <- Stopped    (* finalize *)
      | S (Returned r) -> r.tx <- Stopped    (* finalize *)
      | S (Continue _) -> impossible ()
      end;
      signal r.before;    (* signal triggers from old Continue state *)
      commit r.completions
```

After commit, each computation's `tx` field is `Stopped` — identical to what a plain `try_return`/`try_cancel` would have produced.

### What if someone aborts?

If another thread calls `Tx.try_abort tx` before the commit:

1. CAS `tx.state`: `Started` → `Aborted`
2. Walk the completions list and for each entry:
   - Check if the computation still points to this transaction (`tx == previous_tx`)
   - If yes, CAS it back to its `before` state (the original `Continue`)

```ocaml
let rec abort (Running r as tx : [ `Running ] tx) =
  (* ... *)
  match Atomic.get r.state with
  | Started ->
      if Atomic.compare_and_set r.state Started Aborted then
        rollback tx r.completions
      else abort tx
  | Aborted -> rollback tx r.completions
  | Stopped -> false    (* already committed, can't abort *)

let rec rollback tx = function
  | Nil -> true
  | Completion r ->
      begin match Atomic.get r.computation with
      | (S (Canceled { tx = previous_tx; _ }) | S (Returned { tx = previous_tx; _ })) as before ->
          if tx == previous_tx then
            Atomic.compare_and_set r.computation before (S r.before) |> ignore
      | S (Continue _) -> ()   (* already rolled back by someone else *)
      end;
      rollback tx r.completions
```

After abort, the computations that still belong to this transaction are back to `Continue` — as if the transaction never happened. See below for what "still belong" means.

### Rollback ownership: the `tx == previous_tx` check

The rollback only reverts a computation if it **still points to this transaction** (physical identity `==`):

```ocaml
if tx == previous_tx then
  Atomic.compare_and_set r.computation before (S r.before) |> ignore
```

Why? Because between the abort and the rollback, another transaction may have already grabbed that computation. Example:

```
tx1 tentatively completes comp_a and comp_b.
tx2 aborts tx1 (to grab comp_b), then tentatively completes comp_b itself.

tx1's rollback runs:
  comp_b: Returned{tx=tx2} → tx1 == tx2? NO → skip (not ours anymore)
  comp_a: Returned{tx=tx1} → tx1 == tx1? YES → CAS back to Continue ✓
```

Each transaction only cleans up its own completions. The `tx` pointer acts as an ownership tag.

### Why this is safe under preemption

What if `tx == previous_tx` evaluates to `true`, then the thread gets preempted, and by the time it resumes the computation now belongs to a different transaction?

```
Thread T (rolling back tx1):
  1. Atomic.get r.computation → Returned{tx=tx1}  (snapshot = `before`)
  2. tx1 == tx1? → true
  3. *** PREEMPTED ***

Thread U:
  4. Also rolls back tx1: CAS comp: Returned{tx=tx1} → Continue  ✓
  5. tx2 grabs it: CAS comp: Continue → Returned{99, tx=tx2}  ✓

Thread T resumes:
  6. CAS comp: before(=Returned{tx=tx1}) → Continue
     current value is Returned{tx=tx2} ≠ before
     *** CAS FAILS *** → ignored (|> ignore)
```

The `tx == previous_tx` check is an **optimization** (skip a useless CAS when we know it's not ours), not the safety mechanism. The CAS itself is the final arbiter: it atomically verifies "is the value still what I read?" If anything changed between `Atomic.get` and `compare_and_set`, the CAS fails harmlessly. This is the standard lock-free pattern: read a snapshot, do checks, CAS with the snapshot as expected value.

---

## 6. The `tx` field: visibility control

This is the most important part. The `tx` field in `Returned`/`Canceled` answers one question: **"is this completion final?"**

```
tx = Stopped                         → YES. permanent, visible to everyone.
tx = Running { state = Started }     → NO. tentative, invisible to readers.
tx = Running { state = Aborted }     → NO. rollback in progress.
tx = Running { state = Stopped }     → YES (commit walked through but hasn't
                                       set tx <- Stopped on this one yet;
                                       but this is a transient moment).
```

### Every reader checks `tx`

**Every single function** that reads a computation's result checks `tx == Stopped`:

```ocaml
(* is_running: "is the computation still going?" *)
| S (Canceled { tx; _ }) | S (Returned { tx; _ }) -> tx != Stopped
(* ↑ if tx is not the Stopped constant, it's STILL CONSIDERED RUNNING *)

(* canceled: "give me the cancellation exception, if any" *)
| Canceled { tx; exn; bt } -> if tx == Stopped then Some (exn, bt) else None
(* ↑ if tx is not Stopped, pretend the cancellation doesn't exist *)

(* check: "raise if canceled" *)
| S (Canceled { tx; _ } as canceled) -> if tx == Stopped then raise canceled
(* ↑ only raise if the cancellation is committed *)

(* peek: "give me the result, if done" *)
| Returned { tx; value; _ } -> if tx == Stopped then Some (Ok value) else None
(* ↑ only return the value if committed *)

(* await: "block until done" *)
if tx == Stopped then (* return value or raise exception *)
else block t Peek     (* keep waiting — not done yet! *)
```

This means: **a computation can be in `Returned` or `Canceled` state at the atomic level, but the rest of the world doesn't see it until `tx = Stopped`.** It's like a database row that's been written inside a transaction but not committed — other readers can't see it.

### The race this prevents

Without the `tx` field:

```
Thread A (transaction):                Thread B (observer):
  CAS comp: Continue → Returned{42}
                                        peek comp → Some (Ok 42)  ← SEES IT!
  ... transaction gets aborted ...
  rollback: comp → Continue

  Thread B got 42, but comp is running again.
  Thread B has a PHANTOM VALUE that was never real.
```

With the `tx` field:

```
Thread A (transaction):                Thread B (observer):
  CAS comp: Continue → Returned{42, tx=Running{Started}}
                                        peek comp → tx != Stopped → None ← CORRECT!
  ... transaction gets aborted ...
  rollback: comp → Continue
                                        (Thread B never saw the phantom value)

  ... later, comp completes for real ...
  comp: Continue → Returned{99, tx=Stopped}
                                        peek comp → tx == Stopped → Some (Ok 99) ← CORRECT!
```

### Summary table: all `tx` field interactions

| Function | How it uses `tx` | Purpose |
|----------|-----------------|---------|
| `Tx.try_return` / `Tx.try_cancel` | Embeds `tx` (the running transaction) into new `Returned`/`Canceled` state | Links completion to its transaction |
| `Tx.commit` | Sets `r.tx <- Stopped` on each completion | Finalizes all completions |
| `is_running` | `tx != Stopped` → still running | Hides tentative completions |
| `is_canceled` | `tx == Stopped` → truly canceled | Hides tentative completions |
| `canceled` | `tx == Stopped` → return exception, else `None` | Hides tentative completions |
| `check` | `tx == Stopped` → raise, else skip | Hides tentative completions |
| `peek` / `peek_exn` | `tx == Stopped` → return result, else `None`/block | Hides tentative completions |
| `await` | `tx == Stopped` → return, else keep blocking | Hides tentative completions |
| `try_attach` | `Tx.try_abort tx` if tentative → rollback and retry | Unblocks itself |
| `unsafe_unsuspend` | `Tx.try_abort tx` if tentative → rollback and retry | Unblocks itself |
| `try_terminate` | `Tx.try_abort tx` if tentative → rollback and retry | Unblocks itself |
| Plain `try_return` / `try_cancel` | Uses `tx = Stopped` directly | No transaction overhead |

---

## 7. What happens when operations encounter tentative state

Three core operations (`try_terminate`, `try_attach`, `unsafe_unsuspend`) can find a computation in tentative `Returned`/`Canceled` state. They all handle it the same way:

```ocaml
| S (Returned { tx; _ }) | S (Canceled { tx; _ }) ->
    if Tx.try_abort tx then
      (* transaction aborted, computation rolled back to Continue → retry *)
      retry ...
    else
      (* tx = Stopped: computation is truly done, can't change it *)
      false or handle accordingly
```

And `Tx.try_abort` on the constant `Stopped`:

```ocaml
let try_abort = function
  | Stopped -> false        (* not a transaction, can't abort → completion is final *)
  | Running _ as tx -> abort tx   (* try to abort the transaction *)
```

So for a plain (non-transactional) completion with `tx = Stopped`, `try_abort` returns `false` immediately. Zero overhead.

### Concrete scenario: `try_attach` during a tentative cancellation

A transaction is tentatively canceling `comp`. Meanwhile, another fiber wants to attach a trigger.

```
comp: Continue { triggers = [t1, t2] }

Transaction tx1:
  Tx.try_cancel tx1 comp Exit bt
  → CAS comp: Continue → Canceled { tx = tx1(Started); exn = Exit }
  (tx1 not committed yet)

Another fiber:
  try_attach comp new_trigger
  → sees Canceled { tx = tx1 }
  → tx1.state = Started (not Stopped) → can abort!
  → Tx.try_abort tx1:
      CAS tx1.state: Started → Aborted
      rollback comp: Canceled → Continue { triggers = [t1, t2] }
  → retry try_attach:
      sees Continue → CAS to add new_trigger
      comp: Continue { triggers = [new_trigger, t1, t2] }
```

The attach succeeded by aborting an uncommitted transaction. If the transaction had been committed (`tx = Stopped`), `try_abort` would return `false` and `try_attach` would return `false` too — correctly reporting "computation is already done."

---

## 8. Full trace: two domains racing

Two domains, two computations `a` and `b`, both starting as `Continue`.

**Domain 1** wants: return `a=101` AND cancel `b`. Atomically.
**Domain 2** wants: return `b=42` AND cancel `a`. Atomically.

Only one can win.

```
Domain 1:                                    Domain 2:
─────────────────────────────────────────────────────────────────
tx1 = Tx.create()                            tx2 = Tx.create()
  tx1.state = Started                          tx2.state = Started

Tx.try_return tx1 a 101
  CAS a: Continue → Returned{101, tx=tx1}
  tx1.completions = [a was Continue]

                                              Tx.try_return tx2 b 42
                                                CAS b: Continue → Returned{42, tx=tx2}
                                                tx2.completions = [b was Continue]

Tx.try_cancel tx1 b Exit
  sees b is Returned{42, tx=tx2}
  tx2.state = Started → NOT committed
  → try_abort tx2:
      CAS tx2.state: Started → Aborted ✓
      rollback: CAS b back to Continue ✓
  → retry: CAS b: Continue → Canceled{Exit, tx=tx1} ✓
  tx1.completions = [b was Continue, a was Continue]

                                              Tx.try_cancel tx2 a Exit
                                                sees a is Returned{101, tx=tx1}
                                                tx1.state = Started → NOT committed
                                                → try_abort tx1:
                                                    CAS tx1.state: Started → Aborted ✓
                                                    rollback: CAS b back to Continue ✓
                                                             CAS a back to Continue ✓
                                                → retry: CAS a: Continue → Canceled{Exit, tx=tx2}
                                                but wait — tx2.state = Aborted!
                                                try_complete checks tx2.state != Started
                                                → returns false

                                              Domain 2 lost. tx2 was aborted.
                                              Can't complete anything. Must give up or retry entirely.

Tx.try_commit tx1
  CAS tx1.state: Started → Stopped
  but tx1.state = Aborted (Domain 2 aborted it)
  → CAS fails → returns false

Domain 1 also lost.
```

In this particular interleaving, BOTH lost. Both retry. Eventually one will win — this is the **obstruction-freedom** property: progress is guaranteed only in the absence of interference.

In a successful scenario:

```
Domain 1:
  tx1 = Tx.create()
  Tx.try_return tx1 a 101         a: Continue → Returned{101, tx=tx1}
  Tx.try_cancel tx1 b Exit        b: Continue → Canceled{Exit, tx=tx1}
  Tx.try_commit tx1
    CAS tx1.state: Started → Stopped ✓
    commit:
      a: r.tx <- Stopped, signal a's old triggers
      b: r.tx <- Stopped, signal b's old triggers

Final state:
  a: Returned { value=101; tx=Stopped }   ← permanent
  b: Canceled { exn=Exit;  tx=Stopped }   ← permanent
```

---

## 9. Overlapping transactions

What happens when two transactions share some computations but not all?

```
tx1 wants to complete: comp_a, comp_b, comp_c
tx2 wants to complete: comp_b, comp_d
                        ↑ overlap
```

### Rule: aborting a transaction aborts ALL of it

When tx2 encounters `comp_b` owned by tx1, it doesn't just take `comp_b` — it **aborts the entire tx1**, rolling back `comp_a` and `comp_c` too. Transactions are all-or-nothing.

```
tx1: Tx.try_return tx1 comp_a 1     comp_a: Continue → Returned{1, tx=tx1}
tx1: Tx.try_return tx1 comp_b 2     comp_b: Continue → Returned{2, tx=tx1}

tx2: Tx.try_return tx2 comp_b 99
  sees comp_b is Returned{tx=tx1}, tx1 not committed
  → try_abort tx1:
      CAS tx1.state: Started → Aborted
      rollback ALL of tx1:
        comp_b: Returned{tx=tx1} → tx1==tx1? YES → CAS back to Continue
        comp_a: Returned{tx=tx1} → tx1==tx1? YES → CAS back to Continue
  → retry: CAS comp_b: Continue → Returned{99, tx=tx2}  ✓

tx2 proceeds with comp_d, commits, wins.
tx1's commit fails (state is Aborted). tx1 must retry everything from scratch.
```

### What if tx1 was already committed?

```
tx2: Tx.try_return tx2 comp_b 99
  sees comp_b is Returned{tx=tx1}
  → try_abort tx1:
      tx1.state = Stopped → return false (can't abort a committed transaction)
  → else branch: abort tx2 itself, return false

tx2 cannot get comp_b. It's permanently owned.
```

### Rollback safety with overlapping ownership

If tx1 and tx2 overlap and tx1 gets aborted, tx1's rollback only reverts computations that still point to tx1:

```
tx1 had: comp_a(tx=tx1), comp_b(tx=tx1)
tx2 aborted tx1 and grabbed comp_b → comp_b now has tx=tx2

tx1 rollback:
  comp_b: tx=tx2 → tx1==tx2? NO → skip
  comp_a: tx=tx1 → tx1==tx1? YES → revert ✓
```

No transaction ever reverts another transaction's work.

---

## 10. Obstruction-freedom

The progress guarantee scale:

```
Wait-free          every thread finishes in bounded steps              (strongest)
Lock-free          at least ONE thread makes progress at any time
Obstruction-free   a thread makes progress IF no one interferes        (weakest non-blocking)
```

The `Tx` module is **obstruction-free**. Under contention, two transactions can keep aborting each other (livelock). Neither is guaranteed to win.

Picos accepts this tradeoff because:

1. **Single-computation operations are lock-free** — `try_return`/`try_cancel` without `Tx` use `tx = Stopped` directly. No transaction, no abort risk.
2. **Transactions are rare** — the exotic multi-completion case almost never happens in practice.
3. **Making Tx lock-free would require making single-computation operations heavier** — and that's the common case you want to keep fast.

From the doc comment:

> The implementation of this mechanism is designed to avoid making the single computation completing operations, i.e. `try_return` and `try_cancel`, slower and to avoid making computations heavier.

The `tx` field is already "free" in terms of memory (it's just a pointer, `Stopped` is a constant), and checking `tx == Stopped` is a single pointer comparison. The cost is borne only by the rare transactional path.

---

## 11. Who uses Tx in practice?

### Explicit `Tx.create()` usage: NOBODY in production

Searching the entire picos codebase, `Tx.create` / `Tx.try_return` / `Tx.try_commit` are used **only** in `test/test_picos.ml`. Not in:

- Bundle, Flock, or any structured concurrency code
- Any sync primitive (mutex, condition, semaphore)
- Any scheduler
- Any I/O module

Bundle/Flock use `Computation.attach_canceler` for cascading cancellation — which is a trigger-based mechanism, not transactional.

### Implicit `tx` field usage: EVERYWHERE

The `tx` field is checked by every reader of computation state:

- `is_running`, `is_canceled`, `canceled`, `check`, `peek`, `peek_exn`, `await`

And the `Tx.try_abort` path is hit by any write operation that encounters a tentative state:

- `try_terminate`, `try_attach`, `unsafe_unsuspend`

So while `Tx` the API is rarely used, `tx` the field is **load-bearing infrastructure**. It's what makes the computation state machine correct in the presence of potential concurrent transactions.

### What this means for your code

- You will use `Computation.try_return` and `Computation.try_cancel` (single-computation, lock-free, `tx=Stopped`).
- You will NOT use `Computation.Tx` unless you find a specific race condition that requires atomic multi-completion.
- But you should understand the `tx` field because it explains why reader functions behave the way they do.

---

## Diagram: the full state machine

```
                    Plain try_return/try_cancel
                    (tx = Stopped, immediately final)
                    ┌──────────────────────────────────┐
                    │                                  ▼
              ┌─────────┐                    ┌──────────────────┐
              │Continue  │                    │ Returned/Canceled│
              │(running) │                    │ tx = Stopped     │
              └─────────┘                    │ (PERMANENT)      │
                    │                         └──────────────────┘
                    │ Tx.try_return/try_cancel             ▲
                    │ (tx = Running{Started})               │
                    ▼                                       │
              ┌──────────────────┐     try_commit     ┌────┘
              │ Returned/Canceled│ ───────────────────►│
              │ tx = Running     │     (set tx<-Stopped,
              │ {Started}        │      signal triggers)
              │ (TENTATIVE)      │
              └──────────────────┘
                    │
                    │ try_abort
                    │ (rollback to before state)
                    ▼
              ┌─────────┐
              │Continue  │  ← as if nothing happened
              │(running) │
              └─────────┘
```

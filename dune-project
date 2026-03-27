;; minimum dune version required to build this project.
;; acts like "engines" in package.json — dune < 3.14 will refuse to build.
(lang dune 3.14)

;; project name used internally by dune. this is NOT an opam package name —
;; it's just the monorepo identifier. dune uses it for things like default
;; library search paths.
(name picos)

;; tells dune to auto-generate .opam files from the (package ...) stanzas
;; below. that's why you see picos.opam, picos_aux.opam, etc. in the root —
;; they're all generated. never edit .opam files by hand, edit here instead.
(generate_opam_files true)

;; by default, if library A depends on B and B depends on C, then A can use
;; C without declaring it. setting this to false forces every library to
;; explicitly list all its direct dependencies. stricter, prevents phantom deps.
(implicit_transitive_deps false)

(authors "Vesa Karvonen <vesa.a.j.k@gmail.com>")

(maintainers "Vesa Karvonen <vesa.a.j.k@gmail.com>")

;; (github user/repo) is sugar — dune expands it to the full git URL.
;; this ends up in the generated .opam files as the "dev-repo" field.
(source
 (github ocaml-multicore/picos))

(homepage https://github.com/ocaml-multicore/picos)

;; single version for all packages in the monorepo. referenced below
;; via (= :version) constraints to keep sibling packages in lockstep.
(version 0.6)

;; ISC = permissive license, similar to MIT but shorter.
(license ISC)

;; enables the mdx dune plugin. mdx = "markdown executable" — it compiles
;; and runs OCaml code blocks inside .md and .mli files as tests.
;; the 0.4 is the dune plugin protocol version, not the mdx tool version.
;; this is why `dune runtest` also tests code snippets in README.md.
(using mdx 0.4)

;; ============================================================================
;; PACKAGES
;; ============================================================================
;;
;; each (package ...) block defines a separately installable opam package.
;; dune generates a corresponding .opam file for each one.
;;
;; the ;; inside (depends ...) are just visual separators with no semantic
;; meaning — convention is to group internal deps, then external deps.

;; --- lowest layer: lock-free data structures (htbl, mpmcq, mpscq, rc) -------
;; does NOT depend on picos itself — pure utilities usable outside the framework.
(package
 (name picos_aux)
 (synopsis "Auxiliary libraries for Picos")
 (depends
  ;; 4.14 = last OCaml 4.x release. this package works without effect handlers.
  (ocaml
   (>= 4.14.0))
  ;;
  ;; exponential backoff for CAS retry loops — the standard pattern in lock-free code
  (backoff
   (>= 0.1.1))
  ;; atomic utilities: Transparent_atomic (unboxed atomics), cache-line padding
  ;; (prevents false sharing), fenceless_get (relaxed memory reads)
  (multicore-magic
   (>= 2.3.2))
  ;;
  ))

;; --- core: the scheduler interface (Trigger, Computation, Fiber, 5 effects) -
;; this is the "trait" / contract that schedulers implement and libraries use.
;; deliberately minimal dependencies — it's the shared foundation everything
;; agrees on.
(package
 (name picos)
 (synopsis "Pico scheduler interface")
 (description
  "A systems programming interface between effects based schedulers and concurrent abstractions.")
 (depends
  (backoff
   (>= 0.1.1))
  ;; fiber-local storage, like thread-local but for cooperative fibers.
  ;; used to store the current fiber's context without passing it everywhere.
  (thread-local-storage
   (>= 0.2))
  ;;
  ))

;; --- standard library: sync primitives, structured concurrency, events ------
;; mutex, condition, semaphore, rwlock, ivar, bundle, flock, promise, etc.
;; depends on both picos (for the scheduler interface) and picos_aux
;; (for lock-free queues/htbl used in the implementations).
(package
 (name picos_std)
 (synopsis "Sample libraries for Picos")
 (depends
  ;; (= :version) means "must be the exact same version as this package".
  ;; this is how monorepo sibling packages stay in lockstep — you can't
  ;; install picos_std 0.6 with picos 0.5.
  (picos
   (= :version))
  (picos_aux
   (= :version))
  ;;
  (backoff
   (>= 0.1.1))
  (multicore-magic
   (>= 2.3.2))
  ;;
  ))

;; --- async I/O: select-based multiplexing, file descriptors ----------------
;; integrates fiber suspension with OS-level I/O readiness (Unix.select).
;; fibers block on I/O without blocking the OS thread.
(package
 (name picos_io)
 (synopsis "Asynchronous IO system for Picos")
 (depends
  (picos_aux
   (= :version))
  (picos_std
   (= :version))
  ;;
  (backoff
   (>= 0.1.1))
  ;; monotonic clock — used for timeouts (Cancel_after)
  (mtime
   (>= 2.0.0))
  (multicore-magic
   (>= 2.3.2))
  ;; priority search queue — used to efficiently track timer deadlines
  (psq
   (>= 0.2.1))
  ;;
  ))

;; --- cohttp integration: HTTP client/server on top of picos I/O ------------
(package
 (name picos_io_cohttp)
 (synopsis "Cohttp running on Picos IO")
 (depends
  (picos_io
   (= :version))
  ;;
  ;; cohttp = OCaml HTTP library. this package provides the picos-backed
  ;; I/O layer so cohttp can run on fibers instead of lwt/async.
  (cohttp
   (>= 6.0.0))
  (fmt
   (>= 0.9.0))
  (uri
   (>= 4.4.0))
  ;;
  ))

;; --- schedulers: reference implementations of the picos interface ----------
;; fifo (single-thread), multififo (multi-domain), random (work-stealing),
;; thread (OS thread per fiber).
(package
 (name picos_mux)
 (synopsis "Sample schedulers for Picos")
 (depends
  (picos_aux
   (= :version))
  (picos_std
   (= :version))
  ;;
  (backoff
   (>= 0.1.1))
  (multicore-magic
   (>= 2.3.2))
  ;;
  )
 ;; depopts = optional dependencies. if picos_io is installed, the schedulers
 ;; gain I/O multiplexing support (select integration). if not, they still
 ;; compile but without I/O. this is wired via (select ...) in the dune files.
 (depopts
  (picos_io
   (= :version))
  ;;
  ))

;; --- lwt bridge: run picos fibers inside lwt, or lwt promises on picos -----
;; (allow_empty) = tells opam this package may have no installable libraries
;; on some configurations. needed because picos_lwt only compiles on OCaml 5+
;; (requires effect handlers), so on OCaml 4 the package is empty.
(package
 (name picos_lwt)
 (allow_empty)
 (synopsis "Lwt interface for Picos")
 (depends
  (picos_aux
   (= :version))
  (picos_std
   (= :version))
  ;;
  (lwt
   (>= 6.0.0))
  ;;
  ))

;; --- meta package: integration tests across all picos packages -------------
;; this is not a library you'd ever install as a user. it exists so that
;; `opam install picos_meta --with-test` pulls in ALL packages + ALL test
;; dependencies, enabling the full test suite to run.
;; (allow_empty) because there are no libraries here, only test executables.
(package
 (name picos_meta)
 (allow_empty)
 (synopsis "Integration tests for Picos packages")
 (depends
  ;; --- all sibling packages, pinned to same version ---
  (picos
   (= :version))
  (picos_aux
   (= :version))
  (picos_std
   (= :version))
  (picos_io
   (= :version))
  (picos_io_cohttp
   (= :version))
  (picos_mux
   (= :version))
  (picos_lwt
   (= :version))
  ;;
  ;; --- test framework dependencies (always installed) ---
  ;; dscheck = deterministic model checker for lock-free algorithms.
  ;; explores all possible thread interleavings to find races.
  (dscheck
   (>= 0.4.0))
  (lwt
   (>= 6.0.0))
  ;; qcheck = property-based testing (like QuickCheck in Haskell)
  (qcheck-core
   (>= 0.21.2))
  ;; qcheck-stm = state machine testing for concurrent data structures
  (qcheck-stm
   (>= 0.7))
  (qcheck-multicoretests-util
   (>= 0.7))
  ;;
  ;; --- :with-test dependencies ---
  ;; only installed when you pass --with-test to opam install.
  ;; (and constraint1 constraint2 ...) combines multiple constraints.
  ;;
  ;; alcotest = test runner (like Jest/Mocha for OCaml)
  (alcotest
   (and
    (>= 1.7.0)
    :with-test))
  (backoff
   (and
    (>= 0.1.0)
    :with-test))
  (cohttp
   (and
    (>= 6.0.0)
    :with-test))
  ;; (<> :os "win32") = "not equal to win32" — excludes Windows.
  ;; cohttp-lwt-unix and conduit-lwt-unix use Unix APIs not available on Windows.
  (cohttp-lwt-unix
   (and
    (>= 6.0.0)
    (<> :os "win32")
    :with-test))
  (conduit-lwt-unix
   (and
    (>= 6.2.2)
    (<> :os "win32")
    :with-test))
  ;; conf-npm = virtual package that checks npm/node is available on the system.
  ;; needed for js_of_ocaml tests. excluded on 32-bit, riscv64, and Windows.
  (conf-npm
   (and
    (<> :arch "x86_32")
    (<> :arch "riscv64")
    (<> :os "win32")
    :with-test))
  ;; domain_shims = compatibility shim so OCaml 4 code can use Domain-like APIs.
  ;; lets tests run on both OCaml 4 and 5.
  (domain_shims
   (and
    (>= 0.1.0)
    :with-test))
  ;; js_of_ocaml = OCaml to JavaScript compiler. used to test that picos
  ;; also works when compiled to JS (single-threaded, no real domains).
  (js_of_ocaml
   (and
    (>= 5.4.0)
    :with-test))
  ;; mdx = tests OCaml code blocks inside markdown/mli documentation
  (mdx
   (and
    (>= 2.4.0)
    :with-test))
  ;; multicore-bench = benchmarking framework for multicore OCaml
  (multicore-bench
   (and
    (>= 0.1.7)
    :with-test))
  (multicore-magic
   (and
    (>= 2.3.2)
    :with-test))
  ;; dscheck-compatible version of multicore-magic for deterministic testing
  (multicore-magic-dscheck
   (and
    (>= 2.3.2)
    :with-test))
  ;; used to conditionally run tests based on OCaml compiler version
  (ocaml-version
   (and
    (>= 3.6.4)
    :with-test))
  (cohttp-lwt
   (and
    (>= 6.0.0)
    :with-test))
  (uri
   (and
    (>= 4.4.0)
    :with-test))
  ;;
  ;; --- :with-doc dependencies ---
  ;; only installed when you pass --with-doc to opam install.
  ;; odoc = documentation generator (like javadoc/typedoc for OCaml)
  (odoc
   (and
    (>= 2.4.1)
    :with-doc))
  ;; sherlodoc = search engine for odoc documentation
  (sherlodoc
   (and
    (>= 0.2)
    :with-doc))
  ;;
  ))

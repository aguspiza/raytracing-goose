# raytracing-goose

Ray tracing in a weekend in [Goose](https://aardappel.github.io/goose/), ported from
[raytracing-bend2](https://github.com/aguspiza/raytracing-bend2), which was ported from
[raytracing-nim](https://github.com/aguspiza/raytracing-nim).

![64 samples per pixel](ray.png)

## Run

Goose compiles to one C file. `goose build` drives a C compiler for you, but it
builds with `-O2`, and gcc only vectorizes the hit test at `-O3`. So emit the C
and build it yourself:

```
goose -O2 --standalone -o main.c main.goose
gcc -O3 -march=native main.c -o ray -lm -pthread
./ray                  # 64 samples per pixel -> ray.tga
./ray 16               # 16 samples per pixel
./ray 16 ppm           # also write ray.ppm (P3)
./ray 16 --threads 1   # cap the worker threads (default: every CPU)
```

`goose build main.goose && ./main` also works, and is slower (see below).
On Windows the same build works with MinGW gcc, adding
`-Wa,-muse-unaligned-vector-move`: without it, gcc's 32-byte AVX stack spills
crash under Win64.

## Same image as Bend

The math, the random numbers and the scene are those of the Bend port,
operation by operation and all in f32:

- the xorshift32 state seeded per pixel from its index, and the hashed cell
  numbers for the scene,
- `randInSphere` and `randInDisk` accepting points *outside* the unit ball
  and giving up after 64 redraws, as in `v3.nim`,
- the sphere order of Bend's scene list (ground, cells from last to first,
  then the three big spheres), so a tie between two spheres goes the same way.

The result: at 4 and at 64 samples per pixel, `ray.tga` is byte-identical to
the one raytracing-bend2 writes. `bench.sh` checks it on every run.

## Optimizations

None of these change a single output byte.

- **Spheres as flat arrays.** The hit test reads centers and `r * r` from four
  `f32` arrays (16 bytes per sphere), not a list of sphere records. Materials
  sit in their own array and are read once, for the sphere that was hit.
- **Two passes over the spheres.** The first pass has no branches: it writes
  `qb` and `disc` for all 486 spheres into two scratch arrays, so the C
  compiler turns it into AVX code, 8 spheres at a time. The second pass takes
  the `sqrt` and the divisions only for the few spheres with `disc > 0`. Bend's
  `Sphere.hit` computes both roots for every sphere.
- **No bounds checks in the loop.** One `assert` on the array lengths lets the
  compiler drop every index check in both passes (`goose check --bce-lines`
  shows 0 kept).
- **Threads that share nothing.** Goose has no shared memory: each worker is a
  separate program with its own copy of the globals. Each one builds its own
  copy of the scene (it is a pure function of the cell index), takes rows from
  a queue, and sends each finished row back as one flat value.

What each step is worth, 1 thread, 4 samples per pixel:

| Hit test                                      | C compiler                | Wall time |
| --------------------------------------------- | ------------------------- | --------- |
| One pass, `sqrt` for every sphere (like Bend) | clang `-O2`               | 9.6 s     |
| One pass, `sqrt` only when `disc > 0`         | clang `-O2`               | 7.5 s     |
| One pass, `sqrt` only when `disc > 0`         | clang `-O3 -march=native` | 6.6 s     |
| One pass, `sqrt` only when `disc > 0`         | gcc `-O2`                 | 5.8 s     |
| Two passes, first one vectorized              | gcc `-O2`                 | 7.5 s     |
| Two passes, first one vectorized              | clang `-O2`               | 3.5 s     |
| Two passes, first one vectorized              | clang `-O3 -march=native` | 2.8 s     |
| Two passes, first one vectorized              | gcc `-O3 -march=native`   | **2.4 s** |

The two-pass version is slower than the one-pass one until the compiler
vectorizes it, which gcc does only at `-O3` and clang already does at `-O2`
(`gcc -fopt-info-vec` reports the first pass vectorized with 32-byte vectors).
Skipping spheres behind the ray origin before the `sqrt` made no difference,
so it is gone.

## Timing

1200x600, WSL2 on a 16-thread CPU (Ryzen 7 5700U), median of 3 runs.
Goose v2026.3 with gcc 13.3. Nim is raytracing-nim built with Nim 2.2.10:
the `fix-threads-and-cross` branch with `-d:release`, and the
[`optimized`](https://github.com/aguspiza/raytracing-nim/tree/optimized)
branch, which lays out the data as this port does and writes the same image.
Bend is raytracing-bend2 built with Bend 2.0.39 (see the note below).

| 4 samples per pixel             | Wall time | Peak RAM |
| ------------------------------- | --------- | -------- |
| Nim, `--threads:off`            | 18.9 s    | 11 MB    |
| Nim, `--threads:on`             | 3.2 s     | 14 MB    |
| Nim `optimized`, 1 thread       | 2.2 s     | 11 MB    |
| Nim `optimized`, 16 threads     | 0.38 s    | 11 MB    |
| Bend, 1 thread                  | 30.0 s    | 48 MB    |
| Bend, 16 threads                | 4.9 s     | 48 MB    |
| Goose, 1 thread                 | 2.2 s     | 6 MB     |
| Goose, 16 threads               | 0.34 s    | 6 MB     |

| 64 samples per pixel, 16 threads | Wall time | Peak RAM |
| -------------------------------- | --------- | -------- |
| Nim                              | 52.5 s    | 14 MB    |
| Nim `optimized`                  | 5.6 s     | 11 MB    |
| Bend                             | 81.2 s    | 48 MB    |
| Goose                            | 5.9 s     | 6 MB     |

`./bench.sh [samples] [runs]` builds Goose, Nim and Bend and prints these
tables. It expects raytracing-nim and raytracing-bend2 checked out next to
this repo.

## Where the speed comes from: data-oriented design

The gap is in the design, not in the language. Laid out the same way, Nim
renders the same image in the same time as Goose. What changes the time is
data-oriented design: laying out the data for what the hot loop reads, not by
entity.

The hit test takes over 90% of the time. For each ray it walks 486 spheres,
and it only needs their centers and `r * r`; only the nearest sphere needs its
material, radius and normal. The original Nim port is laid out by entity: it
passes each `Sphere`, material included, to a test that returns a full
`HitData` for every candidate. This port reads four flat `f32` arrays and
keeps only the index and distance of the nearest sphere.

Taking the original Nim port to the `optimized` branch one step at a time,
4 samples per pixel, 1 thread, best of 3:

| Step                                                          | Wall time | Gain  |
| ------------------------------------------------------------- | --------- | ----- |
| Original, `-d:release`                                        | 17.3 s    |       |
| `-d:danger --panics:on -march=native`                         | 16.2 s    | 1.07x |
| Hit test keeps the index and `t`, not a `HitData` per sphere  | 5.9 s     | 2.7x  |
| Spheres as four flat `float32` arrays, two passes (AVX)       | 2.9 s     | 2.0x  |
| The rest: Bend's random numbers and scene, no `Option`        | 2.45 s    | 1.2x  |

The first three steps render the same scene. Compiler flags are worth 7%. The
two data-oriented steps are worth 5.5x:

- gcc can recover most of the first one by itself, but does not by default. It
  judges the call in the loop cold and does not inline it. With `{.inline.}`
  on the test, or with gcc's profile-guided optimization, the original code
  takes 6.4 s.
- No compiler does the second one. A C compiler never changes the layout of a
  struct, so turning an array of spheres into flat arrays it can vectorize is
  up to the programmer.

Goose does not lay the data out this way by itself: an array of sphere
structs works just as well in it, and `goose build` uses `-O2`, where gcc does
not vectorize the loop. Its design notes do discuss the layout:
`docs/design/soa.md` proposes column arrays, `T[||..]`, a struct-of-arrays
type the language would lay out itself, and says that for now it is written by
hand, one array per field, as here. That note also warns that such arrays all
start at the same page offset, which can cost 2x through 4K aliasing. It does
not seem to cost here: the loop only reads those arrays and writes two scratch
ones, and Nim, with the arrays placed elsewhere in memory, takes the same time.
What Goose's tools did point to is the bounds checks: `goose check --bce-lines`
showed which ones were left in the loop.

### Bend 2.0.39 and raytracing-bend2

Bend changed two things since raytracing-bend2 was first written: `IO.args()`
now starts with the program name, as C's `argv[0]`, and runtime options go
between `+RTS` and `-RTS`. raytracing-bend2 skips the program name since commit
015377e, so check out that commit or later; the thread cap is
`./ray 4 +RTS --threads 1 -RTS`.

## Compile time

A full build from source, median of three runs.

| Build                                    | Wall time | Compiler peak RAM |
| ---------------------------------------- | --------- | ----------------- |
| Goose, emit C and gcc `-O3`              | 0.9 s     | 60 MB             |
| Nim 2.2.10, `-f -d:release --threads:on` | 2.3 s     | 87 MB             |
| Nim 2.2.10 `optimized`, `-f`             | 2.2 s     | 89 MB             |
| Bend, full build (`-o ray`)              | 4.0 s     | 138 MB            |

Goose itself takes a few hundredths of a second to check the program and emit
the C. gcc takes the rest.

## Binary size

| Executable, stripped   | Size    |
| ---------------------- | ------- |
| Goose                  | 47 KB   |
| Nim `optimized`        | 93 KB   |
| Bend `ray`             | 122 KB  |
| Nim, `--threads:on`    | 134 KB  |

## Memory

Goose has no heap allocator and no garbage collector: every value lives on a
data stack and goes away when its scope ends. The 6 MB peak is the 2.2 MB image
in RGB, the 2.2 MB targa built from it, and the runtime. Each worker holds its
own copy of the scene (about 20 KB) and one row at a time.

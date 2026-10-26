#!/usr/bin/env bash
# Times the Goose, Nim and Bend renders side by side (Linux or WSL).
# Expects raytracing-nim (branch fix-threads-and-cross) and raytracing-bend2
# checked out next to this repo, and goose, nim and bend on PATH.
#
#   ./bench.sh [samples] [runs]
set -euo pipefail
ns=${1:-4}
runs=${2:-3}
here=$(cd "$(dirname "$0")" && pwd)
nim_src=${NIM_SRC:-$here/../raytracing-nim}
bend_src=${BEND_SRC:-$here/../raytracing-bend2}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/goose" "$work/nim" "$work/bend"

cp "$here/main.goose" "$work/goose/"
cp "$nim_src"/*.nim "$work/nim/"
cp "$bend_src"/*.bend "$work/bend/"

(cd "$work/goose" && goose -O2 --standalone -o main.c main.goose >/dev/null \
  && ${CC:-gcc} -O3 -march=native main.c -o main -lm -pthread)
(cd "$work/nim" && nim c --hints:off --warnings:off -d:release --threads:off -d:nsamples="$ns" -o:ray_st main.nim \
  && nim c --hints:off --warnings:off -d:release --threads:on -d:nsamples="$ns" -o:ray_mt main.nim)
(cd "$work/bend" && bend main.bend -o ray >/dev/null)

# median wall time and peak RSS of $runs runs
measure() {
  local name=$1 dir=$2; shift 2
  local times=() mem=0
  for _ in $(seq "$runs"); do
    local out
    out=$(cd "$dir" && { /usr/bin/time -f "%e %M" "$@" >/dev/null; } 2>&1 | tail -1)
    times+=("${out% *}")
    local m=${out#* }
    (( m > mem )) && mem=$m
  done
  local med
  med=$(printf '%s\n' "${times[@]}" | sort -n | sed -n "$(( (runs + 1) / 2 ))p")
  printf '| %-28s | %7s s | %4d MB |\n' "$name" "$med" $(( mem / 1024 ))
}

echo "1200x600, $ns samples per pixel, median of $runs runs"
echo "| Build                        | Wall time | Peak RAM |"
echo "| ---------------------------- | --------- | -------- |"
measure "Nim, --threads:off" "$work/nim" ./ray_st
measure "Nim, --threads:on" "$work/nim" ./ray_mt
measure "Bend, 1 thread" "$work/bend" ./ray "$ns" +RTS --threads 1 -RTS
measure "Bend, all threads" "$work/bend" ./ray "$ns"
measure "Goose, 1 thread" "$work/goose" ./main "$ns" --threads 1
measure "Goose, all threads" "$work/goose" ./main "$ns"

if cmp -s "$work/goose/ray.tga" "$work/bend/ray.tga"; then
  echo "Goose and Bend wrote byte-identical images."
else
  echo "Goose and Bend images differ."
fi

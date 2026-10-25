// Ray tracing in a weekend, ported from raytracing-bend2 to Goose.
// Renders the random sphere scene to ray.tga (and ray.ppm with "ppm").
//
//   goose -O2 --standalone -o main.c main.goose
//   gcc -O3 -march=native main.c -o ray -lm -pthread
//   ./ray [samples] [ppm] [--threads n]
//
// The math, the random numbers and the scene are those of raytracing-bend2,
// operation by operation and all in f32, so both write the same image.
// What is Goose's own is the layout: the hit test reads the spheres as
// four flat f32 arrays in a branch-free pass the C compiler vectorizes, and
// the image is split into one job per row for a pool of worker threads that
// share no memory.

import std;
import vec;
import math;
import os;

let W = 1200;
let H = 600;
let FAR: f32 = 1000000000.0;
let T_MIN: f32 = 0.01;

let LAMBERTIAN = 0;
let METALIC = 1;
let DIELECTRIC = 2;

struct Ray { a: float3, b: float3 }
struct Mat { kind: i32, albedo: float3, param: f32 }   // param: fuzzy or refraction
struct Cam { origin: float3, corner: float3, hor: float3, vert: float3, u: float3, v: float3, lens: f32 }

// Vec
// ---

fn scale(v: float3, k: f32) -> float3 { float3 { v.x * k, v.y * k, v.z * k } }
fn neg(v: float3) -> float3 { float3 { 0.0 - v.x, 0.0 - v.y, 0.0 - v.z } }
fn div(v: float3, k: f32) -> float3 { float3 { v.x / k, v.y / k, v.z / k } }
fn len(v: float3) -> f32 { sqrt(dot(v, v)) }
fn unit_of(v: float3) -> float3 { scale(v, 1.0 / (len(v) + 0.0001)) }
fn reflect(v: float3, n: float3) -> float3 { v - scale(n, dot(v, n) * 2.0) }

// Random
// ------
// As in the Bend port: a xorshift32 state, and each pixel seeds its own
// from its index. A state is fresh until read: u reads it, next steps past it.

fn rng_hash(x: u32) -> u32 {
    let a = (x ^ (x >> 16)) * 2146121005;
    let b = (a ^ (a >> 15)) * 2221713035;
    return b ^ (b >> 16);
}

fn next(s0: u32) -> u32 {
    var s = s0;
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    return s;
}

fn next2(s: u32) -> u32 { next(next(s)) }
fn next3(s: u32) -> u32 { next(next(next(s))) }

// rand(1f): the float in [0, 1) of a state
fn u(s: u32) -> f32 { (s >> 8) / 16777216.0 }
fn at(h: u32, j: u32) -> f32 { u(rng_hash(h + j)) }

// the point in [-1, 1]^3 drawn from s, next(s) and next2(s)
fn vec3_of(s: u32) -> float3 {
    let s1 = next(s);
    return float3 { 2.0 * u(s) - 1.0, 2.0 * u(s1) - 1.0, 2.0 * u(next(s1)) - 1.0 };
}

fn vec2_of(s: u32) -> float3 { float3 { 2.0 * u(s) - 1.0, 2.0 * u(next(s)) - 1.0, 0.0 } }

// randInSphere and randInDisk: the state whose point is accepted. As in
// v3.nim, a point is accepted when it lies outside the unit ball, and the
// search gives up after 64 redraws.
fn in_sphere(s0: u32) -> u32 {
    var s = s0;
    for k in 64 {
        let p = vec3_of(s);
        if dot(p, p) >= 1.0 { return s; }
        s = next3(s);
    }
    return s;
}

fn in_disk(s0: u32) -> u32 {
    var s = s0;
    for k in 64 {
        let p = vec2_of(s);
        if dot(p, p) >= 1.0 { return s; }
        s = next2(s);
    }
    return s;
}

// Camera
// ------

fn new_cam(from: float3, to: float3) -> Cam {
    let vup = float3 { 0.0, 1.0, 0.0 };
    let dist = from - to;
    let w = unit_of(dist);
    let u = unit_of(cross(vup, w));
    let v = cross(w, u);
    let fd = len(dist);
    let pi: f32 = 3.14159265;
    let hh = tan(20.0 * pi / 180.0 / 2.0);
    let hw = 2.0 * hh;
    // v points up; rows go top to bottom, so the corner is the top left
    // and the vertical span points down
    let corner = from - scale(u, hw * fd) + scale(v, hh * fd) - scale(w, fd);
    let lens: f32 = 0.005;
    return Cam { from, corner, scale(u, hw * fd * 2.0), scale(v, 0.0 - hh * fd * 2.0), u, v, lens / 2.0 };
}

// d: the randInDisk() point for the lens
fn cam_ray(c: Cam, pu: f32, pv: f32, d: float3) -> Ray {
    let offset = scale(c.u, d.x * c.lens) + scale(c.v, d.y * c.lens);
    let uh = scale(c.hor, pu);
    let vv = scale(c.vert, pv) - c.origin - offset;
    return Ray { c.origin - offset, c.corner + (uh + vv) };
}

// Scene
// -----
// Every worker is a program of its own with its own copy of these globals,
// and builds the scene itself: it is a pure function of the cell index.

var ox: f32[>..] = [];    // the hot loop's data: centers and r * r
var oy: f32[>..] = [];
var oz: f32[>..] = [];
var rr: f32[>..] = [];
var rad: f32[>..] = [];
var mats: Mat[>..] = [];

fn add(o: float3, r: f32, m: Mat) {
    ox.push(o.x);
    oy.push(o.y);
    oz.push(o.z);
    rr.push(r * r);
    rad.push(r);
    mats.push(m);
}

// a cell's material from its random numbers h + 3, h + 4, ..
fn pick_mat(mp: f32, h: u32) -> Mat {
    if mp < 0.8 {
        return Mat { LAMBERTIAN, float3 { at(h, 3) * at(h, 4), at(h, 5) * at(h, 6), at(h, 7) * at(h, 8) }, 0.0 };
    }
    if mp < 0.95 {
        return Mat { METALIC, float3 { 0.5 * (at(h, 3) + 1.0), 0.5 * (at(h, 4) + 1.0), 0.5 * (at(h, 5) + 1.0) }, 0.01 };
    }
    return Mat { DIELECTRIC, float3_0, 1.5 };
}

// The Bend scene is a list built by prepending: the ground, the kept cells
// from the last to the first, then the three big spheres. Same order here,
// so a tie between two spheres goes the same way.
fn build_scene() {
    add(float3 { 0.0, -1000.0, 0.0 }, 1000.0, Mat { LAMBERTIAN, float3 { 0.5, 0.5, 0.5 }, 0.0 });
    let tilt: f32 = 0.2;
    var k: u32 = 484;
    while k > 0 {
        k--;
        // the 22 x 22 grid, cell k at (k / 22 - 11, k % 22 - 11)
        let h = k * 16 + 1000;
        let mp = at(h, 0);
        let cx = (k / 22) - 11.0 + 0.9 + at(h, 1);
        let cz = (k % 22) - 11.0 + 0.9 + at(h, 2);
        let c = float3 { cx, 0.2, cz };
        if len(c - float3 { 4.0, 0.2, 0.0 }) > 0.9 {
            let cy = 0.2 - tilt / 45.0 * len(c);
            add(float3 { cx, cy, cz }, 0.2, pick_mat(mp, h));
        }
    }
    add(float3 { 0.0, 1.0, 0.0 }, 1.0, Mat { DIELECTRIC, float3_0, 1.5 });
    add(float3 { -4.0, 1.0, 0.0 }, 1.0, Mat { LAMBERTIAN, float3 { 0.4, 0.2, 0.1 }, 0.0 });
    add(float3 { 4.0, 1.0, 0.0 }, 1.0, Mat { METALIC, float3 { 0.7, 0.6, 0.5 }, 0.01 });
}

// Hits
// ----

// Scratch for hit(): qb and disc of every sphere for the current ray.
let MAX_SPHERES = 512;
var qbs: f32[512];
var discs: f32[512];

// The nearest sphere in (0.01, FAR): its index (-1 on a miss) and t.
// Same arithmetic as Sphere.hit in Bend, in two passes. The first has no
// branches, so the C compiler vectorizes it: qb and disc for every sphere.
// The second only takes the sqrt of the few with disc > 0.
fn hit(r: Ray) -> i64, f32 {
    let n = ox.len;
    assert(oy.len == n && oz.len == n && rr.len == n && n <= MAX_SPHERES);
    let a = r.a;
    let b = r.b;
    let qa = dot(b, b);
    for i in 0..n {
        let cx = a.x - ox[i];
        let cy = a.y - oy[i];
        let cz = a.z - oz[i];
        let qb = cx * b.x + cy * b.y + cz * b.z;
        let qc = cx * cx + cy * cy + cz * cz - rr[i];
        qbs[i] = qb;
        discs[i] = qb * qb - qa * qc;
    }
    var closest = FAR;
    var best = -1;
    for i in 0..n {
        let disc = discs[i];
        if disc > 0.0 {
            let qb = qbs[i];
            let sq = sqrt(disc);
            let tm = (0.0 - qb - sq) / qa;
            if tm > T_MIN && tm < closest {
                closest = tm;
                best = i;
            } else {
                let tp = (0.0 - qb + sq) / qa;
                if tp > T_MIN && tp < closest {
                    closest = tp;
                    best = i;
                }
            }
        }
    }
    return best, closest;
}

// Color
// -----

fn sky(d: float3) -> float3 {
    let t = 0.5 * (unit_of(d).y + 1.0);
    return scale(float3_1, 1.0 - t) + scale(float3 { 0.5, 0.7, 1.0 }, t);
}

fn schlick(cosine: f32, ri: f32) -> f32 {
    let r0 = (1.0 - ri) / (1.0 + ri);
    let r = r0 * r0;
    let five: f32 = 5.0;
    return r + (1.0 - r) * pow(1.0 - cosine, five);
}

// color() of main.nim: up to 49 bounces, then a last hit test, whose hit
// is black. Returns the color and the generator state after it.
fn color(r0: Ray, s0: u32) -> float3, u32 {
    var ray = r0;
    var acc = float3_1;
    var s = s0;
    for bounce in 49 {
        let i, t = hit(ray);
        if i < 0 { return acc * sky(ray.b), s; }
        let b = ray.b;
        let p = ray.a + scale(b, t);
        let n = div(p - float3 { ox[i], oy[i], oz[i] }, rad[i]);
        let m = mats[i];
        if m.kind == LAMBERTIAN {
            let c = in_sphere(s);
            let target = p + n + vec3_of(c);
            ray = Ray { p, target - p };
            acc = acc * m.albedo;
            s = next3(c);
        } else if m.kind == METALIC {
            let c = in_sphere(s);
            let d = reflect(unit_of(b), n) + scale(vec3_of(c), m.param);
            s = next3(c);
            if dot(d, n) <= 0.0 { return float3_0, s; }
            ray = Ray { p, d };
            acc = acc * m.albedo;
        } else {
            let refraction = m.param;
            let bn = dot(b, n);
            let inside = bn > 0.0;
            let out = if inside { neg(n) } else { n };
            let ni = if inside { refraction } else { 1.0 / refraction };
            let cos0 = 0.0 - bn / len(b);
            let cosine = if inside { 0.0 - cos0 * refraction } else { cos0 };
            let nv = unit_of(b);
            let dt = dot(nv, out);
            let disc = 1.0 - ni * ni * (1.0 - dt * dt);
            let through = disc > 0.0 && u(s) > schlick(cosine, refraction);
            let d = if through {
                scale(nv - scale(out, dt), ni) - scale(out, sqrt(disc))
            } else {
                reflect(b, n)
            };
            ray = Ray { p, d };
            s = next(s);
        }
    }
    let i, t = hit(ray);
    if i < 0 { return acc * sky(ray.b), s; }
    return float3_0, s;
}

fn to_byte(x: f32) -> u8 { (((255.99 * sqrt(x)) as! u32) & 255) as! u8 }

// One image line, as r, g, b bytes.
fn render_row(c: Cam, y: i64, ns: i64) -> u8[>..] {
    var px: u8[>..] = [];
    for x in W {
        var s = rng_hash((y * W + x + 1) as u32);
        var sum = float3_0;
        for k in ns {
            let d = in_disk(next2(s));
            let r = cam_ray(c, (x + u(s)) / W, (y + u(next(s))) / H, vec2_of(d));
            let col, s2 = color(r, next2(d));
            sum = sum + col;
            s = s2;
        }
        let m = div(sum, ns);
        px.push(to_byte(m.x));
        px.push(to_byte(m.y));
        px.push(to_byte(m.z));
    }
    return px;
}

// Threads
// -------

struct Job { y: i32, ns: i32 }          // y = -1: no more work
struct Line { y: i32, px: u8[] }        // a flat value: it crosses the queue as one copy

fn look() -> Cam { new_cam(float3 { -1.0, 1.0, 18.0 }, float3 { 0.0, 1.0, -1.0 }) }

thread_fn worker() {
    build_scene();
    let c = look();
    loop {
        let job = qget<Job>();
        guard job.y >= 0 else { break; }
        qput(Line { y: job.y, px: render_row(c, job.y, job.ns) });
    }
}

// Image files
// -----------

// targa stores rows bottom up, as b, g, r
fn tga(img: u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    for b in [0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0] { out.push(b as u8); }
    out.push(W & 255); out.push(W >> 8);
    out.push(H & 255); out.push(H >> 8);
    out.push(24); out.push(0);
    var y = H;
    while y > 0 {
        y--;
        for x in W {
            let i = (y * W + x) * 3;
            out.push(img[i + 2]);
            out.push(img[i + 1]);
            out.push(img[i]);
        }
    }
    return out;
}

fn ppm(img: u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    format(out, "P3\n", W, " ", H, "\n255\n");
    for x in W * H {
        format(out, img[x * 3], " ", img[x * 3 + 1], " ", img[x * 3 + 2], "\n");
    }
    return out;
}

fn save(path: const u8[:], bytes: u8[:]) {
    guard write_file(path, bytes) else { abort(str("cannot write ", path)); }
    print("wrote ", path);
}

// Main
// ----

fn main() {
    var ns = 64;
    var want_ppm = false;
    var threads = max(1, hardware_threads());
    let a = args();
    var i = 1;
    while i < a.len {
        if a[i] == "ppm" {
            want_ppm = true;
        } else if a[i] == "--threads" && i + 1 < a.len {
            i++;
            let n, ok = parse_int(a[i]);
            if ok && n > 0 { threads = n; }
        } else {
            let n, ok = parse_int(a[i]);
            if ok && n > 0 { ns = n; }
        }
        i++;
    }
    print("rendering ", W, "x", H, " at ", ns, " samples per pixel");
    let t0 = clock();
    var img: u8[>..] = [];
    if threads == 1 {
        build_scene();
        let c = look();
        for y in H { img.append(render_row(c, y, ns)); }
    } else {
        for y in H { qput(Job { y: y as i32, ns: ns as i32 }); }
        for k in threads { qput(Job { y: -1, ns: 0 }); }
        var ids: i64[>..] = [];
        for k in threads { ids.push(thread_spawn(worker)); }
        img.resize(W * H * 3, 0);
        for done in H {
            let line = qget<Line>();
            let base = line.y * W * 3;
            for b, k in line.px { img[base + k] = b; }
        }
        for id in ids { thread_wait(id); }
    }
    print("rendered in ", ((clock() - t0) * 1000.0) as i64, " ms");
    save("ray.tga", tga(img));
    if want_ppm { save("ray.ppm", ppm(img)); }
}

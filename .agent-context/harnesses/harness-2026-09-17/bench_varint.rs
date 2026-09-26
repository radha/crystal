// rustc -C opt-level=3 -C target-cpu=native -o /tmp/bv_rs bench_varint.rs && /tmp/bv_rs
// LEB128 loop equivalent to the `integer-encoding` crate's VarInt impl.
use std::time::Instant;

const N: usize = 1_000_000;

fn dataset(kind: &str) -> Vec<u64> {
    let mut x: u64 = 0x9E3779B97F4A7C15;
    (0..N)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            match kind {
                "small" => x & 0x7f,
                "medium" => x & 0x0fff_ffff,
                _ => x >> (x & 63),
            }
        })
        .collect()
}

#[inline]
fn encode(mut v: u64, out: &mut [u8]) -> usize {
    let mut i = 0;
    while v >= 0x80 {
        out[i] = (v as u8) | 0x80;
        v >>= 7;
        i += 1;
    }
    out[i] = v as u8;
    i + 1
}

#[inline]
fn decode(input: &[u8]) -> (u64, usize) {
    let mut result: u64 = 0;
    let mut shift = 0;
    let mut i = 0;
    loop {
        let b = input[i];
        i += 1;
        result |= ((b & 0x7f) as u64) << shift;
        if b < 0x80 {
            return (result, i);
        }
        shift += 7;
        if i == 10 {
            panic!("overflow");
        }
    }
}

fn best(iters: usize, mut f: impl FnMut()) -> f64 {
    let mut b = f64::INFINITY;
    for _ in 0..iters {
        let t = Instant::now();
        f();
        let d = t.elapsed().as_nanos() as f64;
        if d < b {
            b = d;
        }
    }
    b
}

fn report(name: &str, ns: f64, bytes: usize) {
    println!("{:<28} {:7.2} ns/op {:8.1} MB/s", name, ns / N as f64, bytes as f64 / ns * 1e3);
}

fn main() {
    let mut sink: u64 = 0;
    for kind in ["small", "medium", "full"] {
        let values = dataset(kind);
        let mut buffer = vec![0u8; N * 10];
        let mut total = 0;

        let ns = best(20, || {
            let mut pos = 0;
            for &v in &values {
                pos += encode(v, &mut buffer[pos..]);
            }
            total = pos;
        });
        report(&format!("{} encode slice", kind), ns, total);

        let ns = best(20, || {
            let mut pos = 0;
            for _ in 0..N {
                let (v, n) = decode(&buffer[pos..]);
                sink = sink.wrapping_add(v);
                pos += n;
            }
        });
        report(&format!("{} decode slice", kind), ns, total);
    }
    println!("sink {}", sink);
}

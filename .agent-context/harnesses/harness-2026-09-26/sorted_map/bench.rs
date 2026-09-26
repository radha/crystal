// SortedMap benchmark counterpart: std BTreeMap with the same key streams.
use std::collections::BTreeMap;
use std::hint::black_box;
use std::time::Instant;

struct SplitMix(u64);
impl SplitMix {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }
}

fn keys(n: usize, seed: u64) -> Vec<u64> {
    let mut r = SplitMix(seed);
    (0..n).map(|_| r.next()).collect()
}

// Fisher-Yates driven by SplitMix(2): a different permutation than
// Crystal's shuffle, but the same key set and cost profile.
fn shuffled(mut v: Vec<u64>) -> Vec<u64> {
    let mut r = SplitMix(2);
    for i in (1..v.len()).rev() {
        let j = (r.next() % (i as u64 + 1)) as usize;
        v.swap(i, j);
    }
    v
}

fn bench<F: FnMut() -> u64>(name: &str, n: usize, ops: usize, reps: usize, mut f: F) {
    let mut best = f64::MAX;
    let mut sink = 0u64;
    for _ in 0..reps {
        let t = Instant::now();
        sink = sink.wrapping_add(black_box(f()));
        let dt = t.elapsed().as_nanos() as f64;
        if dt < best { best = dt; }
    }
    println!("{:<14} n={:<8} {:>8.1} ns/op  (sink {})", name, n, best / ops as f64, sink & 0xff);
}

fn main() {
    for &n in &[1_000usize, 100_000, 1_000_000] {
        let ks = keys(n, 1);
        let probes = shuffled(keys(n, 1));
        let mut sorted = ks.clone();
        sorted.sort();
        let reps = if n >= 1_000_000 { 3 } else if n >= 100_000 { 5 } else { 200 };
        let map: BTreeMap<u64, u64> = ks.iter().map(|&k| (k, k)).collect();

        bench("insert_rand", n, n, reps, || { let mut m = BTreeMap::new(); for &k in &ks { m.insert(k, k); } m.len() as u64 });
        bench("insert_seq", n, n, reps, || { let mut m = BTreeMap::new(); for &k in &sorted { m.insert(k, k); } m.len() as u64 });
        bench("bulk_sorted", n, n, reps, || { let m: BTreeMap<u64, u64> = sorted.iter().map(|&k| (k, k)).collect(); m.len() as u64 });
        bench("get_hit", n, n, reps, || { let mut s = 0u64; for k in &probes { s = s.wrapping_add(*map.get(k).unwrap_or(&0)); } s });
        bench("iter_all", n, n, reps, || { let mut s = 0u64; for (_, v) in &map { s = s.wrapping_add(*v); } s });
        let q = n.min(1000);
        bench("range_100", n, q * 100, reps, || {
            let mut s = 0u64;
            for i in 0..q {
                let lo = sorted[(i * 7919) % (n - 100)];
                for (_, v) in map.range(lo..).take(100) { s = s.wrapping_add(*v); }
            }
            s
        });
        bench("floor", n, n, reps, || { let mut s = 0u64; for &k in &probes { s = s.wrapping_add(map.range(..=k.wrapping_add(1)).next_back().map(|(k, _)| *k).unwrap_or(0)); } s });
        bench("delete_rand", n, n, reps, || {
            let mut m: BTreeMap<u64, u64> = sorted.iter().map(|&k| (k, k)).collect();
            for k in &probes { m.remove(k); }
            m.len() as u64
        });
    }
}

// LRUCache benchmark counterpart: the `lru` crate (default hasher), same key streams.
use lru::LruCache;
use std::hint::black_box;
use std::num::NonZeroUsize;
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
    for &cap in &[1_000usize, 100_000, 1_000_000] {
        let mut r = SplitMix(1);
        let universe: Vec<u64> = (0..cap * 2).map(|_| r.next()).collect();
        let mut r = SplitMix(3);
        let stream: Vec<u64> = (0..cap * 2).map(|_| universe[(r.next() % (cap as u64 * 2)) as usize]).collect();
        let reps = if cap >= 1_000_000 { 3 } else if cap >= 100_000 { 5 } else { 200 };
        let full = &universe[..cap];
        let mut probes = full.to_vec();
        let mut r = SplitMix(2);
        for i in (1..probes.len()).rev() { let j = (r.next() % (i as u64 + 1)) as usize; probes.swap(i, j); }
        let size = NonZeroUsize::new(cap).unwrap();

        let mut cache = LruCache::new(size);
        for &k in full { cache.put(k, k); }
        bench("get_hit", cap, cap, reps, || { let mut s = 0u64; for k in &probes { s = s.wrapping_add(*cache.get(k).unwrap_or(&0)); } s });
        bench("set_evict", cap, cap * 2, reps, || { let mut c = LruCache::new(size); for &k in &universe { c.put(k, k); } c.len() as u64 });
        bench("fetch_mix", cap, cap * 2, reps, || {
            let mut c = LruCache::new(size);
            let mut s = 0u64;
            for &k in &stream { s = s.wrapping_add(*c.get_or_insert(k, || k.wrapping_mul(3))); }
            s
        });
    }
}

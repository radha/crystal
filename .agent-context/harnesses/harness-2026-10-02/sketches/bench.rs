// Counterpart of bench.cr: same SplitMix64 key streams, same sizes.
use std::hint::black_box;
use std::time::Instant;

use count_min_sketch::CountMinSketch64;
use hyperloglogplus::{HyperLogLog, HyperLogLogPF};
use petgraph::unionfind::UnionFind;
use rapidhash::v3::{rapidhash_v3_seeded, RapidSecrets};
use union_find::{QuickUnionUf, UnionBySize, UnionFind as _};

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

fn bench<F: FnMut() -> u64>(name: &str, ops: usize, reps: usize, mut f: F) {
    let mut best = f64::MAX;
    let mut sink = 0u64;
    for _ in 0..reps {
        let t = Instant::now();
        sink = sink.wrapping_add(black_box(f()));
        let dt = t.elapsed().as_nanos() as f64;
        if dt < best { best = dt; }
    }
    println!("{:<28} {:>8.2} ns/op  (sink {})", name, best / ops as f64, sink & 0xff);
}

fn main() {
    let n = 1_000_000usize;
    let mut r = SplitMix(1);
    let keys: Vec<u64> = (0..n).map(|_| r.next()).collect();
    let misses: Vec<u64> = (0..n).map(|_| r.next()).collect();
    let words: Vec<String> = (0..n).map(|i| format!("item-{}", i)).collect();
    let blob: Vec<u8> = (0..4096u32).map(|i| (i * 31 + 7) as u8).collect();
    let secrets = RapidSecrets::seed_cpp(0);
    let rapid = rapidhash::fast::SeedableState::fixed();

    // Hash
    bench("hash/str ~11B", n, 5, || { let mut s = 0u64; for w in &words { s = s.wrapping_add(rapidhash_v3_seeded(black_box(w.as_bytes()), &secrets)); } s });
    bench("hash/int (16B)", n, 5, || { let mut s = 0u64; for &k in &keys { s = s.wrapping_add(rapidhash_v3_seeded(&black_box(k as i128).to_le_bytes(), &secrets)); } s });
    for len in [64usize, 1024, 4096] {
        let reps = 4_000_000 / len;
        bench(&format!("hash/{}B", len), reps, 5, || { let mut s = 0u64; for _ in 0..reps { s = s.wrapping_add(rapidhash_v3_seeded(black_box(&blob[..len]), &secrets)); } s });
    }

    // Bloom, 1M items at 1%
    bench("bloom(classic)/insert", n, 3, || { let mut b = bloomfilter::Bloom::new_for_fp_rate(n, 0.01).unwrap(); for k in &keys { b.set(k); } b.check(&keys[0]) as u64 });
    let mut b = bloomfilter::Bloom::new_for_fp_rate(n, 0.01).unwrap();
    for k in &keys { b.set(k); }
    bench("bloom(classic)/hit", n, 3, || { let mut s = 0u64; for k in &keys { s += b.check(k) as u64; } s });
    bench("bloom(classic)/miss", n, 3, || { let mut s = 0u64; for k in &misses { s += b.check(k) as u64; } s });
    bench("fastbloom(blocked)/insert", n, 3, || { let mut b = fastbloom::BloomFilter::with_false_pos(0.01).hasher(rapid.clone()).expected_items(n); for k in &keys { b.insert(k); } b.contains(&keys[0]) as u64 });
    let mut fb = fastbloom::BloomFilter::with_false_pos(0.01).hasher(rapid.clone()).expected_items(n);
    for k in &keys { fb.insert(k); }
    bench("fastbloom(blocked)/hit", n, 3, || { let mut s = 0u64; for k in &keys { s += fb.contains(k) as u64; } s });
    bench("fastbloom(blocked)/miss", n, 3, || { let mut s = 0u64; for k in &misses { s += fb.contains(k) as u64; } s });

    // HyperLogLog p=14
    bench("hll/insert", n, 3, || { let mut h: HyperLogLogPF<u64, _> = HyperLogLogPF::new(14, rapid.clone()).unwrap(); for k in &keys { h.insert(k); } h.count() as u64 });
    let mut h: HyperLogLogPF<u64, _> = HyperLogLogPF::new(14, rapid.clone()).unwrap();
    for k in &keys { h.insert(k); }
    bench("hll/count", 1, 50, || { h.insert(&black_box(7u64)); h.count() as u64 });
    let mut h2pre: HyperLogLogPF<u64, _> = HyperLogLogPF::new(14, rapid.clone()).unwrap();
    for k in &misses { h2pre.insert(k); }
    bench("hll/merge+count", 1, 50, || { let mut a = h.clone(); a.merge(&h2pre).unwrap(); a.count() as u64 });
    let mut h2: HyperLogLogPF<u64, _> = HyperLogLogPF::new(14, rapid.clone()).unwrap();
    for k in &misses { h2.insert(k); }
    bench("hll/merge", 1, 50, || { let mut a = h.clone(); a.merge(&h2).unwrap(); 0 });

    // Count-min, 32768 x 6, conservative (the crate's only mode), SipHash13
    bench("cms(conservative)/add", n, 3, || { let mut c = CountMinSketch64::<u64>::new(1_000_000, 0.99, 62.0).unwrap(); for k in &keys { c.increment(&(k & 0xffff)); } c.estimate(&1) });
    let mut c = CountMinSketch64::<u64>::new(1_000_000, 0.99, 62.0).unwrap();
    for k in &keys { c.increment(&(k & 0xffff)); }
    bench("cms(conservative)/estimate", n, 3, || { let mut s = 0u64; for k in &keys { s = s.wrapping_add(c.estimate(&(k & 0xffff))); } s });

    // Union-find over 1M indices: 1M random unions, then 1M finds
    let pairs: Vec<(usize, usize)> = (0..n).map(|_| ((r.next() % n as u64) as usize, (r.next() % n as u64) as usize)).collect();
    bench("uf(petgraph)/union", n, 5, || { let mut u = UnionFind::<u32>::new(n); let mut s = 0u64; for &(a, b) in &pairs { s += u.union(a as u32, b as u32) as u64; } s });
    let mut u = UnionFind::<u32>::new(n);
    for &(a, b) in &pairs { u.union(a as u32, b as u32); }
    bench("uf(petgraph)/find", n, 5, || { let mut s = 0u64; for &(a, _) in &pairs { s += u.find_mut(a as u32) as u64; } s });
    bench("uf(union-find)/union", n, 5, || { let mut u = QuickUnionUf::<UnionBySize>::new(n); let mut s = 0u64; for &(a, b) in &pairs { s += u.union(a, b) as u64; } s });
    let mut q = QuickUnionUf::<UnionBySize>::new(n);
    for &(a, b) in &pairs { q.union(a, b); }
    bench("uf(union-find)/find", n, 5, || { let mut s = 0u64; for &(a, _) in &pairs { s += q.find(a) as u64; } s });
}

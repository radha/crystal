// RadixTree benchmark counterpart: `radix_trie` 0.3 and `qp-trie` 0.8 on the
// same generated keys as bench.cr. Run with `cargo run --release`.
use std::hint::black_box;
use std::time::Instant;

const N: usize = 100_000;
const REPS: usize = 5;

fn urls() -> Vec<String> {
    (0..N).map(|i| format!("/api/v1/users/{}/posts/{}", i, i * 7 % 1000)).collect()
}

fn words() -> Vec<String> {
    let mut state: u64 = 12345;
    let mut next = || {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        state >> 33
    };
    (0..N)
        .map(|_| {
            let len = 3 + next() % 10;
            (0..len).map(|_| (b'a' + (next() % 26) as u8) as char).collect()
        })
        .collect()
}

struct Data {
    name: &'static str,
    keys: Vec<String>,
    probes: Vec<usize>,
    misses: Vec<String>,
    queries: Vec<String>,
    prefixes: Vec<String>,
}

fn data(name: &'static str) -> Data {
    let keys = if name == "urls" { urls() } else { words() };
    let probes: Vec<usize> = (0..N).map(|j| j * 7919 % N).collect();
    let misses = probes.iter().map(|&i| format!("{}~", keys[i])).collect();
    let suffix = if name == "urls" { "/comments/12" } else { "qz" };
    let queries = probes.iter().map(|&i| format!("{}{}", keys[i], suffix)).collect();
    let prefixes = if name == "urls" {
        (10..100).map(|d| format!("/api/v1/users/{}", d)).collect()
    } else {
        let mut v = Vec::new();
        for a in b'a'..=b'z' {
            for b in b'a'..=b'z' {
                v.push(String::from_utf8(vec![a, b]).unwrap());
            }
        }
        v
    };
    Data { name, keys, probes, misses, queries, prefixes }
}

fn report(lib: &str, d: &Data, op: &str, ops: usize, best: f64, check: u64) {
    println!("{:<10} {:<6} {:<14} {:>8.1} ns/op  (ops {}, check {})", lib, d.name, op, best / ops as f64, ops, check);
}

fn time<F: FnMut() -> (u64, usize)>(lib: &str, d: &Data, op: &str, mut f: F) {
    let mut best = f64::MAX;
    let mut check = 0;
    let mut ops = 0;
    for _ in 0..REPS {
        let t = Instant::now();
        let (c, n) = black_box(f());
        let dt = t.elapsed().as_nanos() as f64;
        if dt < best {
            best = dt;
        }
        check = c;
        ops = n;
    }
    report(lib, d, op, ops, best, check);
}

fn bench_radix_trie(d: &Data) {
    use radix_trie::{Trie, TrieCommon};
    let lib = "radix_trie";
    let build = || {
        let mut t = Trie::new();
        for (i, k) in d.keys.iter().enumerate() {
            t.insert(k.clone(), i as u64);
        }
        t
    };
    // insert: keys are cloned before the clock starts and moved in.
    let mut best = f64::MAX;
    let mut len = 0;
    for _ in 0..REPS {
        let owned = d.keys.clone();
        let t0 = Instant::now();
        let mut t = Trie::new();
        for (i, k) in owned.into_iter().enumerate() {
            t.insert(k, i as u64);
        }
        let dt = t0.elapsed().as_nanos() as f64;
        best = best.min(dt);
        len = t.len();
        drop(black_box(t));
    }
    report(lib, d, "insert", N, best, len as u64);

    let t = build();
    time(lib, d, "get_hit", || {
        let mut s = 0u64;
        for &i in &d.probes {
            s = s.wrapping_add(*t.get(d.keys[i].as_str()).unwrap());
        }
        (s, N)
    });
    time(lib, d, "get_miss", || {
        let mut s = 0u64;
        for k in &d.misses {
            if t.get(k.as_str()).is_some() {
                s += 1;
            }
        }
        (s, N)
    });
    time(lib, d, "longest_prefix", || {
        let mut s = 0u64;
        for q in &d.queries {
            s = s.wrapping_add(*t.get_ancestor_value(q.as_str()).unwrap_or(&0));
        }
        (s, N)
    });
    time(lib, d, "prefix_vals", || {
        let mut s = 0u64;
        let mut n = 0;
        for p in &d.prefixes {
            if let Some(sub) = t.get_raw_descendant(p.as_str()) {
                for v in sub.values() {
                    s = s.wrapping_add(*v);
                    n += 1;
                }
            }
        }
        (s, n)
    });
    time(lib, d, "prefix_keys", || {
        let mut s = 0u64;
        let mut n = 0;
        for p in &d.prefixes {
            if let Some(sub) = t.get_raw_descendant(p.as_str()) {
                for (k, v) in sub.iter() {
                    s = s.wrapping_add(*v).wrapping_add(k.len() as u64);
                    n += 1;
                }
            }
        }
        (s, n)
    });
    let mut best = f64::MAX;
    let mut left = 0;
    for _ in 0..REPS {
        let mut t = build();
        let t0 = Instant::now();
        for (j, &i) in d.probes.iter().enumerate() {
            if j % 2 == 0 {
                t.remove(d.keys[i].as_str());
            }
        }
        let dt = t0.elapsed().as_nanos() as f64;
        best = best.min(dt);
        left = t.len();
    }
    report(lib, d, "delete_half", N / 2, best, left as u64);
}

fn bench_qp_trie(d: &Data) {
    use qp_trie::Trie;
    let lib = "qp-trie";
    let build = || {
        let mut t: Trie<&[u8], u64> = Trie::new();
        for (i, k) in d.keys.iter().enumerate() {
            t.insert(k.as_bytes(), i as u64);
        }
        t
    };
    let mut best = f64::MAX;
    let mut len = 0;
    for _ in 0..REPS {
        let owned: Vec<&[u8]> = d.keys.iter().map(|k| k.as_bytes()).collect();
        let t0 = Instant::now();
        let mut t: Trie<&[u8], u64> = Trie::new();
        for (i, k) in owned.into_iter().enumerate() {
            t.insert(k, i as u64);
        }
        let dt = t0.elapsed().as_nanos() as f64;
        best = best.min(dt);
        len = t.count();
        drop(black_box(t));
    }
    report(lib, d, "insert", N, best, len as u64);

    let t = build();
    time(lib, d, "get_hit", || {
        let mut s = 0u64;
        for &i in &d.probes {
            s = s.wrapping_add(*t.get(d.keys[i].as_bytes()).unwrap());
        }
        (s, N)
    });
    time(lib, d, "get_miss", || {
        let mut s = 0u64;
        for k in &d.misses {
            if t.get(k.as_bytes()).is_some() {
                s += 1;
            }
        }
        (s, N)
    });
    // qp-trie has no "longest stored prefix" query: take the longest common
    // prefix with any key, then probe shorter prefixes until one is stored.
    time(lib, d, "longest_prefix", || {
        let mut s = 0u64;
        for q in &d.queries {
            let q = q.as_bytes();
            let mut len = t.longest_common_prefix(q).len();
            loop {
                if let Some(v) = t.get(&q[..len]) {
                    s = s.wrapping_add(*v);
                    break;
                }
                if len == 0 {
                    break;
                }
                len -= 1;
            }
        }
        (s, N)
    });
    time(lib, d, "prefix_vals", || {
        let mut s = 0u64;
        let mut n = 0;
        for p in &d.prefixes {
            for (_, v) in t.iter_prefix(p.as_bytes()) {
                s = s.wrapping_add(*v);
                n += 1;
            }
        }
        (s, n)
    });
    time(lib, d, "prefix_keys", || {
        let mut s = 0u64;
        let mut n = 0;
        for p in &d.prefixes {
            for (k, v) in t.iter_prefix(p.as_bytes()) {
                s = s.wrapping_add(*v).wrapping_add(k.len() as u64);
                n += 1;
            }
        }
        (s, n)
    });
    let mut best = f64::MAX;
    let mut left = 0;
    for _ in 0..REPS {
        let mut t = build();
        let t0 = Instant::now();
        for (j, &i) in d.probes.iter().enumerate() {
            if j % 2 == 0 {
                t.remove(d.keys[i].as_bytes());
            }
        }
        let dt = t0.elapsed().as_nanos() as f64;
        best = best.min(dt);
        left = t.count();
    }
    report(lib, d, "delete_half", N / 2, best, left as u64);
}

fn main() {
    for name in ["urls", "words"] {
        let d = data(name);
        bench_radix_trie(&d);
        bench_qp_trie(&d);
    }
}

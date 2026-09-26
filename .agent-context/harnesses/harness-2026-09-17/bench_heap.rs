use std::cmp::{Ordering, Reverse};
use std::collections::BinaryHeap;
use std::time::Instant;

const N: usize = 1_000_000;
const STEADY: usize = 1024;
const STEADY_OPS: usize = 10_000_000;
const RUNS: usize = 5;

#[derive(Clone, Copy, PartialEq, Eq)]
struct Job {
    priority: i32,
    id: i32,
}
impl Ord for Job {
    fn cmp(&self, o: &Self) -> Ordering {
        self.priority.cmp(&o.priority)
    }
}
impl PartialOrd for Job {
    fn partial_cmp(&self, o: &Self) -> Option<Ordering> {
        Some(self.cmp(o))
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct Wide {
    deadline: i64,
    id: i64,
    #[allow(dead_code)]
    extra: i64,
}
impl Ord for Wide {
    fn cmp(&self, o: &Self) -> Ordering {
        self.deadline.cmp(&o.deadline)
    }
}
impl PartialOrd for Wide {
    fn partial_cmp(&self, o: &Self) -> Option<Ordering> {
        Some(self.cmp(o))
    }
}

fn xorshift(mut x: u32) -> Vec<i32> {
    let mut v = Vec::with_capacity(N);
    for _ in 0..N {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        v.push((x & 0x7fff_ffff) as i32);
    }
    v
}

fn bench<F: FnMut() -> i64>(name: &str, ops: usize, mut f: F) {
    let mut best = f64::INFINITY;
    let mut sink: i64 = 0;
    for _ in 0..RUNS {
        let t = Instant::now();
        sink = sink.wrapping_add(f());
        let e = t.elapsed().as_nanos() as f64;
        if e < best {
            best = e;
        }
    }
    println!("{:<32} {:8.2} ns/op  (sink {})", name, best / ops as f64, sink);
}

fn main() {
    let values = xorshift(2463534242);

    // Reverse => min-heap, matching Crystal's default order.
    bench("push 1M + pop 1M", 2 * N, || {
        let mut h = BinaryHeap::new();
        for &v in &values {
            h.push(Reverse(v));
        }
        let mut s: i64 = 0;
        while let Some(Reverse(v)) = h.pop() {
            s = s.wrapping_add(v as i64);
        }
        s
    });

    bench("heapify 1M + pop 1M", 2 * N, || {
        let mut h: BinaryHeap<Reverse<i32>> = values.iter().map(|&v| Reverse(v)).collect();
        let mut s: i64 = 0;
        while let Some(Reverse(v)) = h.pop() {
            s = s.wrapping_add(v as i64);
        }
        s
    });

    bench("heapify 1M only", N, || {
        let h: BinaryHeap<Reverse<i32>> = values.iter().map(|&v| Reverse(v)).collect();
        h.len() as i64
    });

    bench("steady push+pop (1024)", STEADY_OPS, || {
        let mut h: BinaryHeap<Reverse<i32>> = values[..STEADY].iter().map(|&v| Reverse(v)).collect();
        let mut s: i64 = 0;
        let mut i = 0;
        for _ in 0..STEADY_OPS {
            h.push(Reverse(values[i]));
            s = s.wrapping_add(h.pop().unwrap().0 as i64);
            i += 1;
            if i == N {
                i = 0;
            }
        }
        s
    });

    // peek_mut is Rust's replace_top.
    bench("steady replace_top (1024)", STEADY_OPS, || {
        let mut h: BinaryHeap<Reverse<i32>> = values[..STEADY].iter().map(|&v| Reverse(v)).collect();
        let mut s: i64 = 0;
        let mut i = 0;
        for _ in 0..STEADY_OPS {
            let mut top = h.peek_mut().unwrap();
            s = s.wrapping_add(top.0 as i64);
            *top = Reverse(values[i]);
            drop(top);
            i += 1;
            if i == N {
                i = 0;
            }
        }
        s
    });

    let jobs: Vec<Job> = values.iter().enumerate().map(|(i, &v)| Job { priority: v, id: i as i32 }).collect();

    bench("Job <=> push 1M + pop 1M", 2 * N, || {
        let mut h = BinaryHeap::new();
        for &j in &jobs {
            h.push(Reverse(j));
        }
        let mut s: i64 = 0;
        while let Some(Reverse(j)) = h.pop() {
            s = s.wrapping_add(j.id as i64);
        }
        s
    });

    bench("max push 1M + pop 1M", 2 * N, || {
        let mut h = BinaryHeap::new();
        for &v in &values {
            h.push(v);
        }
        let mut s: i64 = 0;
        while let Some(v) = h.pop() {
            s = s.wrapping_add(v as i64);
        }
        s
    });

    bench("Job steady push+pop (1024)", STEADY_OPS, || {
        let mut h: BinaryHeap<Reverse<Job>> = jobs[..STEADY].iter().map(|&j| Reverse(j)).collect();
        let mut s: i64 = 0;
        let mut i = 0;
        for _ in 0..STEADY_OPS {
            h.push(Reverse(jobs[i]));
            s = s.wrapping_add(h.pop().unwrap().0.id as i64);
            i += 1;
            if i == N {
                i = 0;
            }
        }
        s
    });

    let wides: Vec<Wide> = values.iter().enumerate().map(|(i, &v)| Wide { deadline: v as i64, id: i as i64, extra: 0 }).collect();

    bench("Wide 24B push 1M + pop 1M", 2 * N, || {
        let mut h = BinaryHeap::new();
        for &w in &wides {
            h.push(Reverse(w));
        }
        let mut s: i64 = 0;
        while let Some(Reverse(w)) = h.pop() {
            s = s.wrapping_add(w.id);
        }
        s
    });
}

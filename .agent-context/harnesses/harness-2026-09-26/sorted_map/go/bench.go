// SortedMap benchmark counterpart: github.com/google/btree (BTreeG, degree 32
// as its docs suggest), with the same key streams.
package main

import (
	"fmt"
	"math/rand"
	"sort"
	"time"

	"github.com/google/btree"
)

type kv struct{ k, v uint64 }

func less(a, b kv) bool { return a.k < b.k }

type splitMix struct{ s uint64 }

func (r *splitMix) next() uint64 {
	r.s += 0x9E3779B97F4A7C15
	z := r.s
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return z ^ (z >> 31)
}

func keys(n int, seed uint64) []uint64 {
	r := splitMix{seed}
	out := make([]uint64, n)
	for i := range out {
		out[i] = r.next()
	}
	return out
}

func bench(name string, n, ops, reps int, f func() uint64) {
	best := 1e300
	var sink uint64
	for i := 0; i < reps; i++ {
		t := time.Now()
		sink += f()
		dt := float64(time.Since(t).Nanoseconds())
		if dt < best {
			best = dt
		}
	}
	fmt.Printf("%-14s n=%-8d %8.1f ns/op  (sink %d)\n", name, n, best/float64(ops), sink&0xff)
}

func main() {
	for _, n := range []int{1_000, 100_000, 1_000_000} {
		ks := keys(n, 1)
		probes := keys(n, 1)
		rand.New(rand.NewSource(2)).Shuffle(n, func(i, j int) { probes[i], probes[j] = probes[j], probes[i] })
		sorted := append([]uint64(nil), ks...)
		sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
		reps := 200
		if n >= 1_000_000 {
			reps = 3
		} else if n >= 100_000 {
			reps = 5
		}
		m := btree.NewG[kv](32, less)
		for _, k := range sorted {
			m.ReplaceOrInsert(kv{k, k})
		}

		bench("insert_rand", n, n, reps, func() uint64 {
			t := btree.NewG[kv](32, less)
			for _, k := range ks {
				t.ReplaceOrInsert(kv{k, k})
			}
			return uint64(t.Len())
		})
		bench("insert_seq", n, n, reps, func() uint64 {
			t := btree.NewG[kv](32, less)
			for _, k := range sorted {
				t.ReplaceOrInsert(kv{k, k})
			}
			return uint64(t.Len())
		})
		bench("get_hit", n, n, reps, func() uint64 {
			var s uint64
			for _, k := range probes {
				if e, ok := m.Get(kv{k: k}); ok {
					s += e.v
				}
			}
			return s
		})
		bench("iter_all", n, n, reps, func() uint64 {
			var s uint64
			m.Ascend(func(e kv) bool { s += e.v; return true })
			return s
		})
		q := n
		if q > 1000 {
			q = 1000
		}
		bench("range_100", n, q*100, reps, func() uint64 {
			var s uint64
			for i := 0; i < q; i++ {
				lo := sorted[(i*7919)%(n-100)]
				c := 0
				m.AscendGreaterOrEqual(kv{k: lo}, func(e kv) bool { s += e.v; c++; return c < 100 })
			}
			return s
		})
		bench("floor", n, n, reps, func() uint64 {
			var s uint64
			for _, k := range probes {
				m.DescendLessOrEqual(kv{k: k + 1}, func(e kv) bool { s += e.k; return false })
			}
			return s
		})
		bench("delete_rand", n, n, reps, func() uint64 {
			t := m.Clone()
			for _, k := range probes {
				t.Delete(kv{k: k})
			}
			return uint64(t.Len())
		})
	}
}

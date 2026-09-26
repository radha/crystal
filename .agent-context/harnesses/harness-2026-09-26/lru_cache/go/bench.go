// LRUCache benchmark counterpart: hashicorp/golang-lru/v2 simplelru (no
// lock) and the locking lru.Cache, same key streams.
package main

import (
	"fmt"
	"math/rand"
	"os"
	"time"

	lru "github.com/hashicorp/golang-lru/v2"
	"github.com/hashicorp/golang-lru/v2/simplelru"
)

type splitMix struct{ s uint64 }

func (r *splitMix) next() uint64 {
	r.s += 0x9E3779B97F4A7C15
	z := r.s
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return z ^ (z >> 31)
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

type cache interface {
	Add(k, v uint64) bool
	Get(k uint64) (uint64, bool)
	Len() int
}

func main() {
	sync := len(os.Args) > 1 && os.Args[1] == "sync"
	newCache := func(n int) cache {
		if sync {
			c, _ := lru.New[uint64, uint64](n)
			return c
		}
		c, _ := simplelru.NewLRU[uint64, uint64](n, nil)
		return c
	}
	for _, capacity := range []int{1_000, 100_000, 1_000_000} {
		r := splitMix{1}
		universe := make([]uint64, capacity*2)
		for i := range universe {
			universe[i] = r.next()
		}
		r = splitMix{3}
		stream := make([]uint64, capacity*2)
		for i := range stream {
			stream[i] = universe[r.next()%uint64(capacity*2)]
		}
		reps := 200
		if capacity >= 1_000_000 {
			reps = 3
		} else if capacity >= 100_000 {
			reps = 5
		}
		full := universe[:capacity]
		probes := append([]uint64(nil), full...)
		rand.New(rand.NewSource(2)).Shuffle(len(probes), func(i, j int) { probes[i], probes[j] = probes[j], probes[i] })

		c := newCache(capacity)
		for _, k := range full {
			c.Add(k, k)
		}
		bench("get_hit", capacity, capacity, reps, func() uint64 {
			var s uint64
			for _, k := range probes {
				v, _ := c.Get(k)
				s += v
			}
			return s
		})
		bench("set_evict", capacity, capacity*2, reps, func() uint64 {
			c := newCache(capacity)
			for _, k := range universe {
				c.Add(k, k)
			}
			return uint64(c.Len())
		})
		bench("fetch_mix", capacity, capacity*2, reps, func() uint64 {
			c := newCache(capacity)
			var s uint64
			for _, k := range stream {
				v, ok := c.Get(k)
				if !ok {
					v = k * 3
					c.Add(k, v)
				}
				s += v
			}
			return s
		})
	}
}

// RadixTree benchmark counterpart: github.com/armon/go-radix on the same
// generated keys and operations as ../bench.cr.
package main

import (
	"fmt"
	"strings"
	"time"

	radix "github.com/armon/go-radix"
)

const n = 100_000
const reps = 5

type data struct {
	name                      string
	keys                      []string
	probes                    []int
	misses, queries, prefixes []string
}

func urls() []string {
	keys := make([]string, n)
	for i := range keys {
		keys[i] = fmt.Sprintf("/api/v1/users/%d/posts/%d", i, i*7%1000)
	}
	return keys
}

func words() []string {
	state := uint64(12345)
	next := func() uint64 {
		state = state*6364136223846793005 + 1442695040888963407
		return state >> 33
	}
	keys := make([]string, n)
	for i := range keys {
		length := 3 + next()%10
		var b strings.Builder
		for j := uint64(0); j < length; j++ {
			b.WriteByte(byte('a' + next()%26))
		}
		keys[i] = b.String()
	}
	return keys
}

func makeData(name string) *data {
	d := &data{name: name}
	if name == "urls" {
		d.keys = urls()
	} else {
		d.keys = words()
	}
	suffix := "qz"
	if name == "urls" {
		suffix = "/comments/12"
	}
	for j := 0; j < n; j++ {
		i := j * 7919 % n
		d.probes = append(d.probes, i)
		d.misses = append(d.misses, d.keys[i]+"~")
		d.queries = append(d.queries, d.keys[i]+suffix)
	}
	if name == "urls" {
		for x := 10; x < 100; x++ {
			d.prefixes = append(d.prefixes, fmt.Sprintf("/api/v1/users/%d", x))
		}
	} else {
		for a := 'a'; a <= 'z'; a++ {
			for b := 'a'; b <= 'z'; b++ {
				d.prefixes = append(d.prefixes, string([]rune{a, b}))
			}
		}
	}
	return d
}

func report(d *data, op string, ops int, best float64, check uint64) {
	fmt.Printf("%-10s %-6s %-14s %8.1f ns/op  (ops %d, check %d)\n", "go-radix", d.name, op, best/float64(ops), ops, check)
}

func timeIt(d *data, op string, f func() (uint64, int)) {
	best := 1e300
	var check uint64
	ops := 0
	for r := 0; r < reps; r++ {
		t := time.Now()
		c, k := f()
		dt := float64(time.Since(t).Nanoseconds())
		if dt < best {
			best = dt
		}
		check, ops = c, k
	}
	report(d, op, ops, best, check)
}

func build(d *data) *radix.Tree {
	t := radix.New()
	for i, k := range d.keys {
		t.Insert(k, uint64(i))
	}
	return t
}

func bench(d *data) {
	best := 1e300
	size := 0
	for r := 0; r < reps; r++ {
		t0 := time.Now()
		t := build(d)
		dt := float64(time.Since(t0).Nanoseconds())
		if dt < best {
			best = dt
		}
		size = t.Len()
	}
	report(d, "insert", n, best, uint64(size))

	t := build(d)
	timeIt(d, "get_hit", func() (uint64, int) {
		var s uint64
		for _, i := range d.probes {
			v, _ := t.Get(d.keys[i])
			s += v.(uint64)
		}
		return s, n
	})
	timeIt(d, "get_miss", func() (uint64, int) {
		var s uint64
		for _, k := range d.misses {
			if _, ok := t.Get(k); ok {
				s++
			}
		}
		return s, n
	})
	timeIt(d, "longest_prefix", func() (uint64, int) {
		var s uint64
		for _, q := range d.queries {
			if _, v, ok := t.LongestPrefix(q); ok {
				s += v.(uint64)
			}
		}
		return s, n
	})
	timeIt(d, "prefix_vals", func() (uint64, int) {
		var s uint64
		c := 0
		for _, p := range d.prefixes {
			t.WalkPrefix(p, func(k string, v interface{}) bool {
				s += v.(uint64)
				c++
				return false
			})
		}
		return s, c
	})
	timeIt(d, "prefix_keys", func() (uint64, int) {
		var s uint64
		c := 0
		for _, p := range d.prefixes {
			t.WalkPrefix(p, func(k string, v interface{}) bool {
				s += v.(uint64) + uint64(len(k))
				c++
				return false
			})
		}
		return s, c
	})

	best = 1e300
	left := 0
	for r := 0; r < reps; r++ {
		t := build(d)
		t0 := time.Now()
		for j, i := range d.probes {
			if j%2 == 0 {
				t.Delete(d.keys[i])
			}
		}
		dt := float64(time.Since(t0).Nanoseconds())
		if dt < best {
			best = dt
		}
		left = t.Len()
	}
	report(d, "delete_half", n/2, best, uint64(left))
}

func main() {
	for _, name := range []string{"urls", "words"} {
		bench(makeData(name))
	}
}

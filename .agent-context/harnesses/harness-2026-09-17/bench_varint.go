// go build -o /tmp/bv_go bench_varint.go && /tmp/bv_go
package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math"
	"time"
)

const N = 1_000_000

func dataset(kind string) []uint64 {
	x := uint64(0x9E3779B97F4A7C15)
	out := make([]uint64, N)
	for i := range out {
		x ^= x << 13
		x ^= x >> 7
		x ^= x << 17
		switch kind {
		case "small":
			out[i] = x & 0x7f
		case "medium":
			out[i] = x & 0x0fffffff
		default:
			out[i] = x >> (x & 63)
		}
	}
	return out
}

func best(iters int, f func()) float64 {
	b := math.Inf(1)
	for i := 0; i < iters; i++ {
		t := time.Now()
		f()
		d := float64(time.Since(t).Nanoseconds())
		if d < b {
			b = d
		}
	}
	return b
}

func report(name string, ns float64, nbytes int) {
	fmt.Printf("%-28s %7.2f ns/op %8.1f MB/s\n", name, ns/N, float64(nbytes)/ns*1e3)
}

func main() {
	var sink uint64
	for _, kind := range []string{"small", "medium", "full"} {
		values := dataset(kind)
		buffer := make([]byte, N*10)
		total := 0

		ns := best(20, func() {
			pos := 0
			for _, v := range values {
				pos += binary.PutUvarint(buffer[pos:], v)
			}
			total = pos
		})
		report(kind+" encode slice", ns, total)

		ns = best(20, func() {
			pos := 0
			for i := 0; i < N; i++ {
				v, n := binary.Uvarint(buffer[pos:])
				sink += v
				pos += n
			}
		})
		report(kind+" decode slice", ns, total)

		var buf bytes.Buffer
		buf.Grow(total)
		ns = best(20, func() {
			buf.Reset()
			var tmp [10]byte
			for _, v := range values {
				n := binary.PutUvarint(tmp[:], v)
				buf.Write(tmp[:n])
			}
		})
		report(kind+" encode bytes.Buffer", ns, total)

		ns = best(20, func() {
			r := bytes.NewReader(buffer[:total])
			for i := 0; i < N; i++ {
				v, _ := binary.ReadUvarint(r)
				sink += v
			}
		})
		report(kind+" decode bytes.Reader", ns, total)
	}

	body := bytes.Repeat([]byte{0xab}, 32)
	var fb bytes.Buffer
	fb.Grow(N * 36)
	ns := best(10, func() {
		fb.Reset()
		var hdr [4]byte
		for i := 0; i < N; i++ {
			binary.BigEndian.PutUint32(hdr[:], uint32(len(body)))
			fb.Write(hdr[:])
			fb.Write(body)
		}
	})
	report("frame write 32B u32be", ns, N*36)

	data := fb.Bytes()
	ns = best(10, func() {
		r := bytes.NewReader(data)
		var hdr [4]byte
		for i := 0; i < N; i++ {
			r.Read(hdr[:])
			n := binary.BigEndian.Uint32(hdr[:])
			b := make([]byte, n)
			r.Read(b)
			sink += uint64(len(b))
		}
	})
	report("frame read 32B u32be", ns, N*36)

	fmt.Println("sink", sink)
}

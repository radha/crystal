// bench_format.go
package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"testing"
)

type RpcHeader struct {
	Type, Flags       uint8
	StreamID, Length  uint32
}

type Column struct{ Value []byte }
type DataRow struct{ Columns []Column }

func (r *DataRow) Write(w *bytes.Buffer) {
	total := 4 + 2
	for _, c := range r.Columns {
		total += 4 + len(c.Value)
	}
	w.WriteByte('D')
	binary.Write(w, binary.BigEndian, int32(total))
	binary.Write(w, binary.BigEndian, int16(len(r.Columns)))
	for _, c := range r.Columns {
		binary.Write(w, binary.BigEndian, int32(len(c.Value)))
		w.Write(c.Value)
	}
}

func ReadDataRow(b []byte) DataRow {
	n := int(int16(binary.BigEndian.Uint16(b[5:])))
	p := 7
	cols := make([]Column, 0, n)
	for i := 0; i < n; i++ {
		l := int(int32(binary.BigEndian.Uint32(b[p:])))
		p += 4
		v := make([]byte, l)
		copy(v, b[p:p+l])
		p += l
		cols = append(cols, Column{v})
	}
	return DataRow{cols}
}

func main() {
	h := RpcHeader{1, 2, 3, 4}
	var hb bytes.Buffer
	binary.Write(&hb, binary.BigEndian, h)
	row := DataRow{}
	for i := 0; i < 10; i++ {
		row.Columns = append(row.Columns, Column{[]byte(fmt.Sprintf("value-%d", i))})
	}
	var rb bytes.Buffer
	row.Write(&rb)
	rowBytes := rb.Bytes()
	buf := make([]byte, 64)
	report := func(name string, f func()) {
		r := testing.Benchmark(func(b *testing.B) { for i := 0; i < b.N; i++ { f() } })
		fmt.Printf("%-24s %8.1f ns/op\n", name, float64(r.NsPerOp()))
	}
	report("header read", func() {
		var x RpcHeader
		x.Type, x.Flags = hb.Bytes()[0], hb.Bytes()[1]
		x.StreamID = binary.BigEndian.Uint32(hb.Bytes()[2:])
		x.Length = binary.BigEndian.Uint32(hb.Bytes()[6:])
	})
	report("header write", func() {
		buf[0], buf[1] = h.Type, h.Flags
		binary.BigEndian.PutUint32(buf[2:], h.StreamID)
		binary.BigEndian.PutUint32(buf[6:], h.Length)
	})
	report("datarow read", func() { ReadDataRow(rowBytes) })
	var out bytes.Buffer
	report("datarow write", func() { out.Reset(); row.Write(&out) })
}

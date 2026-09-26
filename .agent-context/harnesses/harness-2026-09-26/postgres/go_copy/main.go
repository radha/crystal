package main

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

func main() {
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, "postgres://postgres@127.0.0.1:5432/crystal_test?sslmode=disable")
	if err != nil {
		panic(err)
	}
	conn.Exec(ctx, "drop table if exists bench_copy_go; create unlogged table bench_copy_go (id int8, name text, score float8, at timestamptz)")
	t := time.Now().UTC()
	n := 1000000
	for r := 0; r < 3; r++ {
		conn.Exec(ctx, "truncate bench_copy_go")
		start := time.Now()
		i := 0
		src := pgx.CopyFromFunc(func() ([]any, error) {
			if i >= n {
				return nil, nil
			}
			row := []any{int64(i), fmt.Sprintf("name-%d", i), float64(i) * 0.5, t}
			i++
			return row, nil
		})
		cnt, err := conn.CopyFrom(ctx, pgx.Identifier{"bench_copy_go"}, []string{"id", "name", "score", "at"}, src)
		if err != nil {
			panic(err)
		}
		el := time.Since(start).Seconds()
		fmt.Printf("pgx CopyFrom 1M: %.2f s (%.0f rows/s)\n", el, float64(cnt)/el)
	}
	conn.Exec(ctx, "drop table bench_copy_go")
}

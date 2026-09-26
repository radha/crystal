// Go (pgx v5) side of the PostgreSQL client benchmarks.
//
//	go build -o bench_go . && ./bench_go [seq|fetch|pool|all]
//
// Statements are cached by pgx's default QueryExecModeCacheStatement
// (prepared once per connection, then Bind/Execute only).
package main

import (
	"context"
	"fmt"
	"os"
	"sort"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type BenchRow struct {
	ID    int64
	Name  string
	Score float64
	At    time.Time
	Ok    bool
}

func url() string {
	if u := os.Getenv("PG_URL"); u != "" {
		return u
	}
	return "postgres://postgres@127.0.0.1:5432/crystal_test?sslmode=disable"
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func benchSeq(ctx context.Context) {
	conn, err := pgx.Connect(ctx, url())
	must(err)
	defer conn.Close(ctx)
	sql := "select $1::int4"
	var v int32
	for i := 0; i < 1000; i++ {
		must(conn.QueryRow(ctx, sql, int32(i)).Scan(&v))
	}
	const n = 20000
	lat := make([]float64, 0, n)
	var sum int64
	start := time.Now()
	for i := 0; i < n; i++ {
		t0 := time.Now()
		must(conn.QueryRow(ctx, sql, int32(i)).Scan(&v))
		lat = append(lat, float64(time.Since(t0).Nanoseconds())/1000)
		sum += int64(v)
	}
	total := float64(time.Since(start).Nanoseconds()) / 1000
	if sum != int64(n)*(n-1)/2 {
		panic("bad sum")
	}
	sort.Float64s(lat)
	pct := func(p float64) float64 { return lat[int(float64(len(lat)-1)*p+0.5)] }
	fmt.Printf("RESULT seq mean_us=%.2f p50_us=%.2f p99_us=%.2f\n", total/n, pct(0.50), pct(0.99))
}

func fetchAll(ctx context.Context, conn *pgx.Conn, sql string) []BenchRow {
	rows, err := conn.Query(ctx, sql)
	must(err)
	list, err := pgx.CollectRows(rows, pgx.RowToStructByPos[BenchRow])
	must(err)
	return list
}

func benchFetch(ctx context.Context) {
	conn, err := pgx.Connect(ctx, url())
	must(err)
	defer conn.Close(ctx)
	sql := "select id, name, score, at, ok from bench_rows"
	for i := 0; i < 10; i++ {
		fetchAll(ctx, conn, sql)
	}
	const iters = 200
	var rows, checksum int64
	start := time.Now()
	for i := 0; i < iters; i++ {
		list := fetchAll(ctx, conn, sql)
		rows += int64(len(list))
		checksum += list[len(list)-1].ID
	}
	elapsed := time.Since(start).Seconds()
	if rows != iters*10000 {
		panic("bad rows")
	}
	fmt.Printf("RESULT fetch ms_per_fetch=%.3f rows_per_s=%.0f\n", elapsed*1000/iters, float64(rows)/elapsed)
}

func benchPool(ctx context.Context) {
	cfg, err := pgxpool.ParseConfig(url())
	must(err)
	cfg.MaxConns = 8
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	must(err)
	defer pool.Close()
	sql := "select $1::int4"
	const tasks, per = 64, 2000
	run := func(count int) {
		var wg sync.WaitGroup
		for t := 0; t < tasks; t++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				var v int32
				for i := 0; i < count; i++ {
					must(pool.QueryRow(ctx, sql, int32(i)).Scan(&v))
				}
			}()
		}
		wg.Wait()
	}
	run(50) // warm-up: open all 8 connections, prepare on each
	start := time.Now()
	run(per)
	elapsed := time.Since(start).Seconds()
	fmt.Printf("RESULT pool ops_per_s=%.0f\n", float64(tasks*per)/elapsed)
}

func main() {
	ctx := context.Background()
	mode := "all"
	if len(os.Args) > 1 {
		mode = os.Args[1]
	}
	switch mode {
	case "seq":
		benchSeq(ctx)
	case "fetch":
		benchFetch(ctx)
	case "pool":
		benchPool(ctx)
	case "all":
		benchSeq(ctx)
		benchFetch(ctx)
		benchPool(ctx)
	default:
		fmt.Fprintln(os.Stderr, "usage: bench_go [seq|fetch|pool|all]")
		os.Exit(2)
	}
}

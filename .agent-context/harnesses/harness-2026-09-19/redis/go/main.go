package main

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strconv"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

func report(name string, ops int64, d time.Duration) {
	secs := d.Seconds()
	fmt.Printf("%-28s %8d ops/s  %.1f µs/op\n",
		name, int64(float64(ops)/secs+0.5), float64(d.Nanoseconds())/float64(ops)/1000.0)
}

func main() {
	ctx := context.Background()

	slice2 := false
	slice3 := false
	useChan := false
	for _, a := range os.Args[1:] {
		if a == "slice2" {
			slice2 = true
		}
		if a == "slice3" {
			slice3 = true
		}
		if a == "chan" {
			useChan = true
		}
	}

	if slice3 {
		runSlice3(ctx)
		return
	}

	client := redis.NewClient(&redis.Options{
		Addr:     "127.0.0.1:6379",
		DB:       14,
		Protocol: 3,
	})
	defer client.Close()

	if err := client.FlushDB(ctx).Err(); err != nil {
		panic(err)
	}
	if err := client.Set(ctx, "k", "v", 0).Err(); err != nil {
		panic(err)
	}

	if slice2 {
		runSlice2(ctx, client, useChan)
	} else {
		runSlice1(ctx, client)
	}
}

func runSlice3(ctx context.Context) {
	c := redis.NewClusterClient(&redis.ClusterOptions{Addrs: []string{"127.0.0.1:7100", "127.0.0.1:7101", "127.0.0.1:7102"}})
	defer c.Close()
	keys := make([]string, 300)
	for i := range keys {
		keys[i] = fmt.Sprintf("k%d", i)
		c.Set(ctx, keys[i], "v", 0)
	}
	n := 50000
	t := time.Now()
	for i := 0; i < n; i++ {
		c.Get(ctx, "k0").Result()
	}
	el := time.Since(t)
	fmt.Printf("GET via cluster (go)            %9.0f ops/s  %.2f µs/op\n", float64(n)/el.Seconds(), float64(el.Nanoseconds())/float64(n)/1000)
	total := 500000
	var wg sync.WaitGroup
	t = time.Now()
	for f := 0; f < 64; f++ {
		wg.Add(1)
		go func(f int) {
			defer wg.Done()
			for i := 0; i < total/64; i++ {
				c.Get(ctx, keys[(f+i*64)%300]).Result()
			}
		}(f)
	}
	wg.Wait()
	fmt.Printf("64 goroutines GET (go)          %9.0f ops/s\n", float64(total)/time.Since(t).Seconds())
}

func runSlice1(ctx context.Context, client *redis.Client) {
	var n int64 = 50_000
	t := time.Now()
	for i := int64(0); i < n; i++ {
		if err := client.Get(ctx, "k").Err(); err != nil {
			panic(err)
		}
	}
	report("sequential GET", n, time.Since(t))

	var fibers int64 = 64
	var per int64 = 5_000

	t = time.Now()
	var wg sync.WaitGroup
	for i := int64(0); i < fibers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := int64(0); j < per; j++ {
				if err := client.Get(ctx, "k").Err(); err != nil {
					panic(err)
				}
			}
		}()
	}
	wg.Wait()
	report("64 goroutines GET", fibers*per, time.Since(t))

	t = time.Now()
	for i := int64(0); i < fibers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := int64(0); j < per; j++ {
				if err := client.Incr(ctx, "c").Err(); err != nil {
					panic(err)
				}
			}
		}()
	}
	wg.Wait()
	report("64 goroutines INCR", fibers*per, time.Since(t))

	t = time.Now()
	pipe := client.Pipeline()
	for i := 0; i < 10_000; i++ {
		pipe.Incr(ctx, "p")
	}
	if _, err := pipe.Exec(ctx); err != nil {
		panic(err)
	}
	report("10k pipeline INCR", 10_000, time.Since(t))
}

func runSlice2(ctx context.Context, client *redis.Client, useChan bool) {
	// 1. publish -> receive latency, one channel, sequential round trips.
	pubsub := client.Subscribe(ctx, "bench")
	if _, err := pubsub.Receive(ctx); err != nil {
		panic(err)
	}
	n := 10_000
	latencies := make([]float64, 0, n)
	for i := 0; i < n; i++ {
		t0 := time.Now()
		if err := client.Publish(ctx, "bench", strconv.Itoa(i)).Err(); err != nil {
			panic(err)
		}
		if _, err := pubsub.ReceiveMessage(ctx); err != nil {
			panic(err)
		}
		latencies = append(latencies, float64(time.Since(t0).Nanoseconds())/1000.0)
	}
	sort.Float64s(latencies)
	fmt.Printf("pubsub round trip: median %.1f µs, p99 %.1f µs\n",
		latencies[n/2], latencies[n*99/100])
	pubsub.Close()

	// 2. subscriber throughput: 64 channels, 1M pipelined publishes.
	chans := make([]string, 64)
	for i := range chans {
		chans[i] = "c" + strconv.Itoa(i)
	}
	sub := client.Subscribe(ctx, chans...)
	if _, err := sub.Receive(ctx); err != nil {
		panic(err)
	}
	total := 1_000_000
	done := make(chan struct{})
	// `chan` switches the receive side to pubsub.Channel(), go-redis's
	// buffered-goroutine API, which is the closer analogue of Crystal's
	// reader fiber -> bounded Channel -> consumer fiber.
	if useChan {
		msgs := sub.Channel()
		go func() {
			for i := 0; i < total; i++ {
				<-msgs
			}
			close(done)
		}()
	} else {
		go func() {
			for i := 0; i < total; i++ {
				if _, err := sub.ReceiveMessage(ctx); err != nil {
					panic(err)
				}
			}
			close(done)
		}()
	}
	t := time.Now()
	for b := 0; b < total/10_000; b++ {
		p := client.Pipeline()
		for j := 0; j < 10_000; j++ {
			p.Publish(ctx, chans[j%64], "m")
		}
		if _, err := p.Exec(ctx); err != nil {
			panic(err)
		}
	}
	<-done
	report("subscriber throughput", int64(total), time.Since(t))
	sub.Close()

	// 3. TxPipelined with 10 INCR vs the same 10 in a plain pipeline.
	iters := 10_000
	t = time.Now()
	for i := 0; i < iters; i++ {
		if _, err := client.Pipelined(ctx, func(p redis.Pipeliner) error {
			for j := 0; j < 10; j++ {
				p.Incr(ctx, "pl")
			}
			return nil
		}); err != nil {
			panic(err)
		}
	}
	report("pipeline 10 INCR", int64(iters), time.Since(t))

	t = time.Now()
	for i := 0; i < iters; i++ {
		if _, err := client.TxPipelined(ctx, func(p redis.Pipeliner) error {
			for j := 0; j < 10; j++ {
				p.Incr(ctx, "tx")
			}
			return nil
		}); err != nil {
			panic(err)
		}
	}
	report("multi 10 INCR", int64(iters), time.Since(t))

	// 4. Script.Run vs EvalSha by hand.
	script := redis.NewScript("return redis.call('INCR', KEYS[1])")
	if err := script.Run(ctx, client, []string{"s"}).Err(); err != nil {
		panic(err)
	}
	sha := script.Hash()
	n2 := 100_000
	t = time.Now()
	for i := 0; i < n2; i++ {
		if err := client.EvalSha(ctx, sha, []string{"s"}).Err(); err != nil {
			panic(err)
		}
	}
	report("evalsha by hand", int64(n2), time.Since(t))

	t = time.Now()
	for i := 0; i < n2; i++ {
		if err := script.Run(ctx, client, []string{"s"}).Err(); err != nil {
			panic(err)
		}
	}
	report("run(script)", int64(n2), time.Since(t))
}

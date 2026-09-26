use futures_util::StreamExt;
use redis::aio::MultiplexedConnection;
use redis::AsyncCommands;
use std::time::Instant;

fn report(name: &str, ops: u64, secs: f64) {
    println!(
        "{:<28} {:>8} ops/s  {:.1} µs/op",
        name,
        (ops as f64 / secs).round() as u64,
        secs * 1e6 / ops as f64
    );
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> redis::RedisResult<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let slice2 = args.iter().any(|a| a == "slice2");
    let slice3 = args.iter().any(|a| a == "slice3");
    if slice3 {
        return run_slice3().await;
    }
    let url = args
        .iter()
        .find(|a| a.as_str() != "slice2")
        .cloned()
        .unwrap_or_else(|| "redis://127.0.0.1:6379/14".to_string());
    let client = redis::Client::open(url)?;
    let mut con = client.get_multiplexed_tokio_connection().await?;
    redis::cmd("FLUSHDB").query_async::<()>(&mut con).await?;
    let _: () = con.set("k", "v").await?;

    if slice2 {
        run_slice2(&client, &mut con).await
    } else {
        run_slice1(&mut con).await
    }
}

async fn run_slice3() -> redis::RedisResult<()> {
    use redis::cluster::ClusterClient;
    use redis::AsyncCommands;
    let nodes = vec!["redis://127.0.0.1:7100/", "redis://127.0.0.1:7101/", "redis://127.0.0.1:7102/"];
    let client = ClusterClient::new(nodes)?;
    let mut con = client.get_async_connection().await?;
    let keys: Vec<String> = (0..300).map(|i| format!("k{}", i)).collect();
    for k in &keys { let _: () = con.set(k, "v").await?; }
    let n = 50_000;
    let t = std::time::Instant::now();
    for _ in 0..n { let _: String = con.get("k0").await?; }
    println!("GET via cluster (rs)            {:>9.0} ops/s  {:.2} µs/op", n as f64 / t.elapsed().as_secs_f64(), t.elapsed().as_nanos() as f64 / n as f64 / 1000.0);
    let total = 500_000;
    let t = std::time::Instant::now();
    let mut tasks = Vec::new();
    for f in 0..64 {
        let mut con = con.clone();
        let keys = keys.clone();
        tasks.push(tokio::spawn(async move {
            for i in 0..(total / 64) { let _: String = con.get(&keys[(f + i * 64) % 300]).await.unwrap(); }
        }));
    }
    for t in tasks { t.await.unwrap(); }
    println!("64 tasks GET (rs)               {:>9.0} ops/s", total as f64 / t.elapsed().as_secs_f64());
    Ok(())
}

async fn run_slice1(con: &mut MultiplexedConnection) -> redis::RedisResult<()> {
    let n: u64 = 50_000;
    let t = Instant::now();
    for _ in 0..n {
        let _: Option<String> = con.get("k").await?;
    }
    report("sequential GET", n, t.elapsed().as_secs_f64());

    let fibers: u64 = 64;
    let per: u64 = 5_000;

    let t = Instant::now();
    let mut handles = Vec::new();
    for _ in 0..fibers {
        let mut c = con.clone();
        handles.push(tokio::spawn(async move {
            for _ in 0..per {
                let _: Option<String> = c.get("k").await.unwrap();
            }
        }));
    }
    for h in handles {
        h.await.unwrap();
    }
    report("64 tasks GET", fibers * per, t.elapsed().as_secs_f64());

    let t = Instant::now();
    let mut handles = Vec::new();
    for _ in 0..fibers {
        let mut c = con.clone();
        handles.push(tokio::spawn(async move {
            for _ in 0..per {
                let _: i64 = c.incr("c", 1).await.unwrap();
            }
        }));
    }
    for h in handles {
        h.await.unwrap();
    }
    report("64 tasks INCR", fibers * per, t.elapsed().as_secs_f64());

    let t = Instant::now();
    let mut pipe = redis::pipe();
    for _ in 0..10_000 {
        pipe.cmd("INCR").arg("p");
    }
    let _: Vec<i64> = pipe.query_async(con).await?;
    report("10k pipeline INCR", 10_000, t.elapsed().as_secs_f64());

    Ok(())
}

async fn run_slice2(
    client: &redis::Client,
    con: &mut MultiplexedConnection,
) -> redis::RedisResult<()> {
    // 1. publish -> receive latency, one channel, sequential round trips.
    let n: usize = 10_000;
    let mut latencies: Vec<f64> = Vec::with_capacity(n);
    {
        let mut pubsub = client.get_async_pubsub().await?;
        pubsub.subscribe("bench").await?;
        let mut stream = pubsub.on_message();
        for i in 0..n {
            let t0 = Instant::now();
            let _: () = con.publish("bench", i.to_string()).await?;
            stream.next().await.unwrap();
            latencies.push(t0.elapsed().as_secs_f64() * 1e6);
        }
    }
    latencies.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!(
        "pubsub round trip: median {:.1} µs, p99 {:.1} µs",
        latencies[n / 2],
        latencies[n * 99 / 100]
    );

    // 2. subscriber throughput: 64 channels, 1M pipelined publishes.
    let total: usize = 1_000_000;
    let mut pubsub = client.get_async_pubsub().await?;
    for i in 0..64 {
        pubsub.subscribe(format!("c{}", i)).await?;
    }
    let handle = tokio::spawn(async move {
        let mut stream = pubsub.on_message();
        for _ in 0..total {
            stream.next().await.unwrap();
        }
    });
    let t = Instant::now();
    for _ in 0..(total / 10_000) {
        let mut pipe = redis::pipe();
        for j in 0..10_000 {
            pipe.cmd("PUBLISH").arg(format!("c{}", j % 64)).arg("m").ignore();
        }
        let _: () = pipe.query_async(&mut *con).await?;
    }
    handle.await.unwrap();
    report("subscriber throughput", total as u64, t.elapsed().as_secs_f64());

    // 3. MULTI/EXEC with 10 INCR vs the same 10 in a plain pipeline.
    let iters: u64 = 10_000;
    let t = Instant::now();
    for _ in 0..iters {
        let mut pipe = redis::pipe();
        for _ in 0..10 {
            pipe.cmd("INCR").arg("pl");
        }
        let _: Vec<i64> = pipe.query_async(&mut *con).await?;
    }
    report("pipeline 10 INCR", iters, t.elapsed().as_secs_f64());

    let t = Instant::now();
    for _ in 0..iters {
        let mut pipe = redis::pipe();
        pipe.atomic();
        for _ in 0..10 {
            pipe.cmd("INCR").arg("tx");
        }
        let _: Vec<i64> = pipe.query_async(&mut *con).await?;
    }
    report("multi 10 INCR", iters, t.elapsed().as_secs_f64());

    // 4. Script::invoke_async vs EVALSHA by hand.
    let script = redis::Script::new("return redis.call('INCR', KEYS[1])");
    let _: i64 = script.key("s").invoke_async(&mut *con).await?;
    let sha = script.get_hash().to_string();
    let n: u64 = 100_000;
    let t = Instant::now();
    for _ in 0..n {
        let _: i64 = redis::cmd("EVALSHA")
            .arg(&sha)
            .arg(1)
            .arg("s")
            .query_async(&mut *con)
            .await?;
    }
    report("evalsha by hand", n, t.elapsed().as_secs_f64());

    let t = Instant::now();
    for _ in 0..n {
        let _: i64 = script.key("s").invoke_async(&mut *con).await?;
    }
    report("run(script)", n, t.elapsed().as_secs_f64());

    Ok(())
}

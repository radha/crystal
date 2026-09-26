//! Rust (tokio-postgres) side of the PostgreSQL client benchmarks.
//!
//!   cargo build --release && target/release/bench_rs [seq|fetch|pool|all]
//!
//! Statements are prepared once per connection (`client.prepare` for the
//! single connection; `prepare_cached` on deadpool's `ClientWrapper` for
//! the pool). Runtime: tokio multi-thread, default worker count (= nproc).
use deadpool_postgres::{Config, ManagerConfig, PoolConfig, RecyclingMethod, Runtime};
use std::time::Instant;
use tokio_postgres::NoTls;

struct BenchRow {
    id: i64,
    #[allow(dead_code)]
    name: String,
    #[allow(dead_code)]
    score: f64,
    #[allow(dead_code)]
    at: chrono::DateTime<chrono::Utc>,
    #[allow(dead_code)]
    ok: bool,
}

fn url() -> String {
    std::env::var("PG_URL")
        .unwrap_or_else(|_| "postgres://postgres@127.0.0.1:5432/crystal_test?sslmode=disable".into())
}

async fn connect() -> tokio_postgres::Client {
    let (client, conn) = tokio_postgres::connect(&url(), NoTls).await.unwrap();
    tokio::spawn(async move {
        if let Err(e) = conn.await {
            eprintln!("connection error: {e}");
        }
    });
    client
}

async fn bench_seq() {
    let client = connect().await;
    let stmt = client.prepare("select $1::int4").await.unwrap();
    for i in 0..1000i32 {
        let _: i32 = client.query_one(&stmt, &[&i]).await.unwrap().get(0);
    }
    const N: usize = 20_000;
    let mut lat = Vec::with_capacity(N);
    let mut sum: i64 = 0;
    let start = Instant::now();
    for i in 0..N as i32 {
        let t0 = Instant::now();
        let v: i32 = client.query_one(&stmt, &[&i]).await.unwrap().get(0);
        lat.push(t0.elapsed().as_nanos() as f64 / 1000.0);
        sum += v as i64;
    }
    let total = start.elapsed().as_nanos() as f64 / 1000.0;
    assert_eq!(sum, (N as i64) * (N as i64 - 1) / 2);
    lat.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let pct = |p: f64| lat[((lat.len() - 1) as f64 * p).round() as usize];
    println!(
        "RESULT seq mean_us={:.2} p50_us={:.2} p99_us={:.2}",
        total / N as f64,
        pct(0.50),
        pct(0.99)
    );
}

async fn fetch_all(client: &tokio_postgres::Client, stmt: &tokio_postgres::Statement) -> Vec<BenchRow> {
    client
        .query(stmt, &[])
        .await
        .unwrap()
        .iter()
        .map(|r| BenchRow { id: r.get(0), name: r.get(1), score: r.get(2), at: r.get(3), ok: r.get(4) })
        .collect()
}

async fn bench_fetch() {
    let client = connect().await;
    let stmt = client.prepare("select id, name, score, at, ok from bench_rows").await.unwrap();
    for _ in 0..10 {
        fetch_all(&client, &stmt).await;
    }
    const ITERS: usize = 200;
    let mut rows = 0usize;
    let mut checksum = 0i64;
    let start = Instant::now();
    for _ in 0..ITERS {
        let list = fetch_all(&client, &stmt).await;
        rows += list.len();
        checksum = checksum.wrapping_add(list.last().unwrap().id);
    }
    let elapsed = start.elapsed().as_secs_f64();
    assert_eq!(rows, ITERS * 10_000);
    std::hint::black_box(checksum);
    println!(
        "RESULT fetch ms_per_fetch={:.3} rows_per_s={:.0}",
        elapsed * 1000.0 / ITERS as f64,
        rows as f64 / elapsed
    );
}

async fn bench_pool() {
    let mut cfg = Config::new();
    cfg.url = Some(url());
    cfg.manager = Some(ManagerConfig { recycling_method: RecyclingMethod::Fast });
    cfg.pool = Some(PoolConfig::new(8));
    let pool = cfg.create_pool(Some(Runtime::Tokio1), NoTls).unwrap();
    const TASKS: usize = 64;
    const PER: i32 = 2000;
    let run = |count: i32| {
        let pool = pool.clone();
        async move {
            let mut handles = Vec::with_capacity(TASKS);
            for _ in 0..TASKS {
                let pool = pool.clone();
                handles.push(tokio::spawn(async move {
                    for i in 0..count {
                        // checkout per query, like the Crystal and Go versions
                        let client = pool.get().await.unwrap();
                        let stmt = client.prepare_cached("select $1::int4").await.unwrap();
                        let _: i32 = client.query_one(&stmt, &[&i]).await.unwrap().get(0);
                    }
                }));
            }
            for h in handles {
                h.await.unwrap();
            }
        }
    };
    run(50).await; // warm-up: open all 8 connections, prepare on each
    let start = Instant::now();
    run(PER).await;
    let elapsed = start.elapsed().as_secs_f64();
    println!("RESULT pool ops_per_s={:.0}", (TASKS as f64 * PER as f64) / elapsed);
}

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    let mode = std::env::args().nth(1).unwrap_or_else(|| "all".into());
    match mode.as_str() {
        "seq" => bench_seq().await,
        "fetch" => bench_fetch().await,
        "pool" => bench_pool().await,
        "all" => {
            bench_seq().await;
            bench_fetch().await;
            bench_pool().await;
        }
        _ => {
            eprintln!("usage: bench_rs [seq|fetch|pool|all]");
            std::process::exit(2);
        }
    }
}

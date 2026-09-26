use binrw::{binrw, BinRead, BinWrite};
use std::io::Cursor;
use std::time::Instant;

#[binrw]
#[brw(big)]
#[derive(Clone, Debug, PartialEq)]
struct RpcHeader { r#type: u8, flags: u8, stream_id: u32, length: u32 }

#[binrw]
#[brw(big)]
#[derive(Clone, Debug, PartialEq)]
struct Column {
    #[bw(calc = value.as_ref().map(|v| v.len() as i32).unwrap_or(-1))]
    length: i32,
    #[br(if(length >= 0), count = length)]
    value: Option<Vec<u8>>,
}

#[binrw]
#[brw(big)]
#[derive(Clone, Debug, PartialEq)]
struct DataRow {
    #[bw(calc = b'D')]
    #[br(temp)]
    r#type: u8,
    #[bw(calc = 4 + 2 + columns.iter().map(|c| 4 + c.value.as_ref().map(|v| v.len()).unwrap_or(0)).sum::<usize>() as i32)]
    #[br(temp)]
    length: i32,
    #[bw(calc = columns.len() as i16)]
    #[br(temp)]
    count: i16,
    #[br(count = count)]
    columns: Vec<Column>,
}

fn bench<F: FnMut()>(name: &str, mut f: F) {
    let iters = 2_000_000u32;
    for _ in 0..200_000 { f(); }
    let t = Instant::now();
    for _ in 0..iters { f(); }
    let ns = t.elapsed().as_nanos() as f64 / iters as f64;
    println!("{name:24} {ns:8.1} ns/op");
}

fn main() {
    let header = RpcHeader { r#type: 1, flags: 2, stream_id: 3, length: 4 };
    let mut hb = Cursor::new(Vec::new());
    header.write(&mut hb).unwrap();
    let header_bytes = hb.into_inner();
    let row = DataRow { columns: (0..10).map(|i| Column { value: Some(format!("value-{i}").into_bytes()) }).collect() };
    let mut rb = Cursor::new(Vec::new());
    row.write(&mut rb).unwrap();
    let row_bytes = rb.into_inner();
    let mut out = Vec::with_capacity(4096);

    bench("header read", || { std::hint::black_box(RpcHeader::read(&mut Cursor::new(&header_bytes)).unwrap()); });
    bench("header write", || { out.clear(); header.write(&mut Cursor::new(&mut out)).unwrap(); });
    bench("datarow read", || { std::hint::black_box(DataRow::read(&mut Cursor::new(&row_bytes)).unwrap()); });
    bench("datarow write", || { out.clear(); row.write(&mut Cursor::new(&mut out)).unwrap(); });
}

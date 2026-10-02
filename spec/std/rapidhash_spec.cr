require "spec"
require "rapidhash"

# Known answers from the Rust `rapidhash` crate 4.5.1:
# `rapidhash_v3_seeded(data, &RapidSecrets::seed_cpp(seed))`.
private KAT_DATA = Bytes.new(5000) { |i| ((i * 31 + 7) & 0xff).to_u8 }

private KAT_BYTES = {
  {0_u64, 0, 0x0338dc4be2cecdae_u64},
  {0_u64, 1, 0x5c2caf7d68f06d3e_u64},
  {0_u64, 2, 0xae51663c7995f8f8_u64},
  {0_u64, 3, 0x3bd769fd1eeff68b_u64},
  {0_u64, 4, 0x94c4e44cba1be502_u64},
  {0_u64, 5, 0x20b60f776813eba8_u64},
  {0_u64, 6, 0x8e87031845d729dd_u64},
  {0_u64, 7, 0x3402f3bff7d5ef0f_u64},
  {0_u64, 8, 0xefd148285045d1f3_u64},
  {0_u64, 9, 0x2f8407ca55d0192d_u64},
  {0_u64, 10, 0x1d2ad8eb67c504e5_u64},
  {0_u64, 11, 0x66ba4468275946aa_u64},
  {0_u64, 12, 0x91fef7e79ee0fda3_u64},
  {0_u64, 13, 0x3e6a079d488b5b31_u64},
  {0_u64, 14, 0x6363d3ebe278b175_u64},
  {0_u64, 15, 0x94192c8d95e7a5a5_u64},
  {0_u64, 16, 0x0811971e7cf397ba_u64},
  {0_u64, 17, 0x6d84939d31572677_u64},
  {0_u64, 18, 0xfe2d714eb688e006_u64},
  {0_u64, 19, 0xf8b2070a9d3a1e73_u64},
  {0_u64, 20, 0xe4f443e74d5c7343_u64},
  {0_u64, 24, 0x34acc0ed95129db0_u64},
  {0_u64, 31, 0x8371afa501b0cd07_u64},
  {0_u64, 32, 0xba48299a836e97da_u64},
  {0_u64, 33, 0xaf3a3a115f66dba3_u64},
  {0_u64, 47, 0x92f8b21ca81775e0_u64},
  {0_u64, 48, 0xb647c688e65ab5d9_u64},
  {0_u64, 49, 0xeb24b4c29d6da81e_u64},
  {0_u64, 63, 0x610c8ac5ad5d4ea1_u64},
  {0_u64, 64, 0xecac72effb517b5d_u64},
  {0_u64, 65, 0x45f05f1baab30c17_u64},
  {0_u64, 79, 0xfd8017c88c212c90_u64},
  {0_u64, 80, 0x533c9fc90f0516dc_u64},
  {0_u64, 81, 0x0f7545b5c1c5b9c6_u64},
  {0_u64, 95, 0xbed1e95ed8160277_u64},
  {0_u64, 96, 0xe2fc8588a9bfb097_u64},
  {0_u64, 97, 0xc343800740e6176b_u64},
  {0_u64, 111, 0x251c6ba5b0f578fe_u64},
  {0_u64, 112, 0x7fe548224c71702a_u64},
  {0_u64, 113, 0xdd9a928d4d5f38be_u64},
  {0_u64, 127, 0x718572f1ab34ff72_u64},
  {0_u64, 128, 0xf0339dece659fbb5_u64},
  {0_u64, 200, 0x109243db406cd749_u64},
  {0_u64, 223, 0xbb29f3adef171013_u64},
  {0_u64, 224, 0xb58fdb872bdb4e42_u64},
  {0_u64, 225, 0x5e32d5a5f2c4ba73_u64},
  {0_u64, 226, 0x2fe7931d86795dd2_u64},
  {0_u64, 336, 0x2eea149f5778a279_u64},
  {0_u64, 337, 0x0bba5f54de8f59d2_u64},
  {0_u64, 447, 0xc723c0248be137e8_u64},
  {0_u64, 448, 0xd109b1f4abc5896d_u64},
  {0_u64, 449, 0x1f690da6b4c0f939_u64},
  {0_u64, 450, 0x5c6d411f6b777888_u64},
  {0_u64, 1000, 0xa43ecd1f34504ec6_u64},
  {0_u64, 4096, 0x23558a4c3b6f91f0_u64},
  {42_u64, 0, 0x9293ba21a570895d_u64},
  {42_u64, 1, 0xebbcdb8ddf67160a_u64},
  {42_u64, 2, 0xe7c5d6e1bcbf3fe3_u64},
  {42_u64, 3, 0x04b619bd239c92b9_u64},
  {42_u64, 4, 0xccfcf0a51d479646_u64},
  {42_u64, 5, 0xb30a4774331e4be2_u64},
  {42_u64, 6, 0x92cbca5d3a503f18_u64},
  {42_u64, 7, 0xaeb632549d7bca0a_u64},
  {42_u64, 8, 0x1735d73c4a51f9e4_u64},
  {42_u64, 9, 0xde9b7a856ad0d677_u64},
  {42_u64, 10, 0x1e8d31bc89ce4b5f_u64},
  {42_u64, 11, 0x8e55ed44ef0b6b87_u64},
  {42_u64, 12, 0x40029a9ec6078ebf_u64},
  {42_u64, 13, 0xba12c82eaca7dcb7_u64},
  {42_u64, 14, 0xab0ad493db970a63_u64},
  {42_u64, 15, 0x7e63738e22f69906_u64},
  {42_u64, 16, 0x0409a1d269cfe8f9_u64},
  {42_u64, 17, 0x85d1651923259815_u64},
  {42_u64, 18, 0x7561050c99ac37c4_u64},
  {42_u64, 19, 0xfeb8ffaa4b9d0f71_u64},
  {42_u64, 20, 0x92004093fe7eeea6_u64},
  {42_u64, 24, 0x44126bf5c281ad56_u64},
  {42_u64, 31, 0x917ba46c741f644e_u64},
  {42_u64, 32, 0x68ff5bdfcea6f19f_u64},
  {42_u64, 33, 0xcfb587cf91c50293_u64},
  {42_u64, 47, 0x25034273801fba34_u64},
  {42_u64, 48, 0xc82247789f391263_u64},
  {42_u64, 49, 0xe156d3e98f4cc7ff_u64},
  {42_u64, 63, 0x3520c646c5328a65_u64},
  {42_u64, 64, 0x1fc6f4d393bad17b_u64},
  {42_u64, 65, 0xb1a03b29bfcc05fd_u64},
  {42_u64, 79, 0xd146ac9d295a9cc4_u64},
  {42_u64, 80, 0xde53839bef4a37b9_u64},
  {42_u64, 81, 0x5332822376d678fd_u64},
  {42_u64, 95, 0x15f34342f9b0bdd1_u64},
  {42_u64, 96, 0xcd40a59a41e48a76_u64},
  {42_u64, 97, 0xeaed552f30c44b73_u64},
  {42_u64, 111, 0x9601121702ba2171_u64},
  {42_u64, 112, 0x468d259215df9c4b_u64},
  {42_u64, 113, 0x7c7c7516f388ea52_u64},
  {42_u64, 127, 0xc3de4cf6005c21b2_u64},
  {42_u64, 128, 0x070579f8813b6496_u64},
  {42_u64, 200, 0x4be9e81fc871d080_u64},
  {42_u64, 223, 0xb8b68199050a1f6a_u64},
  {42_u64, 224, 0xfebd145e9e4762a2_u64},
  {42_u64, 225, 0xe391de42dfe443ba_u64},
  {42_u64, 226, 0x048c231d63a31a28_u64},
  {42_u64, 336, 0x56fc059d85825ee9_u64},
  {42_u64, 337, 0x594dc411b9a8416e_u64},
  {42_u64, 447, 0x59bb4bace32212de_u64},
  {42_u64, 448, 0x3c2e0d6b2c633c4f_u64},
  {42_u64, 449, 0x06c45229d522df5b_u64},
  {42_u64, 450, 0x369253ea105986c3_u64},
  {42_u64, 1000, 0x11850fa955c7cdba_u64},
  {42_u64, 4096, 0xc77217c6175249ea_u64},
  {16045690984503098046_u64, 0, 0x06371798fffbc11f_u64},
  {16045690984503098046_u64, 1, 0x13eaabf87cad456c_u64},
  {16045690984503098046_u64, 2, 0x5d9a63e11bee9d76_u64},
  {16045690984503098046_u64, 3, 0x634dd715b3e18121_u64},
  {16045690984503098046_u64, 4, 0xfb14df62d0d7e5ef_u64},
  {16045690984503098046_u64, 5, 0x458a0edb81055e4f_u64},
  {16045690984503098046_u64, 6, 0xb483c304e9523446_u64},
  {16045690984503098046_u64, 7, 0xddde3b302bbcec3b_u64},
  {16045690984503098046_u64, 8, 0xa393504955f98abd_u64},
  {16045690984503098046_u64, 9, 0xf1bc881967067717_u64},
  {16045690984503098046_u64, 10, 0xcdc01eaf06cc1aa9_u64},
  {16045690984503098046_u64, 11, 0xc818d4802a9c8436_u64},
  {16045690984503098046_u64, 12, 0x427d52a4eaea4aa5_u64},
  {16045690984503098046_u64, 13, 0x77830da6619d442e_u64},
  {16045690984503098046_u64, 14, 0x1fc10de8c46d1e72_u64},
  {16045690984503098046_u64, 15, 0xb96da3eb536429f7_u64},
  {16045690984503098046_u64, 16, 0x28d3d72cfd3efb54_u64},
  {16045690984503098046_u64, 17, 0xbce132de48fec432_u64},
  {16045690984503098046_u64, 18, 0x819ffb96e6f45250_u64},
  {16045690984503098046_u64, 19, 0x77ca5df935874d67_u64},
  {16045690984503098046_u64, 20, 0xe3c058dac083eb00_u64},
  {16045690984503098046_u64, 24, 0x048186abd68785bb_u64},
  {16045690984503098046_u64, 31, 0x2e27afd9fe7c3ec5_u64},
  {16045690984503098046_u64, 32, 0xf36496f60daf3497_u64},
  {16045690984503098046_u64, 33, 0x6a2102796204981e_u64},
  {16045690984503098046_u64, 47, 0x8779c3a510646f82_u64},
  {16045690984503098046_u64, 48, 0xdae199d764d4a35f_u64},
  {16045690984503098046_u64, 49, 0x98fde1c4ec4d5140_u64},
  {16045690984503098046_u64, 63, 0x0a3f4de7e3059c56_u64},
  {16045690984503098046_u64, 64, 0x3058b528ccdf3f07_u64},
  {16045690984503098046_u64, 65, 0x4c36fcc8e1e1c8e2_u64},
  {16045690984503098046_u64, 79, 0xb5385aa42e558ccd_u64},
  {16045690984503098046_u64, 80, 0x46bda68eaf7570ea_u64},
  {16045690984503098046_u64, 81, 0xbfea82f804d13138_u64},
  {16045690984503098046_u64, 95, 0x6c358c642483ec77_u64},
  {16045690984503098046_u64, 96, 0xec5874d187dca71f_u64},
  {16045690984503098046_u64, 97, 0xa94e7c83dd1c0ea7_u64},
  {16045690984503098046_u64, 111, 0xda4c3962df3a5036_u64},
  {16045690984503098046_u64, 112, 0x594a6910ba0446d3_u64},
  {16045690984503098046_u64, 113, 0xa5c7d3bdfada7841_u64},
  {16045690984503098046_u64, 127, 0x18905b60065d1e94_u64},
  {16045690984503098046_u64, 128, 0x54131dbc662d0a75_u64},
  {16045690984503098046_u64, 200, 0xb99cd61ed3481349_u64},
  {16045690984503098046_u64, 223, 0x237f94ab8bea8062_u64},
  {16045690984503098046_u64, 224, 0x7c97f83e3635a395_u64},
  {16045690984503098046_u64, 225, 0xa09efef112fda9b3_u64},
  {16045690984503098046_u64, 226, 0x60f7335a6d1c19f1_u64},
  {16045690984503098046_u64, 336, 0xa5d1b2bf14eb41fe_u64},
  {16045690984503098046_u64, 337, 0x93b1e3b5c05e9acc_u64},
  {16045690984503098046_u64, 447, 0xfadc0ce8d2766a05_u64},
  {16045690984503098046_u64, 448, 0x3f133a4067cf7908_u64},
  {16045690984503098046_u64, 449, 0xb7f22b1202a5620d_u64},
  {16045690984503098046_u64, 450, 0xd8e1c67aaa206488_u64},
  {16045690984503098046_u64, 1000, 0xe63b55e3182685ae_u64},
  {16045690984503098046_u64, 4096, 0x68debd64c163f42e_u64},
}

private KAT_INTS = {
  {0_u64, 0_i128, 0xa4096b29990c1731_u64},
  {0_u64, 1_i128, 0xcd8fc3740225740b_u64},
  {0_u64, -1_i128, 0x176427935a1a5c21_u64},
  {0_u64, 42_i128, 0xdecf13b7e9bf1347_u64},
  {0_u64, 9223372036854775807_i128, 0x76ef00f13ea02098_u64},
  {0_u64, -9223372036854775808_i128, 0x8720562b005fce61_u64},
  {0_u64, 18446744073709551615_i128, 0x04b22198ba9e0d1e_u64},
  {42_u64, 0_i128, 0xb934b1c9c854424c_u64},
  {42_u64, 1_i128, 0x0629a3bfca7ccda2_u64},
  {42_u64, -1_i128, 0x7023136f14254840_u64},
  {42_u64, 42_i128, 0x895be931531e3ffa_u64},
  {42_u64, 9223372036854775807_i128, 0x25fd40d1710a9c4f_u64},
  {42_u64, -9223372036854775808_i128, 0xae6e367114655f02_u64},
  {42_u64, 18446744073709551615_i128, 0x1ae3904f625a4f2d_u64},
  {16045690984503098046_u64, 0_i128, 0xb9f26054df589542_u64},
  {16045690984503098046_u64, 1_i128, 0x27b7bbd63c258edf_u64},
  {16045690984503098046_u64, -1_i128, 0x7eb0c33f2ca0952c_u64},
  {16045690984503098046_u64, 42_i128, 0x441bb8324e1ecae8_u64},
  {16045690984503098046_u64, 9223372036854775807_i128, 0xcb8e08147383192f_u64},
  {16045690984503098046_u64, -9223372036854775808_i128, 0x9f66fe9ee9feafc7_u64},
  {16045690984503098046_u64, 18446744073709551615_i128, 0x5628d69e7746a166_u64},
}

private KAT_FLOATS = {
  {0_u64, 1.5, 0x76c9a8331385f98a_u64},
  {0_u64, 0.0, 0x9efc171aebcea1f3_u64},
  {0_u64, -2.25, 0xbc6bf2ad238caf86_u64},
  {42_u64, 1.5, 0xcf7b66859be5233f_u64},
  {42_u64, 0.0, 0x2d3f40fc0da4e68c_u64},
  {42_u64, -2.25, 0x36cad59f46ff0e1f_u64},
  {16045690984503098046_u64, 1.5, 0xca91507422fa779b_u64},
  {16045690984503098046_u64, 0.0, 0xf9c3700cdaf3b5ba_u64},
  {16045690984503098046_u64, -2.25, 0xd8ca900a7a243f1b_u64},
}

private KAT_STRINGS = {
  {0_u64, "", 0x0338dc4be2cecdae_u64},
  {0_u64, "a", 0x599f47df33a2e1eb_u64},
  {0_u64, "hello", 0x2e2d7651b45f7946_u64},
  {0_u64, "héllo wörld, ünïcode ✓", 0x07d2e66ece8ea5b1_u64},
  {42_u64, "", 0x9293ba21a570895d_u64},
  {42_u64, "a", 0x0c4b4535681ad65d_u64},
  {42_u64, "hello", 0x158d2d51c1f1576e_u64},
  {42_u64, "héllo wörld, ünïcode ✓", 0x6a49ebc97a858487_u64},
  {16045690984503098046_u64, "", 0x06371798fffbc11f_u64},
  {16045690984503098046_u64, "a", 0xabb06675d6592cc7_u64},
  {16045690984503098046_u64, "hello", 0x0d9efcf40b618387_u64},
  {16045690984503098046_u64, "héllo wörld, ünïcode ✓", 0xc3cda7a5c5593861_u64},
}

private KAT_NAN = {
                     0_u64 => 0x72b70d1f43833ccf_u64,
                    42_u64 => 0xa962f429a71e3fd2_u64,
  16045690984503098046_u64 => 0xa04fc2059e6c22e9_u64,
}

private KAT_UINT128_MAX = {
                     0_u64 => 0x176427935a1a5c21_u64,
                    42_u64 => 0x7023136f14254840_u64,
  16045690984503098046_u64 => 0x7eb0c33f2ca0952c_u64,
}

private struct Point
  def initialize(@x : Int32, @y : Int32)
  end

  def rapidhash(seed : UInt64) : UInt64
    Rapidhash.of_premixed(@x.to_i64 << 32 | @y.to_u32, seed)
  end
end

describe Rapidhash do
  describe ".v3" do
    it "matches the reference for every length class" do
      KAT_BYTES.each do |seed, size, expected|
        Rapidhash.v3(KAT_DATA[0, size], seed).should eq(expected), failure_message: "size #{size} seed #{seed}"
      end
    end

    it "matches the reference for strings" do
      KAT_STRINGS.each do |seed, string, expected|
        Rapidhash.v3(string, seed).should eq(expected)
        Rapidhash.v3(string.to_slice, seed).should eq(expected)
      end
    end

    it "defaults the seed to zero" do
      Rapidhash.v3("hello").should eq(Rapidhash.v3("hello", 0_u64))
    end

    it "reads unaligned input" do
      buffer = Bytes.new(300) { |i| (i &* 13).to_u8! }
      (0..7).each do |offset|
        [3, 7, 15, 16, 17, 100, 113, 250].each do |size|
          copy = Bytes.new(size)
          copy.copy_from(buffer[offset, size])
          Rapidhash.v3(buffer[offset, size]).should eq(Rapidhash.v3(copy))
        end
      end
    end
  end

  describe ".of" do
    it "hashes integers by value as 128-bit little-endian" do
      KAT_INTS.each do |seed, value, expected|
        Rapidhash.of(value, seed).should eq(expected)
        Rapidhash.of(value.to_i64, seed).should eq(expected) if Int64::MIN <= value <= Int64::MAX
        Rapidhash.of(value.to_u64, seed).should eq(expected) if 0 <= value <= UInt64::MAX
      end
      KAT_UINT128_MAX.each do |seed, expected|
        Rapidhash.of(UInt128::MAX, seed).should eq(expected)
      end
    end

    it "hashes every integer type of the same value alike" do
      [0, 1, 42, 127].each do |n|
        expected = Rapidhash.of(n)
        {n.to_i8, n.to_i16, n.to_i64, n.to_i128, n.to_u8, n.to_u16, n.to_u32, n.to_u64, n.to_u128}.each do |v|
          Rapidhash.of(v).should eq(expected)
        end
      end
      Rapidhash.of(-1_i8).should eq(Rapidhash.of(-1_i128))
      Rapidhash.of(255_u8).should_not eq(Rapidhash.of(-1_i8))
    end

    it "hashes floats by value" do
      KAT_FLOATS.each do |seed, value, expected|
        Rapidhash.of(value, seed).should eq(expected)
        Rapidhash.of(value.to_f32, seed).should eq(expected)
      end
      Rapidhash.of(-0.0).should eq(Rapidhash.of(0.0))
      Rapidhash.of(1.0).should_not eq(Rapidhash.of(1))
    end

    it "hashes every NaN alike" do
      KAT_NAN.each do |seed, expected|
        Rapidhash.of(Float64::NAN, seed).should eq(expected)
        Rapidhash.of(-Float64::NAN, seed).should eq(expected)
        Rapidhash.of(Float32::NAN, seed).should eq(expected)
      end
    end

    it "hashes strings, bytes and chars by their bytes" do
      Rapidhash.of("héllo").should eq(Rapidhash.v3("héllo"))
      Rapidhash.of("héllo".to_slice, 7_u64).should eq(Rapidhash.v3("héllo", 7_u64))
      Rapidhash.of('é').should eq(Rapidhash.v3("é"))
      Rapidhash.of('✓', 3_u64).should eq(Rapidhash.v3("✓", 3_u64))
    end

    it "calls a type's own rapidhash method" do
      Rapidhash.of(Point.new(1, 2)).should eq(Rapidhash.of(1_i64 << 32 | 2))
      Rapidhash.of(Point.new(1, 2)).should_not eq(Rapidhash.of(Point.new(2, 1)))
    end
  end
end

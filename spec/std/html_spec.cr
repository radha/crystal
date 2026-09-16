require "./spec_helper"
require "html"

describe "HTML" do
  describe ".escape" do
    it "does not change a safe string" do
      HTML.escape("safe_string").should eq("safe_string")
    end

    it "escapes dangerous characters from a string" do
      HTML.escape("< & > ' \"").should eq("&lt; &amp; &gt; &#39; &quot;")
    end

    it "returns the same string when nothing needs escaping" do
      string = "safe_string"
      HTML.escape(string).should be(string)
      HTML.escape("").should be_empty
    end

    it "escapes specials at the edges and adjacent to each other" do
      HTML.escape("&").should eq("&amp;")
      HTML.escape("<a>").should eq("&lt;a&gt;")
      HTML.escape("a<<b").should eq("a&lt;&lt;b")
      HTML.escape("\"'").should eq("&quot;&#39;")
    end

    it "preserves multibyte characters around escaped ones" do
      HTML.escape("ü<ß>€").should eq("ü&lt;ß&gt;€")
      HTML.escape("ü<ß>€").size.should eq(11)
      HTML.escape("日本語").should eq("日本語")
    end

    it "replaces invalid UTF-8 with U+FFFD like the char-based path did" do
      HTML.escape("\xff<\xfe").should eq("\uFFFD&lt;\uFFFD")
      HTML.escape("\xffab").should eq("\uFFFDab")
    end

    it "escapes to an IO and from bytes" do
      io = IO::Memory.new
      HTML.escape("ü<a>&'\"", io)
      io.to_s.should eq("ü&lt;a&gt;&amp;&#39;&quot;")

      io = IO::Memory.new
      HTML.escape("plain".to_slice, io)
      io.to_s.should eq("plain")

      io = IO::Memory.new
      HTML.escape("".to_slice, io)
      io.to_s.should eq("")
    end
  end

  pending_wasm32 describe: ".unescape" do
    it "identity" do
      HTML.unescape("safe_string").should be("safe_string")
    end

    it "empty entity" do
      HTML.unescape("foo&;bar").should eq "foo&;bar"
    end

    context "numeric entities" do
      it "decimal" do
        HTML.unescape("3 &#43; 2 &#00061 5 &#9;").should eq("3 + 2 = 5 \t")
      end

      it "hex" do
        HTML.unescape("&#x000033; &#x2B; 2 &#x0003D &#x000035; &#x9;").should eq("3 + 2 = 5 \t")
      end

      it "early termination" do
        HTML.unescape("&# &#x &#128;43 &#169f &#xa9").should eq "&# &#x €43 ©f ©"
      end

      it "ISO-8859-1 replacement" do
        HTML.unescape("&#x87;").should eq "‡"
      end

      it "does not unescape Char::MAX_CODEPOINT" do
        # U+10FFFF and U+10FFFE are noncharacter and are not replaced
        HTML.unescape("limit &#x10FFFF;").should eq("limit &#x10FFFF;")
        HTML.unescape("limit &#x10FFFE;").should eq("limit &#x10FFFE;")
        HTML.unescape("limit &#x10FFFD;").should eq("limit \u{10FFFD}")
      end

      it "does not unescape characters above Char::MAX_CODEPOINT" do
        HTML.unescape("limit &#x110000;").should eq("limit \uFFFD")
        HTML.unescape("limit &#1114112;").should eq("limit \uFFFD")
        HTML.unescape("limit &#x110000000000000;").should eq("limit \uFFFD")
      end

      it "ignores leading zeros" do
        HTML.unescape("&#0000000065;").should eq("A")
        HTML.unescape("&#x0000000065;").should eq("e")
      end

      it "space characters" do
        HTML.unescape("&#x0020;&#32;&#x0009;&#x000A;&#x000C;&#x0080;&#x009F;").should eq("  \t\n\f\u20AC\u0178")
      end

      it "does not escape non-space unicode control characters" do
        HTML.unescape("&#x0001;-&#x001F; &#x000D; &#x007F;&#x000;").should eq("&#x0001;-&#x001F; &#x000D; &#x007F;\uFFFD")
      end

      it "does not escape noncharacter codepoints" do
        # noncharacters http://www.unicode.org/faq/private_use.html
        string = "&#xFDD0;-&#xFDEF; &#xFFFE; &#FFFF; &#x1FFFE; &#x1FFFF; &#x2FFFE; &#x10FFFF;"
        HTML.unescape(string).should eq(string)
      end

      it "does not escape unicode surrogate characters" do
        HTML.unescape("&#xD800;-&#xDFFF;").should eq("\uFFFD-\uFFFD")
      end
    end

    context "named entities" do
      it "simple named entities" do
        HTML.unescape("&lt; &amp; &gt;").should eq("< & >")
        HTML.unescape("nbsp&nbsp;space ").should eq("nbsp\u{0000A0}space ")
      end

      it "without trailing semicolon" do
        HTML.unescape("&amphello").should eq("&hello")
      end

      it "end of string" do
        HTML.unescape("&amp; &amp").should eq("& &")
      end

      it "multi codepoint" do
        HTML.unescape(" &NotSquareSuperset; ").should eq(" ⊐̸ ")
      end

      it "invalid entities" do
        HTML.unescape("&&lt;&amp&gt;&quot&abcdefghijklmn &ThisIsNotAnEntity;").should eq("&<&>\"&abcdefghijklmn &ThisIsNotAnEntity;")
      end

      it "entity with numerical characters" do
        HTML.unescape("&frac34;").should eq("\u00BE")
      end
    end

    it "unescapes javascript example from a string" do
      HTML.unescape("&lt;script&gt;alert&#40;&#39;You are being hacked&#39;&#41;&lt;/script&gt;").should eq("<script>alert('You are being hacked')</script>")
    end

    it "invalid utf-8" do
      HTML.unescape("test \xff\xfe").should eq "test \xff\xfe"
    end
  end
end

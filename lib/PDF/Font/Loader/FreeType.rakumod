class PDF::Font::Loader::FreeType {
    use PDF::COS;
    use PDF::COS::Name;
    use PDF::COS::Stream;
    use PDF::IO::Blob;
    use PDF::IO::Util :pack;
    use PDF::Writer;
    use NativeCall;
    use PDF::Font::Loader::Enc::CMap;
    use PDF::Font::Loader::Enc::Identity;
    use PDF::Font::Loader::Enc::Identity-H;
    use PDF::Font::Loader::Enc::Type1;
    use Font::FreeType:ver(v0.3.0+);
    use Font::FreeType::Face;
    use Font::FreeType::Error;
    use Font::FreeType::Raw;
    use Font::FreeType::Raw::Defs;
    use PDF::Content:ver(v0.2.3+);
    use PDF::Content::Font;

    constant Px = 64.0;

    has Font::FreeType::Face $.face is required;
    use PDF::Font::Loader::Enc;
    has PDF::Font::Loader::Enc $!encoder handles <decode>;
    has $.font-stream is required;
    has PDF::Content::Font $!dict;
    has uint $.first-char;
    has uint $.last-char;
    has uint16 @!widths;
    method widths is rw { @!widths }
    my subset EncodingScheme where 'mac'|'win'|'zapf'|'sym'|'identity'|'identity-h'|'identity-v'|'std';
    has EncodingScheme $!enc;
    has Bool $.embed = True;

    submethod TWEAK(:@differences,
                    :$widths,
                    PDF::COS::Stream :$cmap,
                    Str :$!enc = self!font-format eq 'Type1' || ! $!embed || $!face.num-glyphs <= 255
            ?? 'win'
            !! 'identity-h') {
        if $!enc ~~ 'identity'|'identity-h'|'identity-v' {
            die "can't use $!enc encoding with type-1 fonts"
                if self!font-format eq 'Type1';
            die "can't use $!enc encoding with unembedded fonts"
                unless $!embed;
        }

        $!encoder = do {
            when $cmap.defined
                        { PDF::Font::Loader::Enc::CMap.new: :$cmap, :$!face }
            when $!enc eq 'identity'
                        { PDF::Font::Loader::Enc::Identity.new: :$!face }
            when $!enc ~~ 'identity-h'|'identity-v'
                        { PDF::Font::Loader::Enc::Identity-H.new: :$!face }
            default     { PDF::Font::Loader::Enc::Type1.new: :$!enc, :$!face; }
        }

        $!encoder.differences = @differences
            if @differences;

        @!widths = .map(*.Int) with $widths;
    }

    method height($pointsize = 1000, Bool :$from-baseline, Bool :$hanging) {
        die "todo: height of non-scaling fonts" unless $!face.is-scalable;
        my List $bbox = $!face.bounding-box.Array;
        my Numeric $height = $hanging ?? $!face.ascender !! $bbox[3];
        $height -= $hanging ?? $!face.descender !! $bbox[1]
            unless $from-baseline;
        $height * $pointsize / $!face.units-per-EM;
    }

    method encode(Str $text, :$str) {
        my $encoded := $!encoder.encode($text);
        if $encoded {
            my $to-unicode := $!encoder.to-unicode;
            my uint16 $min = $encoded.min;
            my uint16 $max = $encoded.max;
            $!first-char = $min if !$!first-char || $min < $!first-char;
            $!last-char = $max if !$!last-char || $max > $!last-char;
            for $encoded.list {
                @!widths[$_] ||= $.stringwidth($to-unicode[$_].chr).round;
            }
        }

        # 16 bit encoding. convert to bytes
        $encoded := pack($encoded, 16)
            if $encoded.of ~~ uint16;

        $str
            ?? $encoded.decode('latin-1')
            !! $encoded;
    }

    my subset FontFormat of Str where 'TrueType'|'OpenType'|'Type1';
    method !font-format returns FontFormat {
        given $!face.font-format {
            when 'CFF'|'TrueType' { 'TrueType' }
            when 'Type 1' { 'Type1' }
            default { die "unsupported font format: $_" }
        }
    }

      method !font-file-entry {
        given self!font-format {
            when 'TrueType' { 'FontFile2' }
            when 'OpenType' { 'FontFile3' }
            default { 'FontFile' }
        }
    }

    method font-name {
        $!face.postscript-name
    }

    method !font-file {
        my  $decoded = do with $!font-stream {
            PDF::IO::Blob.new: $_;
        }
        else {
            die "can't embed font without a font stream";
        }

        my %dict = :Length1($!font-stream.bytes);
        %dict<Filter> = :name<FlateDecode>
            unless self!font-format eq 'Type1';
        %dict<Subtype> = :name<CIDFontType0C>
            unless self!font-format eq 'TrueType';

        PDF::COS.coerce: :stream{ :$decoded, :%dict, };
    }

    sub bit(\n) { 1 +< (n-1) }
    my enum Flags «
        :FixedPitch(bit(1))
        :Serif(bit(2))
        :Symbolic(bit(3))
        :Script(bit(4))
        :Nonsymbolic(bit(6))
        :Italic(bit(7))
        :AllCap(bit(17))
        :SmallCap(bit(18))
        :ForceBold(bit(19))
        »;

    method !font-descriptor {
        my Numeric $Ascent = $!face.ascender;
        my Numeric $Descent = $!face.descender;
        my PDF::COS::Name $FontName = PDF::COS.coerce: :name($.font-name);
        my Str $FontFamily = $!face.family-name;
        my Numeric @FontBBox[4] = $!face.bounding-box.Array;
        my UInt $Flags;
        $Flags +|= FixedPitch if $!face.is-fixed-width;
        $Flags +|= Italic if $!face.is-italic;
        my Numeric $CapHeight = (self!char-height( 'X'.ord) || $Ascent * 0.9).round;
        my Numeric $XHeight   = (self!char-height( 'x'.ord) || $Ascent * 0.7).round;
        # estimates for required fields
        my Numeric $ItalicAngle = $!face.is-italic ?? -12 !! 0;
        my Numeric $StemV = $!face.is-bold ?? 110 !! 80;

        my $dict = {
            :Type( :name<FontDescriptor> ),
            :$FontName, :$FontFamily, :$Flags,
            :$Ascent, :$Descent, :@FontBBox,
            :$ItalicAngle, :$StemV, :$CapHeight, :$XHeight,
        };
        $dict{self!font-file-entry} = self!font-file
            if $!embed;
        $dict;
    }

    method !encoding-name {
        my %enc-name = :win<WinAnsiEncoding>, :mac<MacRomanEncoding>, :identity-h<Identity-H>;
        with %enc-name{$!enc} -> $name {
            :$name;
        }
    }

    method !make-roman-dict {
        my $FontDescriptor = self!font-descriptor;
        my $BaseFont = $FontDescriptor<FontName>;
        my $Encoding = self!encoding-name;
        $FontDescriptor<Flags> +|= Nonsymbolic;
        {
            :Type( :name<Font> ), :Subtype( :name(self!font-format) ),
            :$BaseFont,
            :$Encoding,
            :$FontDescriptor,
        };
    }

    method !make-unicode-cmap {
        my $CMapName = :name('p6-cmap-' ~ $.font-name);
        my $dict = {
            :Type( :name<CMap> ),
            :$CMapName,
            :CIDSystemInfo{
                :Ordering<Identity>,
                :Registry($.font-name),
                :Supplement(0),
            },
        };

        my $to-unicode := $!encoder.to-unicode;
        my @cmap-char;
        my @cmap-range;

        loop (my uint16 $cid = $!first-char; $cid <= $!last-char; $cid++) {
            my uint32 $char-code = $to-unicode[$cid]
              || next;
            my uint16 $start-cid = $cid;
            my uint32 $start-code = $char-code;
            while $cid < $!last-char && $to-unicode[$cid + 1] == $char-code+1 {
                $cid++; $char-code++;
            }
            if $start-cid == $cid {
                @cmap-char.push: '<%04X> <%04X>'.sprintf($cid, $start-code);
            }
            else {
                @cmap-range.push: '<%04X> <%04X> <%04X>'.sprintf($start-cid, $cid, $start-code);
            }
        }

        if @cmap-char {
            @cmap-char.unshift: "{+@cmap-char} beginbfchar";
            @cmap-char.push: 'endbfchar';
        }

        if @cmap-range {
            @cmap-range.unshift: "{+@cmap-range} beginbfrange";
            @cmap-range.push: 'endbfrange';
        }

        my PDF::Writer $writer .= new;
        my $cmap-name = $writer.write: $CMapName;
        my $postscript-name = $writer.write: :literal($.font-name);

        my $decoded = qq:to<--END-->.chomp;
            %% Custom
            %% CMap
            %%
            /CIDInit /ProcSet findresource begin
            12 dict begin begincmap
            /CIDSystemInfo <<
               /Registry $postscript-name
               /Ordering (XYZ)
               /Supplement 0
            >> def
            /CMapName $cmap-name def
            1 begincodespacerange <{$!first-char.fmt("%04x")}> <{$!last-char.fmt("%04x")}> endcodespacerange
            {@cmap-char.join: "\n"}
            {@cmap-range.join: "\n"}
            endcmap CMapName currendict /CMap defineresource pop end end
            --END--

        PDF::COS.coerce: :stream{ :$dict, :$decoded };
    }

    method !make-index-dict {
        my $FontDescriptor = self!font-descriptor;
        my $BaseFont = $FontDescriptor<FontName>;
        $FontDescriptor<Flags> +|= Symbolic;
        my $Subtype = :name( given self!font-format {
            when 'Type1'    {'Type1'}
            when 'TrueType' {'CIDFontType2'}
            default { 'CIDFontType0' }
        });

        my $DescendantFonts = [
            :dict{
                :Type( :name<Font> ),
                :$Subtype,
                :$BaseFont,
                :CIDToGIDMap( :name<Identity> ),
                :CIDSystemInfo{
                    :Ordering<Identity>,
                      :Registry<Adobe>,
                      :Supplement(0),
                  },
                  :$FontDescriptor,
            }, ];

        my $name = $!enc eq 'identity-v' ?? 'Identity-V' !! 'Identity-H';
        { :Type( :name<Font> ), :Subtype( :name<Type0> ),
            :$BaseFont,
            :$DescendantFonts,
            :Encoding( :$name ),
        };
    }

    method !make-dict {
        $!enc ~~ 'identity-h'|'indentity-v'
          ?? self!make-index-dict
          !! self!make-roman-dict
      }

    method to-dict {
        $!dict //= PDF::Content::Font.make-font(
            PDF::COS::Dict.coerce(self!make-dict),
            self);
    }

    method stringwidth(Str $text is copy, Numeric $pointsize?, Bool :$kern) {
        my FT_Pos $x = 0;
        my FT_Pos $y = 0;
        my FT_UInt $prev-idx = 0;
        my FT_Vector $kerning .= new;
        my $struct = $!face.raw;
        my $glyph-slot = $struct.glyph;
        my Numeric $stringwidth = 0;
        my $scale = 1000 / ($!face.units-per-EM || 1000);

        for $text.ords -> $char-code {
            my FT_UInt $this-idx = $struct.FT_Get_Char_Index( $char-code );
            if $this-idx {
                CATCH {
                    when Font::FreeType::Error { warn "error processing char $char-code: " ~ .message; }
                }
                ft-try({ $struct.FT_Load_Glyph( $this-idx, FT_LOAD_NO_SCALE ); });
                $stringwidth += $glyph-slot.metrics.hori-advance * $scale;
                if $kern && $prev-idx {
                    ft-try({ $struct.FT_Get_Kerning($prev-idx, $this-idx, FT_KERNING_UNSCALED, $kerning); });
                    my $dx := ($kerning.x * $scale).round;
                    $stringwidth += $dx;
                }
            }
            $prev-idx = $this-idx;
        }
        $stringwidth = $stringwidth.round;
        $stringwidth *= $_ / 1000 with $pointsize;
        $stringwidth;
    }

    method !char-height(UInt $char-code) {
        my $face-struct = $!face.raw;
        my $glyph-slot = $face-struct.glyph;
        my $scale = 1000 / ($!face.units-per-EM || 1000);
        my FT_UInt $idx = $face-struct.FT_Get_Char_Index( $char-code );
        if $idx {
            ft-try({ $face-struct.FT_Load_Glyph( $idx, FT_LOAD_NO_SCALE); });
            $glyph-slot.metrics.height * $scale;
        }
        else {
            0
        }
    }

    method kern(Str $text) {
        my FT_UInt      $prev-idx = 0;
        my Bool         $has-kerning = $!face.has-kerning;
        my FT_Vector    $kerning .= new;
        my FT_Face      $face-struct = $!face.raw;
        my FT_GlyphSlot $glyph-slot = $face-struct.glyph;
        my Str          $str = '';
        my Numeric      $stringwidth = 0.0;
        my @chunks;
        my $scale = 1000 / $!face.units-per-EM;

        for $text.ords -> $char-code {
            my FT_UInt $this-idx = $face-struct.FT_Get_Char_Index( $char-code );
            if $this-idx {
                ft-try({ $face-struct.FT_Load_Glyph( $this-idx, FT_LOAD_NO_SCALE); });
                $stringwidth += $glyph-slot.metrics.hori-advance * $scale;
                if $has-kerning && $prev-idx {
                    ft-try({ $face-struct.FT_Get_Kerning($prev-idx, $this-idx, FT_KERNING_UNSCALED, $kerning); });
                    my $dx := ($kerning.x * $scale).round;
                    if $dx {
                        @chunks.push: $str;
                        @chunks.push: $dx;
                        $stringwidth += $dx;
                        $str = '';
                    }
                }
                $str ~= $char-code.chr;
                $prev-idx = $this-idx;
            }
        }

        @chunks.push: $str
            if $str.chars;

        @chunks, $stringwidth.round;
    }

    method cb-finish {
        given $!enc {
            when 'identity-h' {
                my @Widths;
                my uint $j = -2;
                my $chars = [];
                loop (my uint16 $i = $!first-char; $i <= $!last-char; $i++) {
                    my uint $w = @!widths[$i];
                    if $w {
                        if ++$j == $i {
                            $chars.push: $w;
                        }
                        else {
                            $chars = $w.Array;
                            $j = $i;
                            @Widths.append: ($i, $chars);
                        }
                    }
                }
                $.to-dict<DescendantFonts>[0]<W> = @Widths;
                $.to-dict<ToUnicode> = self!make-unicode-cmap;
            }
            default {
                given $.to-dict {
                    if $!first-char.defined {
                        .<FirstChar> = $!first-char;
                        .<LastChar> = $!last-char;
                        .<Widths> = @!widths[$!first-char .. $!last-char];
                    }
                    else {
                        warn "Font embedded, but not used: $.font-name";
                    }

                    my $Differences = $!encoder.differences;
                    if $Differences {
                        .<Encoding> = %(
                            :Type( :name<Encoding> ),
                            :BaseEncoding(self!encoding-name),
                            :$Differences,
                           );
                    }
                }
            }
        }
    }
}
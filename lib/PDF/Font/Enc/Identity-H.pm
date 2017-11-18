class PDF::Font::Enc::Identity-H {

    use Font::FreeType::Face;
    use Font::FreeType::Native::Types;
    use PDF::DAO;

    has Font::FreeType::Face $.face is required;
    has uint32 @!to-unicode;

    multi method encode(Str $text, :$str! --> Str) {
        my $hex-string = self.encode($text).decode: 'latin-1';
        PDF::DAO.coerce: :$hex-string;
    }
    multi method encode(Str $text --> buf8) is default {
        my uint8 @codes;
        my $face-struct = $!face.struct;
        for $text.ords {
            my uint $index = $face-struct.FT_Get_Char_Index($_);
            @!to-unicode[$index] ||= $_;
            @codes.push: $index div 256;
            @codes.push: $index mod 256;
        }
        buf8.new: @codes;
    }

      method !setup-decoding {
          my $struct = $!face.struct;
          my FT_UInt $glyph-idx;
          my FT_ULong $char-code = $struct.FT_Get_First_Char( $glyph-idx);
          while $glyph-idx {
              @!to-unicode[ $glyph-idx ] = $char-code;
              $char-code = $struct.FT_Get_Next_Char( $char-code, $glyph-idx);
          }
    }

    method to-unicode {
        state $ = self!setup-decoding;
        @!to-unicode;
    }

    multi method decode(Str $encoded, :$str! --> Str) {
        my @to-unicode := self.to-unicode;
        $encoded.ords.map( -> \hi, \lo {@to-unicode[hi +< 8 + lo]}).grep({$_}).map({.chr}).join;
    }
    multi method decode(Str $encoded --> buf32) {
        my @to-unicode := self.to-unicode;
        buf32.new: $encoded.ords.map( -> \hi, \lo {@to-unicode[hi +< 8 + lo]}).grep: {$_};
    }

}
// Transcribed from the Unicode Character Database, `Blocks-17.0.0.txt`, dated 2025-08-01.
// Verify any line against https://www.unicode.org/Public/17.0.0/ucd/Blocks.txt

/// Every Unicode 17 block, less the six that cannot be generated from.
///
/// Blocks rather than assigned code points. A set derived from what the host considers assigned moves whenever the host's Unicode version does, and scalars are addressed by flat index, so a recorded replay seed would name a different character on a different machine. Block boundaries are fixed, so a host that only knows Unicode 16 draws unassigned code points where 17 has characters and every index stays where it is.
///
/// Drawing unassigned scalars is deliberate. They are valid input, and code that assumes every scalar has a name or a category breaks on them.
///
/// Three kinds of code point are absent because no caller can receive them. The three surrogate blocks are not `Unicode.Scalar`s. The three private use blocks have no meaning to agree on. The 66 noncharacters are carved out of the blocks that would otherwise contain them, which is why Arabic Presentation Forms-A appears twice and Specials stops at U+FFFD.
///
/// Named for the version so a later `unicode18ScalarRanges` can sit beside this one rather than replace it. Adopting a new version has to be the caller's choice: it moves every index above the first new block, and recorded replay seeds with it.
let unicode17ScalarRanges: [ClosedRange<UInt32>] = [
    0x00000 ... 0x0007F, // Basic Latin
    0x00080 ... 0x000FF, // Latin-1 Supplement
    0x00100 ... 0x0017F, // Latin Extended-A
    0x00180 ... 0x0024F, // Latin Extended-B
    0x00250 ... 0x002AF, // IPA Extensions
    0x002B0 ... 0x002FF, // Spacing Modifier Letters
    0x00300 ... 0x0036F, // Combining Diacritical Marks
    0x00370 ... 0x003FF, // Greek and Coptic
    0x00400 ... 0x004FF, // Cyrillic
    0x00500 ... 0x0052F, // Cyrillic Supplement
    0x00530 ... 0x0058F, // Armenian
    0x00590 ... 0x005FF, // Hebrew
    0x00600 ... 0x006FF, // Arabic
    0x00700 ... 0x0074F, // Syriac
    0x00750 ... 0x0077F, // Arabic Supplement
    0x00780 ... 0x007BF, // Thaana
    0x007C0 ... 0x007FF, // NKo
    0x00800 ... 0x0083F, // Samaritan
    0x00840 ... 0x0085F, // Mandaic
    0x00860 ... 0x0086F, // Syriac Supplement
    0x00870 ... 0x0089F, // Arabic Extended-B
    0x008A0 ... 0x008FF, // Arabic Extended-A
    0x00900 ... 0x0097F, // Devanagari
    0x00980 ... 0x009FF, // Bengali
    0x00A00 ... 0x00A7F, // Gurmukhi
    0x00A80 ... 0x00AFF, // Gujarati
    0x00B00 ... 0x00B7F, // Oriya
    0x00B80 ... 0x00BFF, // Tamil
    0x00C00 ... 0x00C7F, // Telugu
    0x00C80 ... 0x00CFF, // Kannada
    0x00D00 ... 0x00D7F, // Malayalam
    0x00D80 ... 0x00DFF, // Sinhala
    0x00E00 ... 0x00E7F, // Thai
    0x00E80 ... 0x00EFF, // Lao
    0x00F00 ... 0x00FFF, // Tibetan
    0x01000 ... 0x0109F, // Myanmar
    0x010A0 ... 0x010FF, // Georgian
    0x01100 ... 0x011FF, // Hangul Jamo
    0x01200 ... 0x0137F, // Ethiopic
    0x01380 ... 0x0139F, // Ethiopic Supplement
    0x013A0 ... 0x013FF, // Cherokee
    0x01400 ... 0x0167F, // Unified Canadian Aboriginal Syllabics
    0x01680 ... 0x0169F, // Ogham
    0x016A0 ... 0x016FF, // Runic
    0x01700 ... 0x0171F, // Tagalog
    0x01720 ... 0x0173F, // Hanunoo
    0x01740 ... 0x0175F, // Buhid
    0x01760 ... 0x0177F, // Tagbanwa
    0x01780 ... 0x017FF, // Khmer
    0x01800 ... 0x018AF, // Mongolian
    0x018B0 ... 0x018FF, // Unified Canadian Aboriginal Syllabics Extended
    0x01900 ... 0x0194F, // Limbu
    0x01950 ... 0x0197F, // Tai Le
    0x01980 ... 0x019DF, // New Tai Lue
    0x019E0 ... 0x019FF, // Khmer Symbols
    0x01A00 ... 0x01A1F, // Buginese
    0x01A20 ... 0x01AAF, // Tai Tham
    0x01AB0 ... 0x01AFF, // Combining Diacritical Marks Extended
    0x01B00 ... 0x01B7F, // Balinese
    0x01B80 ... 0x01BBF, // Sundanese
    0x01BC0 ... 0x01BFF, // Batak
    0x01C00 ... 0x01C4F, // Lepcha
    0x01C50 ... 0x01C7F, // Ol Chiki
    0x01C80 ... 0x01C8F, // Cyrillic Extended-C
    0x01C90 ... 0x01CBF, // Georgian Extended
    0x01CC0 ... 0x01CCF, // Sundanese Supplement
    0x01CD0 ... 0x01CFF, // Vedic Extensions
    0x01D00 ... 0x01D7F, // Phonetic Extensions
    0x01D80 ... 0x01DBF, // Phonetic Extensions Supplement
    0x01DC0 ... 0x01DFF, // Combining Diacritical Marks Supplement
    0x01E00 ... 0x01EFF, // Latin Extended Additional
    0x01F00 ... 0x01FFF, // Greek Extended
    0x02000 ... 0x0206F, // General Punctuation
    0x02070 ... 0x0209F, // Superscripts and Subscripts
    0x020A0 ... 0x020CF, // Currency Symbols
    0x020D0 ... 0x020FF, // Combining Diacritical Marks for Symbols
    0x02100 ... 0x0214F, // Letterlike Symbols
    0x02150 ... 0x0218F, // Number Forms
    0x02190 ... 0x021FF, // Arrows
    0x02200 ... 0x022FF, // Mathematical Operators
    0x02300 ... 0x023FF, // Miscellaneous Technical
    0x02400 ... 0x0243F, // Control Pictures
    0x02440 ... 0x0245F, // Optical Character Recognition
    0x02460 ... 0x024FF, // Enclosed Alphanumerics
    0x02500 ... 0x0257F, // Box Drawing
    0x02580 ... 0x0259F, // Block Elements
    0x025A0 ... 0x025FF, // Geometric Shapes
    0x02600 ... 0x026FF, // Miscellaneous Symbols
    0x02700 ... 0x027BF, // Dingbats
    0x027C0 ... 0x027EF, // Miscellaneous Mathematical Symbols-A
    0x027F0 ... 0x027FF, // Supplemental Arrows-A
    0x02800 ... 0x028FF, // Braille Patterns
    0x02900 ... 0x0297F, // Supplemental Arrows-B
    0x02980 ... 0x029FF, // Miscellaneous Mathematical Symbols-B
    0x02A00 ... 0x02AFF, // Supplemental Mathematical Operators
    0x02B00 ... 0x02BFF, // Miscellaneous Symbols and Arrows
    0x02C00 ... 0x02C5F, // Glagolitic
    0x02C60 ... 0x02C7F, // Latin Extended-C
    0x02C80 ... 0x02CFF, // Coptic
    0x02D00 ... 0x02D2F, // Georgian Supplement
    0x02D30 ... 0x02D7F, // Tifinagh
    0x02D80 ... 0x02DDF, // Ethiopic Extended
    0x02DE0 ... 0x02DFF, // Cyrillic Extended-A
    0x02E00 ... 0x02E7F, // Supplemental Punctuation
    0x02E80 ... 0x02EFF, // CJK Radicals Supplement
    0x02F00 ... 0x02FDF, // Kangxi Radicals
    0x02FF0 ... 0x02FFF, // Ideographic Description Characters
    0x03000 ... 0x0303F, // CJK Symbols and Punctuation
    0x03040 ... 0x0309F, // Hiragana
    0x030A0 ... 0x030FF, // Katakana
    0x03100 ... 0x0312F, // Bopomofo
    0x03130 ... 0x0318F, // Hangul Compatibility Jamo
    0x03190 ... 0x0319F, // Kanbun
    0x031A0 ... 0x031BF, // Bopomofo Extended
    0x031C0 ... 0x031EF, // CJK Strokes
    0x031F0 ... 0x031FF, // Katakana Phonetic Extensions
    0x03200 ... 0x032FF, // Enclosed CJK Letters and Months
    0x03300 ... 0x033FF, // CJK Compatibility
    0x03400 ... 0x04DBF, // CJK Unified Ideographs Extension A
    0x04DC0 ... 0x04DFF, // Yijing Hexagram Symbols
    0x04E00 ... 0x09FFF, // CJK Unified Ideographs
    0x0A000 ... 0x0A48F, // Yi Syllables
    0x0A490 ... 0x0A4CF, // Yi Radicals
    0x0A4D0 ... 0x0A4FF, // Lisu
    0x0A500 ... 0x0A63F, // Vai
    0x0A640 ... 0x0A69F, // Cyrillic Extended-B
    0x0A6A0 ... 0x0A6FF, // Bamum
    0x0A700 ... 0x0A71F, // Modifier Tone Letters
    0x0A720 ... 0x0A7FF, // Latin Extended-D
    0x0A800 ... 0x0A82F, // Syloti Nagri
    0x0A830 ... 0x0A83F, // Common Indic Number Forms
    0x0A840 ... 0x0A87F, // Phags-pa
    0x0A880 ... 0x0A8DF, // Saurashtra
    0x0A8E0 ... 0x0A8FF, // Devanagari Extended
    0x0A900 ... 0x0A92F, // Kayah Li
    0x0A930 ... 0x0A95F, // Rejang
    0x0A960 ... 0x0A97F, // Hangul Jamo Extended-A
    0x0A980 ... 0x0A9DF, // Javanese
    0x0A9E0 ... 0x0A9FF, // Myanmar Extended-B
    0x0AA00 ... 0x0AA5F, // Cham
    0x0AA60 ... 0x0AA7F, // Myanmar Extended-A
    0x0AA80 ... 0x0AADF, // Tai Viet
    0x0AAE0 ... 0x0AAFF, // Meetei Mayek Extensions
    0x0AB00 ... 0x0AB2F, // Ethiopic Extended-A
    0x0AB30 ... 0x0AB6F, // Latin Extended-E
    0x0AB70 ... 0x0ABBF, // Cherokee Supplement
    0x0ABC0 ... 0x0ABFF, // Meetei Mayek
    0x0AC00 ... 0x0D7AF, // Hangul Syllables
    0x0D7B0 ... 0x0D7FF, // Hangul Jamo Extended-B
    0x0F900 ... 0x0FAFF, // CJK Compatibility Ideographs
    0x0FB00 ... 0x0FB4F, // Alphabetic Presentation Forms
    0x0FB50 ... 0x0FDCF, // Arabic Presentation Forms-A
    0x0FDF0 ... 0x0FDFF, // Arabic Presentation Forms-A
    0x0FE00 ... 0x0FE0F, // Variation Selectors
    0x0FE10 ... 0x0FE1F, // Vertical Forms
    0x0FE20 ... 0x0FE2F, // Combining Half Marks
    0x0FE30 ... 0x0FE4F, // CJK Compatibility Forms
    0x0FE50 ... 0x0FE6F, // Small Form Variants
    0x0FE70 ... 0x0FEFF, // Arabic Presentation Forms-B
    0x0FF00 ... 0x0FFEF, // Halfwidth and Fullwidth Forms
    0x0FFF0 ... 0x0FFFD, // Specials
    0x10000 ... 0x1007F, // Linear B Syllabary
    0x10080 ... 0x100FF, // Linear B Ideograms
    0x10100 ... 0x1013F, // Aegean Numbers
    0x10140 ... 0x1018F, // Ancient Greek Numbers
    0x10190 ... 0x101CF, // Ancient Symbols
    0x101D0 ... 0x101FF, // Phaistos Disc
    0x10280 ... 0x1029F, // Lycian
    0x102A0 ... 0x102DF, // Carian
    0x102E0 ... 0x102FF, // Coptic Epact Numbers
    0x10300 ... 0x1032F, // Old Italic
    0x10330 ... 0x1034F, // Gothic
    0x10350 ... 0x1037F, // Old Permic
    0x10380 ... 0x1039F, // Ugaritic
    0x103A0 ... 0x103DF, // Old Persian
    0x10400 ... 0x1044F, // Deseret
    0x10450 ... 0x1047F, // Shavian
    0x10480 ... 0x104AF, // Osmanya
    0x104B0 ... 0x104FF, // Osage
    0x10500 ... 0x1052F, // Elbasan
    0x10530 ... 0x1056F, // Caucasian Albanian
    0x10570 ... 0x105BF, // Vithkuqi
    0x105C0 ... 0x105FF, // Todhri
    0x10600 ... 0x1077F, // Linear A
    0x10780 ... 0x107BF, // Latin Extended-F
    0x10800 ... 0x1083F, // Cypriot Syllabary
    0x10840 ... 0x1085F, // Imperial Aramaic
    0x10860 ... 0x1087F, // Palmyrene
    0x10880 ... 0x108AF, // Nabataean
    0x108E0 ... 0x108FF, // Hatran
    0x10900 ... 0x1091F, // Phoenician
    0x10920 ... 0x1093F, // Lydian
    0x10940 ... 0x1095F, // Sidetic
    0x10980 ... 0x1099F, // Meroitic Hieroglyphs
    0x109A0 ... 0x109FF, // Meroitic Cursive
    0x10A00 ... 0x10A5F, // Kharoshthi
    0x10A60 ... 0x10A7F, // Old South Arabian
    0x10A80 ... 0x10A9F, // Old North Arabian
    0x10AC0 ... 0x10AFF, // Manichaean
    0x10B00 ... 0x10B3F, // Avestan
    0x10B40 ... 0x10B5F, // Inscriptional Parthian
    0x10B60 ... 0x10B7F, // Inscriptional Pahlavi
    0x10B80 ... 0x10BAF, // Psalter Pahlavi
    0x10C00 ... 0x10C4F, // Old Turkic
    0x10C80 ... 0x10CFF, // Old Hungarian
    0x10D00 ... 0x10D3F, // Hanifi Rohingya
    0x10D40 ... 0x10D8F, // Garay
    0x10E60 ... 0x10E7F, // Rumi Numeral Symbols
    0x10E80 ... 0x10EBF, // Yezidi
    0x10EC0 ... 0x10EFF, // Arabic Extended-C
    0x10F00 ... 0x10F2F, // Old Sogdian
    0x10F30 ... 0x10F6F, // Sogdian
    0x10F70 ... 0x10FAF, // Old Uyghur
    0x10FB0 ... 0x10FDF, // Chorasmian
    0x10FE0 ... 0x10FFF, // Elymaic
    0x11000 ... 0x1107F, // Brahmi
    0x11080 ... 0x110CF, // Kaithi
    0x110D0 ... 0x110FF, // Sora Sompeng
    0x11100 ... 0x1114F, // Chakma
    0x11150 ... 0x1117F, // Mahajani
    0x11180 ... 0x111DF, // Sharada
    0x111E0 ... 0x111FF, // Sinhala Archaic Numbers
    0x11200 ... 0x1124F, // Khojki
    0x11280 ... 0x112AF, // Multani
    0x112B0 ... 0x112FF, // Khudawadi
    0x11300 ... 0x1137F, // Grantha
    0x11380 ... 0x113FF, // Tulu-Tigalari
    0x11400 ... 0x1147F, // Newa
    0x11480 ... 0x114DF, // Tirhuta
    0x11580 ... 0x115FF, // Siddham
    0x11600 ... 0x1165F, // Modi
    0x11660 ... 0x1167F, // Mongolian Supplement
    0x11680 ... 0x116CF, // Takri
    0x116D0 ... 0x116FF, // Myanmar Extended-C
    0x11700 ... 0x1174F, // Ahom
    0x11800 ... 0x1184F, // Dogra
    0x118A0 ... 0x118FF, // Warang Citi
    0x11900 ... 0x1195F, // Dives Akuru
    0x119A0 ... 0x119FF, // Nandinagari
    0x11A00 ... 0x11A4F, // Zanabazar Square
    0x11A50 ... 0x11AAF, // Soyombo
    0x11AB0 ... 0x11ABF, // Unified Canadian Aboriginal Syllabics Extended-A
    0x11AC0 ... 0x11AFF, // Pau Cin Hau
    0x11B00 ... 0x11B5F, // Devanagari Extended-A
    0x11B60 ... 0x11B7F, // Sharada Supplement
    0x11BC0 ... 0x11BFF, // Sunuwar
    0x11C00 ... 0x11C6F, // Bhaiksuki
    0x11C70 ... 0x11CBF, // Marchen
    0x11D00 ... 0x11D5F, // Masaram Gondi
    0x11D60 ... 0x11DAF, // Gunjala Gondi
    0x11DB0 ... 0x11DEF, // Tolong Siki
    0x11EE0 ... 0x11EFF, // Makasar
    0x11F00 ... 0x11F5F, // Kawi
    0x11FB0 ... 0x11FBF, // Lisu Supplement
    0x11FC0 ... 0x11FFF, // Tamil Supplement
    0x12000 ... 0x123FF, // Cuneiform
    0x12400 ... 0x1247F, // Cuneiform Numbers and Punctuation
    0x12480 ... 0x1254F, // Early Dynastic Cuneiform
    0x12F90 ... 0x12FFF, // Cypro-Minoan
    0x13000 ... 0x1342F, // Egyptian Hieroglyphs
    0x13430 ... 0x1345F, // Egyptian Hieroglyph Format Controls
    0x13460 ... 0x143FF, // Egyptian Hieroglyphs Extended-A
    0x14400 ... 0x1467F, // Anatolian Hieroglyphs
    0x16100 ... 0x1613F, // Gurung Khema
    0x16800 ... 0x16A3F, // Bamum Supplement
    0x16A40 ... 0x16A6F, // Mro
    0x16A70 ... 0x16ACF, // Tangsa
    0x16AD0 ... 0x16AFF, // Bassa Vah
    0x16B00 ... 0x16B8F, // Pahawh Hmong
    0x16D40 ... 0x16D7F, // Kirat Rai
    0x16E40 ... 0x16E9F, // Medefaidrin
    0x16EA0 ... 0x16EDF, // Beria Erfe
    0x16F00 ... 0x16F9F, // Miao
    0x16FE0 ... 0x16FFF, // Ideographic Symbols and Punctuation
    0x17000 ... 0x187FF, // Tangut
    0x18800 ... 0x18AFF, // Tangut Components
    0x18B00 ... 0x18CFF, // Khitan Small Script
    0x18D00 ... 0x18D7F, // Tangut Supplement
    0x18D80 ... 0x18DFF, // Tangut Components Supplement
    0x1AFF0 ... 0x1AFFF, // Kana Extended-B
    0x1B000 ... 0x1B0FF, // Kana Supplement
    0x1B100 ... 0x1B12F, // Kana Extended-A
    0x1B130 ... 0x1B16F, // Small Kana Extension
    0x1B170 ... 0x1B2FF, // Nushu
    0x1BC00 ... 0x1BC9F, // Duployan
    0x1BCA0 ... 0x1BCAF, // Shorthand Format Controls
    0x1CC00 ... 0x1CEBF, // Symbols for Legacy Computing Supplement
    0x1CEC0 ... 0x1CEFF, // Miscellaneous Symbols Supplement
    0x1CF00 ... 0x1CFCF, // Znamenny Musical Notation
    0x1D000 ... 0x1D0FF, // Byzantine Musical Symbols
    0x1D100 ... 0x1D1FF, // Musical Symbols
    0x1D200 ... 0x1D24F, // Ancient Greek Musical Notation
    0x1D2C0 ... 0x1D2DF, // Kaktovik Numerals
    0x1D2E0 ... 0x1D2FF, // Mayan Numerals
    0x1D300 ... 0x1D35F, // Tai Xuan Jing Symbols
    0x1D360 ... 0x1D37F, // Counting Rod Numerals
    0x1D400 ... 0x1D7FF, // Mathematical Alphanumeric Symbols
    0x1D800 ... 0x1DAAF, // Sutton SignWriting
    0x1DF00 ... 0x1DFFF, // Latin Extended-G
    0x1E000 ... 0x1E02F, // Glagolitic Supplement
    0x1E030 ... 0x1E08F, // Cyrillic Extended-D
    0x1E100 ... 0x1E14F, // Nyiakeng Puachue Hmong
    0x1E290 ... 0x1E2BF, // Toto
    0x1E2C0 ... 0x1E2FF, // Wancho
    0x1E4D0 ... 0x1E4FF, // Nag Mundari
    0x1E5D0 ... 0x1E5FF, // Ol Onal
    0x1E6C0 ... 0x1E6FF, // Tai Yo
    0x1E7E0 ... 0x1E7FF, // Ethiopic Extended-B
    0x1E800 ... 0x1E8DF, // Mende Kikakui
    0x1E900 ... 0x1E95F, // Adlam
    0x1EC70 ... 0x1ECBF, // Indic Siyaq Numbers
    0x1ED00 ... 0x1ED4F, // Ottoman Siyaq Numbers
    0x1EE00 ... 0x1EEFF, // Arabic Mathematical Alphabetic Symbols
    0x1F000 ... 0x1F02F, // Mahjong Tiles
    0x1F030 ... 0x1F09F, // Domino Tiles
    0x1F0A0 ... 0x1F0FF, // Playing Cards
    0x1F100 ... 0x1F1FF, // Enclosed Alphanumeric Supplement
    0x1F200 ... 0x1F2FF, // Enclosed Ideographic Supplement
    0x1F300 ... 0x1F5FF, // Miscellaneous Symbols and Pictographs
    0x1F600 ... 0x1F64F, // Emoticons
    0x1F650 ... 0x1F67F, // Ornamental Dingbats
    0x1F680 ... 0x1F6FF, // Transport and Map Symbols
    0x1F700 ... 0x1F77F, // Alchemical Symbols
    0x1F780 ... 0x1F7FF, // Geometric Shapes Extended
    0x1F800 ... 0x1F8FF, // Supplemental Arrows-C
    0x1F900 ... 0x1F9FF, // Supplemental Symbols and Pictographs
    0x1FA00 ... 0x1FA6F, // Chess Symbols
    0x1FA70 ... 0x1FAFF, // Symbols and Pictographs Extended-A
    0x1FB00 ... 0x1FBFF, // Symbols for Legacy Computing
    0x20000 ... 0x2A6DF, // CJK Unified Ideographs Extension B
    0x2A700 ... 0x2B73F, // CJK Unified Ideographs Extension C
    0x2B740 ... 0x2B81F, // CJK Unified Ideographs Extension D
    0x2B820 ... 0x2CEAF, // CJK Unified Ideographs Extension E
    0x2CEB0 ... 0x2EBEF, // CJK Unified Ideographs Extension F
    0x2EBF0 ... 0x2EE5F, // CJK Unified Ideographs Extension I
    0x2F800 ... 0x2FA1F, // CJK Compatibility Ideographs Supplement
    0x30000 ... 0x3134F, // CJK Unified Ideographs Extension G
    0x31350 ... 0x323AF, // CJK Unified Ideographs Extension H
    0x323B0 ... 0x3347F, // CJK Unified Ideographs Extension J
    0xE0000 ... 0xE007F, // Tags
    0xE0100 ... 0xE01EF, // Variation Selectors Supplement
]

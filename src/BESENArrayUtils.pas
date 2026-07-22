(*******************************************************************************
                                 L I C E N S E
********************************************************************************

BESEN - A ECMAScript Fifth Edition Object Pascal Implementation
Copyright (C) 2009-2016, Benjamin 'BeRo' Rosseaux

The source code of the BESEN ecmascript engine library and helper tools are 
distributed under the Library GNU Lesser General Public License Version 2.1 
(see the file copying.txt) with the following modification:

As a special exception, the copyright holders of this library give you
permission to link this library with independent modules to produce an
executable, regardless of the license terms of these independent modules,
and to copy and distribute the resulting executable under terms of your choice,
provided that you also meet, for each linked independent module, the terms
and conditions of the license of that module. An independent module is a module
which is not derived from or based on this library. If you modify this
library, you may extend this exception to your version of the library, but you 
are not obligated to do so. If you do not wish to do so, delete this exception
statement from your version.

If you didn't receive a copy of the license, see <http://www.gnu.org/licenses/>
or contact:
      Free Software Foundation
      675 Mass Ave
      Cambridge, MA  02139
      USA

*******************************************************************************)
unit BESENArrayUtils;
{$i BESEN.inc}

interface

uses
    SysUtils, BESENConstants, BESENTypes, BESENValue;

	function BESENArrayToIndex(const AProp: TBESENString; var v: int64): TBESENBoolean;
	function BESENArrayToIndexEx(const AProp: TBESENString): int64;
	function BESENArrayIndexToStr(v: TBESENUINT32): TBESENString;
	procedure BESENArrayCheckTooLong(const a, b: TBESENUINT32);

implementation

uses
    BESEN, BESENUtils, BESENErrors;

{$ifndef besen_array_optimizations}
	function BESENArrayToIndex(AProp:TBESENString;var v:int64):TBESENBoolean;
	var i:integer;
	begin
	 if length(AProp)=0 then begin
	  result:=false;
	 end else if (length(AProp)>1) and (AProp[1]='0') then begin
	  result:=false;
	 end else begin
	  result:=true;
	  v:=0;
	  for i:=1 to length(AProp) do begin
	   if (word(widechar(AProp[i]))>=ord('0')) and (word(widechar(AProp[i]))<=ord('9')) then begin
	    v:=(v*10)+(word(widechar(AProp[i]))-ord('0'));
	   end else begin
	    result:=false;
	    break;
	   end;
	  end;
	  if result and ((IntToStr(v and $ffffffff)<>AProp) or (v>=$ffffffff)) then begin
	   result:=false;
	  end;
	 end;
	end;
{$else}

	function BESENArrayToIndex(const AProp: TBESENString; var v: int64): TBESENBoolean;
	var i, d: integer;
	begin
		if length(AProp) = 0 then begin
			Result := False;
		end else if (length(AProp) > 1) and (AProp[1] = '0') then begin
			Result := False;
		end else begin
			Result := True;
			v := 0;
			// PERF: Keep validation allocation-free in this hot path.
			// We now reject out-of-range values during digit parsing instead of
			// using IntToStr(...) for post-parse canonical verification.
			for i := 1 to length(AProp) do begin
				if (word(widechar(AProp[i])) >= Ord('0')) and (word(widechar(AProp[i])) <= Ord('9')) then begin
					d := word(widechar(AProp[i])) - Ord('0');
					v := (v * 10) + d;
					if v >= $ffffffff then begin
						Result := False;
						break;
					end;
				end else begin
					Result := False;
					break;
				end;
			end;
		end;
	end;

{$endif}

function BESENArrayToIndexEx(const AProp: TBESENString): int64;
var i: integer;
begin
	if length(AProp) = 0 then begin
		Result := 0;
	end else if (length(AProp) > 1) and (AProp[1] = '0') then begin
		Result := 0;
	end else begin
		Result := 0;
		for i := 1 to length(AProp) do begin
			if (word(widechar(AProp[i])) >= Ord('0')) and (word(widechar(AProp[i])) <= Ord('9')) then begin
				Result := (Result * 10) + (word(widechar(AProp[i])) - Ord('0'));
			end else begin
				Result := 0;
				break;
			end;
		end;
	end;
end;

// this function is slow and needs to be optimized.

// BESENArrayIndexToStr

// Converts an unsigned 32-bit integer array index into its decimal string
// representation as a TBESENString (WideString).

// This is a hand-rolled integer-to-string conversion that intentionally avoids
// any runtime library calls (no IntToStr, no Format, no Str()).  The reason is
// performance and portability: BESEN runs on both Delphi and FPC, and RTL
// string conversion functions carry overhead (locale handling, exception
// frames, heap calls) that is unnecessary for a simple decimal digit expansion
// of an array index.

// The algorithm runs in two passes over the digits of v:

//   Pass 1 — count digits
//     Divides a copy of v by 10 repeatedly, incrementing a counter each time,
//     until the value reaches zero.  The counter gives the exact number of
//     decimal digits needed, with no leading zeros.
//     Example: v=1234 → divisions: 123, 12, 1, 0 → i=4

//   Pass 2 — fill digits right-to-left
//     Sets the result string length to the digit count from pass 1, then fills
//     it from the last character position backwards.  Each iteration extracts
//     the least-significant digit via (v mod 10), converts it to a WideChar by
//     adding the ASCII code of '0' (48), writes it to result[i], then divides v
//     by 10 to remove that digit and decrements i.
//     Filling right-to-left means the digits land in the correct order without
//     needing a reversal step.
//     Example: v=1234 → writes '4' at [4], '3' at [3], '2' at [2], '1' at [1]

// The special case v=0 is handled up front because the two-pass loop would
// produce zero iterations for v=0 (the while o<>0 condition fails immediately),
// leaving result as an empty string rather than '0'.

// The cast chain  widechar(word(v mod 10)+ord('0'))  is deliberate:
//   v mod 10      → TBESENUINT32 (0..9)
//   +ord('0')     → promotes to a larger integer type, value 48..57
//   word(...)     → narrows to 16-bit unsigned, matching WideChar's storage size
//   widechar(...) → final cast to WideChar; avoids any implicit conversion
//                   that a direct TBESENUINT32→WideChar cast might trigger in
//                   older Delphi versions.

// Parameters:
//   v  — the array index to convert; valid range is 0 .. 2^32-1 (TBESENUINT32)

// Returns:
//   The decimal string representation of v, e.g. 0→'0', 1→'1', 42→'42'.
//   Always returns a plain decimal string with no leading zeros (except '0'
//   itself), no sign, and no locale-specific formatting.

// Called by:
//   Array property access and enumeration paths that need to compare or expose
//   a numeric index as an ECMAScript string key.  ECMAScript specifies that
//   array indices are canonical decimal strings, so this function must match
//   that exact format.

// this basically does inttostr..

{$ifdef original_besen_BESENArrayIndexToStr}

function BESENArrayIndexToStr(v:TBESENUINT32):TBESENString;
var i:integer;    // digit counter / write position (1-based, filled right-to-left)
    o:TBESENUINT32; // scratch copy of v used in the digit-counting pass
begin
 // Special case: the loop below requires v>0 to produce any output.
 // Return '0' directly rather than an empty string.
 if v=0 then begin
  result:='0';
 end else begin
  result:='';

  // --- Pass 1: count the number of decimal digits needed ---
  // We must know the length up front so we can pre-allocate the string and
  // fill it right-to-left without a separate reversal step.
  i:=0;
  o:=v;
  while o<>0 do begin
   inc(i);        // one more digit required
   o:=o div 10;  // drop the least-significant digit
  end;
  // i now holds the exact digit count, e.g. 1234 → 4

  // Pre-allocate the result string to exactly the right length.
  // No reallocation will occur during Pass 2.
  SetLength(result,i);

  // --- Pass 2: extract digits right-to-left and write into result ---
  // i starts at the last (rightmost) character position and decrements toward 1.
  // v is modified in place; o is no longer needed.
  while (v<>0) and (i>0) do begin
   // Extract the least-significant decimal digit (0..9).
   // Convert to WideChar: add ASCII '0' (48), narrow to word, cast to WideChar.
   // The word() narrowing step is explicit to avoid ambiguous implicit conversions
   // from TBESENUINT32 to WideChar in older Delphi versions.
   result[i]:=widechar(word(v mod 10)+ord('0'));
   dec(i);        // move write position one step left
   v:=v div 10;  // drop the least-significant digit from v
  end;
  // Both loop guards (v<>0 and i>0) become false simultaneously under normal
  // operation — v is exhausted exactly when all i positions are filled.
  // The double guard is defensive: it prevents an out-of-bounds write or
  // infinite loop if the two passes were ever to disagree on digit count.
 end;
end;

{$else}

function BESENArrayIndexToStr(v: TBESENUINT32): TBESENString;
const
	   // Lookup table: two ASCII digit characters for every value 00..99.
	   // Stored as pairs of AnsiChar so the table fits in 200 bytes (L1 cache-hot).
	   // Each entry is indexed as Digits100[n][0] = tens digit, [1] = units digit.
	   Digits100: array[0..99, 0..1] of ansichar = (
	('0', '0'), ('0', '1'), ('0', '2'), ('0', '3'), ('0', '4'),
		  ('0', '5'), ('0', '6'), ('0', '7'), ('0', '8'), ('0', '9'),
		  ('1', '0'), ('1', '1'), ('1', '2'), ('1', '3'), ('1', '4'),
		  ('1', '5'), ('1', '6'), ('1', '7'), ('1', '8'), ('1', '9'),
		  ('2', '0'), ('2', '1'), ('2', '2'), ('2', '3'), ('2', '4'),
		  ('2', '5'), ('2', '6'), ('2', '7'), ('2', '8'), ('2', '9'),
		  ('3', '0'), ('3', '1'), ('3', '2'), ('3', '3'), ('3', '4'),
		  ('3', '5'), ('3', '6'), ('3', '7'), ('3', '8'), ('3', '9'),
		  ('4', '0'), ('4', '1'), ('4', '2'), ('4', '3'), ('4', '4'),
		  ('4', '5'), ('4', '6'), ('4', '7'), ('4', '8'), ('4', '9'),
		  ('5', '0'), ('5', '1'), ('5', '2'), ('5', '3'), ('5', '4'),
		  ('5', '5'), ('5', '6'), ('5', '7'), ('5', '8'), ('5', '9'),
		  ('6', '0'), ('6', '1'), ('6', '2'), ('6', '3'), ('6', '4'),
		  ('6', '5'), ('6', '6'), ('6', '7'), ('6', '8'), ('6', '9'),
		  ('7', '0'), ('7', '1'), ('7', '2'), ('7', '3'), ('7', '4'),
		  ('7', '5'), ('7', '6'), ('7', '7'), ('7', '8'), ('7', '9'),
		  ('8', '0'), ('8', '1'), ('8', '2'), ('8', '3'), ('8', '4'),
		  ('8', '5'), ('8', '6'), ('8', '7'), ('8', '8'), ('8', '9'),
		  ('9', '0'), ('9', '1'), ('9', '2'), ('9', '3'), ('9', '4'),
		  ('9', '5'), ('9', '6'), ('9', '7'), ('9', '8'), ('9', '9')
	);
var
	// Maximum digits for TBESENUINT32 (0..4294967295) is 10.
	// Buffer holds 10 WideChars = 20 bytes — fits entirely in registers on 64-bit.
	buf: array[0..9] of widechar;
	p: integer;  // current write position, filled right-to-left
	r: TBESENUINT32; // remainder for two-digit extraction
begin
	// Fast path for the most common array indices.
	// Avoids all division for the overwhelming majority of real-world arrays.
	if v < 10 then begin
		Result := widechar(word(v) + Ord('0'));
		exit;
	end;

	// Fill buffer right-to-left, two digits at a time.
	// div/mod 100 compiles to multiply-shift at -O2 — no hardware divide.
	p := 10;
	while v >= 100 do begin
		r := v mod 100;
		v := v div 100;
		Dec(p);	buf[p] := widechar(Ord(Digits100[r][1])); // units digit
		Dec(p);	buf[p] := widechar(Ord(Digits100[r][0])); // tens digit
	end;

	// Handle the last 1 or 2 remaining digits (v is now 0..99).
	if v >= 10 then begin
		Dec(p);	buf[p] := widechar(Ord(Digits100[v][1]));
		Dec(p);	buf[p] := widechar(Ord(Digits100[v][0]));
	end else begin
		Dec(p);	buf[p] := widechar(word(v) + Ord('0'));
	end;

	// Single allocation + single copy — no second pass, no counting pass.
	SetLength(Result, 10 - p);
	Move(buf[p], Result[1], (10 - p) * SizeOf(widechar));
end;

{$endif}

procedure BESENArrayCheckTooLong(const a, b: TBESENUINT32);
var c: TBESENUINT32;
begin
	c := TBESENUINT32(a + b) and $ffffffff;
	if (c < a) or (c < b) then begin
		BESENThrowRangeError('Array too long');
	end;
end;

end.

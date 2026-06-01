(*******************************************************************************
                                 L I C E N S E
********************************************************************************

BESEN - A ECMAScript Fifth Edition Object Pascal Implementation
Copyright (C) 2009-2018, Benjamin 'BeRo' Rosseaux

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


{$ifdef fpc}
 {$mode delphiunicode} // 2 bytes per char!!
 {$ifdef cpui386}
  {$define cpu386}
 {$endif}
 {$ifdef cpu386}
  {$asmmode intel}
 {$endif}
 {$ifdef cpuamd64}
  {$asmmode intel}
 {$endif}
 {$ifdef FPC_LITTLE_ENDIAN}
  {$define LITTLE_ENDIAN}
 {$else}
  {$ifdef FPC_BIG_ENDIAN}
   {$define BIG_ENDIAN}
  {$endif}
 {$endif}
 {$pic off}
 {$define caninline}
 {$ifdef FPC_HAS_TYPE_EXTENDED}
  {$define HAS_TYPE_EXTENDED}
 {$else}
  {$undef HAS_TYPE_EXTENDED}
 {$endif}
 {$ifdef FPC_HAS_TYPE_DOUBLE}
  {$define HAS_TYPE_DOUBLE}
 {$else}
  {$undef HAS_TYPE_DOUBLE}
 {$endif}
 {$ifdef FPC_HAS_TYPE_SINGLE}
  {$define HAS_TYPE_SINGLE}
 {$else}
  {$undef HAS_TYPE_SINGLE}
 {$endif}
{$else}
 {$realcompatibility off}
 {$localsymbols on}
 {$define LITTLE_ENDIAN}
 {$ifndef cpu64}
  {$define cpu32}
 {$endif}
 {$define HAS_TYPE_EXTENDED}
 {$define HAS_TYPE_DOUBLE}
 {$define HAS_TYPE_SINGLE}
 {$ifndef BCB}
  {$ifdef ver120}
   {$define Delphi4or5}
  {$endif}
  {$ifdef ver130}
   {$define Delphi4or5}
  {$endif}
  {$ifdef ver140}
   {$define Delphi6}
  {$endif}
  {$ifdef ver150}
   {$define Delphi7}
  {$endif}
  {$ifdef ver170}
   {$define Delphi2005}
  {$endif}
 {$else}
  {$ifdef ver120}
   {$define Delphi4or5}
   {$define BCB4}
  {$endif}
  {$ifdef ver130}
   {$define Delphi4or5}
  {$endif}
 {$endif}
 {$ifdef ver180}
  {$define BDS2006}
  {$define Delphi2006}
 {$endif}
 {$ifdef ver185}
  {$define Delphi2007}
 {$endif}
 {$ifdef ver190}
  {$define Delphi2007Net}
 {$endif}
 {$ifdef ver200}
  {$define Delphi2009}
  {$define Delphi2009AndUp}
 {$endif}
 {$ifdef ver210}
  {$define Delphi2010}
  {$define Delphi2009AndUp}
 {$endif}
 {$ifdef ver220}
  {$define DelphiXE}
  {$define DelphiXEAndUp}
  {$define Delphi2009AndUp}
 {$endif}
 {$ifdef ver230}
  {$define DelphiXE2}
  {$define DelphiXEAndUp}
  {$define DelphiXE2AndUp}
  {$define Delphi2009AndUp}
 {$endif}
 {$ifdef ver240}
  {$define DelphiXE3}
  {$define DelphiXEAndUp}
  {$define DelphiXE2AndUp}
  {$define DelphiXE3AndUp}
  {$define Delphi2009AndUp}
 {$endif}
 {$ifdef ver250}
  {$define DelphiXE4}
  {$define DelphiXEAndUp}
  {$define DelphiXE2AndUp}
  {$define DelphiXE3AndUp}
  {$define DelphiXE4AndUp}
  {$define Delphi2009AndUp}
 {$endif}
 {$ifdef ver260}
  {$define DelphiXE5}
  {$define DelphiXEAndUp}
  {$define DelphiXE2AndUp}
  {$define DelphiXE3AndUp}
  {$define DelphiXE4AndUp}
  {$define DelphiXE5AndUp}
  {$define Delphi2009AndUp}
 {$endif}
 {$ifdef ver270}
  {$define DelphiXE6}
  {$define DelphiXEAndUp}
  {$define DelphiXE2AndUp}
  {$define DelphiXE3AndUp}
  {$define DelphiXE4AndUp}
  {$define DelphiXE5AndUp}
  {$define DelphiXE6AndUp}
  {$define Delphi2009AndUp}
 {$endif}
 {$ifdef ver280}
  {$define DelphiXE7}
  {$define DelphiXEAndUp}
  {$define DelphiXE2AndUp}
  {$define DelphiXE3AndUp}
  {$define DelphiXE4AndUp}
  {$define DelphiXE5AndUp}
  {$define DelphiXE6AndUp}
  {$define DelphiXE7AndUp}
  {$define Delphi2009AndUp}
 {$endif}
 {$ifdef ver290}
  {$define DelphiXE8}
  {$define DelphiXEAndUp}
  {$define DelphiXE2AndUp}
  {$define DelphiXE3AndUp}
  {$define DelphiXE4AndUp}
  {$define DelphiXE5AndUp}
  {$define DelphiXE6AndUp}
  {$define DelphiXE7AndUp}
  {$define DelphiXE8AndUp}
  {$define Delphi2009AndUp}
 {$endif}
 {$ifdef ver300}
  {$define DelphiSeattle}
  {$define DelphiXEAndUp}
  {$define DelphiXE2AndUp}
  {$define DelphiXE3AndUp}
  {$define DelphiXE4AndUp}
  {$define DelphiXE5AndUp}
  {$define DelphiXE6AndUp}
  {$define DelphiXE7AndUp}
  {$define DelphiXE8AndUp}
  {$define DelphiSeattleAndUp}
  {$define Delphi2009AndUp}
 {$endif}
 {$ifdef ver310}
  {$define DelphiBerlin}
  {$define DelphiXEAndUp}
  {$define DelphiXE2AndUp}
  {$define DelphiXE3AndUp}
  {$define DelphiXE4AndUp}
  {$define DelphiXE5AndUp}
  {$define DelphiXE6AndUp}
  {$define DelphiXE7AndUp}
  {$define DelphiXE8AndUp}
  {$define DelphiBerlinAndUp}
  {$define Delphi2009AndUp}
 {$endif} 
 {$ifdef ver320}
  {$define DelphiTokyo}
  {$define Delphi2009AndUp}
  {$define DelphiXEAndUp}
  {$define DelphiXE2AndUp}
  {$define DelphiXE3AndUp}
  {$define DelphiXE4AndUp}
  {$define DelphiXE5AndUp}
  {$define DelphiXE6AndUp}
  {$define DelphiXE7AndUp}
  {$define DelphiXE8AndUp}
  {$define DelphiBerlinAndUp}
  {$define DelphiTokyoAndUp}
 {$endif}
 {$ifdef ver330}
  {$define DelphiRio}
  {$define Delphi2009AndUp}
  {$define DelphiXEAndUp}
  {$define DelphiXE2AndUp}
  {$define DelphiXE3AndUp}
  {$define DelphiXE4AndUp}
  {$define DelphiXE5AndUp}
  {$define DelphiXE6AndUp}
  {$define DelphiXE7AndUp}
  {$define DelphiXE8AndUp}
  {$define DelphiBerlinAndUp}
  {$define DelphiTokyoAndUp}
  {$define DelphiRioAndUp}
 {$endif}

 {$ifndef Delphi4or5}
  {$ifndef BCB}
   {$define Delphi6AndUp}
  {$endif}
   {$ifndef Delphi6}
    {$define BCB6OrDelphi7AndUp}
    {$ifndef BCB}
     {$define Delphi7AndUp}
    {$endif}
    {$ifndef BCB}
     {$ifndef Delphi7}
      {$ifndef Delphi2005}
       {$define BDS2006AndUp}
      {$endif}
     {$endif}
    {$endif}
   {$endif}
 {$endif}
 {$ifdef Delphi6AndUp}
  {$warn symbol_platform off}
  {$warn symbol_deprecated off}
 {$endif}
{$endif}
{$ifdef win32}
 {$define windows}
{$endif}
{$ifdef win64}
 {$define windows}
{$endif}
{$ifdef wince}
 {$define windows}
{$endif}
{$extendedsyntax on}
{$writeableconst on}
{$varstringchecks on}
{$typeinfo on}

{$rangechecks off}
{$overflowchecks off}
{.$hints off}
{.$booleval off}
{.$typedaddress off}
{.$stackframes off}

{$longstrings on}
{$openstrings on}
{$undef UseSafeStringEquals}
{$define strictutf8}
{$define UseOptimizedHashing}
{$define UseAssert}
{$define UseSafeOperations}
{$undef HasJIT}
{$ifdef cpu386}
 {$define UseRegister}
 {$define HasJIT}
 {$undef UseSafeOperations}
{$endif}
{$ifdef cpuamd64}
 {$define UseRegister}
 {$define HasJIT}
{$endif}
{$ifdef NextGen}
 {$define BESENEmbarcaderoNextGen}
 {$define BESENSingleStringType}
 {$define PurePascal}
 {$ZeroBasedStrings off}
{$endif}
{$ifdef PurePascal}
 {$define DisableJIT}
 {$undef ForceJIT}
{$endif}
{$ifdef DisableJIT}
 {$undef HasJIT}
{$endif}
{$ifdef ForceJIT}
 {$define HasJIT}
{$endif}
{$ifdef ForceUseSafeOperations}
 {$define UseSafeOperations}
{$endif}
{$ifndef HAS_TYPE_DOUBLE}
 {$error No double floating point precision }
{$endif}
{$ifdef DelphiXE2AndUp}
 {$ifdef MacOS}
  {$define BESENDelphiHasNoSystemTimeMore}
 {$endif}
{$endif}

{.$define cpu32}                            // does nothing
{.$define HAS_TYPE_SINGLE}                  // does nothing
{.$define HAS_TYPE_DOUBLE}					// does nothing
{.$define BESENDelphiHasNoSystemTimeMore}	// some more delphi specific stuff related to date and timezones
{.$define BESENEmbarcaderoNextGen}			// will use some newer delphi-specific language constructs, mainly to do with utf, char conversion
{.$define BESENSingleStringType}			// if defined: it uses TBESENSTRING otherwise TBESENUTF8STRING (based on ansistring) it is not clear to what it will set things to.
{.$define BIG_ENDIAN}                       // affects BESENNumberUtils, affects TDoubleCasted and BESENTypes.TBESENDoubleHiLo in some functions.
{.$define caninline}						// besencodecontext inlines some functions. requires PurePascal. in BESENNumberUtils it also inlines some functions (PurePascal not required there)
{.$define cpu386}                           // 32 bit specific assembly code is used as optimizations in many places.
{.$define HAS_TYPE_EXTENDED}				// sets BESENFPUPrecisionMode to pmEXTENDED and then uses that to call SetPrecisionMode()
{.$define HasJIT}							// uses JIT optimized code execution (TBESENCodeContext.ExecuteCode) instead of classical code interpretation, also changes some things in BESENNativeCodeMemoryManager
{.$define LITTLE_ENDIAN}                    // does not do anything.
{.$define PurePascal}                       // disables JIT by setting DisableJIT, if NOT set, some parts also set PurePascalExecuteByteCode
{.$define PurePascalExecuteByteCode}		// TBESENCodeContext.ExecuteByteCode is pascal based.
{.$define strictutf8}                       // affects BESENStringUtils, seems to be sort of stricter type of encoding
{.$define UseAssert}						// used as kinda unit tests for how some things are used.
{.$define UseOptimizedHashing}				// BESENHashUtils uses different algorythm ( https://github.com/BeRo1985/besen/pull/14 )
{.$define UseRegister}						// some functions will use {$ifdef UseRegister}register;{$endif} calling convention. this is default for x86. Not sure what purpose this serves.
{.$define UseSafeOperations}				// does a lot more nan and inf checks on floats
{.$define windows}							// uses windows VirtualProtect for locking and mmsystem
{.$define HasSAR}                           // uses SARLongint 32-bit Shift Arithmetic Right function ( https://www.freepascal.org/docs-html/rtl/system/sarlongint.html )
{.$define DisableJIT}						// disables JIT by unsetting HasJIT
{.$define reddor_patch_ast_bytecode}		// includes following BESEN fixes by reddor: (avoid traversing AST for function bodies multiple times, fix potential access violation in bytecode generator, add missing register allocation in bytecode generator, which could lead to memory corruption or access violations when bytecode is executed ) - see: https://github.com/reddor/besenws/commit/3008f66d9fb6d38b1c92fc1ebc18f9e4eefef714#diff-ce5fc568af420ac988d5546ff58f5c0b
{.$define besen_arena_allocator}			// uses a faster cache optimized garbage collector (ai written arena pool allocator)
{.$define original_besen_BESENArrayIndexToStr}		// does not use lookup table optimization for BESENArrayIndexToStr

{.$define reddor_patch_ast_bytecode} // does not work on 64 bit.
{$define HasSAR}
{$define besen_arena_allocator}


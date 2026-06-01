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

{

	Because windows has vastly different 64 bit ABI than system v / unix, it uses different JIT unit.
	see: https://wiki.osdev.org/System_V_ABI#x86-64 and https://learn.microsoft.com/en-us/cpp/build/x64-software-conventions?view=msvc-170

	This has been vibe coded with AI, i'm sorry - but it WORKS.

}

unit BESENCodeJITx64windows;

{$i BESEN.inc}

interface

uses {$ifdef windows}Windows,MMSystem,{$endif}{$ifdef unix}dl,BaseUnix,Unix,
     UnixType,{$endif}BESENConstants,BESENTypes;

{$ifdef HasJIT}
{$ifdef cpuamd64}
function BESENGenerateNativeCode(ACodeContext:TObject):TBESENBoolean;
function BESENExecuteNativeCode(ACodeContext:TObject):TBESENBoolean; {$ifdef UseRegister}register;{$endif}
{$endif}
{$endif}

implementation

{$ifdef HasJIT}
{$ifdef cpuamd64}
uses BESEN,BESENValue,BESENASTNodes,BESENCode,BESENCodeContext,BESENContext,BESENOpcodes,
     BESENGarbageCollector,
     BESENNumberUtils,BESENLexicalEnvironment,
     BESENDeclarativeEnvironmentRecord,BESENNativeCodeMemoryManager,
     BESENObject,BESENObjectEnvironmentRecord;

{
================================================================================
Windows x64 vs Unix x64 ABI Compatibility Information
================================================================================

This module implements a JIT compiler for x86-64 that works correctly on both
Windows and Unix-like systems (Linux, BSD, macOS). The two platforms have
different calling conventions and ABI requirements:

WINDOWS x64 ABI (Microsoft x64 Calling Convention):
---------------------------------------------------
Parameter passing:
  1st integer parameter: RCX
  2nd integer parameter: RDX
  3rd integer parameter: R8
  4th integer parameter: R9
  XMM parameters: XMM0-XMM3 (first 4 float/double parameters)

Return values:
  Integer result: RAX (or RDX:RAX for 128-bit)
  Float result: XMM0 or XMM0:XMM1

Stack and frame:
  - Caller allocates 32 bytes of "shadow space" (home space) for RCX, RDX, R8, R9
  - Stack must be 16-byte aligned BEFORE a CALL instruction (RSP % 16 == 0)
  - Caller responsible for cleaning up arguments on the stack
  - The called function can use the shadow space to save parameter registers

Callee-saved registers: RBX, RBP, RDI, RSI, R12-R15
Caller-saved registers: RAX, RCX, RDX, RSI, RDI, R8-R11

UNIX x64 ABI (System V AMD64 ABI):
-----------------------------------
Parameter passing:
  1st integer parameter: RDI
  2nd integer parameter: RSI
  3rd integer parameter: RDX
  4th integer parameter: RCX
  5th integer parameter: R8
  6th integer parameter: R9
  XMM parameters: XMM0-XMM7 (first 8 float/double parameters)

Return values:
  Integer result: RAX (or RDX:RAX for 128-bit)
  Float result: XMM0 or XMM0:XMM1

Stack and frame:
  - No shadow space required
  - Stack must be 16-byte aligned BEFORE a CALL instruction (RSP % 16 == 0)
  - Caller responsible for cleaning up arguments on the stack
  - Called function can use the red zone (128 bytes below RSP) for temporary storage

Callee-saved registers: RBX, RBP, R12-R15
Caller-saved registers: RAX, RCX, RDX, RSI, RDI, R8-R11

BESEN x86-64 JIT Implementation:
--------------------------------
Register usage in JIT-compiled code:
  RBX       = Instance pointer (callee-saved on both platforms)
  R12       = Code context pointer (callee-saved on both platforms)
  R13       = Bytecode <-> native code offset mapping array (callee-saved)
  R14       = Virtual machine register values array (callee-saved)
  R15       = Local variable hash table for function scopes (callee-saved)
  RAX-RDI   = Temporary registers for operations (caller-saved)
  XMM0-XMM7 = Floating point computations (caller-saved)

Key implementation details:
1. The AddDispatcher function calls into opcode handlers and must:
   - Allocate shadow space on Windows (32 bytes via SUB RSP,32)
   - Deallocate shadow space on Windows after CALL (32 bytes via ADD RSP,32)
   - Maintain 16-byte stack alignment before CALL instructions
   - Use correct parameter registers for Windows vs Unix

2. The BESENExecuteNativeCode function must:
   - Preserve callee-saved registers (RBX, R12-R15)
   - Maintain proper stack alignment throughout
   - Call the JIT-compiled code with correct stack state

3. All CALL instructions must be preceded by code that ensures:
   - Stack is 16-byte aligned (RSP % 16 == 0 before CALL)
   - Shadow space is allocated on Windows
   - Parameters are in the correct registers for the platform

================================================================================
}

function BESENGenerateNativeCode(ACodeContext:TObject):TBESENBoolean;
type TFixupKind=(fkPTR,fkRET,fkOFS);
     TFixup=record
      Kind:TFixupKind;
      Ofs:integer;
      Dest:pointer;
      ToOfs:integer;
     end;
     TFixups=array of TFixup;
var Fixups:TFixups;
    CountFixups,i:integer;
    Offsets:array of longword;
    Opcode:byte;
    Instruction:TBESENUINT32;
    CodeBuffer:TBESENBytes;
    CodeBufferLen:integer;
    CurrentPC,Temp,RetOfs,Literal:longword;
    CodeBegin,CodeEnd:pointer;
    ByteCode:PBESENUINT32Array;
    Operands:PBESENINT32Array;
    Code:TBESENCode;
    CodeContext:TBESENCodeContext;
    v:TBESENValue;
 procedure Add(const s:TBESENANSISTRING);
 begin
  if length(s)>0 then begin
   if (CodeBufferLen+length(s))>=length(CodeBuffer) then begin
    SetLength(CodeBuffer,(CodeBufferLen+length(s)+4096) and not 4095);
   end;
   move(s[1],CodeBuffer[CodeBufferLen],length(s));
   inc(CodeBufferLen,length(s));
  end;
 end;
 procedure AddCode(CodeBegin,CodeEnd:pointer);
 var CodeLen:ptrint;
{$ifdef windows}
     OldProtect,OldProtectDummy:longword;
     OK:boolean;
{$endif}
 begin
  CodeLen:=ptrint(ptruint(CodeEnd)-ptruint(CodeBegin));
  if CodeLen>0 then begin
{$ifdef windows}
   OK:=VirtualProtect(CodeBegin,CodeLen,PAGE_EXECUTE_READWRITE,OldProtect);
{$endif}
{$ifdef unix}
   fpmprotect(CodeBegin,CodeLen,PROT_READ or PROT_WRITE or PROT_EXEC);
{$endif}
   if (CodeBufferLen+CodeLen)>=length(CodeBuffer) then begin
    SetLength(CodeBuffer,(CodeBufferLen+CodeLen+4096) and not 4095);
   end;
   move(CodeBegin^,CodeBuffer[CodeBufferLen],CodeLen);
   inc(CodeBufferLen,CodeLen);
{$ifdef windows}
   if OK then begin
    VirtualProtect(CodeBegin,CodeLen,OldProtect,OldProtectDummy);
   end;
{$endif}
  end;
 end;
 procedure AddDWord(const v:longword);
 begin
  if (CodeBufferLen+sizeof(longword))>=length(CodeBuffer) then begin
   SetLength(CodeBuffer,(CodeBufferLen+sizeof(longword)+4096) and not 4095);
  end;
  move(v,CodeBuffer[CodeBufferLen],sizeof(longword));
  inc(CodeBufferLen,sizeof(longword));
 end;
 procedure AddQWord(const v:qword);
 begin
  if (CodeBufferLen+sizeof(qword))>=length(CodeBuffer) then begin
   SetLength(CodeBuffer,(CodeBufferLen+sizeof(qword)+4096) and not 4095);
  end;
  move(v,CodeBuffer[CodeBufferLen],sizeof(qword));
  inc(CodeBufferLen,sizeof(qword));
 end;
 procedure AddPtr(const v:pointer);
 begin
  if (CodeBufferLen+sizeof(ptruint))>=length(CodeBuffer) then begin
   SetLength(CodeBuffer,(CodeBufferLen+sizeof(ptruint)+4096) and not 4095);
  end;
  move(v,CodeBuffer[CodeBufferLen],sizeof(ptruint));
  inc(CodeBufferLen,sizeof(ptruint));
 end;
  procedure AddCallCopyValueProc;
  begin
{$ifdef windows}
   // Win64 ABI: reserve 32-byte shadow space and 8-byte alignment fix before CALL.
   Add(#$48#$83#$ec#$28); // sub rsp,40
{$else}
   // SysV AMD64: align stack before CALL.
   Add(#$48#$83#$ec#$08); // sub rsp,8
{$endif}

   // mov r11,offset BESENCopyValueProcs
   Add(#$49#$bb);
   AddPtr(@BESENCopyValueProcs);
   // call qword ptr [r11+rax*8]
   Add(#$49#$ff#$14#$c3);

{$ifdef windows}
   Add(#$48#$83#$c4#$28); // add rsp,40
{$else}
   Add(#$48#$83#$c4#$08); // add rsp,8
{$endif}
  end;
   procedure AddDispatcher;
   var Temp:qword;
       CodeBegin,CodeEnd:pointer;
   begin
    // Lazy PC update: only update PC for control flow / exception operations
    // that may change execution path. Skip for arithmetic, type coercion, etc.
    case Opcode of
     // Control flow: requires PC update
     bopEND,bopJZ,bopJNZ,bopJMP,bopJNULL,bopLOOPENUM,bopTRACE,bopJZERO,bopJNZERO,
     bopCALL,bopNEW,bopTHROW,bopENDF,bopSTRYC,bopSTRYF,
     // Exceptions: may need stack unwinding
     bopSCATCH,
     // Debugging: may break
     bopDEBUGGER:begin
      Add(#$41#$c7#$84#$24); // mov dword ptr [r12+TBESENCodeContext.PC],CurrentPC
      asm
       push rax
       mov rax,offset TBESENCodeContext.PC
       mov qword ptr Temp,rax
       pop rax
      end;
      AddDWord(Temp);
      AddDWord(CurrentPC);
     end;
    end;

   {
   Windows x64 ABI requirements before calling a function:
   1. Stack must be 16-byte aligned (RSP % 16 = 0) before the CALL instruction
   2. 32 bytes of shadow space must be allocated by the caller (sub rsp,32)
   3. Parameters: RCX (first), RDX (second), R8 (third), R9 (fourth)

   Unix x64 ABI requirements before calling a function:
   1. Stack must be 16-byte aligned (RSP % 16 = 0) before the CALL instruction
   2. No shadow space needed
   3. Parameters: RDI (first), RSI (second), RDX (third), RCX (fourth), R8 (fifth), R9 (sixth)
   }

{$ifdef windows}
   // Windows x64: entry from JIT code is rsp%16==8, so reserve 32-byte shadow
   // space plus 8 bytes to restore 16-byte alignment before CALL.
   Add(#$48#$83#$ec#$28); // sub rsp,40 (32-byte shadow space + 8-byte alignment)
{$else}
   // System V AMD64: no shadow space, only fix alignment before CALL.
   Add(#$48#$83#$ec#$08); // sub rsp,8
{$endif}

{$ifdef windows}
   Add(#$4c#$89#$e1); // mov rcx,r12 (first parameter: code context)
{$else}
   Add(#$4c#$89#$e7); // mov rdi,r12 (first parameter: code context)
{$endif}

{$ifdef windows}
   Add(#$48#$ba); // mov rdx,Operands (second parameter)
{$else}
   Add(#$48#$be); // mov rsi,Operands (second parameter)
{$endif}
   AddPtr(Operands);

   // mov rax,OpcodeDispatcher
   Add(#$48#$b8);
   AddPtr(BESENCodeContextOpcodes[Opcode]);

   // call rax
   Add(#$ff#$d0);

{$ifdef windows}
   Add(#$48#$83#$c4#$28); // add rsp,40
{$else}
   Add(#$48#$83#$c4#$08); // add rsp,8
{$endif}

   case Opcode of
    bopEND,bopTRACE,bopENDF:begin
     if (Opcode<>bopEND) or (Operands^[0]=0) then begin
      asm
       jmp @Skip
        @CodeBegin:
         cmp dword ptr [r12+TBESENCodeContext.BlockRunning],0
        @CodeEnd:
       @Skip:
       push rax
       mov rax,offset @CodeBegin
       mov qword ptr CodeBegin,rax
       mov rax,offset @CodeEnd
       mov qword ptr CodeEnd,rax
       pop rax
      end;
      AddCode(CodeBegin,CodeEnd);

      Add(#$0f#$84); // jz RET
      if CountFixups>=length(Fixups) then begin
       SetLength(Fixups,CountFixups+4096);
      end;
      Fixups[CountFixups].Kind:=fkRET;
      Fixups[CountFixups].Ofs:=CodeBufferLen;
      inc(CountFixups);
      Add(#$00#$00#$00#$00);
     end;
    end;
   end;

   case Opcode of
    bopEND,bopENDF,bopJMP,bopJZ,bopJNZ,bopJNULL,bopLOOPENUM,bopJZERO,bopJNZERO:begin
     asm
      jmp @Skip
       @CodeBegin:
        xor rax,rax
        mov eax,dword ptr [r12+TBESENCodeContext.PC]
        jmp qword ptr [r13+rax*8]
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;
     AddCode(CodeBegin,CodeEnd);
    end;
   end;

  end;
begin
 result:=false;
 try
  CodeContext:=TBESENCodeContext(ACodeContext);
  Code:=TBESENCode(CodeContext.Code);
  if assigned(Code.NativeCode) then begin
   TBESEN(CodeContext.Instance).NativeCodeMemoryManager.FreeMemory(Code.NativeCode);
   Code.NativeCode:=nil;
   Code.NativeCodeSize:=0;
  end;
  CodeBuffer:=nil;
  CodeBufferLen:=0;
  CurrentPC:=0;
  Fixups:=nil;
  CountFixups:=0;
  Offsets:=nil;
  ByteCode:=@Code.ByteCode[0];
  SetLength(Offsets,Code.ByteCodeLen);
  while CurrentPC<TBESENUINT32(Code.ByteCodeLen) do begin
   Offsets[CurrentPC]:=CodeBufferLen;
   Instruction:=ByteCode^[CurrentPC];
   Operands:=@ByteCode^[CurrentPC+1];
   inc(CurrentPC,1+(Instruction shr 8));
   Opcode:=Instruction and $ff;

   case Opcode of
    bopSTOP:begin
     asm
      jmp @Skip
       @CodeBegin:
        mov dword ptr [r12+TBESENCodeContext.BlockRunning],0
        mov dword ptr [r12+TBESENCodeContext.Running],0
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;
     AddCode(CodeBegin,CodeEnd);

     Add(#$e9); // jmp to code end
     if CountFixups>=length(Fixups) then begin
      SetLength(Fixups,CountFixups+4096);
     end;
     Fixups[CountFixups].Kind:=fkRET;
     Fixups[CountFixups].Ofs:=CodeBufferLen;
     inc(CountFixups);
     Add(#$00#$00#$00#$00);
    end;
    bopNEW:begin
     AddDispatcher;
    end;
    bopCALL:begin
     AddDispatcher;
    end;
    bopEND:begin
     if (Code.MaxBlock=0) and (Operands^[0]=0) then begin
      asm
       jmp @Skip
        @CodeBegin:
         mov dword ptr [r12+TBESENCodeContext.BlockRunning],0
         mov dword ptr [r12+TBESENCodeContext.Running],0
        @CodeEnd:
       @Skip:
       push rax
       mov rax,offset @CodeBegin
       mov qword ptr CodeBegin,rax
       mov rax,offset @CodeEnd
       mov qword ptr CodeEnd,rax
       pop rax
      end;
      AddCode(CodeBegin,CodeEnd);

      Add(#$e9); // jmp to code end
      if CountFixups>=length(Fixups) then begin
       SetLength(Fixups,CountFixups+4096);
      end;
      Fixups[CountFixups].Kind:=fkRET;
      Fixups[CountFixups].Ofs:=CodeBufferLen;
      inc(CountFixups);
      Add(#$00#$00#$00#$00);
     end else begin
      AddDispatcher;
     end;
    end;
    bopVREF:begin
     AddDispatcher;
    end;
    bopLREF:begin
     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtLOCAL
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtLOCAL);

     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.LocalIndex],LocalIndex
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.LocalIndex))-ptruint(pointer(@v))));
     AddDWord(Operands^[1]);
    end;
    bopNOP:begin
    end;
      bopCOPY:begin
       AddDispatcher;
      end;
    bopNEQ:begin
     AddDispatcher;
    end;
    bopNSEQ:begin
     AddDispatcher;
    end;
    bopAREF:begin
     AddDispatcher;
    end;
    bopTHROW:begin
     AddDispatcher;
    end;
    bopSETC:begin
     AddDispatcher;
    end;
    bopGETC:begin
     AddDispatcher;
    end;
    bopTHIS:begin
     AddDispatcher;
    end;
    bopOBJECT:begin
     asm
      jmp @Skip
       @CodeBegin:
        mov rax,qword ptr [rbx+TBESEN.ObjectConstructor]
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;
     AddCode(CodeBegin,CodeEnd);

     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtOBJECT
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtOBJECT);

     Add(#$49#$89#$86); // mov qword ptr [r14+RegisterOfs+TBESENValue.Obj],rax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Obj))-ptruint(pointer(@v))));
    end;
    bopARRAY:begin
     asm
      jmp @Skip
       @CodeBegin:
        mov rax,qword ptr [rbx+TBESEN.ObjectArrayConstructor]
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;
     AddCode(CodeBegin,CodeEnd);

     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtOBJECT
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtOBJECT);

     Add(#$49#$89#$86); // mov qword ptr [r14+RegisterOfs+TBESENValue.Obj],rax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Obj))-ptruint(pointer(@v))));
    end;
    bopREGEXP:begin
     asm
      jmp @Skip
       @CodeBegin:
        mov rax,qword ptr [rbx+TBESEN.ObjectRegExpConstructor]
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;
     AddCode(CodeBegin,CodeEnd);

     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtOBJECT
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtOBJECT);

     Add(#$49#$89#$86); // mov qword ptr [r14+RegisterOfs+TBESENValue.Obj],rax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Obj))-ptruint(pointer(@v))));
    end;
    bopREF:begin
     AddDispatcher;
    end;
    bopGETVALUE:begin
     AddDispatcher;
    end;
    bopLOOKUP:begin
     AddDispatcher;
    end;
    bopPUTVALUE:begin
     AddDispatcher;
    end;
    bopDELETE:begin
     AddDispatcher;
    end;
    bopTYPEOF:begin
     AddDispatcher;
    end;
    bopTOOBJECT:begin
     AddDispatcher;
    end;
    bopTONUMBER:begin
     if Operands^[0]=Operands^[1] then begin
      Add(#$41#$81#$be); // cmp dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtNUMBER
      AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtNUMBER);

      Add(#$0f#$84); // jz SkipDispatcher
      Temp:=CodeBufferLen;
      Add(#$00#$00#$00#$00);

      AddDispatcher;

      longword(pointer(@CodeBuffer[Temp])^):=longword(CodeBufferLen-(Temp+4));
     end else begin
      Add(#$41#$81#$be); // cmp dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtNUMBER
      AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtNUMBER);

      Add(#$0f#$85); // jnz Dispatcher
      Temp:=CodeBufferLen;
      Add(#$00#$00#$00#$00);

      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtNUMBER
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtNUMBER);

      Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
      AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

      Add(#$f2#$41#$0f#$11#$86); // movsd qword ptr [r14+RegisterOfs+TBESENValue.Num],xmm0
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

      Add(#$e9); // jmp End
      Literal:=CodeBufferLen;
      Add(#$00#$00#$00#$00);

      longword(pointer(@CodeBuffer[Temp])^):=longword(CodeBufferLen-(Temp+4));
      AddDispatcher;
      longword(pointer(@CodeBuffer[Literal])^):=longword(CodeBufferLen-(Literal+4));
     end;
    end;
    bopTOBOOLEAN:begin
     if Operands^[0]=Operands^[1] then begin
      Add(#$41#$81#$be); // cmp dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
      AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtBOOLEAN);

      Add(#$0f#$84); // jz SkipDispatcher
      Temp:=CodeBufferLen;
      Add(#$00#$00#$00#$00);

      AddDispatcher;

      longword(pointer(@CodeBuffer[Temp])^):=longword(CodeBufferLen-(Temp+4));
     end else begin
      Add(#$41#$81#$be); // cmp dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
      AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtBOOLEAN);

      Add(#$0f#$85); // jnz Dispatcher
      Temp:=CodeBufferLen;
      Add(#$00#$00#$00#$00);

      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtBOOLEAN);

      Add(#$41#$8b#$86); // mov eax,dword ptr [r14+RegisterOfs+TBESENValue.Bool]
      AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));

      Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));

      Add(#$e9); // jmp End
      Literal:=CodeBufferLen;
      Add(#$00#$00#$00#$00);

      longword(pointer(@CodeBuffer[Temp])^):=longword(CodeBufferLen-(Temp+4));
      AddDispatcher;
      longword(pointer(@CodeBuffer[Literal])^):=longword(CodeBufferLen-(Literal+4));
     end;
    end;
    bopTOSTRING:begin
     AddDispatcher;
    end;
    bopTOPRIMITIVE:begin
     AddDispatcher;
    end;
    bopNEG:begin
     if Operands^[0]<>Operands^[1] then begin
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtNUMBER
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtNUMBER);
     end;

     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$f2#$41#$0f#$11#$86); // movsd qword ptr [r14+RegisterOfs+TBESENValue.Num],xmm0
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$41#$81#$b6); // xor dword ptr [r14+RegisterOfs+TBESENValue.Num+4],$80000000
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+((ptruint(pointer(@v.Num))+4)-ptruint(pointer(@v))));
     AddDWord($80000000);
    end;
    bopINV:begin
     AddDispatcher;
    end;
    bopNOT:begin
     Add(#$41#$8b#$86); // mov eax,dword ptr [r14+RegisterOfs+TBESENValue.Bool]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));

     asm
      jmp @Skip
       @CodeBegin:
        cmp eax,$01
        sbb eax,eax
        neg eax
        neg al
        sbb eax,eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;
     AddCode(CodeBegin,CodeEnd);

     if Operands^[0]<>Operands^[1] then begin
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtBOOLEAN);
     end;

     Add(#$41#$89#$86); // mov dword ptr [edi+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
    end;
    bopMUL:begin
     if (Operands^[0]<>Operands^[1]) and (Operands^[0]<>Operands^[2]) then begin
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtNUMBER
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtNUMBER);
     end;

     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$f2#$41#$0f#$59#$86); // mulsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[2]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$f2#$41#$0f#$11#$86); // movsd qword ptr [r14+RegisterOfs+TBESENValue.Num],xmm0
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));
    end;
    bopDIV:begin
     if (Operands^[0]<>Operands^[1]) and (Operands^[0]<>Operands^[2]) then begin
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtNUMBER
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtNUMBER);
     end;

     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$f2#$41#$0f#$5e#$86); // divsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[2]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$f2#$41#$0f#$11#$86); // movsd qword ptr [r14+RegisterOfs+TBESENValue.Num],xmm0
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));
    end;
    bopMOD:begin
     AddDispatcher;
    end;
    bopADD:begin
     AddDispatcher;
    end;
    bopADDNUM:begin
     if (Operands^[0]<>Operands^[1]) and (Operands^[0]<>Operands^[2]) then begin
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtNUMBER
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtNUMBER);
     end;

     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$f2#$41#$0f#$58#$86); // addsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[2]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$f2#$41#$0f#$11#$86); // movsd qword ptr [r14+RegisterOfs+TBESENValue.Num],xmm0
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));
    end;
    bopSUB:begin
     if (Operands^[0]<>Operands^[1]) and (Operands^[0]<>Operands^[2]) then begin
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtNUMBER
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtNUMBER);
     end;

     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$f2#$41#$0f#$5c#$86); // subsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[2]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$f2#$41#$0f#$11#$86); // movsd qword ptr [r14+RegisterOfs+TBESENValue.Num],xmm0
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));
    end;
    bopSHL:begin
     AddDispatcher;
    end;
    bopSHR:begin
     AddDispatcher;
    end;
    bopUSHR:begin
     AddDispatcher;
    end;
    bopLT:begin
     AddDispatcher;
    end;
    bopGT:begin
     AddDispatcher;
    end;
    bopLE:begin
     AddDispatcher;
    end;
    bopGE:begin
     AddDispatcher;
    end;
    bopINSTANCEOF:begin
     AddDispatcher;
    end;
    bopIN:begin
     AddDispatcher;
    end;
    bopEQ:begin
     AddDispatcher;
    end;
    bopSEQ:begin
     AddDispatcher;
    end;
    bopBAND:begin
     AddDispatcher;
    end;
    bopBXOR:begin
     AddDispatcher;
    end;
    bopBOR:begin
     AddDispatcher;
    end;
    bopSENUM:begin
     AddDispatcher;
    end;
    bopSWITH:begin
     AddDispatcher;
    end;
    bopSCATCH:begin
     AddDispatcher;
    end;
    bopENDF:begin
     AddDispatcher;
    end;
    bopJMP:begin
     if longword(Operands^[0])<>CurrentPC then begin
      Add(#$e9); // jmp Arg
      if CountFixups>=length(Fixups) then begin
       SetLength(Fixups,CountFixups+4096);
      end;
      Fixups[CountFixups].Kind:=fkOFS;
      Fixups[CountFixups].Ofs:=CodeBufferLen;
      Fixups[CountFixups].ToOfs:=Operands^[0];
      inc(CountFixups);
      Add(#$00#$00#$00#$00);
     end;
    end;
    bopJZ:begin
     if longword(Operands^[0])<>CurrentPC then begin
      Add(#$41#$83#$be); // cmp dword ptr [r14+RegisterOfs+TBESENValue.Bool],0
      AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
      Add(#$00);

      Add(#$0f#$85); // jnz Arg
      if CountFixups>=length(Fixups) then begin
       SetLength(Fixups,CountFixups+4096);
      end;
      Fixups[CountFixups].Kind:=fkOFS;
      Fixups[CountFixups].Ofs:=CodeBufferLen;
      Fixups[CountFixups].ToOfs:=Operands^[0];
      inc(CountFixups);
      Add(#$00#$00#$00#$00);
     end;
    end;
    bopJNZ:begin
     if longword(Operands^[0])<>CurrentPC then begin
      Add(#$41#$83#$be); // cmp dword ptr [r14+RegisterOfs+TBESENValue.Bool],0
      AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
      Add(#$00);

      Add(#$0f#$84); // jnz Arg
      if CountFixups>=length(Fixups) then begin
       SetLength(Fixups,CountFixups+4096);
      end;
      Fixups[CountFixups].Kind:=fkOFS;
      Fixups[CountFixups].Ofs:=CodeBufferLen;
      Fixups[CountFixups].ToOfs:=Operands^[0];
      inc(CountFixups);
      Add(#$00#$00#$00#$00);
     end;
    end;
    bopJNULL:begin
     AddDispatcher;
    end;
    bopLOOPENUM:begin
     AddDispatcher;
    end;
    bopSTRYC:begin
     AddDispatcher;
    end;
    bopSTRYF:begin
     AddDispatcher;
    end;
     bopLITERALUNDEF:begin
      // Optimize: Use shorter encoding for UNDEFINED constant
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtUNDEFINED (3)
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtUNDEFINED); // 3
     end;
     bopLITERALNULL:begin
      // Optimize: Use shorter encoding for NULL constant
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtNULL (4)
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtNULL); // 4
     end;
     bopLITERALBOOL:begin
      // Set ValueType to BOOLEAN (0)
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtBOOLEAN); // 0

      // Set Bool field to either BESENLongBooleanValues[true] or [false]
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],value
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
      if Operands^[1]<>0 then begin
       AddDWord(longword(pointer(@BESENLongBooleanValues[true])^));
      end else begin
       AddDWord(longword(pointer(@BESENLongBooleanValues[false])^));
      end;
     end;
    bopLITERALNUM:begin
     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtNUMBER
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtNUMBER);

     Add(#$48#$b8); // mov rax,offset Num
     AddPtr(@Code.Literals[Operands^[1]].Num);

     Add(#$f2#$0f#$10#$00); // movsd xmm0,qword ptr [rax]

     Add(#$f2#$41#$0f#$11#$86); // movsd qword ptr [r14+RegisterOfs+TBESENValue.Num],xmm0
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));
    end;
    bopLITERALSTR:begin
     AddDispatcher;
    end;
    bopLITERALOBJ:begin
     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtOBJECT
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtOBJECT);

     Add(#$48#$b8); // mov rax,Obj
     AddPtr(Code.Literals[Operands^[1]].Obj);

     Add(#$49#$89#$86); // mov qword ptr [r14+RegisterOfs+TBESENValue.Obj],rax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Obj))-ptruint(pointer(@v))));
    end;
    bopFUNC:begin
     AddDispatcher;
    end;
    bopLINE:begin
     Add(#$b8); // mov eax,Arg
     AddDWord(Code.Locations[Operands^[0]].iLineNumber);

     asm
      jmp @Skip
       @CodeBegin:
        mov dword ptr [rbx+TBESEN.LineNumber],eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;
     AddCode(CodeBegin,CodeEnd);
    end;
    bopGC:begin
     Add(#$48#$8b#$83); // mov rax,qword ptr [rbx+TBESEN.GarbageCollector]
     AddDWord(ptruint(pointer(@TBESEN(nil^).GarbageCollector)));

{$ifdef windows}
     Add(#$48#$83#$ec#$28); // sub rsp,40
     Add(#$48#$89#$c1); // mov rcx,rax
{$else}
     Add(#$48#$83#$ec#$08); // sub rsp,8
     Add(#$48#$89#$c7); // mov rdi,rax
{$endif}

     Add(#$48#$b8); // mov rax,offset TBESENGarbageCollector.TriggerCollect
     AddPtr(@TBESENGarbageCollector.TriggerCollect);
     Add(#$ff#$d0); // call rax

{$ifdef windows}
     Add(#$48#$83#$c4#$28); // add rsp,40
{$else}
     Add(#$48#$83#$c4#$08); // add rsp,8
{$endif}
    end;
    bopSTRICT:begin
     Add(#$b8); // mov eax,Arg
     AddDWord(longword(BESENLongBooleanValues[Operands^[0]<>0]));

     asm
      jmp @Skip
       @CodeBegin:
        mov dword ptr [rbx+TBESEN.IsStrict],eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;
     AddCode(CodeBegin,CodeEnd);
    end;
    bopSTRICTCHECKREF:begin
     if not Code.Body.IsStrict then begin
      Add(#$41#$8b#$86); // mov eax,dword ptr [r14+RegisterOfs+TBESENValue.ReferenceIsStrict]
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ReferenceIsStrict))-ptruint(pointer(@v))));

      Add(#$85#$c0); // test eax,rax

      Add(#$0f#$84); // jz Arg
      if CountFixups>=length(Fixups) then begin
       SetLength(Fixups,CountFixups+4096);
      end;
      Fixups[CountFixups].Kind:=fkOFS;
      Fixups[CountFixups].Ofs:=CodeBufferLen;
      Fixups[CountFixups].ToOfs:=CurrentPC;
      inc(CountFixups);
      Add(#$00#$00#$00#$00);
     end;

     AddDispatcher;
    end;
    bopDEBUGGER:begin
     if TBESEN(CodeContext.Instance).CodeTracable then begin
      AddDispatcher;
     end;
    end;
    bopCHECKOBJECTCOERCIBLE:begin
     AddDispatcher;
    end;
    bopPUTOBJVALUE:begin
     AddDispatcher;
    end;
    bopPUTOBJGET:begin
     AddDispatcher;
    end;
    bopPUTOBJSET:begin
     AddDispatcher;
    end;
    bopINC:begin
     if Operands^[0]<>Operands^[1] then begin
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtNUMBER
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtNUMBER);
     end;

     Add(#$48#$b8); // mov rax,offset BESENDoubleOne
     AddPtr(@BESENDoubleOne);

     Add(#$f2#$0f#$10#$00); // movsd xmm0,qword ptr [rax]

     Add(#$f2#$41#$0f#$58#$86); // addsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$f2#$41#$0f#$11#$86); // movsd qword ptr [r14+RegisterOfs+TBESENValue.Num],xmm0
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));
    end;
    bopDEC:begin
     if Operands^[0]<>Operands^[1] then begin
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtNUMBER
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtNUMBER);
     end;

     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$48#$b8); // mov rax,offset BESENDoubleOne
     AddPtr(@BESENDoubleOne);

     Add(#$f2#$0f#$5c#$00); // subsd xmm0,qword ptr [rax]

     Add(#$f2#$41#$0f#$11#$86); // movsd qword ptr [r14+RegisterOfs+TBESENValue.Num],xmm0
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));
    end;
    bopCOPYBOOL:begin
     if Operands^[0]<>Operands^[1] then begin
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtBOOLEAN);

      Add(#$41#$8b#$86); // mov eax,dword ptr [r14+RegisterOfs+TBESENValue.Bool]
      AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));

      Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
     end;
    end;
    bopCOPYNUM:begin
     if Operands^[0]<>Operands^[1] then begin
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtNUMBER
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtNUMBER);

      Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
      AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

      Add(#$f2#$41#$0f#$11#$86); // movsd qword ptr [r14+RegisterOfs+TBESENValue.Num],xmm0
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));
     end;
    end;
     bopCOPYOBJ:begin
      if Operands^[0]<>Operands^[1] then begin
       Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtOBJECT
       AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
       AddDWord(bvtOBJECT);

       Add(#$49#$8b#$86); // mov rax,qword ptr [r14+RegisterOfs+TBESENValue.Obj]
       AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Obj))-ptruint(pointer(@v))));

       Add(#$49#$89#$86); // mov qword ptr [r14+RegisterOfs+TBESENValue.Obj],rax
       AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Obj))-ptruint(pointer(@v))));
      end;
     end;
    bopCOPYREF:begin
     if Operands^[0]<>Operands^[1] then begin
      AddDispatcher;
     end;
    end;
    bopCOPYLOCAL:begin
     if Operands^[0]<>Operands^[1] then begin
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtLOCAL
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtLOCAL);

      Add(#$41#$8b#$86); // mov eax,dword ptr [r14+RegisterOfs+TBESENValue.LocalIndex]
      AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.LocalIndex))-ptruint(pointer(@v))));

      Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.LocalIndex],eax
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.LocalIndex))-ptruint(pointer(@v))));
     end;
    end;
    bopGETVALUEREF:begin
     AddDispatcher;
    end;
    bopPUTVALUEREF:begin
     AddDispatcher;
    end;
    bopGETVALUELOCAL:begin
     AddDispatcher;
    end;
    bopPUTVALUELOCAL:begin
     AddDispatcher;
    end;
    bopGETVALUELOCALFAST:begin
     AddDispatcher;
    end;
    bopPUTVALUELOCALFAST:begin
     AddDispatcher;
    end;
    bopGETVALUELOCALBOOL:begin
     AddDispatcher;
    end;
    bopPUTVALUELOCALBOOL:begin
     AddDispatcher;
    end;
    bopGETVALUELOCALNUM:begin
     AddDispatcher;
    end;
    bopPUTVALUELOCALNUM:begin
     AddDispatcher;
    end;
    bopGETVALUELOCALSTR:begin
     AddDispatcher;
    end;
    bopPUTVALUELOCALSTR:begin
     AddDispatcher;
    end;
    bopGETVALUELOCALOBJ:begin
     AddDispatcher;
    end;
    bopPUTVALUELOCALOBJ:begin
     AddDispatcher;
    end;
    bopGETVALUELOCALINDEX:begin
     AddDispatcher;
    end;
    bopPUTVALUELOCALINDEX:begin
     AddDispatcher;
    end;
   bopGETVALUELOCALINDEXBOOL:begin
     AddDispatcher;
    end;
    bopPUTVALUELOCALINDEXBOOL:begin
     AddDispatcher;
    end;
    bopGETVALUELOCALINDEXNUM:begin
     AddDispatcher;
    end;
    bopPUTVALUELOCALINDEXNUM:begin
     AddDispatcher;
    end;
    bopGETVALUELOCALINDEXSTR:begin
     AddDispatcher;
    end;
    bopPUTVALUELOCALINDEXSTR:begin
     AddDispatcher;
    end;
   bopGETVALUELOCALINDEXOBJ:begin
     AddDispatcher;
    end;
    bopPUTVALUELOCALINDEXOBJ:begin
     AddDispatcher;
    end;
    bopLOOPINITCOUNT:begin
    end;
    bopLOOPADDCOUNT:begin
    end;
    bopTRACE:begin
     if TBESEN(CodeContext.Instance).CodeTracable then begin
      AddDispatcher;
     end;
    end;
    bopLTBOOL:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$41#$8b#$86); // mov eax,dword ptr [r14+RegisterOfs+TBESENValue.Bool]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));

     Add(#$41#$8b#$96); // mov edx,dword ptr [r14+RegisterOfs+TBESENValue.Bool]
     AddDWord(ptruint(Operands^[2]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));

     asm
      jmp @Skip
       @CodeBegin:
        cmp al,$01
        sbb eax,eax
        inc eax
        cmp dl,$01
        sbb edx,edx
        inc edx
        cmp al,dl
        setb al
        neg al
        sbb eax,eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     if (Operands^[0]<>Operands^[1]) and (Operands^[0]<>Operands^[2]) then begin
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtBOOLEAN);
     end;

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    bopGTBOOL:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$41#$8b#$86); // mov eax,dword ptr [r14+RegisterOfs+TBESENValue.Bool]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));

     Add(#$41#$8b#$96); // mov edx,dword ptr [r14+RegisterOfs+TBESENValue.Bool]
     AddDWord(ptruint(Operands^[2]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));

     asm
      jmp @Skip
       @CodeBegin:
        cmp al,$01
        sbb eax,eax
        inc eax
        cmp dl,$01
        sbb edx,edx
        inc edx
        cmp al,dl
        setnbe al
        neg al
        sbb eax,eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     if (Operands^[0]<>Operands^[1]) and (Operands^[0]<>Operands^[2]) then begin
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtBOOLEAN);
     end;

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    bopLEBOOL:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$41#$8b#$86); // mov eax,dword ptr [r14+RegisterOfs+TBESENValue.Bool]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));

     Add(#$41#$8b#$96); // mov edx,dword ptr [r14+RegisterOfs+TBESENValue.Bool]
     AddDWord(ptruint(Operands^[2]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));

     asm
      jmp @Skip
       @CodeBegin:
        cmp al,$01
        sbb eax,eax
        inc eax
        cmp dl,$01
        sbb edx,edx
        inc edx
        cmp al,dl
        setbe al
        neg al
        sbb eax,eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     if (Operands^[0]<>Operands^[1]) and (Operands^[0]<>Operands^[2]) then begin
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtBOOLEAN);
     end;

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    bopGEBOOL:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$41#$8b#$86); // mov eax,dword ptr [r14+RegisterOfs+TBESENValue.Bool]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));

     Add(#$41#$8b#$96); // mov edx,dword ptr [r14+RegisterOfs+TBESENValue.Bool]
     AddDWord(ptruint(Operands^[2]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));

     asm
      jmp @Skip
       @CodeBegin:
        cmp al,$01
        sbb eax,eax
        inc eax
        cmp dl,$01
        sbb edx,edx
        inc edx
        cmp al,dl
        setnb al
        neg al
        sbb eax,eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     if (Operands^[0]<>Operands^[1]) and (Operands^[0]<>Operands^[2]) then begin
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtBOOLEAN);
     end;

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    bopEQBOOL:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$41#$8b#$86); // mov eax,dword ptr [r14+RegisterOfs+TBESENValue.Bool]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));

     Add(#$41#$8b#$96); // mov edx,dword ptr [r14+RegisterOfs+TBESENValue.Bool]
     AddDWord(ptruint(Operands^[2]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));

     asm
      jmp @Skip
       @CodeBegin:
        cmp eax,edx
        setz al
        neg al
        sbb eax,eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     if (Operands^[0]<>Operands^[1]) and (Operands^[0]<>Operands^[2]) then begin
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtBOOLEAN);
     end;

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    bopNEQBOOL:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$41#$8b#$86); // mov eax,dword ptr [r14+RegisterOfs+TBESENValue.Bool]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));

     Add(#$41#$8b#$96); // mov edx,dword ptr [r14+RegisterOfs+TBESENValue.Bool]
     AddDWord(ptruint(Operands^[2]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));

     asm
      jmp @Skip
       @CodeBegin:
        cmp eax,edx
        setnz al
        neg al
        sbb eax,eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     if (Operands^[0]<>Operands^[1]) and (Operands^[0]<>Operands^[2]) then begin
      Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
      AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
      AddDWord(bvtBOOLEAN);
     end;

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    bopLTNUM:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$66#$41#$0f#$2f#$86); // comisd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[2]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     asm
      jmp @Skip
       @CodeBegin:
        setb al
        setnp cl
        and al,cl
        neg al
        sbb eax,eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtBOOLEAN);

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    bopGTNUM:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$66#$41#$0f#$2f#$86); // comisd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[2]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     asm
      jmp @Skip
       @CodeBegin:
        setnbe al
        setnp cl
        and al,cl
        neg al
        sbb eax,eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtBOOLEAN);

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    bopLENUM:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$66#$41#$0f#$2f#$86); // comisd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[2]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     asm
      jmp @Skip
       @CodeBegin:
        setbe al
        setnp cl
        and al,cl
        neg al
        sbb eax,eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtBOOLEAN);

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    bopGENUM:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$66#$41#$0f#$2f#$86); // comisd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[2]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     asm
      jmp @Skip
       @CodeBegin:
        setnb al
        setnp cl
        and al,cl
        neg al
        sbb eax,eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtBOOLEAN);

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    bopEQNUM:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$66#$41#$0f#$2f#$86); // comisd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[2]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     asm
      jmp @Skip
       @CodeBegin:
        setz al
        setnp cl
        and al,cl
        neg al
        sbb eax,eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtBOOLEAN);

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    bopNEQNUM:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$66#$41#$0f#$2f#$86); // comisd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[2]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     asm
      jmp @Skip
       @CodeBegin:
        setz al
        setnp cl
        and al,cl
        neg al
        sbb eax,eax
        not eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtBOOLEAN);

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    bopLTSTR:begin
     AddDispatcher;
    end;
    bopGTSTR:begin
     AddDispatcher;
    end;
    bopLESTR:begin
     AddDispatcher;
    end;
    bopGESTR:begin
     AddDispatcher;
    end;
    bopEQSTR:begin
     AddDispatcher;
    end;
    bopNEQSTR:begin
     AddDispatcher;
    end;
    bopSHLBOOL:begin
     AddDispatcher;
    end;
    bopSHRBOOL:begin
     AddDispatcher;
    end;
    bopBANDBOOL:begin
     AddDispatcher;
    end;
    bopBXORBOOL:begin
     AddDispatcher;
    end;
    bopBORBOOL:begin
     AddDispatcher;
    end;
    bopSHLNUM:begin
     AddDispatcher;
    end;
    bopSHRNUM:begin
     AddDispatcher;
    end;
    bopUSHRNUM:begin
     AddDispatcher;
    end;
    bopBANDNUM:begin
     AddDispatcher;
    end;
    bopBXORNUM:begin
     AddDispatcher;
    end;
    bopBORNUM:begin
     AddDispatcher;
    end;
    bopSETCUNDEF:begin
     asm
      jmp @Skip
       @CodeBegin:
        lea rax,qword ptr [r12+TBESENCodeContext.ResultValue]
        mov dword ptr [rax+TBESENValue.ValueType],bvtUNDEFINED
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;
     AddCode(CodeBegin,CodeEnd);
    end;
    bopSETCNULL:begin
     asm
      jmp @Skip
       @CodeBegin:
        lea rax,qword ptr [r12+TBESENCodeContext.ResultValue]
        mov dword ptr [rax+TBESENValue.ValueType],bvtNULL
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;
     AddCode(CodeBegin,CodeEnd);
    end;
    bopSETCBOOL:begin
     Add(#$49#$8d#$86); // lea rax,qword ptr [r14+RegisterOfs]
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue)));
     asm
      jmp @Skip
       @CodeBegin:
        lea rdx,qword ptr [r12+TBESENCodeContext.ResultValue]
        mov dword ptr [rdx+TBESENValue.ValueType],bvtBOOLEAN
        mov ecx,dword ptr [rax+TBESENValue.Bool]
        mov dword ptr [rdx+TBESENValue.Bool],ecx
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;
     AddCode(CodeBegin,CodeEnd);
    end;
    bopSETCNUM:begin
     Add(#$49#$8d#$86); // lea rax,qword ptr [r14+RegisterOfs]
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue)));
     asm
      jmp @Skip
       @CodeBegin:
        lea rdx,qword ptr [r12+TBESENCodeContext.ResultValue]
        mov dword ptr [rdx+TBESENValue.ValueType],bvtNUMBER
        movsd xmm0,qword ptr [rax+TBESENValue.Num]
        movsd qword ptr [rdx+TBESENValue.Num],xmm0
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;
     AddCode(CodeBegin,CodeEnd);
    end;
    bopSETCSTR:begin
     AddDispatcher;
    end;
    bopSETCOBJ:begin
     Add(#$49#$8d#$86); // lea rax,qword ptr [r14+RegisterOfs]
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue)));
     asm
      jmp @Skip
       @CodeBegin:
        lea rdx,qword ptr [r12+TBESENCodeContext.ResultValue]
        mov dword ptr [rdx+TBESENValue.ValueType],bvtOBJECT
        mov rcx,qword ptr [rax+TBESENValue.Obj]
        mov qword ptr [rdx+TBESENValue.Obj],rcx
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;
     AddCode(CodeBegin,CodeEnd);
    end;
    bopTRACENEW:begin
     AddDispatcher;
    end;
    bopTRACECALL:begin
     AddDispatcher;
    end;
    bopLTNUMCONST:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$48#$b8); // mov rax,offset Num
     AddPtr(@Code.Literals[Operands^[2]].Num);

     Add(#$66#$0f#$2f#$00); // comisd xmm0,qword ptr [rax]

     asm
      jmp @Skip
       @CodeBegin:
        setb al
        setnp cl
        and al,cl
        neg al
        sbb eax,eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtBOOLEAN);

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    bopGTNUMCONST:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$48#$b8); // mov rax,offset Num
     AddPtr(@Code.Literals[Operands^[2]].Num);

     Add(#$66#$0f#$2f#$00); // comisd xmm0,qword ptr [rax]

     asm
      jmp @Skip
       @CodeBegin:
        setnbe al
        setnp cl
        and al,cl
        neg al
        sbb eax,eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtBOOLEAN);

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    bopLENUMCONST:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$48#$b8); // mov rax,offset Num
     AddPtr(@Code.Literals[Operands^[2]].Num);

     Add(#$66#$0f#$2f#$00); // comisd xmm0,qword ptr [rax]

     asm
      jmp @Skip
       @CodeBegin:
        setbe al
        setnp cl
        and al,cl
        neg al
        sbb eax,eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtBOOLEAN);

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    bopGENUMCONST:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$48#$b8); // mov rax,offset Num
     AddPtr(@Code.Literals[Operands^[2]].Num);

     Add(#$66#$0f#$2f#$00); // comisd xmm0,qword ptr [rax]

     asm
      jmp @Skip
       @CodeBegin:
        setnb al
        setnp cl
        and al,cl
        neg al
        sbb eax,eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtBOOLEAN);

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    bopEQNUMCONST:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$48#$b8); // mov rax,offset Num
     AddPtr(@Code.Literals[Operands^[2]].Num);

     Add(#$66#$0f#$2f#$00); // comisd xmm0,qword ptr [rax]

     asm
      jmp @Skip
       @CodeBegin:
        setz al
        setnp cl
        and al,cl
        neg al
        sbb eax,eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtBOOLEAN);

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    bopNEQNUMCONST:begin
{$ifdef UseSafeOperations}
     AddDispatcher;
{$else}
     Add(#$f2#$41#$0f#$10#$86); // movsd xmm0,qword ptr [r14+RegisterOfs+TBESENValue.Num]
     AddDWord(ptruint(Operands^[1]*sizeof(TBESENValue))+(ptruint(pointer(@v.Num))-ptruint(pointer(@v))));

     Add(#$48#$b8); // mov rax,offset Num
     AddPtr(@Code.Literals[Operands^[2]].Num);

     Add(#$66#$0f#$2f#$00); // comisd xmm0,qword ptr [rax]

     asm
      jmp @Skip
       @CodeBegin:
        setz al
        setnp cl
        and al,cl
        neg al
        sbb eax,eax
        not eax
       @CodeEnd:
      @Skip:
      push rax
      mov rax,offset @CodeBegin
      mov qword ptr CodeBegin,rax
      mov rax,offset @CodeEnd
      mov qword ptr CodeEnd,rax
      pop rax
     end;

     AddCode(CodeBegin,CodeEnd);

     Add(#$41#$c7#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.ValueType],bvtBOOLEAN
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.ValueType))-ptruint(pointer(@v))));
     AddDWord(bvtBOOLEAN);

     Add(#$41#$89#$86); // mov dword ptr [r14+RegisterOfs+TBESENValue.Bool],eax
     AddDWord(ptruint(Operands^[0]*sizeof(TBESENValue))+(ptruint(pointer(@v.Bool))-ptruint(pointer(@v))));
{$endif}
    end;
    else begin
     AddDispatcher;
    end;
   end;

  end;
  RetOfs:=CodeBufferLen;
  Add(#$c3); // ret
  SetLength(CodeBuffer,CodeBufferLen);
  Code.NativeCodeSize:=CodeBufferLen;
  Code.NativeCode:=TBESEN(CodeContext.Instance).NativeCodeMemoryManager.GetMemory(Code.NativeCodeSize);
  move(CodeBuffer[0],Code.NativeCode^,Code.NativeCodeSize);
  SetLength(Code.NativeCodePCOffsets,Code.ByteCodeLen);
  for i:=0 to Code.ByteCodeLen-1 do begin
   Code.NativeCodePCOffsets[i]:=pointer(@PBESENByteArray(Code.NativeCode)[Offsets[i]]);
  end;
  for i:=0 to CountFixups-1 do begin
   case FixUps[i].Kind of
    fkPTR:begin
     longword(pointer(@PBESENByteArray(Code.NativeCode)[FixUps[i].Ofs])^):=(ptruint(FixUps[i].Dest)-(ptruint(pointer(@PBESENByteArray(Code.NativeCode)[FixUps[i].Ofs]))+4));
    end;
    fkRET:begin
     longword(pointer(@PBESENByteArray(Code.NativeCode)[FixUps[i].Ofs])^):=(ptruint(pointer(@PBESENByteArray(Code.NativeCode)[RetOfs]))-(ptruint(pointer(@PBESENByteArray(Code.NativeCode)[FixUps[i].Ofs]))+4));
    end;
    fkOFS:begin
     longword(pointer(@PBESENByteArray(Code.NativeCode)[FixUps[i].Ofs])^):=(ptruint(Code.NativeCodePCOffsets[FixUps[i].ToOfs])-(ptruint(pointer(@PBESENByteArray(Code.NativeCode)[FixUps[i].Ofs]))+4));
    end;
   end;
  end;
  result:=true;
 finally
  SetLength(Fixups,0);
  SetLength(Offsets,0);
  SetLength(CodeBuffer,0);
 end;
end;

function BESENExecuteNativeCode(ACodeContext:TObject):TBESENBoolean; {$ifdef UseRegister}register;{$endif}
var CodeContext:TBESENCodeContext;
begin
 CodeContext:=TBESENCodeContext(ACodeContext);
 CodeContext.BlockRunning:=true;
 asm
  // Preserve nonvolatile registers used by the JIT register layout.

  push rax                           // Save rax (temporary register)
  push rbx                           // Save rbx (we'll use it for instance pointer)
  push r12
  push r13
  push r14
  push r15

   // Load the code context and related pointers
   mov r12,qword ptr CodeContext     // r12 = TBESENCodeContext pointer
   mov rbx,qword ptr [r12+TBESENCodeContext.Instance]  // rbx = TBESEN instance
   mov r13,qword ptr [r12+TBESENCodeContext.Code]      // r13 = TBESENCode
   mov rax,qword ptr [r13+TBESENCode.Body]             // rax = Function body
   mov r13,qword ptr [r13+TBESENCode.NativeCodePCOffsets]  // r13 = PC offset array
   mov r14,qword ptr [r12+TBESENCodeContext.RegisterValues] // r14 = VM registers

   // r15 will hold the local hash table (for function scopes only)
   xor r15,r15
   mov eax,dword ptr [rax+TBESENASTNodeFunctionBody.IsFunction]
   test eax,eax
   jz @IsNoFunction
    // Get local variable hash table for function scope
    mov r15,qword ptr [r12+TBESENCodeContext.Context]
    mov r15,qword ptr [r15+TBESENContext.VariableEnvironment]
    mov r15,qword ptr [r15+TBESENLexicalEnvironment.EnvironmentRecord]
    mov r15,qword ptr [r15+TBESENDeclarativeEnvironmentRecord.HashValues]
   @IsNoFunction:

   // Get PC and dispatch to native code via jump table.
   xor rax,rax
   mov eax,dword ptr [r12+TBESENCodeContext.PC]

   // Align stack dynamically for the call into generated code.
   // rbp is non-volatile in both Win64 and SysV AMD64 — the callee will preserve it.
   // We use it as a frame anchor so the alignment delta is not lost across the call.
   push rbp             // save original rbp
   mov rbp,rsp          // anchor: rbp now holds rsp value after this push
   and rsp,-16          // align rsp to 16 bytes
{$ifdef windows}
   sub rsp,$20          // Win64: 32-byte shadow space
{$endif}
   call qword ptr [r13+rax*8]
{$ifdef windows}
   add rsp,$20
{$endif}
   mov rsp,rbp          // restore rsp to post-push-rbp value
   pop rbp              // restore original rbp

  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  pop rax
 end ['rax','rbx','rbp','r12','r13','r14','r15'];
 result:=CodeContext.BlockRunning;
end;
{$endif}
{$endif}

end.


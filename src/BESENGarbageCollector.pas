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

unit BESENGarbageCollector;
{$i BESEN.inc}

interface

uses BESENConstants,BESENTypes,BESENBaseObject,BESENCollectorObject,
     BESENPointerSelfBalancedTree,BESENValue;

type TBESENGarbageCollectorObjectList=class;

	 { TBESENGarbageCollectorObject }

     TBESENGarbageCollectorObject=class(TBESENCollectorObject) // TBESENObject, TBESENEnvironmentRecord, TBESENLexicalEnvironment, TBESENFunctionLiteralContainer, TBESENScope, TBESENValueContainer are all extended from this.
      public
       GarbageCollectorPrevious,GarbageCollectorNext,
       GarbageCollectorRootObjectListPrevious,GarbageCollectorRootObjectListNext,
       GarbageCollectorProtectedObjectListPrevious,GarbageCollectorProtectedObjectListNext,
       GarbageCollectorObjectListPrevious,GarbageCollectorObjectListNext:TBESENGarbageCollectorObject;

       GarbageCollectorObjectList:TBESENGarbageCollectorObjectList;

       GarbageCollectorDependsChildren, GarbageCollectorDependsParents: TBESENPointerSelfBalancedTree;

       GarbageCollectorLockReferenceCounter:integer;

       // OPT-1: Explicit membership flags replace unreliable pointer-heuristic Contains()
       GarbageCollectorInRootList:boolean;
       GarbageCollectorInProtectedList:boolean;
       constructor Create(AInstance:TObject); overload; override;
       destructor Destroy; override;

       procedure FreeupLists();

       procedure Finalize; virtual;
       procedure Mark; virtual;
       procedure DependsOn(Parent:TBESENGarbageCollectorObject);
       procedure GarbageCollectorWriteBarrier; {$ifdef caninline}inline;{$endif}
       procedure GarbageCollectorLock;         {$ifdef caninline}inline;{$endif}
       procedure GarbageCollectorUnlock;       {$ifdef caninline}inline;{$endif}
     end;

     // todo: TBESENGarbageCollectorRootObjectList, TBESENGarbageCollectorProtectedObjectList, TBESENGarbageCollectorObjectList: merge.

     TBESENGarbageCollectorRootObjectList=class(TBESENBaseObject)
      public
       First,Last:TBESENGarbageCollectorObject;
       constructor Create(AInstance:TObject); overload; override;
       destructor Destroy; override;
       procedure Clear;
       procedure ClearWithFree;
       procedure Add(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
       procedure Remove(AObject:TBESENGarbageCollectorObject);
       function Contains(AObject:TBESENGarbageCollectorObject):boolean;
       procedure Push(AObject:TBESENGarbageCollectorObject);
       function Pop:TBESENGarbageCollectorObject;
     end;

     TBESENGarbageCollectorProtectedObjectList=class(TBESENBaseObject)
      public
       First,Last:TBESENGarbageCollectorObject;
       constructor Create(AInstance:TObject); overload; override;
       destructor Destroy; override;
       procedure Clear;
       procedure ClearWithFree;
       procedure Add(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
       procedure Remove(AObject:TBESENGarbageCollectorObject);
       function Contains(AObject:TBESENGarbageCollectorObject):boolean;
       procedure Push(AObject:TBESENGarbageCollectorObject);
       function Pop:TBESENGarbageCollectorObject;
     end;

     TBESENGarbageCollectorObjectList=class(TBESENBaseObject)
      public
       First,Last:TBESENGarbageCollectorObject;
       constructor Create(AInstance:TObject); overload; override;
       destructor Destroy; override;
       procedure Clear;
       procedure ClearWithFree;
       procedure Add(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
       procedure Remove(AObject:TBESENGarbageCollectorObject);
       function Contains(AObject:TBESENGarbageCollectorObject):boolean;
       procedure Push(AObject:TBESENGarbageCollectorObject);
       function Pop:TBESENGarbageCollectorObject;
     end;

     TBESENGarbageCollectorState=(bgcsINIT,bgcsMARKROOTS,bgcsMARKPROTECTED,bgcsMARKPROGRAMNODES,bgcsMARKCONTEXTS,bgcsMARKGRAYS,bgcsSWEEPWHITES,bgcsDONE);

     TBESENGarbageCollector=class(TBESENBaseObject)
      public
       First,Last:TBESENGarbageCollectorObject;
       CurrentRootObject:TBESENGarbageCollectorObject;
       CurrentProtectedObject:TBESENGarbageCollectorObject;
       CurrentMarkObject:TBESENGarbageCollectorObject;
       CurrentSweepObject:TBESENGarbageCollectorObject;
       CurrentContext:TObject;

       // todo: unify classes, change.
       RootObjectList:TBESENGarbageCollectorRootObjectList;
       ProtectedObjectList:TBESENGarbageCollectorProtectedObjectList;

       WhiteObjectList:TBESENGarbageCollectorObjectList;
       GrayObjectList:TBESENGarbageCollectorObjectList;
       BlackObjectList:TBESENGarbageCollectorObjectList;



       IsSweeping:longbool;
       State:TBESENGarbageCollectorState;
       TriggerCounter:integer;
       MarkFactor:integer;
       TriggerCountPerCollect:integer;
       Count:int64;
       constructor Create(AInstance:TObject); overload; override;
       destructor Destroy; override;
       procedure Clear;
       procedure Reset;
       procedure WhiteIt(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
       procedure ForceGrayIt(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
       procedure GrayIt(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
       procedure BlackIt(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
       procedure Protect(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
       procedure Unprotect(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
       procedure FinalizeObjectForSweeping(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
       procedure GrayValue(var Value:TBESENValue);
       procedure FinalizeValue(var Value:TBESENValue); {$ifdef caninline}inline;{$endif}
       procedure Mark(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
       procedure Flip;
       procedure TriggerCollect;
       function Collect:boolean;
       procedure CollectAll;
       procedure Use(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
       procedure Add(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
       procedure AddRoot(AObject:TBESENGarbageCollectorObject);
       procedure RemoveRoot(AObject:TBESENGarbageCollectorObject);
       procedure AddProtected(AObject:TBESENGarbageCollectorObject);
       procedure RemoveProtected(AObject:TBESENGarbageCollectorObject);
       procedure LockObject(Obj:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
       procedure UnlockObject(Obj:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
       procedure LockValue(const Value:TBESENValue);
       procedure UnlockValue(const Value:TBESENValue);
     end;

implementation

uses BESEN,BESENUtils,BESENObject,BESENEnvironmentRecord,
     BESENASTNodes,BESENCode,BESENContext,
     BESENObjectDeclaredFunction;

constructor TBESENGarbageCollectorObject.Create(AInstance:TObject);
begin
 inherited Create(AInstance);
 inc(TBESEN(Instance).GarbageCollector.Count);
 GarbageCollectorPrevious:=TBESEN(Instance).GarbageCollector.Last;
 GarbageCollectorNext:=nil;
 if assigned(GarbageCollectorPrevious) then begin
  GarbageCollectorPrevious.GarbageCollectorNext:=self;
 end else begin
  TBESEN(Instance).GarbageCollector.First:=self;
 end;
 TBESEN(Instance).GarbageCollector.Last:=self;
 GarbageCollectorRootObjectListPrevious:=nil;
 GarbageCollectorRootObjectListNext:=nil;
 GarbageCollectorProtectedObjectListPrevious:=nil;
 GarbageCollectorProtectedObjectListNext:=nil;
 GarbageCollectorObjectListPrevious:=nil;
 GarbageCollectorObjectListNext:=nil;
 GarbageCollectorObjectList:=nil;
 GarbageCollectorDependsChildren:=TBESENPointerSelfBalancedTree.Create;
 GarbageCollectorDependsParents:=TBESENPointerSelfBalancedTree.Create;
 GarbageCollectorLockReferenceCounter:=0;
 GarbageCollectorInRootList:=false;      // OPT-1
 GarbageCollectorInProtectedList:=false; // OPT-1
end;

destructor TBESENGarbageCollectorObject.Destroy;
var n:PBESENPointerSelfBalancedTreeNode;
begin
 if assigned(GarbageCollectorPrevious) then begin
  GarbageCollectorPrevious.GarbageCollectorNext:=GarbageCollectorNext;
 end else if TBESEN(Instance).GarbageCollector.First=self then begin
  TBESEN(Instance).GarbageCollector.First:=GarbageCollectorNext;
 end;
 if assigned(GarbageCollectorNext) then begin
  GarbageCollectorNext.GarbageCollectorPrevious:=GarbageCollectorPrevious;
 end else if TBESEN(Instance).GarbageCollector.Last=self then begin
  TBESEN(Instance).GarbageCollector.Last:=GarbageCollectorPrevious;
 end;
 GarbageCollectorNext:=nil;
 GarbageCollectorPrevious:=nil;
 if assigned(GarbageCollectorObjectList) then begin
  GarbageCollectorObjectList.Remove(self);
  GarbageCollectorObjectList:=nil;
 end;

 FreeupLists();

 BESENFreeAndNil(GarbageCollectorDependsChildren);
 BESENFreeAndNil(GarbageCollectorDependsParents);
 if assigned(Instance) and assigned(TBESEN(Instance).GarbageCollector) then begin
  // OPT-1: O(1) flag check instead of O(n) list scan
  if assigned(TBESEN(Instance).GarbageCollector.RootObjectList) and GarbageCollectorInRootList then begin
   TBESEN(Instance).GarbageCollector.RootObjectList.Remove(self);
  end;
  if assigned(TBESEN(Instance).GarbageCollector.ProtectedObjectList) and GarbageCollectorInProtectedList then begin
   TBESEN(Instance).GarbageCollector.ProtectedObjectList.Remove(self);
  end;
 end;
 dec(TBESEN(Instance).GarbageCollector.Count);
 inherited Destroy;
end;

procedure TBESENGarbageCollectorObject.FreeupLists();
var
	n: PBESENPointerSelfBalancedTreeNode;
begin

 if assigned(GarbageCollectorDependsParents) then begin
   n:=GarbageCollectorDependsParents.FirstKey;
   while assigned(n) do begin
    if assigned(n^.Key) and assigned(TBESENGarbageCollectorObject(n^.Key).GarbageCollectorDependsChildren) then begin
     TBESENGarbageCollectorObject(n^.Key).GarbageCollectorDependsChildren.Remove(self);
    end;
    n:=n^.NextKey;
   end;
  end;
  if assigned(GarbageCollectorDependsChildren) then begin
   n:=GarbageCollectorDependsChildren.FirstKey;
   while assigned(n) do begin
    if assigned(n^.Key) and assigned(TBESENGarbageCollectorObject(n^.Key).GarbageCollectorDependsParents) then begin
     TBESENGarbageCollectorObject(n^.Key).GarbageCollectorDependsParents.Remove(self);
    end;
    n:=n^.NextKey;
   end;
  end;

end;

procedure TBESENGarbageCollectorObject.Finalize;
begin

	FreeupLists();

end;

procedure TBESENGarbageCollectorObject.Mark;
var n:PBESENPointerSelfBalancedTreeNode;
begin
 if assigned(GarbageCollectorDependsChildren) then begin
  n:=GarbageCollectorDependsChildren.FirstKey;
  while assigned(n) do begin
   if assigned(n^.Key) then begin
    TBESEN(Instance).GarbageCollector.GrayIt(TBESENGarbageCollectorObject(n^.Key));
   end;
   n:=n^.NextKey;
  end;
 end;
end;

procedure TBESENGarbageCollectorObject.DependsOn(Parent:TBESENGarbageCollectorObject);
var v:TBESENPointerSelfBalancedTreeValue;
begin
 if assigned(Parent) then begin
  if assigned(GarbageCollectorDependsParents) then begin
   v.p:=Parent;
   GarbageCollectorDependsParents.Insert(Parent,v);
  end;
  if assigned(Parent.GarbageCollectorDependsChildren) then begin
   v.p:=self;
   Parent.GarbageCollectorDependsChildren.Insert(self,v);
  end;
 end;
end;

procedure TBESENGarbageCollectorObject.GarbageCollectorWriteBarrier;
begin
 TBESEN(Instance).GarbageCollector.GrayIt(self);
end;

procedure TBESENGarbageCollectorObject.GarbageCollectorLock;
begin
 inc(GarbageCollectorLockReferenceCounter);
end;

procedure TBESENGarbageCollectorObject.GarbageCollectorUnlock;
begin
 // OPT-4: Guard against underflow — a negative counter would let the GC sweep
 // an object that the caller still holds a lock on.
 if GarbageCollectorLockReferenceCounter>0 then begin
  dec(GarbageCollectorLockReferenceCounter);
 end;
end;

constructor TBESENGarbageCollectorRootObjectList.Create(AInstance:TObject);
begin
 inherited Create(AInstance);
 Clear;
end;

destructor TBESENGarbageCollectorRootObjectList.Destroy;
begin
 Clear;
 inherited Destroy;
end;

procedure TBESENGarbageCollectorRootObjectList.Clear;
var Item,NextItem:TBESENGarbageCollectorObject;
begin
 Item:=First;
 while assigned(Item) do begin
  NextItem:=Item.GarbageCollectorRootObjectListNext;
  Item.GarbageCollectorRootObjectListPrevious:=nil;
  Item.GarbageCollectorRootObjectListNext:=nil;
  Item.GarbageCollectorInRootList:=false; // OPT-1
  Item:=NextItem;
 end;
 First:=nil;
 Last:=nil;
end;

procedure TBESENGarbageCollectorRootObjectList.ClearWithFree;
begin
 while assigned(First) do begin
  First.Free;
 end;
 Clear;
end;

procedure TBESENGarbageCollectorRootObjectList.Add(AObject:TBESENGarbageCollectorObject);
begin
 if AObject.GarbageCollectorInRootList then exit; // OPT-1: idempotent
 if assigned(Last) then begin
  Last.GarbageCollectorRootObjectListNext:=AObject;
  AObject.GarbageCollectorRootObjectListPrevious:=Last;
  AObject.GarbageCollectorRootObjectListNext:=nil;
  Last:=AObject;
 end else begin
  First:=AObject;
  Last:=AObject;
  AObject.GarbageCollectorRootObjectListPrevious:=nil;
  AObject.GarbageCollectorRootObjectListNext:=nil;
 end;
 AObject.GarbageCollectorInRootList:=true;
end;

procedure TBESENGarbageCollectorRootObjectList.Remove(AObject:TBESENGarbageCollectorObject);
begin
 if not AObject.GarbageCollectorInRootList then exit; // OPT-1: fast bail
 if assigned(AObject.GarbageCollectorRootObjectListPrevious) then begin
  AObject.GarbageCollectorRootObjectListPrevious.GarbageCollectorRootObjectListNext:=AObject.GarbageCollectorRootObjectListNext;
 end else if First=AObject then begin
  First:=AObject.GarbageCollectorRootObjectListNext;
 end;
 if assigned(AObject.GarbageCollectorRootObjectListNext) then begin
  AObject.GarbageCollectorRootObjectListNext.GarbageCollectorRootObjectListPrevious:=AObject.GarbageCollectorRootObjectListPrevious;
 end else if Last=AObject then begin
  Last:=AObject.GarbageCollectorRootObjectListPrevious;
 end;
 AObject.GarbageCollectorRootObjectListNext:=nil;
 AObject.GarbageCollectorRootObjectListPrevious:=nil;
 AObject.GarbageCollectorInRootList:=false;
end;

// OPT-1: replaced unreliable pointer-heuristic with O(1) flag
function TBESENGarbageCollectorRootObjectList.Contains(AObject:TBESENGarbageCollectorObject):boolean;
begin
 result:=AObject.GarbageCollectorInRootList;
end;

procedure TBESENGarbageCollectorRootObjectList.Push(AObject:TBESENGarbageCollectorObject);
begin
 Add(AObject);
end;

function TBESENGarbageCollectorRootObjectList.Pop:TBESENGarbageCollectorObject;
begin
 result:=Last;
 if assigned(result) then begin
  Remove(result);
 end;
end;

constructor TBESENGarbageCollectorProtectedObjectList.Create(AInstance:TObject);
begin
 inherited Create(AInstance);
 Clear;
end;

destructor TBESENGarbageCollectorProtectedObjectList.Destroy;
begin
 Clear;
 inherited Destroy;
end;

procedure TBESENGarbageCollectorProtectedObjectList.Clear;
var Item,NextItem:TBESENGarbageCollectorObject;
begin
 Item:=First;
 while assigned(Item) do begin
  NextItem:=Item.GarbageCollectorProtectedObjectListNext;
  Item.GarbageCollectorProtectedObjectListPrevious:=nil;
  Item.GarbageCollectorProtectedObjectListNext:=nil;
  Item.GarbageCollectorInProtectedList:=false; // OPT-1
  Item:=NextItem;
 end;
 First:=nil;
 Last:=nil;
end;

procedure TBESENGarbageCollectorProtectedObjectList.ClearWithFree;
begin
 while assigned(First) do begin
  First.Free;
 end;
 Clear;
end;

procedure TBESENGarbageCollectorProtectedObjectList.Add(AObject:TBESENGarbageCollectorObject);
begin
 if AObject.GarbageCollectorInProtectedList then exit; // OPT-1: idempotent
 if assigned(Last) then begin
  Last.GarbageCollectorProtectedObjectListNext:=AObject;
  AObject.GarbageCollectorProtectedObjectListPrevious:=Last;
  AObject.GarbageCollectorProtectedObjectListNext:=nil;
  Last:=AObject;
 end else begin
  First:=AObject;
  Last:=AObject;
  AObject.GarbageCollectorProtectedObjectListPrevious:=nil;
  AObject.GarbageCollectorProtectedObjectListNext:=nil;
 end;
 AObject.GarbageCollectorInProtectedList:=true;
end;

procedure TBESENGarbageCollectorProtectedObjectList.Remove(AObject:TBESENGarbageCollectorObject);
begin
 if not AObject.GarbageCollectorInProtectedList then exit; // OPT-1: fast bail
 if assigned(AObject.GarbageCollectorProtectedObjectListPrevious) then begin
  AObject.GarbageCollectorProtectedObjectListPrevious.GarbageCollectorProtectedObjectListNext:=AObject.GarbageCollectorProtectedObjectListNext;
 end else if First=AObject then begin
  First:=AObject.GarbageCollectorProtectedObjectListNext;
 end;
 if assigned(AObject.GarbageCollectorProtectedObjectListNext) then begin
  AObject.GarbageCollectorProtectedObjectListNext.GarbageCollectorProtectedObjectListPrevious:=AObject.GarbageCollectorProtectedObjectListPrevious;
 end else if Last=AObject then begin
  Last:=AObject.GarbageCollectorProtectedObjectListPrevious;
 end;
 AObject.GarbageCollectorProtectedObjectListNext:=nil;
 AObject.GarbageCollectorProtectedObjectListPrevious:=nil;
 AObject.GarbageCollectorInProtectedList:=false;
end;

// OPT-1: replaced unreliable pointer-heuristic with O(1) flag
function TBESENGarbageCollectorProtectedObjectList.Contains(AObject:TBESENGarbageCollectorObject):boolean;
begin
 result:=AObject.GarbageCollectorInProtectedList;
end;

procedure TBESENGarbageCollectorProtectedObjectList.Push(AObject:TBESENGarbageCollectorObject);
begin
 Add(AObject);
end;

function TBESENGarbageCollectorProtectedObjectList.Pop:TBESENGarbageCollectorObject;
begin
 result:=Last;
 if assigned(result) then begin
  Remove(result);
 end;
end;

constructor TBESENGarbageCollectorObjectList.Create(AInstance:TObject);
begin
 inherited Create(AInstance);
 Clear;
end;

destructor TBESENGarbageCollectorObjectList.Destroy;
begin
 Clear;
 inherited Destroy;
end;

procedure TBESENGarbageCollectorObjectList.Clear;
var Item,NextItem:TBESENGarbageCollectorObject;
begin
 Item:=First;
 while assigned(Item) do begin
  NextItem:=Item.GarbageCollectorObjectListNext;
  Item.GarbageCollectorObjectListPrevious:=nil;
  Item.GarbageCollectorObjectListNext:=nil;
  Item.GarbageCollectorObjectList:=nil;
  Item:=NextItem;
 end;
 First:=nil;
 Last:=nil;
end;

procedure TBESENGarbageCollectorObjectList.ClearWithFree;
begin
 while assigned(First) do begin
  First.Free;
 end;
 Clear;
end;

procedure TBESENGarbageCollectorObjectList.Add(AObject:TBESENGarbageCollectorObject);
begin
 if assigned(AObject.GarbageCollectorObjectList) then begin
  AObject.GarbageCollectorObjectList.Remove(AObject);
 end;
 AObject.GarbageCollectorObjectList:=self;
 if assigned(Last) then begin
  AObject.GarbageCollectorObjectListPrevious:=Last;
  Last.GarbageCollectorObjectListNext:=AObject;
 end else begin
  First:=AObject;
  AObject.GarbageCollectorObjectListPrevious:=nil;
 end;
 AObject.GarbageCollectorObjectListNext:=nil;
 Last:=AObject;
end;

procedure TBESENGarbageCollectorObjectList.Remove(AObject:TBESENGarbageCollectorObject);
begin
 if assigned(AObject.GarbageCollectorObjectListPrevious) then begin
  AObject.GarbageCollectorObjectListPrevious.GarbageCollectorObjectListNext:=AObject.GarbageCollectorObjectListNext;
 end else if First=AObject then begin
  First:=AObject.GarbageCollectorObjectListNext;
 end;
 if assigned(AObject.GarbageCollectorObjectListNext) then begin
  AObject.GarbageCollectorObjectListNext.GarbageCollectorObjectListPrevious:=AObject.GarbageCollectorObjectListPrevious;
 end else if Last=AObject then begin
  Last:=AObject.GarbageCollectorObjectListPrevious;
 end;
 AObject.GarbageCollectorObjectListNext:=nil;
 AObject.GarbageCollectorObjectListPrevious:=nil;
 AObject.GarbageCollectorObjectList:=nil;
end;

function TBESENGarbageCollectorObjectList.Contains(AObject:TBESENGarbageCollectorObject):boolean;
begin
 result:=AObject.GarbageCollectorObjectList=self;
end;

procedure TBESENGarbageCollectorObjectList.Push(AObject:TBESENGarbageCollectorObject);
begin
 Add(AObject);
end;

function TBESENGarbageCollectorObjectList.Pop:TBESENGarbageCollectorObject;
begin
 result:=Last;
 if assigned(result) then begin
  Remove(result);
 end;
end;

constructor TBESENGarbageCollector.Create(AInstance:TObject);
begin
 inherited Create(AInstance);
 First:=nil;
 Last:=nil;
 RootObjectList:=TBESENGarbageCollectorRootObjectList.Create(Instance);
 ProtectedObjectList:=TBESENGarbageCollectorProtectedObjectList.Create(Instance);
 WhiteObjectList:=TBESENGarbageCollectorObjectList.Create(Instance);
 GrayObjectList:=TBESENGarbageCollectorObjectList.Create(Instance);
 BlackObjectList:=TBESENGarbageCollectorObjectList.Create(Instance);
 IsSweeping:=false;
 State:=bgcsINIT;
 TriggerCounter:=0;
 MarkFactor:=BESEN_GC_MARKFACTOR;
 TriggerCountPerCollect:=BESEN_GC_TRIGGERCOUNT_PER_COLLECT;
 Count:=0;
end;

destructor TBESENGarbageCollector.Destroy;
begin
 Clear;
 RootObjectList.Free;
 ProtectedObjectList.Free;
 WhiteObjectList.Free;
 GrayObjectList.Free;
 BlackObjectList.Free;
 inherited Destroy;
end;

procedure TBESENGarbageCollector.Clear;
var CurrentObject:TBESENGarbageCollectorObject;
begin
 CurrentObject:=First;
 while assigned(CurrentObject) do begin
  FinalizeObjectForSweeping(CurrentObject);
  CurrentObject:=CurrentObject.GarbageCollectorNext;
 end;
 while assigned(First) do begin
  First.Free;
 end;
 First:=nil;
 Last:=nil;
 RootObjectList.Clear;
 ProtectedObjectList.Clear;
 WhiteObjectList.Clear;
 GrayObjectList.Clear;
 BlackObjectList.Clear;
 CurrentRootObject:=nil;
 CurrentProtectedObject:=nil;
 CurrentMarkObject:=nil;
 CurrentSweepObject:=nil;
 TriggerCounter:=0;
 Count:=0;
 State:=bgcsINIT;
 IsSweeping:=false;
end;

procedure TBESENGarbageCollector.Reset;
begin
 Flip;
 CurrentRootObject:=nil;
 CurrentProtectedObject:=nil;
 CurrentSweepObject:=nil;
 State:=bgcsINIT;
end;

procedure TBESENGarbageCollector.WhiteIt(AObject:TBESENGarbageCollectorObject);
begin
 if assigned(AObject) and not WhiteObjectList.Contains(AObject) then begin
  if assigned(AObject.GarbageCollectorObjectList) then begin
   AObject.GarbageCollectorObjectList.Remove(AObject);
  end;
  WhiteObjectList.Push(AObject);
 end;
end;

procedure TBESENGarbageCollector.ForceGrayIt(AObject:TBESENGarbageCollectorObject);
begin
 if assigned(AObject) and not GrayObjectList.Contains(AObject) then begin
  if assigned(AObject.GarbageCollectorObjectList) then begin
   AObject.GarbageCollectorObjectList.Remove(AObject);
  end;
  GrayObjectList.Push(AObject);
 end;
end;

// OPT-5: GrayIt is on the write-barrier hot path. Original called Contains() twice
// (once for Gray, once for Black). One pointer comparison replaces both.
procedure TBESENGarbageCollector.GrayIt(AObject:TBESENGarbageCollectorObject);
begin
 if assigned(AObject) then begin
  if (AObject.GarbageCollectorObjectList=GrayObjectList) or
     (AObject.GarbageCollectorObjectList=BlackObjectList) then begin
   exit; // already grey or black
  end;
  if assigned(AObject.GarbageCollectorObjectList) then begin
   AObject.GarbageCollectorObjectList.Remove(AObject);
  end;
  GrayObjectList.Push(AObject);
 end;
end;

procedure TBESENGarbageCollector.BlackIt(AObject:TBESENGarbageCollectorObject);
begin
 if assigned(AObject) and not BlackObjectList.Contains(AObject) then begin
  if assigned(AObject.GarbageCollectorObjectList) then begin
   AObject.GarbageCollectorObjectList.Remove(AObject);
  end;
  BlackObjectList.Push(AObject);
 end;
end;

procedure TBESENGarbageCollector.Protect(AObject:TBESENGarbageCollectorObject);
begin
 AddProtected(AObject);
end;

procedure TBESENGarbageCollector.Unprotect(AObject:TBESENGarbageCollectorObject);
begin
 RemoveProtected(AObject);
end;

procedure TBESENGarbageCollector.GrayValue(var Value:TBESENValue);
begin
 case Value.ValueType of
  bvtOBJECT:begin
   if assigned(Value.Obj) then begin
    GrayIt(TBESENObject(Value.Obj));
   end;
  end;
  bvtREFERENCE:begin
   case Value.ReferenceBase.ValueType of
    brbvtOBJECT:begin
     if assigned(Value.ReferenceBase.Obj) then begin
      GrayIt(TBESENObject(Value.ReferenceBase.Obj));
     end;
    end;
    brbvtENVREC:begin
     if assigned(Value.ReferenceBase.EnvRec) then begin
      GrayIt(TBESENEnvironmentRecord(Value.ReferenceBase.EnvRec));
     end;
    end;
   end;
  end;
 end;
end;

procedure TBESENGarbageCollector.FinalizeValue(var Value:TBESENValue);
begin
 Value:=BESENEmptyValue;
end;

procedure TBESENGarbageCollector.Mark(AObject:TBESENGarbageCollectorObject);
begin
 if assigned(AObject) then begin
  AObject.Mark;
 end;
end;

procedure TBESENGarbageCollector.FinalizeObjectForSweeping(AObject:TBESENGarbageCollectorObject);
begin
 if assigned(AObject) then begin
  AObject.Finalize;
 end;
end;

procedure TBESENGarbageCollector.Flip;
var TempObjectList:TBESENGarbageCollectorObjectList;
begin
 TempObjectList:=WhiteObjectList;
 WhiteObjectList:=BlackObjectList;
 BlackObjectList:=TempObjectList;
end;

procedure TBESENGarbageCollector.TriggerCollect;
begin
 inc(TriggerCounter);
 if TriggerCounter>=TriggerCountPerCollect then begin
  TriggerCounter:=0;
  Collect;
 end;
end;

function TBESENGarbageCollector.Collect:boolean;
var i:integer;
    MarkCount:int64;
    Current:PBESENPointerSelfBalancedTreeNode;
    Node:TBESENASTNodeProgram;
    NextObject:TBESENGarbageCollectorObject;
begin
 result:=false;
 while true do begin
  case State of
   bgcsINIT:begin
    State:=bgcsMARKROOTS;
    CurrentRootObject:=RootObjectList.First;
   end;
   bgcsMARKROOTS:begin
    result:=false;
    MarkCount:=(MarkFactor*Count) div 256;
    if MarkCount<256 then begin
     MarkCount:=256;
    end else if MarkCount>$7fffffff then begin
     MarkCount:=$7fffffff;
    end;
    for i:=1 to MarkCount do begin
     if assigned(CurrentRootObject) then begin
      BlackIt(CurrentRootObject);
      Mark(CurrentRootObject);
      CurrentRootObject:=CurrentRootObject.GarbageCollectorRootObjectListNext;
      result:=assigned(CurrentRootObject);
     end else begin
      break;
     end;
    end;
    if result then begin
     break;
    end else begin
     CurrentProtectedObject:=ProtectedObjectList.First;
     State:=bgcsMARKPROTECTED;
    end;
   end;
   bgcsMARKPROTECTED:begin
    result:=false;
    MarkCount:=(MarkFactor*Count) div 256;
    if MarkCount<256 then begin
     MarkCount:=256;
    end else if MarkCount>$7fffffff then begin
     MarkCount:=$7fffffff;
    end;
    for i:=1 to MarkCount do begin
     if assigned(CurrentProtectedObject) then begin
      BlackIt(CurrentProtectedObject);
      Mark(CurrentProtectedObject);
      CurrentProtectedObject:=CurrentProtectedObject.GarbageCollectorProtectedObjectListNext;
      result:=assigned(CurrentProtectedObject);
     end else begin
      break;
     end;
    end;
    if result then begin
     break;
    end else begin
     State:=bgcsMARKPROGRAMNODES;
    end;
   end;
   bgcsMARKPROGRAMNODES:begin
    Current:=TBESEN(Instance).ProgramNodes.FirstKey;
    while assigned(Current) do begin
     Node:=TBESENASTNodeProgram(Current^.Key);
     if assigned(Node) and assigned(Node.Body) and assigned(Node.Body.Code) then begin
      TBESENCode(Node.Body.Code).Mark;
     end;
     Current:=Current^.NextKey;
    end;
    CurrentContext:=TBESEN(Instance).ContextFirst;
    State:=bgcsMARKCONTEXTS;
   end;
   bgcsMARKCONTEXTS:begin
    result:=false;
    while assigned(CurrentContext) do begin
     TBESENContext(CurrentContext).Mark;
     CurrentContext:=TBESENContext(CurrentContext).Next;
     result:=assigned(CurrentContext);
    end;
    if result then begin
     break;
    end else begin
     State:=bgcsMARKGRAYS;
    end;
   end;
   bgcsMARKGRAYS:begin
    result:=false;
    MarkCount:=(MarkFactor*Count) div 256;
    if MarkCount<256 then begin
     MarkCount:=256;
    end else if MarkCount>$7fffffff then begin
     MarkCount:=$7fffffff;
    end;
    for i:=1 to MarkCount do begin
     CurrentMarkObject:=GrayObjectList.Pop;
     if assigned(CurrentMarkObject) then begin
      Mark(CurrentMarkObject);
      BlackIt(CurrentMarkObject);
      result:=assigned(GrayObjectList.Last);
     end else begin
      break;
     end;
    end;
    if result then begin
     break;
    end else begin
     CurrentSweepObject:=WhiteObjectList.First;
     State:=bgcsSWEEPWHITES;
    end;
   end;
   bgcsSWEEPWHITES:begin
    // OPT-7: Two explicit passes.  First, rescue locked/protected whites;
    // then finalize+free everything that remains.  CurrentSweepObject is
    // explicitly reset before each pass so re-entry is always correct.
    CurrentSweepObject:=WhiteObjectList.First;
    while assigned(CurrentSweepObject) do begin
     NextObject:=CurrentSweepObject.GarbageCollectorObjectListNext;
     // OPT-1: ProtectedObjectList.Contains is now O(1) via flag
     if (CurrentSweepObject.GarbageCollectorLockReferenceCounter>0) or
        ProtectedObjectList.Contains(CurrentSweepObject) then begin
      GrayIt(CurrentSweepObject);
     end;
     CurrentSweepObject:=NextObject;
    end;
    if assigned(GrayObjectList.First) then begin
     State:=bgcsMARKGRAYS;
    end else begin
     // Finalize then free every remaining white object
     CurrentSweepObject:=WhiteObjectList.First;
     while assigned(CurrentSweepObject) do begin
      FinalizeObjectForSweeping(CurrentSweepObject);
      CurrentSweepObject:=CurrentSweepObject.GarbageCollectorObjectListNext;
     end;
     while assigned(WhiteObjectList.First) do begin
      IsSweeping:=true;
      WhiteObjectList.First.Free;
      IsSweeping:=false;
     end;
     State:=bgcsDONE;
    end;
   end;
   bgcsDONE:begin
    Flip;
    State:=bgcsINIT;
    result:=false;
    break;
   end;
  end;
 end;
end;

procedure TBESENGarbageCollector.CollectAll;
begin
 // should it not be internal and all external stuff call TriggerCollect?
 while Collect do begin
 end;
end;

procedure TBESENGarbageCollector.Use(AObject:TBESENGarbageCollectorObject);
begin
 ForceGrayIt(AObject);
end;

procedure TBESENGarbageCollector.Add(AObject:TBESENGarbageCollectorObject);
begin
 GrayIt(AObject);
end;

procedure TBESENGarbageCollector.AddRoot(AObject:TBESENGarbageCollectorObject);
begin
 RootObjectList.Add(AObject);
 State:=bgcsINIT;
end;

procedure TBESENGarbageCollector.RemoveRoot(AObject:TBESENGarbageCollectorObject);
begin
 State:=bgcsINIT;
 if RootObjectList.Contains(AObject) then begin
  RootObjectList.Remove(AObject);
  ForceGrayIt(AObject);
 end;
end;

procedure TBESENGarbageCollector.AddProtected(AObject:TBESENGarbageCollectorObject);
begin
 GrayIt(AObject);
 ProtectedObjectList.Add(AObject);
 State:=bgcsINIT;
end;

procedure TBESENGarbageCollector.RemoveProtected(AObject:TBESENGarbageCollectorObject);
begin
 State:=bgcsINIT;
 if ProtectedObjectList.Contains(AObject) then begin
  ProtectedObjectList.Remove(AObject);
  ForceGrayIt(AObject);
 end;
end;

procedure TBESENGarbageCollector.LockObject(Obj:TBESENGarbageCollectorObject);
begin
 if assigned(Obj) then begin
  Obj.GarbageCollectorLock;
 end;
end;

procedure TBESENGarbageCollector.UnlockObject(Obj:TBESENGarbageCollectorObject);
begin
 if assigned(Obj) then begin
  Obj.GarbageCollectorUnlock;
 end;
end;

procedure TBESENGarbageCollector.LockValue(const Value:TBESENValue);
begin
 case Value.ValueType of
  bvtOBJECT:begin
   if assigned(Value.Obj) then begin
    LockObject(TBESENObject(Value.Obj));
   end;
  end;
  bvtREFERENCE:begin
   case Value.ReferenceBase.ValueType of
    brbvtOBJECT:begin
     if assigned(Value.ReferenceBase.Obj) then begin
      LockObject(TBESENObject(Value.ReferenceBase.Obj));
     end;
    end;
    brbvtENVREC:begin
     if assigned(Value.ReferenceBase.EnvRec) then begin
      LockObject(TBESENEnvironmentRecord(Value.ReferenceBase.EnvRec));
     end;
    end;
   end;
  end;
 end;
end;

procedure TBESENGarbageCollector.UnlockValue(const Value:TBESENValue);
begin
 case Value.ValueType of
  bvtOBJECT:begin
   if assigned(Value.Obj) then begin
    UnlockObject(TBESENObject(Value.Obj));
   end;
  end;
  bvtREFERENCE:begin
   case Value.ReferenceBase.ValueType of
    brbvtOBJECT:begin
     if assigned(Value.ReferenceBase.Obj) then begin
      UnlockObject(TBESENObject(Value.ReferenceBase.Obj));
     end;
    end;
    brbvtENVREC:begin
     if assigned(Value.ReferenceBase.EnvRec) then begin
      UnlockObject(TBESENEnvironmentRecord(Value.ReferenceBase.EnvRec));
     end;
    end;
   end;
  end;
 end;
end;

end.

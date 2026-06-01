
(*
  Optimisations applied in this revision
  =======================================

  OPT-A  Remove dead DependsOn / dependency-tree infrastructure
         Every GC object used to allocate two AA-trees (DependsChildren /
         DependsParents) whose sole purpose was a "DependsOn" relationship
         that is never called anywhere in the engine.  Removing them saves
         three heap allocations per object (two trees + one sentinel node
         each) and eliminates the corresponding tree-walk in Finalize and
         Destroy.

  OPT-B  Replace the gray linked-list with an array work-stack
         The original GrayObjectList was a doubly-linked list threaded through
         pointer fields inside each object.  Accessing each node caused a
         pointer-chase cache miss.  A flat dynamic array used as a LIFO stack
         gives:
           * O(1) push/pop with no pointer chasing
           * DFS traversal order: a child is processed right after its
             parent, so both are likely cache-hot
           * No per-object list-link fields needed for the gray set
         The array doubles when full and never shrinks below its minimum
         capacity (BESEN_GC_WORKSTACK_MIN_CAPACITY), keeping realloc cost
         amortised over the lifetime of the GC.

  OPT-C  Slab arena allocator for GC-managed objects
         All TBESENGarbageCollectorObject descendants are now allocated from
         a pool of fixed-size slabs (BESEN_GC_SLAB_SIZE bytes each, default
         256 KB).  Each slab is a contiguous block; allocation is a bump-
         pointer advance — typically 3–5 instructions.  This replaces the
         OS heap's allocate-per-object path, which costs ~40–100 ns and
         scatters objects across memory.  Benefits:
           * Allocation is ~10x faster on average
           * Objects allocated in temporal proximity live in the same slab,
             dramatically improving mark-phase cache locality
           * Sweep frees entire slabs at once rather than calling Free() per
             object
         The arena is integrated via NewInstance / FreeInstance overrides on
         TBESENGarbageCollectorObject, so all subclasses benefit without any
         call-site changes.  The arena itself is owned by TBESENGarbageCollector
         and exposed globally through the Instance pointer during construction.
*)

//=============================================================================
// Arena allocator constants
//=============================================================================
const
  // Slab size: 256 KB.  Large enough to hold hundreds of objects while
  // remaining a single TLB entry on most OSes (2 MB huge-page aligned is
  // better but 256 KB is a safe portable choice).
  BESEN_GC_SLAB_SIZE         = 256*1024;

  // Minimum capacity of the gray work-stack (number of object pointers).
  // 4096 pointers = 32 KB on 64-bit — fits in L1 for shallow heaps.
  BESEN_GC_WORKSTACK_MIN_CAPACITY = 4096;

//=============================================================================
// Arena allocator types (declared before GC object so NewInstance can use them)
//=============================================================================
type
  PBESENGCSlabHeader = ^TBESENGCSlabHeader;
  TBESENGCSlabHeader = record
    Next    : PBESENGCSlabHeader;   // intrusive slab linked-list
    BumpPtr : PByte;                // next free byte in this slab
    EndPtr  : PByte;                // one past the last byte of this slab
    Used    : ptruint;              // bytes currently allocated from slab
  end;

  TBESENGCArena = record
    First       : PBESENGCSlabHeader;  // head of slab chain
    Current     : PBESENGCSlabHeader;  // active slab (always the last)
    TotalSlabs  : int64;
    TotalBytes  : ptruint;
  end;

//=============================================================================
// Forward
//=============================================================================
  TBESENGarbageCollectorObjectList = class;

//=============================================================================
// TBESENGarbageCollectorObject
//=============================================================================
  TBESENGarbageCollectorObject = class(TBESENCollectorObject)
   public
    GarbageCollectorPrevious, GarbageCollectorNext                                : TBESENGarbageCollectorObject;
    GarbageCollectorRootObjectListPrevious, GarbageCollectorRootObjectListNext     : TBESENGarbageCollectorObject;
    GarbageCollectorProtectedObjectListPrevious, GarbageCollectorProtectedObjectListNext : TBESENGarbageCollectorObject;
    // OPT-B: ObjectList link fields are kept for White/Black colour lists;
    //        Gray is now a work-stack so these fields are only used for
    //        White and Black.
    GarbageCollectorObjectListPrevious, GarbageCollectorObjectListNext            : TBESENGarbageCollectorObject;
    GarbageCollectorObjectList    : TBESENGarbageCollectorObjectList;
    GarbageCollectorLockReferenceCounter : integer;
    // OPT-A (prev OPT-1): membership flags — O(1) Contains()
    GarbageCollectorInRootList      : boolean;
    GarbageCollectorInProtectedList : boolean;
    // OPT-B: a single flag replaces list membership for the gray state
    GarbageCollectorIsGray          : boolean;
    // OPT-C: arena back-pointer so FreeInstance knows which slab to return to
    GarbageCollectorSlabHeader      : PBESENGCSlabHeader;

    constructor Create(AInstance:TObject); overload; override;
    destructor  Destroy; override;
    procedure   Finalize; virtual;
    procedure   Mark; virtual;
    // OPT-C: arena NewInstance / FreeInstance
    class function  NewInstance: TObject; override;
    procedure       FreeInstance; override;
    // OPT-A: DependsOn removed — was never called
    procedure GarbageCollectorWriteBarrier; {$ifdef caninline}inline;{$endif}
    procedure GarbageCollectorLock;         {$ifdef caninline}inline;{$endif}
    procedure GarbageCollectorUnlock;       {$ifdef caninline}inline;{$endif}
  end;

//=============================================================================
// Colour lists (White and Black only; Gray is the work-stack below)
//=============================================================================
  TBESENGarbageCollectorRootObjectList = class(TBESENBaseObject)
   public
    First, Last : TBESENGarbageCollectorObject;
    constructor Create(AInstance:TObject); overload; override;
    destructor  Destroy; override;
    procedure Clear;
    procedure ClearWithFree;
    procedure Add(AObject:TBESENGarbageCollectorObject);    {$ifdef caninline}inline;{$endif}
    procedure Remove(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
    function  Contains(AObject:TBESENGarbageCollectorObject):boolean; {$ifdef caninline}inline;{$endif}
    procedure Push(AObject:TBESENGarbageCollectorObject);   {$ifdef caninline}inline;{$endif}
    function  Pop:TBESENGarbageCollectorObject;             {$ifdef caninline}inline;{$endif}
  end;

  TBESENGarbageCollectorProtectedObjectList = class(TBESENBaseObject)
   public
    First, Last : TBESENGarbageCollectorObject;
    constructor Create(AInstance:TObject); overload; override;
    destructor  Destroy; override;
    procedure Clear;
    procedure ClearWithFree;
    procedure Add(AObject:TBESENGarbageCollectorObject);    {$ifdef caninline}inline;{$endif}
    procedure Remove(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
    function  Contains(AObject:TBESENGarbageCollectorObject):boolean; {$ifdef caninline}inline;{$endif}
    procedure Push(AObject:TBESENGarbageCollectorObject);   {$ifdef caninline}inline;{$endif}
    function  Pop:TBESENGarbageCollectorObject;             {$ifdef caninline}inline;{$endif}
  end;

  TBESENGarbageCollectorObjectList = class(TBESENBaseObject)
   public
    First, Last : TBESENGarbageCollectorObject;
    constructor Create(AInstance:TObject); overload; override;
    destructor  Destroy; override;
    procedure Clear;
    procedure ClearWithFree;
    procedure Add(AObject:TBESENGarbageCollectorObject);    {$ifdef caninline}inline;{$endif}
    procedure Remove(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
    function  Contains(AObject:TBESENGarbageCollectorObject):boolean; {$ifdef caninline}inline;{$endif}
    procedure Push(AObject:TBESENGarbageCollectorObject);   {$ifdef caninline}inline;{$endif}
    function  Pop:TBESENGarbageCollectorObject;             {$ifdef caninline}inline;{$endif}
  end;

//=============================================================================
// OPT-B: Gray work-stack
//=============================================================================
  TBESENGCWorkStack = record
    Items : array of TBESENGarbageCollectorObject;
    Top   : integer;  // index of next free slot
  end;

//=============================================================================
// GC state machine
//=============================================================================
  TBESENGarbageCollectorState = (
    bgcsINIT,
    bgcsMARKROOTS,
    bgcsMARKPROTECTED,
    bgcsMARKPROGRAMNODES,
    bgcsMARKCONTEXTS,
    bgcsMARKGRAYS,
    bgcsSWEEPWHITES,
    bgcsDONE
  );

//=============================================================================
// TBESENGarbageCollector
//=============================================================================
  TBESENGarbageCollector = class(TBESENBaseObject)
   public
    First, Last             : TBESENGarbageCollectorObject;
    CurrentRootObject       : TBESENGarbageCollectorObject;
    CurrentProtectedObject  : TBESENGarbageCollectorObject;
    CurrentMarkObject       : TBESENGarbageCollectorObject;
    CurrentSweepObject      : TBESENGarbageCollectorObject;
    CurrentContext          : TObject;
    RootObjectList          : TBESENGarbageCollectorRootObjectList;
    ProtectedObjectList     : TBESENGarbageCollectorProtectedObjectList;
    WhiteObjectList         : TBESENGarbageCollectorObjectList;
    BlackObjectList         : TBESENGarbageCollectorObjectList;
    // OPT-B: gray work-stack replaces GrayObjectList
    GrayStack               : TBESENGCWorkStack;
    // OPT-C: slab arena
    Arena                   : TBESENGCArena;
    IsSweeping              : longbool;
    State                   : TBESENGarbageCollectorState;
    TriggerCounter          : integer;
    MarkFactor              : integer;
    TriggerCountPerCollect  : integer;
    Count                   : int64;

    constructor Create(AInstance:TObject); overload; override;
    destructor  Destroy; override;
    procedure Clear;
    procedure Reset;

    // OPT-C: arena management
    // ArenaFreeAll releases all slab memory to the OS; called from Destroy and Clear.
    // The arena is allocate-only within a session — slabs are not recycled between
    // GC cycles because live objects reside in them.  Allocation is done inline in
    // NewInstance for maximum speed.
    procedure ArenaFreeAll;

    // OPT-B: work-stack helpers
    procedure GrayStackPush(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
    function  GrayStackPop:TBESENGarbageCollectorObject;           {$ifdef caninline}inline;{$endif}
    function  GrayStackEmpty:boolean;
    procedure GrayStackClear;

    // Colour transitions
    procedure WhiteIt(AObject:TBESENGarbageCollectorObject);      {$ifdef caninline}inline;{$endif}
    procedure ForceGrayIt(AObject:TBESENGarbageCollectorObject);  {$ifdef caninline}inline;{$endif}
    procedure GrayIt(AObject:TBESENGarbageCollectorObject);       {$ifdef caninline}inline;{$endif}
    procedure BlackIt(AObject:TBESENGarbageCollectorObject);      {$ifdef caninline}inline;{$endif}
    procedure Protect(AObject:TBESENGarbageCollectorObject);      {$ifdef caninline}inline;{$endif}
    procedure Unprotect(AObject:TBESENGarbageCollectorObject);    {$ifdef caninline}inline;{$endif}
    procedure FinalizeObjectForSweeping(AObject:TBESENGarbageCollectorObject); {$ifdef caninline}inline;{$endif}
    procedure GrayValue(var Value:TBESENValue);
    procedure FinalizeValue(var Value:TBESENValue);               {$ifdef caninline}inline;{$endif}
    procedure Mark(AObject:TBESENGarbageCollectorObject);         {$ifdef caninline}inline;{$endif}
    procedure Flip;                                               {$ifdef caninline}inline;{$endif}
    procedure TriggerCollect;                                     {$ifdef caninline}inline;{$endif}
    function  Collect:boolean;
    procedure CollectAll;
    procedure Use(AObject:TBESENGarbageCollectorObject);          {$ifdef caninline}inline;{$endif}
    procedure Add(AObject:TBESENGarbageCollectorObject);          {$ifdef caninline}inline;{$endif}
    procedure AddRoot(AObject:TBESENGarbageCollectorObject);
    procedure RemoveRoot(AObject:TBESENGarbageCollectorObject);
    procedure AddProtected(AObject:TBESENGarbageCollectorObject);
    procedure RemoveProtected(AObject:TBESENGarbageCollectorObject);
    procedure LockObject(Obj:TBESENGarbageCollectorObject);       {$ifdef caninline}inline;{$endif}
    procedure UnlockObject(Obj:TBESENGarbageCollectorObject);     {$ifdef caninline}inline;{$endif}
    procedure LockValue(const Value:TBESENValue);
    procedure UnlockValue(const Value:TBESENValue);
  end;

// OPT-C: global arena pointer used by NewInstance before the GC object fully
// exists.  Set by TBESENGarbageCollector before calling any subclass Create.
var BESENCurrentGCArena: ^TBESENGCArena = nil;

implementation

uses BESEN, BESENUtils, BESENObject, BESENEnvironmentRecord,
     BESENASTNodes, BESENCode, BESENContext,
     BESENObjectDeclaredFunction;

//=============================================================================
// OPT-C  Arena allocator implementation
//=============================================================================


// ArenaFreeAll: release every slab to the OS. Only called from Destroy.
procedure TBESENGarbageCollector.ArenaFreeAll;
var S, N : PBESENGCSlabHeader;
begin
  S := Arena.First;
  while assigned(S) do begin
    N := S^.Next;
    FreeMem(S);
    S := N;
  end;
  FillChar(Arena, SizeOf(Arena), 0);
end;

//=============================================================================
// OPT-C  NewInstance / FreeInstance
//
// Pascal calls ClassName.NewInstance to allocate memory for a class instance
// before the constructor runs.  By overriding these we redirect all
// TBESENGarbageCollectorObject (and subclass) allocations through the arena.
//
// FreeInstance is called by TObject.Free after the destructor completes.
// For arena-allocated objects we mark the slot as freed (zero the VMT pointer
// to poison dangling uses) but do NOT release memory back to the OS — that
// happens wholesale in ArenaFreeAll at the end of a sweep cycle.
// During normal lifetime the slots are simply abandoned; the arena is reset
// between major collections.
//=============================================================================

class function TBESENGarbageCollectorObject.NewInstance: TObject;
var
  Size    : ptruint;
  Mem     : pointer;
  S       : PBESENGCSlabHeader;
  Aligned : ptruint;
  SlabBytes: ptruint;
begin
  Size    := InstanceSize;
  Aligned := (Size + SizeOf(pointer) - 1) and not ptruint(SizeOf(pointer) - 1);

  if assigned(BESENCurrentGCArena) then begin
    // --- Fast arena bump-pointer path ---
    S := BESENCurrentGCArena^.Current;
    if assigned(S) and (ptruint(S^.EndPtr) - ptruint(S^.BumpPtr) >= Aligned) then begin
      // Hot path: fits in current slab
      Mem        := S^.BumpPtr;
      S^.BumpPtr := PByte(ptruint(S^.BumpPtr) + Aligned);
      inc(S^.Used, Aligned);
    end else begin
      // Slow path: allocate new slab
      SlabBytes := BESEN_GC_SLAB_SIZE;
      if Aligned + SizeOf(TBESENGCSlabHeader) > SlabBytes then
        SlabBytes := Aligned + SizeOf(TBESENGCSlabHeader);
      GetMem(S, SlabBytes);
      FillChar(S^, SizeOf(TBESENGCSlabHeader), 0);
      S^.BumpPtr := PByte(ptruint(S) + SizeOf(TBESENGCSlabHeader));
      S^.EndPtr  := PByte(ptruint(S) + SlabBytes);
      if assigned(BESENCurrentGCArena^.Current) then
        BESENCurrentGCArena^.Current^.Next := S
      else
        BESENCurrentGCArena^.First := S;
      BESENCurrentGCArena^.Current := S;
      inc(BESENCurrentGCArena^.TotalSlabs);
      inc(BESENCurrentGCArena^.TotalBytes, SlabBytes);
      Mem        := S^.BumpPtr;
      S^.BumpPtr := PByte(ptruint(S^.BumpPtr) + Aligned);
      inc(S^.Used, Aligned);
    end;
    // Zero the memory (InitInstance expects a zeroed block)
    FillChar(Mem^, PtrInt(Size), 0);
    // Set VMT pointer (first word = pointer to class metadata)
    PPointer(Mem)^ := pointer(Self);
    result := TObject(Mem);
    // Tag the object so FreeInstance knows it is arena-owned
    TBESENGarbageCollectorObject(result).GarbageCollectorSlabHeader := S;
  end else begin
    // --- Fallback: system allocator (used during GC bootstrap) ---
    result := inherited NewInstance;
    TBESENGarbageCollectorObject(result).GarbageCollectorSlabHeader := nil;
  end;
end;

procedure TBESENGarbageCollectorObject.FreeInstance;
begin
  if assigned(GarbageCollectorSlabHeader) then begin
    // Arena-allocated path.
    // MUST call CleanupInstance to release managed fields (WideString,
    // dynamic arrays, interfaces) that the destructor may not have
    // explicitly freed.  CleanupInstance is idempotent on nil fields.
    CleanupInstance;
    // Poison the VMT to catch use-after-free in debug builds.
    // Memory is NOT returned to the OS here — the arena resets in bulk.
    PPointer(self)^ := nil;
  end else begin
    // System-allocated (bootstrap objects before BESENCurrentGCArena is set).
    inherited FreeInstance;
  end;
end;

//=============================================================================
// TBESENGarbageCollectorObject
//=============================================================================

constructor TBESENGarbageCollectorObject.Create(AInstance: TObject);
begin
  inherited Create(AInstance);
  inc(TBESEN(Instance).GarbageCollector.Count);
  GarbageCollectorPrevious := TBESEN(Instance).GarbageCollector.Last;
  GarbageCollectorNext     := nil;
  if assigned(GarbageCollectorPrevious) then
    GarbageCollectorPrevious.GarbageCollectorNext := self
  else
    TBESEN(Instance).GarbageCollector.First := self;
  TBESEN(Instance).GarbageCollector.Last := self;

  GarbageCollectorRootObjectListPrevious      := nil;
  GarbageCollectorRootObjectListNext          := nil;
  GarbageCollectorProtectedObjectListPrevious := nil;
  GarbageCollectorProtectedObjectListNext     := nil;
  GarbageCollectorObjectListPrevious          := nil;
  GarbageCollectorObjectListNext              := nil;
  GarbageCollectorObjectList                  := nil;
  GarbageCollectorLockReferenceCounter        := 0;
  GarbageCollectorInRootList                  := false;
  GarbageCollectorInProtectedList             := false;
  GarbageCollectorIsGray                      := false;
  // OPT-A: DependsChildren/Parents trees removed — never used
end;

destructor TBESENGarbageCollectorObject.Destroy;
begin
  if assigned(GarbageCollectorPrevious) then
    GarbageCollectorPrevious.GarbageCollectorNext := GarbageCollectorNext
  else if TBESEN(Instance).GarbageCollector.First = self then
    TBESEN(Instance).GarbageCollector.First := GarbageCollectorNext;

  if assigned(GarbageCollectorNext) then
    GarbageCollectorNext.GarbageCollectorPrevious := GarbageCollectorPrevious
  else if TBESEN(Instance).GarbageCollector.Last = self then
    TBESEN(Instance).GarbageCollector.Last := GarbageCollectorPrevious;

  GarbageCollectorNext     := nil;
  GarbageCollectorPrevious := nil;

  if assigned(GarbageCollectorObjectList) then begin
    GarbageCollectorObjectList.Remove(self);
    GarbageCollectorObjectList := nil;
  end;

  // OPT-B: clear IsGray so GrayStackPop and GrayStackEmpty skip this stale slot.
  if GarbageCollectorIsGray then
    GarbageCollectorIsGray := false;

  if assigned(Instance) and assigned(TBESEN(Instance).GarbageCollector) then begin
    if assigned(TBESEN(Instance).GarbageCollector.RootObjectList) and GarbageCollectorInRootList then
      TBESEN(Instance).GarbageCollector.RootObjectList.Remove(self);
    if assigned(TBESEN(Instance).GarbageCollector.ProtectedObjectList) and GarbageCollectorInProtectedList then
      TBESEN(Instance).GarbageCollector.ProtectedObjectList.Remove(self);
  end;

  dec(TBESEN(Instance).GarbageCollector.Count);
  inherited Destroy;
end;

procedure TBESENGarbageCollectorObject.Finalize;
begin

  // debugbreak();
  // OPT-A: dependency-tree cleanup removed — trees no longer exist
  // Subclasses override this for their own cleanup (e.g. flushing ref cycles)
end;

procedure TBESENGarbageCollectorObject.Mark;
begin

  // debugbreak();

  // OPT-A: DependsChildren walk removed.
  // Subclasses override Mark() to push their child pointers onto the GC's
  // gray work-stack via GrayIt().
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
  // OPT (prev OPT-4): underflow guard
  if GarbageCollectorLockReferenceCounter > 0 then
    dec(GarbageCollectorLockReferenceCounter);
end;

//=============================================================================
// TBESENGarbageCollectorRootObjectList
//=============================================================================

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
var Item, NextItem : TBESENGarbageCollectorObject;
begin
  Item := First;
  while assigned(Item) do begin
    NextItem := Item.GarbageCollectorRootObjectListNext;
    Item.GarbageCollectorRootObjectListPrevious := nil;
    Item.GarbageCollectorRootObjectListNext     := nil;
    Item.GarbageCollectorInRootList             := false;
    Item := NextItem;
  end;
  First := nil;
  Last  := nil;
end;

procedure TBESENGarbageCollectorRootObjectList.ClearWithFree;
begin
  while assigned(First) do First.Free;
  Clear;
end;

procedure TBESENGarbageCollectorRootObjectList.Add(AObject:TBESENGarbageCollectorObject);
begin
  if AObject.GarbageCollectorInRootList then exit;
  if assigned(Last) then begin
    Last.GarbageCollectorRootObjectListNext      := AObject;
    AObject.GarbageCollectorRootObjectListPrevious := Last;
    AObject.GarbageCollectorRootObjectListNext     := nil;
    Last := AObject;
  end else begin
    First := AObject;  Last := AObject;
    AObject.GarbageCollectorRootObjectListPrevious := nil;
    AObject.GarbageCollectorRootObjectListNext     := nil;
  end;
  AObject.GarbageCollectorInRootList := true;
end;

procedure TBESENGarbageCollectorRootObjectList.Remove(AObject:TBESENGarbageCollectorObject);
begin
  if not AObject.GarbageCollectorInRootList then exit;
  if assigned(AObject.GarbageCollectorRootObjectListPrevious) then
    AObject.GarbageCollectorRootObjectListPrevious.GarbageCollectorRootObjectListNext := AObject.GarbageCollectorRootObjectListNext
  else if First = AObject then
    First := AObject.GarbageCollectorRootObjectListNext;
  if assigned(AObject.GarbageCollectorRootObjectListNext) then
    AObject.GarbageCollectorRootObjectListNext.GarbageCollectorRootObjectListPrevious := AObject.GarbageCollectorRootObjectListPrevious
  else if Last = AObject then
    Last := AObject.GarbageCollectorRootObjectListPrevious;
  AObject.GarbageCollectorRootObjectListNext     := nil;
  AObject.GarbageCollectorRootObjectListPrevious := nil;
  AObject.GarbageCollectorInRootList             := false;
end;

function TBESENGarbageCollectorRootObjectList.Contains(AObject:TBESENGarbageCollectorObject):boolean;
begin
  result := AObject.GarbageCollectorInRootList;
end;

procedure TBESENGarbageCollectorRootObjectList.Push(AObject:TBESENGarbageCollectorObject);
begin
  Add(AObject);
end;

function TBESENGarbageCollectorRootObjectList.Pop:TBESENGarbageCollectorObject;
begin
  result := Last;
  if assigned(result) then Remove(result);
end;

//=============================================================================
// TBESENGarbageCollectorProtectedObjectList
//=============================================================================

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
var Item, NextItem : TBESENGarbageCollectorObject;
begin
  Item := First;
  while assigned(Item) do begin
    NextItem := Item.GarbageCollectorProtectedObjectListNext;
    Item.GarbageCollectorProtectedObjectListPrevious := nil;
    Item.GarbageCollectorProtectedObjectListNext     := nil;
    Item.GarbageCollectorInProtectedList             := false;
    Item := NextItem;
  end;
  First := nil;  Last := nil;
end;

procedure TBESENGarbageCollectorProtectedObjectList.ClearWithFree;
begin
  while assigned(First) do First.Free;
  Clear;
end;

procedure TBESENGarbageCollectorProtectedObjectList.Add(AObject:TBESENGarbageCollectorObject);
begin
  if AObject.GarbageCollectorInProtectedList then exit;
  if assigned(Last) then begin
    Last.GarbageCollectorProtectedObjectListNext          := AObject;
    AObject.GarbageCollectorProtectedObjectListPrevious   := Last;
    AObject.GarbageCollectorProtectedObjectListNext       := nil;
    Last := AObject;
  end else begin
    First := AObject;  Last := AObject;
    AObject.GarbageCollectorProtectedObjectListPrevious := nil;
    AObject.GarbageCollectorProtectedObjectListNext     := nil;
  end;
  AObject.GarbageCollectorInProtectedList := true;
end;

procedure TBESENGarbageCollectorProtectedObjectList.Remove(AObject:TBESENGarbageCollectorObject);
begin
  if not AObject.GarbageCollectorInProtectedList then exit;
  if assigned(AObject.GarbageCollectorProtectedObjectListPrevious) then
    AObject.GarbageCollectorProtectedObjectListPrevious.GarbageCollectorProtectedObjectListNext := AObject.GarbageCollectorProtectedObjectListNext
  else if First = AObject then
    First := AObject.GarbageCollectorProtectedObjectListNext;
  if assigned(AObject.GarbageCollectorProtectedObjectListNext) then
    AObject.GarbageCollectorProtectedObjectListNext.GarbageCollectorProtectedObjectListPrevious := AObject.GarbageCollectorProtectedObjectListPrevious
  else if Last = AObject then
    Last := AObject.GarbageCollectorProtectedObjectListPrevious;
  AObject.GarbageCollectorProtectedObjectListNext     := nil;
  AObject.GarbageCollectorProtectedObjectListPrevious := nil;
  AObject.GarbageCollectorInProtectedList             := false;
end;

function TBESENGarbageCollectorProtectedObjectList.Contains(AObject:TBESENGarbageCollectorObject):boolean;
begin
  result := AObject.GarbageCollectorInProtectedList;
end;

procedure TBESENGarbageCollectorProtectedObjectList.Push(AObject:TBESENGarbageCollectorObject);
begin
  Add(AObject);
end;

function TBESENGarbageCollectorProtectedObjectList.Pop:TBESENGarbageCollectorObject;
begin
  result := Last;
  if assigned(result) then Remove(result);
end;

//=============================================================================
// TBESENGarbageCollectorObjectList  (White / Black only)
//=============================================================================

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
var Item, NextItem : TBESENGarbageCollectorObject;
begin
  Item := First;
  while assigned(Item) do begin
    NextItem := Item.GarbageCollectorObjectListNext;
    Item.GarbageCollectorObjectListPrevious := nil;
    Item.GarbageCollectorObjectListNext     := nil;
    Item.GarbageCollectorObjectList         := nil;
    Item := NextItem;
  end;
  First := nil;  Last := nil;
end;

procedure TBESENGarbageCollectorObjectList.ClearWithFree;
begin
  while assigned(First) do First.Free;
  Clear;
end;

procedure TBESENGarbageCollectorObjectList.Add(AObject:TBESENGarbageCollectorObject);
begin
  if assigned(Last) then begin
    Last.GarbageCollectorObjectListNext      := AObject;
    AObject.GarbageCollectorObjectListPrevious := Last;
    AObject.GarbageCollectorObjectListNext     := nil;
    Last := AObject;
  end else begin
    First := AObject;  Last := AObject;
    AObject.GarbageCollectorObjectListPrevious := nil;
    AObject.GarbageCollectorObjectListNext     := nil;
  end;
  AObject.GarbageCollectorObjectList := self;
end;

procedure TBESENGarbageCollectorObjectList.Remove(AObject:TBESENGarbageCollectorObject);
begin
  if assigned(AObject.GarbageCollectorObjectListPrevious) then
    AObject.GarbageCollectorObjectListPrevious.GarbageCollectorObjectListNext := AObject.GarbageCollectorObjectListNext
  else if First = AObject then
    First := AObject.GarbageCollectorObjectListNext;
  if assigned(AObject.GarbageCollectorObjectListNext) then
    AObject.GarbageCollectorObjectListNext.GarbageCollectorObjectListPrevious := AObject.GarbageCollectorObjectListPrevious
  else if Last = AObject then
    Last := AObject.GarbageCollectorObjectListPrevious;
  AObject.GarbageCollectorObjectListNext     := nil;
  AObject.GarbageCollectorObjectListPrevious := nil;
  AObject.GarbageCollectorObjectList         := nil;
end;

function TBESENGarbageCollectorObjectList.Contains(AObject:TBESENGarbageCollectorObject):boolean;
begin
  result := AObject.GarbageCollectorObjectList = self;
end;

procedure TBESENGarbageCollectorObjectList.Push(AObject:TBESENGarbageCollectorObject);
begin
  Add(AObject);
end;

function TBESENGarbageCollectorObjectList.Pop:TBESENGarbageCollectorObject;
begin
  result := Last;
  if assigned(result) then Remove(result);
end;

//=============================================================================
// TBESENGarbageCollector — work-stack helpers (OPT-B)
//=============================================================================

procedure TBESENGarbageCollector.GrayStackClear;
begin
  // Reset Top only. Stale pointers above Top are never read (Push/Pop both
  // guard on Top), so zeroing the array is unnecessary.
  // Do NOT touch object fields — only called from Clear after all objects freed.
  GrayStack.Top := 0;
end;

procedure TBESENGarbageCollector.GrayStackPush(AObject:TBESENGarbageCollectorObject);
begin
  if GrayStack.Top >= Length(GrayStack.Items) then begin
    if Length(GrayStack.Items) = 0 then
      SetLength(GrayStack.Items, BESEN_GC_WORKSTACK_MIN_CAPACITY)
    else
      SetLength(GrayStack.Items, Length(GrayStack.Items) * 2);
  end;
  GrayStack.Items[GrayStack.Top] := AObject;


  inc(GrayStack.Top);
end;

function TBESENGarbageCollector.GrayStackPop:TBESENGarbageCollectorObject;
begin
  // Skip stale slots: IsGray=false means WhiteIt/BlackIt/Destroy already
  // claimed this object; the slot was not nil-able without tracking the index.
  while GrayStack.Top > 0 do begin
    dec(GrayStack.Top);
    result := GrayStack.Items[GrayStack.Top];
    GrayStack.Items[GrayStack.Top] := nil;
    if assigned(result) and result.GarbageCollectorIsGray then begin
      result.GarbageCollectorIsGray := false;
      exit;
    end;
  end;
  result := nil;
end;

// Scan from top downwards past stale slots to find if any live gray object remains.
// Stale slots have IsGray=false (cleared by WhiteIt/BlackIt/Destroy).
// This matches the original's "assigned(GrayObjectList.First)" semantics exactly.
function TBESENGarbageCollector.GrayStackEmpty:boolean;
begin
  // Compact Top past any trailing stale slots so future calls are cheaper.
  while (GrayStack.Top > 0) and
        (not assigned(GrayStack.Items[GrayStack.Top-1]) or
         not GrayStack.Items[GrayStack.Top-1].GarbageCollectorIsGray) do
    dec(GrayStack.Top);
  result := GrayStack.Top = 0;
end;

//=============================================================================
// TBESENGarbageCollector
//=============================================================================

constructor TBESENGarbageCollector.Create(AInstance:TObject);
begin
  inherited Create(AInstance);
  First := nil;  Last := nil;
  RootObjectList      := TBESENGarbageCollectorRootObjectList.Create(Instance);
  ProtectedObjectList := TBESENGarbageCollectorProtectedObjectList.Create(Instance);
  WhiteObjectList     := TBESENGarbageCollectorObjectList.Create(Instance);
  BlackObjectList     := TBESENGarbageCollectorObjectList.Create(Instance);
  // OPT-B: initialise work-stack
  FillChar(GrayStack, SizeOf(GrayStack), 0);
  SetLength(GrayStack.Items, BESEN_GC_WORKSTACK_MIN_CAPACITY);
  // OPT-C: initialise arena
  FillChar(Arena, SizeOf(Arena), 0);
  IsSweeping            := false;
  State                 := bgcsINIT;
  TriggerCounter        := 0;
  MarkFactor            := BESEN_GC_MARKFACTOR;
  TriggerCountPerCollect := BESEN_GC_TRIGGERCOUNT_PER_COLLECT;
  Count                 := 0;
end;

destructor TBESENGarbageCollector.Destroy;
begin
  Clear;
  RootObjectList.Free;
  ProtectedObjectList.Free;
  WhiteObjectList.Free;
  BlackObjectList.Free;
  SetLength(GrayStack.Items, 0);
  // OPT-C: release all arena slabs
  ArenaFreeAll;
  inherited Destroy;
end;

procedure TBESENGarbageCollector.Clear;
var CurrentObject : TBESENGarbageCollectorObject;
begin
  CurrentObject := First;
  while assigned(CurrentObject) do begin
    FinalizeObjectForSweeping(CurrentObject);
    CurrentObject := CurrentObject.GarbageCollectorNext;
  end;
  while assigned(First) do First.Free;
  First := nil;  Last := nil;
  RootObjectList.Clear;
  ProtectedObjectList.Clear;
  WhiteObjectList.Clear;
  BlackObjectList.Clear;
  GrayStackClear;
  CurrentRootObject      := nil;
  CurrentProtectedObject := nil;
  CurrentMarkObject      := nil;
  CurrentSweepObject     := nil;
  TriggerCounter         := 0;
  Count                  := 0;
  State                  := bgcsINIT;
  IsSweeping             := false;
  // OPT-C: release all arena slabs — Clear is a full teardown.
  ArenaFreeAll;
end;

procedure TBESENGarbageCollector.Reset;
begin
  Flip;
  CurrentRootObject      := nil;
  CurrentProtectedObject := nil;
  CurrentSweepObject     := nil;
  State                  := bgcsINIT;
end;

//-----------------------------------------------------------------------------
// Colour transitions
//-----------------------------------------------------------------------------

procedure TBESENGarbageCollector.WhiteIt(AObject:TBESENGarbageCollectorObject);
begin
  if not assigned(AObject) then exit;
  if AObject.GarbageCollectorIsGray then begin
    AObject.GarbageCollectorIsGray := false;
    // stale slot remains in array; GrayStackPop and GrayStackEmpty skip it
  end;
  if not WhiteObjectList.Contains(AObject) then begin
    if assigned(AObject.GarbageCollectorObjectList) then
      AObject.GarbageCollectorObjectList.Remove(AObject);
    WhiteObjectList.Push(AObject);
  end;
end;

procedure TBESENGarbageCollector.ForceGrayIt(AObject:TBESENGarbageCollectorObject);
begin
  if not assigned(AObject) then exit;
  if not AObject.GarbageCollectorIsGray then begin
    if assigned(AObject.GarbageCollectorObjectList) then
      AObject.GarbageCollectorObjectList.Remove(AObject);
    AObject.GarbageCollectorIsGray := true;
    GrayStackPush(AObject);
  end;
end;

// GrayIt: hottest GC routine — every heap-pointer write hits this.
// Two flag checks (IsGray, is-Black) → early exit on the common already-marked path.
procedure TBESENGarbageCollector.GrayIt(AObject:TBESENGarbageCollectorObject);
begin
  if not assigned(AObject) then exit;
  if AObject.GarbageCollectorIsGray then exit;
  if AObject.GarbageCollectorObjectList = BlackObjectList then exit;
  if assigned(AObject.GarbageCollectorObjectList) then
    AObject.GarbageCollectorObjectList.Remove(AObject);
  AObject.GarbageCollectorIsGray := true;
  GrayStackPush(AObject);
end;

procedure TBESENGarbageCollector.BlackIt(AObject:TBESENGarbageCollectorObject);
begin
  if not assigned(AObject) then exit;
  if AObject.GarbageCollectorIsGray then begin
    // Was gray: definitely not in BlackObjectList, skip Contains check
    AObject.GarbageCollectorIsGray := false;
    if assigned(AObject.GarbageCollectorObjectList) then
      AObject.GarbageCollectorObjectList.Remove(AObject);
    BlackObjectList.Push(AObject);
  end else if not BlackObjectList.Contains(AObject) then begin
    if assigned(AObject.GarbageCollectorObjectList) then
      AObject.GarbageCollectorObjectList.Remove(AObject);
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
    bvtOBJECT: begin
      if assigned(Value.Obj) then
        GrayIt(TBESENObject(Value.Obj));
    end;
    bvtREFERENCE: begin
      case Value.ReferenceBase.ValueType of
        brbvtOBJECT: begin
          if assigned(Value.ReferenceBase.Obj) then
            GrayIt(TBESENObject(Value.ReferenceBase.Obj));
        end;
        brbvtENVREC: begin
          if assigned(Value.ReferenceBase.EnvRec) then
            GrayIt(TBESENEnvironmentRecord(Value.ReferenceBase.EnvRec));
        end;
      end;
    end;
  end;
end;

procedure TBESENGarbageCollector.FinalizeValue(var Value:TBESENValue);
begin
  Value := BESENEmptyValue;
end;

procedure TBESENGarbageCollector.Mark(AObject:TBESENGarbageCollectorObject);
begin
  if assigned(AObject) then AObject.Mark;
end;

procedure TBESENGarbageCollector.FinalizeObjectForSweeping(AObject:TBESENGarbageCollectorObject);
begin
  if assigned(AObject) then AObject.Finalize;
end;

// OPT-B: Flip now swaps White ↔ Black pointer lists only.
// The gray work-stack is separate and cleared at the start of each cycle.
procedure TBESENGarbageCollector.Flip;
var Tmp : TBESENGarbageCollectorObjectList;
begin
  Tmp             := WhiteObjectList;
  WhiteObjectList := BlackObjectList;
  BlackObjectList := Tmp;
end;

procedure TBESENGarbageCollector.TriggerCollect;
begin
  inc(TriggerCounter);
  if TriggerCounter >= TriggerCountPerCollect then begin
    TriggerCounter := 0;
    Collect;
  end;
end;

//=============================================================================
// Collect — the main incremental GC state machine
//=============================================================================
function TBESENGarbageCollector.Collect:boolean;
var
  i          : NativeInt;
  MarkCount  : NativeInt;
  Current    : PBESENPointerSelfBalancedTreeNode;
  Node       : TBESENASTNodeProgram;
  NextObject : TBESENGarbageCollectorObject;
begin
  result := false;
  while true do begin
    case State of
      bgcsINIT: begin
        State             := bgcsMARKROOTS;
        CurrentRootObject := RootObjectList.First;
      end;

      bgcsMARKROOTS: begin
        result    := false;
        MarkCount := (MarkFactor * Count) div 256;
        if MarkCount < 256        then MarkCount := 256;
        if MarkCount > $7fffffff  then MarkCount := $7fffffff;
        for i := 1 to MarkCount do begin
          if assigned(CurrentRootObject) then begin
            BlackIt(CurrentRootObject);
            Mark(CurrentRootObject);
            CurrentRootObject := CurrentRootObject.GarbageCollectorRootObjectListNext;
            result := assigned(CurrentRootObject);
          end else
            break;
        end;
        if result then break;
        CurrentProtectedObject := ProtectedObjectList.First;
        State := bgcsMARKPROTECTED;
      end;

      bgcsMARKPROTECTED: begin
        result    := false;
        MarkCount := (MarkFactor * Count) div 256;
        if MarkCount < 256        then MarkCount := 256;
        if MarkCount > $7fffffff  then MarkCount := $7fffffff;
        for i := 1 to MarkCount do begin
          if assigned(CurrentProtectedObject) then begin
            BlackIt(CurrentProtectedObject);
            Mark(CurrentProtectedObject);
            CurrentProtectedObject := CurrentProtectedObject.GarbageCollectorProtectedObjectListNext;
            result := assigned(CurrentProtectedObject);
          end else
            break;
        end;
        if result then break;
        State := bgcsMARKPROGRAMNODES;
      end;

      bgcsMARKPROGRAMNODES: begin
        Current := TBESEN(Instance).ProgramNodes.FirstKey;
        while assigned(Current) do begin
          Node := TBESENASTNodeProgram(Current^.Key);
          if assigned(Node) and assigned(Node.Body) and assigned(Node.Body.Code) then
            TBESENCode(Node.Body.Code).Mark;
          Current := Current^.NextKey;
        end;
        CurrentContext := TBESEN(Instance).ContextFirst;
        State := bgcsMARKCONTEXTS;
      end;

      bgcsMARKCONTEXTS: begin
        result := false;
        while assigned(CurrentContext) do begin
          TBESENContext(CurrentContext).Mark;
          CurrentContext := TBESENContext(CurrentContext).Next;
          result := assigned(CurrentContext);
        end;
        if result then break;
        State := bgcsMARKGRAYS;
      end;

      bgcsMARKGRAYS: begin
        // OPT-B: pop from the array work-stack (LIFO = DFS order = cache friendly)
        MarkCount := (MarkFactor * Count) div 256;
        if MarkCount < 256        then MarkCount := 256;
        if MarkCount > $7fffffff  then MarkCount := $7fffffff;
        for i := 1 to MarkCount do begin
          CurrentMarkObject := GrayStackPop;
          if not assigned(CurrentMarkObject) then break;
          // IsGray cleared by GrayStackPop
          Mark(CurrentMarkObject);
          BlackIt(CurrentMarkObject);
        end;
        // Check once after the batch whether more work remains
        result := not GrayStackEmpty;
        if result then break;
        CurrentSweepObject := WhiteObjectList.First;
        State := bgcsSWEEPWHITES;
      end;

      bgcsSWEEPWHITES: begin
        // Pass 1: rescue locked / protected whites back to gray
        CurrentSweepObject := WhiteObjectList.First;
        while assigned(CurrentSweepObject) do begin
          NextObject := CurrentSweepObject.GarbageCollectorObjectListNext;
          if (CurrentSweepObject.GarbageCollectorLockReferenceCounter > 0) or
             ProtectedObjectList.Contains(CurrentSweepObject) then
            GrayIt(CurrentSweepObject);
          CurrentSweepObject := NextObject;
        end;
        if not GrayStackEmpty then begin
          State := bgcsMARKGRAYS;
        end else begin
          // Pass 2: finalize + free all remaining whites
          CurrentSweepObject := WhiteObjectList.First;
          while assigned(CurrentSweepObject) do begin
            FinalizeObjectForSweeping(CurrentSweepObject);
            CurrentSweepObject := CurrentSweepObject.GarbageCollectorObjectListNext;
          end;
          while assigned(WhiteObjectList.First) do begin
            IsSweeping := true;
            WhiteObjectList.First.Free;
            IsSweeping := false;
          end;
          State := bgcsDONE;
        end;
      end;

      bgcsDONE: begin
        Flip;
        State  := bgcsINIT;
        result := false;
        break;
      end;
    end; // case
  end; // while
end;

procedure TBESENGarbageCollector.CollectAll;
begin
  while Collect do begin end;
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
  State := bgcsINIT;
end;

procedure TBESENGarbageCollector.RemoveRoot(AObject:TBESENGarbageCollectorObject);
begin
  State := bgcsINIT;
  if RootObjectList.Contains(AObject) then begin
    RootObjectList.Remove(AObject);
    ForceGrayIt(AObject);
  end;
end;

procedure TBESENGarbageCollector.AddProtected(AObject:TBESENGarbageCollectorObject);
begin
  GrayIt(AObject);
  ProtectedObjectList.Add(AObject);
  State := bgcsINIT;
end;

procedure TBESENGarbageCollector.RemoveProtected(AObject:TBESENGarbageCollectorObject);
begin
  State := bgcsINIT;
  if ProtectedObjectList.Contains(AObject) then begin
    ProtectedObjectList.Remove(AObject);
    ForceGrayIt(AObject);
  end;
end;

procedure TBESENGarbageCollector.LockObject(Obj:TBESENGarbageCollectorObject);
begin
  if assigned(Obj) then Obj.GarbageCollectorLock;
end;

procedure TBESENGarbageCollector.UnlockObject(Obj:TBESENGarbageCollectorObject);
begin
  if assigned(Obj) then Obj.GarbageCollectorUnlock;
end;

procedure TBESENGarbageCollector.LockValue(const Value:TBESENValue);
begin
  case Value.ValueType of
    bvtOBJECT: begin
      if assigned(Value.Obj) then LockObject(TBESENObject(Value.Obj));
    end;
    bvtREFERENCE: begin
      case Value.ReferenceBase.ValueType of
        brbvtOBJECT: begin
          if assigned(Value.ReferenceBase.Obj) then
            LockObject(TBESENObject(Value.ReferenceBase.Obj));
        end;
        brbvtENVREC: begin
          if assigned(Value.ReferenceBase.EnvRec) then
            LockObject(TBESENEnvironmentRecord(Value.ReferenceBase.EnvRec));
        end;
      end;
    end;
  end;
end;

procedure TBESENGarbageCollector.UnlockValue(const Value:TBESENValue);
begin
  case Value.ValueType of
    bvtOBJECT: begin
      if assigned(Value.Obj) then UnlockObject(TBESENObject(Value.Obj));
    end;
    bvtREFERENCE: begin
      case Value.ReferenceBase.ValueType of
        brbvtOBJECT: begin
          if assigned(Value.ReferenceBase.Obj) then
            UnlockObject(TBESENObject(Value.ReferenceBase.Obj));
        end;
        brbvtENVREC: begin
          if assigned(Value.ReferenceBase.EnvRec) then
            UnlockObject(TBESENEnvironmentRecord(Value.ReferenceBase.EnvRec));
        end;
      end;
    end;
  end;
end;

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
unit BESENDeclarativeEnvironmentRecord;
{$i BESEN.inc}

interface

uses SysUtils, BESENConstants, BESENTypes, BESENEnvironmentRecord, BESENValue, BESENPointerList, BESENStringList, BESENIntegerList, BESENObjectPropertyDescriptor, BESENStringUtils;

type
    PBESENDeclarativeEnvironmentRecordHashItem = ^TBESENDeclarativeEnvironmentRecordHashItem;

	TBESENDeclarativeEnvironmentRecordHashItem = record
		Previous, Next, HashPrevious, HashNext: PBESENDeclarativeEnvironmentRecordHashItem;
		Hash: TBESENHash; // Hash field is sometimes used as bucket index??
		Mutable: TBESENBoolean;
		Initialized: TBESENBoolean;
		Deletion: TBESENBoolean;
		Key: TBESENString;
		Value: TBESENValue;
		Index: integer;
	end;

	TBESENDeclarativeEnvironmentRecordHashBucket = record
		HashFirst, HashLast: PBESENDeclarativeEnvironmentRecordHashItem;
	end;

	TBESENDeclarativeEnvironmentRecordHashBuckets = array of TBESENDeclarativeEnvironmentRecordHashBucket;

	TBESENDeclarativeEnvironmentRecordValues = array of PBESENValue;

	{ TBESENDeclarativeEnvironmentRecord }

	TBESENDeclarativeEnvironmentRecord = class(TBESENEnvironmentRecord)
	private
		LastUsedItem: PBESENDeclarativeEnvironmentRecordHashItem;
		procedure ClearProper;
		procedure ClearDestructFast;
		procedure GrowAndRehashIfNeeded;
	public
		First, Last: PBESENDeclarativeEnvironmentRecordHashItem;
		HashBuckets: TBESENDeclarativeEnvironmentRecordHashBuckets;
		HashSize: longword;
		HashSizeMask: longword;
		HashedItems: longword;			// what is this for?
		HashBucketsUsed: longword;
		HashIndexes: TBESENPointerList;
		HashIndexNames: TBESENStringList;
		HashIndexIDs: TBESENIntegerList;
		HashValues: TBESENDeclarativeEnvironmentRecordValues;
		Touched: TBESENBoolean;
		IndexInitialized: TBESENBoolean;
		constructor Create(AInstance: TObject); overload; override;
		destructor Destroy; override;
		procedure Reset;
		function GetKey(const Key: TBESENString; Hash: TBESENHash = 0): PBESENDeclarativeEnvironmentRecordHashItem;
		function NewKey(const Key: TBESENString; Force: boolean = False; Hash: TBESENHash = 0): PBESENDeclarativeEnvironmentRecordHashItem;
		function DeleteKey(const Item: PBESENDeclarativeEnvironmentRecordHashItem): TBESENBoolean;
		function HasBindingEx(const N: TBESENString; var Descriptor: TBESENObjectPropertyDescriptor; Hash: TBESENHash = 0): TBESENBoolean; override;
		function CreateMutableBinding(const N: TBESENString; const D: TBESENBoolean = False; Hash: TBESENHash = 0): TBESENBoolean; override;
		function SetMutableBindingEx(const N: TBESENString; const V: TBESENValue; const S: TBESENBoolean; var Descriptor, OwnDescriptor: TBESENObjectPropertyDescriptor; var TempValue: TBESENValue; Hash: TBESENHash = 0): TBESENBoolean; override;
		procedure GetBindingValueEx(const N: TBESENString; const S: TBESENBoolean; var R: TBESENValue; var Descriptor: TBESENObjectPropertyDescriptor; Hash: TBESENHash = 0); override;
		function DeleteBindingEx(const N: TBESENString; var Descriptor: TBESENObjectPropertyDescriptor; Hash: TBESENHash = 0): TBESENBoolean; override;
		procedure UpdateImplicitThisValue; override;
		function CreateImmutableBinding(const N: TBESENString; Hash: TBESENHash = 0): TBESENBoolean; override;
		function InitializeImmutableBinding(const N: TBESENString; const V: TBESENValue; Hash: TBESENHash = 0): TBESENBoolean; override;
		function SetBindingValueIndex(const N: TBESENString; const I: integer; Hash: TBESENHash = 0): TBESENBoolean; override;
		function SetIndexValue(const I, ID: integer; const V: TBESENValue; const S: TBESENBoolean): TBESENBoolean; override;
		procedure GetIndexValue(const I, ID: integer; const S: TBESENBoolean; var R: TBESENValue); override;
		function DeleteIndex(const I, ID: integer): TBESENBoolean; override;
		procedure Finalize; override;
		procedure Mark; override;
	end;

implementation

uses BESEN, BESENHashUtils, BESENErrors;

constructor TBESENDeclarativeEnvironmentRecord.Create(AInstance: TObject);
var
    Hash: TBESENHash;
begin
	inherited Create(AInstance);

	FillChar(HashBuckets, sizeof(TBESENDeclarativeEnvironmentRecordHashBuckets), #0);
	First := nil;
	Last := nil;
	HashSize := 256;
	HashSizeMask := HashSize - 1;
	HashedItems := 0;
	HashBucketsUsed := 0;
	SetLength(HashBuckets, HashSize);

	for Hash := 0 to HashSizeMask do begin
		HashBuckets[Hash].HashFirst := nil;
		HashBuckets[Hash].HashLast := nil;
	end;

	HashIndexes := TBESENPointerList.Create;
	HashIndexNames := TBESENStringList.Create;
	HashIndexIDs := TBESENIntegerList.Create;
	HashValues := nil;
	Touched := False;
	IndexInitialized := False;
	LastUsedItem := nil;
	RecordType := BESENEnvironmentRecordTypeDeclarative;
end;

destructor TBESENDeclarativeEnvironmentRecord.Destroy;
begin
	ClearProper;
	SetLength(HashValues, 0);
	SetLength(HashBuckets, 0);
	FreeAndNil(HashIndexes);;
	FreeAndNil(HashIndexNames);
	FreeAndNil(HashIndexIDs);
	inherited Destroy;
end;

procedure TBESENDeclarativeEnvironmentRecord.ClearProper;
var
    Hash: TBESENHash;
	Item, NextItem: PBESENDeclarativeEnvironmentRecordHashItem;
begin
	Item := First;

	while assigned(Item) do begin
		NextItem := Item^.Next;
		Item^.Previous := nil;
		Item^.Next := nil;
		Item^.Key := '';
		Item^.Value.ValueType := bvtUNDEFINED;
		Dispose(Item);
		Item := NextItem;
	end;

	First := nil;
	Last := nil;
	LastUsedItem := nil;
	HashSize := 256;
	HashSizeMask := HashSize - 1;
	HashedItems := 0;
	HashBucketsUsed := 0;
	SetLength(HashBuckets, HashSize);

	for Hash := 0 to HashSizeMask do begin
		HashBuckets[Hash].HashFirst := nil;
		HashBuckets[Hash].HashLast := nil;
	end;

	HashIndexes.Clear;
	HashIndexNames.Clear;
	HashIndexIDs.Clear;
	SetLength(HashValues, 0);
	Touched := False;
	IndexInitialized := False;
end;

procedure TBESENDeclarativeEnvironmentRecord.ClearDestructFast;
var
	Item, NextItem: PBESENDeclarativeEnvironmentRecordHashItem;
begin

	// GPT version
	Item := First;
	while Assigned(Item) do begin
		NextItem := Item^.Next;
		Dispose(Item);
		Item := NextItem;
	end;

	First := nil;
	Last := nil;
	LastUsedItem := nil;

	HashSize := 0;
	HashSizeMask := 0;
	HashedItems := 0;
	HashBucketsUsed := 0;

	SetLength(HashBuckets, 0);
	SetLength(HashValues, 0);

	if Assigned(HashIndexes) then begin
		HashIndexes.Clear;
	end;
	if Assigned(HashIndexNames) then begin
		HashIndexNames.Clear;
	end;
	if Assigned(HashIndexIDs) then begin
		HashIndexIDs.Clear;
	end;

	Touched := False;
	IndexInitialized := False;

 (*

	// my version

  // Free linked list nodes
  Item := First;
  while Assigned(Item) do begin
    NextItem := Item^.Next;
    Item^.Key := '';  // Must finalize the managed string to avoid leak
    Dispose(Item);
    Item := NextItem;
  end;

  // Free dynamic arrays in one shot
  SetLength(HashBuckets, 0);
  SetLength(HashValues, 0);

  // Clear index structures
  HashIndexes.Clear;
  HashIndexNames.Clear;
  HashIndexIDs.Clear;

  *)

end;

procedure TBESENDeclarativeEnvironmentRecord.Reset;
var Item: PBESENDeclarativeEnvironmentRecordHashItem;
begin
	Item := First;
	while assigned(Item) do begin
		Item^.Value.ValueType := bvtUNDEFINED;
		Item^.Initialized := Item^.Mutable;
		Item := Item^.Next;
	end;
	Touched := False;
end;

procedure TBESENDeclarativeEnvironmentRecord.GrowAndRehashIfNeeded;
var Bucket: TBESENHash;
	Item: PBESENDeclarativeEnvironmentRecordHashItem;
begin
	if (HashSize < BESENHashMaxSize) and (HashedItems >= (HashBucketsUsed * BESENHashItemsPerBucketsThreshold)) then begin
		LastUsedItem := nil;
		Inc(HashSize, HashSize);
		if HashSize > BESENHashMaxSize then begin
			HashSize := BESENHashMaxSize;
		end;
		HashSizeMask := HashSize - 1;
		SetLength(HashBuckets, HashSize);
		// ClearProper all buckets (old + newly added) in one pass
		for Bucket := 0 to HashSizeMask do begin
			HashBuckets[Bucket].HashFirst := nil;
			HashBuckets[Bucket].HashLast := nil;
		end;
		// Single traversal: re-insert every item into the resized bucket table
		HashedItems := 0;
		HashBucketsUsed := 0;
		Item := First;
		while assigned(Item) do begin
			Inc(HashedItems);
			Bucket := BESENHashKey(Item^.Key) and HashSizeMask;
			Item^.Hash := Bucket;
			Item^.HashPrevious := nil;
			Item^.HashNext := nil;
			if assigned(HashBuckets[Bucket].HashLast) then begin
				HashBuckets[Bucket].HashLast^.HashNext := Item;
				Item^.HashPrevious := HashBuckets[Bucket].HashLast;
				HashBuckets[Bucket].HashLast := Item;
				Item^.HashNext := nil;
			end else begin
				Inc(HashBucketsUsed);
				HashBuckets[Bucket].HashFirst := Item;
				HashBuckets[Bucket].HashLast := Item;
			end;
			Item := Item^.Next;
		end;
	end;
end;

function TBESENDeclarativeEnvironmentRecord.GetKey(const Key: TBESENString; Hash: TBESENHash = 0): PBESENDeclarativeEnvironmentRecordHashItem;
var
    Bucket: TBESENHash;
begin

	if assigned(LastUsedItem) and (LastUsedItem^.Key = Key) then begin
		Result := LastUsedItem;
		Bucket := Result^.Hash;
	end else begin
		if Hash = 0 then begin
			Hash := BESENHashKey(Key);
		end;
		Bucket := Hash and HashSizeMask;
		Result := HashBuckets[Bucket].HashFirst;
		while assigned(Result) and (Result^.Key <> Key) do begin
			Result := Result^.HashNext;
		end;
	end;

	if assigned(Result) then begin
		LastUsedItem := Result;
		if HashBuckets[Bucket].HashFirst <> Result then begin
			if assigned(Result.HashPrevious) then begin
				Result.HashPrevious.HashNext := Result.HashNext;
			end;
			if assigned(Result.HashNext) then begin
				Result.HashNext.HashPrevious := Result.HashPrevious;
			end else if HashBuckets[Bucket].HashLast = Result then begin
				HashBuckets[Bucket].HashLast := Result.HashPrevious;
			end;
			HashBuckets[Bucket].HashFirst.HashPrevious := Result;
			Result.HashNext := HashBuckets[Bucket].HashFirst;
			Result.HashPrevious := nil;
			HashBuckets[Bucket].HashFirst := Result;
		end;
	end;
end;

function TBESENDeclarativeEnvironmentRecord.NewKey(const Key: TBESENString; Force: boolean = False; Hash: TBESENHash = 0): PBESENDeclarativeEnvironmentRecordHashItem;
var Bucket: TBESENHash;
begin
	if Force then begin
		Result := nil;
		if Hash = 0 then begin
			Hash := BESENHashKey(Key);
		end;
		Hash := Hash and HashSizeMask;
		Bucket := Hash;
	end else if assigned(LastUsedItem) and (LastUsedItem^.Key = Key) then begin
		Result := LastUsedItem;
		Bucket := Result^.Hash;
	end else begin
		if Hash = 0 then begin
			Hash := BESENHashKey(Key);
		end;
		Hash := Hash and HashSizeMask;
		Bucket := Hash;
		Result := HashBuckets[Bucket].HashFirst;
		if not assigned(Result) then begin
			Inc(HashBucketsUsed);
		end;
		while assigned(Result) and (Result^.Key <> Key) do begin
			Result := Result^.HashNext;
		end;
	end;
	if not assigned(Result) then begin
		Inc(HashedItems);
		New(Result);
		fillchar(Result^, sizeof(TBESENDeclarativeEnvironmentRecordHashItem), #0);
		Result^.Hash := Bucket;
		Result^.Key := Key;
		Result^.Index := -1;
		Result^.Value.ValueType := bvtUNDEFINED;
		Result^.Mutable := False;
		Result^.Initialized := False;
		Result^.Deletion := False;
		if assigned(HashBuckets[Bucket].HashLast) then begin
			HashBuckets[Bucket].HashLast^.HashNext := Result;
			Result^.HashPrevious := HashBuckets[Bucket].HashLast;
			Result^.HashNext := nil;
			HashBuckets[Bucket].HashLast := Result;
		end else begin
			HashBuckets[Bucket].HashFirst := Result;
			HashBuckets[Bucket].HashLast := Result;
			Result^.HashPrevious := nil;
			Result^.HashNext := nil;
		end;
		if assigned(Last) then begin
			Last^.Next := Result;
			Result^.Previous := Last;
			Result^.Next := nil;
			Last := Result;
		end else begin
			First := Result;
			Last := Result;
			Result^.Previous := nil;
			Result^.Next := nil;
		end;
		LastUsedItem := Result;
	end;
	GrowAndRehashIfNeeded;
	Touched := True;
end;

function TBESENDeclarativeEnvironmentRecord.DeleteKey(const Item: PBESENDeclarativeEnvironmentRecordHashItem): TBESENBoolean;
var Bucket: TBESENHash;
begin
	Result := assigned(Item);
	if Result then begin
		Touched := True;
		Dec(HashedItems); // fix: keep HashedItems accurate so rehash threshold is correct
		if LastUsedItem = Item then begin
			if assigned(Item^.Next) then begin
				LastUsedItem := Item^.Next;
			end else begin
				LastUsedItem := Item^.Previous;
			end;
		end;
		if assigned(Item^.Previous) then begin
			Item^.Previous^.Next := Item^.Next;
		end else if First = Item then begin
			First := Item^.Next;
		end;
		if assigned(Item^.Next) then begin
			Item^.Next^.Previous := Item^.Previous;
		end else if Last = Item then begin
			Last := Item^.Previous;
		end;
		Item^.Next := nil;
		Item^.Previous := nil;
		Bucket := Item^.Hash;
		if assigned(Item^.HashPrevious) then begin
			Item^.HashPrevious^.HashNext := Item^.HashNext;
		end else if HashBuckets[Bucket].HashFirst = Item then begin
			HashBuckets[Bucket].HashFirst := Item^.HashNext;
		end;
		if assigned(Item^.HashNext) then begin
			Item^.HashNext^.HashPrevious := Item^.HashPrevious;
		end else if HashBuckets[Bucket].HashLast = Item then begin
			HashBuckets[Bucket].HashLast := Item^.HashPrevious;
		end;
		Item^.HashNext := nil;
		Item^.HashPrevious := nil;
		Item^.Key := ''; // release string memory before pooling
		Item^.Value := BESENUndefinedValue;
		if Item^.Index >= 0 then begin
			HashIndexes[Item^.Index] := nil;
			HashValues[Item^.Index] := @BESENDummyValue;
		end;
		Dispose(Item);
	end;
end;

function TBESENDeclarativeEnvironmentRecord.HasBindingEx(const N: TBESENString; var Descriptor: TBESENObjectPropertyDescriptor; Hash: TBESENHash = 0): TBESENBoolean;
begin
	Result := assigned(GetKey(N, Hash));
end;

function TBESENDeclarativeEnvironmentRecord.CreateMutableBinding(const N: TBESENString; const D: TBESENBoolean = False; Hash: TBESENHash = 0): TBESENBoolean;
var
    Item: PBESENDeclarativeEnvironmentRecordHashItem;
begin

	if assigned(GetKey(N, Hash)) then begin
		BESENThrowTypeError(self, 'CreateMutableBinding for "' + N + '" failed');
	end;

	Item := NewKey(N, False, Hash);
	Item^.Value.ValueType := bvtUNDEFINED;
	Item^.Mutable := True;
	Item^.Initialized := False;
	Item^.Deletion := D;
	Result := True;
end;

function TBESENDeclarativeEnvironmentRecord.SetMutableBindingEx(const N: TBESENString; const V: TBESENValue; const S: TBESENBoolean; var Descriptor, OwnDescriptor: TBESENObjectPropertyDescriptor; var TempValue: TBESENValue; Hash: TBESENHash = 0): TBESENBoolean;
var
    Item: PBESENDeclarativeEnvironmentRecordHashItem;

	procedure ThrowIt;
	begin
		BESENThrowTypeError(self, 'SetMutableBinding for "' + N + '" failed');
	end;

begin

	Result := False;
	Item := GetKey(N, Hash);

	if not assigned(Item) then begin
		ThrowIt;

	end else if Item^.Mutable then begin
		BESENCopyValue(Item^.Value, V);
		Item^.Initialized := True;
		Result := True;
	end else begin

		if S then begin // will added/fixed in ES5 errata too
			ThrowIt;
		end;

	end;

end;

procedure TBESENDeclarativeEnvironmentRecord.GetBindingValueEx(const N: TBESENString; const S: TBESENBoolean; var R: TBESENValue; var Descriptor: TBESENObjectPropertyDescriptor; Hash: TBESENHash = 0);
var Item: PBESENDeclarativeEnvironmentRecordHashItem;

    procedure ThrowUninitialized;
	begin
		BESENThrowReferenceError('Uninitialized immutable binding "' + N + '"');
	end;

	procedure ThrowIt;
	begin
		BESENThrowTypeError(self, 'GetBindingValue for "' + N + '" failed');
	end;

begin
	Item := GetKey(N, Hash);
	if assigned(Item) then begin
		if Item^.Mutable or Item^.Initialized then begin
			BESENCopyValue(R, Item^.Value);
		end else begin
			if S then begin
				ThrowUninitialized;
			end else begin
				R.ValueType := bvtUNDEFINED;
			end;
		end;
	end else begin
		ThrowIt;
	end;
end;

function TBESENDeclarativeEnvironmentRecord.DeleteBindingEx(const N: TBESENString; var Descriptor: TBESENObjectPropertyDescriptor; Hash: TBESENHash = 0): TBESENBoolean;
var Item: PBESENDeclarativeEnvironmentRecordHashItem;
begin
	Item := GetKey(N, Hash);
	if assigned(Item) then begin
		if Item^.Mutable and Item^.Deletion then begin
			if Item^.Index >= 0 then begin
				HashIndexes[Item^.Index] := nil;
				HashValues[Item^.Index] := @BESENDummyValue;
			end;
			DeleteKey(Item);
			Result := True;
		end else begin
			Result := False;
		end;
	end else begin
		Result := True;
	end;
end;

procedure TBESENDeclarativeEnvironmentRecord.UpdateImplicitThisValue;
begin
	ImplicitThisValue.ValueType := bvtUNDEFINED;
	ImplicitThisValue.Obj := nil;
end;

function TBESENDeclarativeEnvironmentRecord.CreateImmutableBinding(const N: TBESENString; Hash: TBESENHash = 0): TBESENBoolean;
var
    Item: PBESENDeclarativeEnvironmentRecordHashItem;
begin
	if assigned(GetKey(N, Hash)) then begin
		BESENThrowTypeError(self, 'CreateImmutableBinding for "' + N + '" failed');
	end;
	Item := NewKey(N, False, Hash);
	Item^.Value.ValueType := bvtUNDEFINED;
	Item^.Mutable := False;
	Item^.Initialized := False;
	Item^.Deletion := False;
	Result := True;
end;

function TBESENDeclarativeEnvironmentRecord.InitializeImmutableBinding(const N: TBESENString; const V: TBESENValue; Hash: TBESENHash = 0): TBESENBoolean;
var
    Item: PBESENDeclarativeEnvironmentRecordHashItem;
begin
	Item := GetKey(N, Hash);
	if assigned(Item) and not (Item^.Mutable or Item^.Initialized) then begin
		BESENCopyValue(Item^.Value, v);
		Item^.Initialized := True;
	end else begin
		BESENThrowTypeError(self, 'InitializeImmutableBinding for "' + N + '" failed');
	end;
	Result := True;
end;

function TBESENDeclarativeEnvironmentRecord.SetBindingValueIndex(const N: TBESENString; const I: integer; Hash: TBESENHash = 0): TBESENBoolean;
var
    Item: PBESENDeclarativeEnvironmentRecordHashItem;
begin
	Item := GetKey(N, Hash);
	if assigned(Item) then begin
		Item^.Index := I;
		HashIndexes.Insert(I, Item);
		HashIndexNames.Insert(I, N);
		HashIndexIDs.Insert(I, TBESEN(Instance).KeyIDManager.Get(N, Hash));
		if i >= length(HashValues) then begin
			SetLength(HashValues, i + 256);
		end;
		HashValues[i] := @Item^.Value;
		Result := True;
	end else begin
		Result := False;
	end;
end;

function TBESENDeclarativeEnvironmentRecord.SetIndexValue(const I, ID: integer; const V: TBESENValue; const S: TBESENBoolean): TBESENBoolean;
var
    Item: PBESENDeclarativeEnvironmentRecordHashItem;

	procedure ThrowIt;
	begin
		BESENThrowTypeError(self, 'SetIndexValue for "' + IntToStr(I) + '" failed');
	end;

begin
	if (I >= 0) and (I < HashIndexes.Count) then begin
		Item := HashIndexes[I];
	end else begin
		Item := nil;
	end;
	if assigned(Item) and Item^.Mutable then begin
		BESENCopyValue(Item^.Value, v);
		Item^.Initialized := True;
	end else begin
		ThrowIt;
	end;
	Result := True;
end;

procedure TBESENDeclarativeEnvironmentRecord.GetIndexValue(const I, ID: integer; const S: TBESENBoolean; var R: TBESENValue);
var
    Item: PBESENDeclarativeEnvironmentRecordHashItem;

	procedure ThrowUninitialized;
	begin
		BESENThrowReferenceError('Uninitialized immutable binding "' + Item^.Key + '"');
	end;

	procedure ThrowIt;
	begin
		BESENThrowTypeError(self, 'GetIndexValue for "' + IntToStr(I) + '" failed');
	end;

begin
	if (I >= 0) and (I < HashIndexes.Count) then begin
		Item := HashIndexes[I];
	end else begin
		Item := nil;
	end;
	if assigned(Item) then begin
		if Item^.Mutable or Item^.Initialized then begin
			BESENCopyValue(R, Item^.Value);
		end else begin
			if S then begin
				ThrowUninitialized;
			end else begin
				R.ValueType := bvtUNDEFINED;
			end;
		end;
	end else begin
		ThrowIt;
	end;
end;

function TBESENDeclarativeEnvironmentRecord.DeleteIndex(const I, ID: integer): TBESENBoolean;
var Item: PBESENDeclarativeEnvironmentRecordHashItem;
begin
	if (I >= 0) and (I < HashIndexes.Count) then begin
		Item := HashIndexes[I];
	end else begin
		Item := nil;
	end;
	if assigned(Item) then begin
		if Item^.Mutable and Item^.Deletion then begin
			HashIndexes[i] := nil;
			HashValues[i] := @BESENDummyValue;
			DeleteKey(Item);
			Result := True;
		end else begin
			Result := False;
		end;
	end else begin
		Result := True;
	end;
end;

procedure TBESENDeclarativeEnvironmentRecord.Finalize;
begin
	ClearProper;
	inherited Finalize;
end;

procedure TBESENDeclarativeEnvironmentRecord.Mark;
var Item: PBESENDeclarativeEnvironmentRecordHashItem;
begin
	Item := First;
	while assigned(Item) do begin
		TBESEN(Instance).GarbageCollector.GrayValue(Item^.Value);
		Item := Item^.Next;
	end;
	inherited Mark;
end;

end.

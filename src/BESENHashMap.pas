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
unit BESENHashMap;
{$i BESEN.inc}

interface

uses BESENConstants, BESENTypes, BESENStringUtils, BESENHashUtils;

type

    PBESENHashMapItem = ^TBESENHashMapItem;

	TBESENHashMapItem = record
		Previous, Next, HashPrevious, HashNext: PBESENHashMapItem;
		Hash: TBESENHash;
		Key: TBESENString;
		Value: int64;
		Ptr: pointer;
	end;

	TBESENHashMapHashBucket = record
		HashFirst, HashLast: PBESENHashMapItem;
	end;

	TBESENHashMapHashBuckets = array of TBESENHashMapHashBucket;

	TBESENHashMap = class
	private
		LastUsedItem: PBESENHashMapItem;
		procedure GrowAndRehashIfNeeded;
	public
		First, Last: PBESENHashMapItem;
		HashBuckets: TBESENHashMapHashBuckets;
		HashSize: longword;
		HashSizeMask: longword;
		HashedItems: longword;
		HashBucketsUsed: longword;
		constructor Create;
		destructor Destroy; override;
		procedure Clear;
		function GetKey(const Key: TBESENString; Hash: TBESENHash = 0): PBESENHashMapItem;
		function NewKey(const Key: TBESENString; Force: boolean = False; Hash: TBESENHash = 0): PBESENHashMapItem;
		function DeleteKey(const Item: PBESENHashMapItem): TBESENBoolean;
	end;

implementation

constructor TBESENHashMap.Create;
var Hash: TBESENHash;
begin
	inherited Create;
	FillChar(HashBuckets, sizeof(TBESENHashMapHashBuckets), #0);
	First := nil;
	Last := nil;
	HashSize := 256;
	HashSizeMask := HashSize - 1;
	HashedItems := 0;
	HashBucketsUsed := 0;
	HashBuckets := nil;
	SetLength(HashBuckets, HashSize);
	for Hash := 0 to HashSizeMask do begin
		HashBuckets[Hash].HashFirst := nil;
		HashBuckets[Hash].HashLast := nil;
	end;
	LastUsedItem := nil;
end;

destructor TBESENHashMap.Destroy;
begin
	Clear;
	SetLength(HashBuckets, 0);
	inherited Destroy;
end;

procedure TBESENHashMap.Clear;
var Hash: TBESENHash;
	Item, NextItem: PBESENHashMapItem;
begin
	Item := First;
	while assigned(Item) do begin
		NextItem := Item^.Next;
		Item^.Next := nil;
		Item^.Key := '';
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
end;

procedure TBESENHashMap.GrowAndRehashIfNeeded;
var Hash: TBESENHash;
	Item: PBESENHashMapItem;
begin
	if (HashSize < BESENHashMaxSize) and (HashedItems >= (HashBucketsUsed * BESENHashItemsPerBucketsThreshold)) then begin
		LastUsedItem := nil;
		Inc(HashSize, HashSize);
		if HashSize > BESENHashMaxSize then begin
			HashSize := BESENHashMaxSize;
		end;
		HashSizeMask := HashSize - 1;
		SetLength(HashBuckets, HashSize);
		for Hash := 0 to HashSizeMask do begin
			HashBuckets[Hash].HashFirst := nil;
			HashBuckets[Hash].HashLast := nil;
		end;
		HashedItems := 0;
		HashBucketsUsed := 0;
		Item := First;
		while assigned(Item) do begin
			Hash := BESENHashKey(Item^.Key) and HashSizeMask;
			Item^.Hash := Hash;
			Inc(HashedItems);
			Item^.HashPrevious := HashBuckets[Hash].HashLast;
			if assigned(Item^.HashPrevious) then begin
				Item^.HashPrevious^.HashNext := Item;
			end else begin
				Inc(HashBucketsUsed);
				HashBuckets[Hash].HashFirst := Item;
			end;
			Item^.HashNext := nil;
			HashBuckets[Hash].HashLast := Item;
			Item := Item^.Next;
		end;
	end;
end;

function TBESENHashMap.GetKey(const Key: TBESENString; Hash: TBESENHash = 0): PBESENHashMapItem;
begin
	if assigned(LastUsedItem) and (LastUsedItem^.Key = Key) then begin
		Result := LastUsedItem;
		Hash := Result^.Hash;
	end else begin
		if Hash = 0 then begin
			Hash := BESENHashKey(Key);
		end;
		Hash := Hash and HashSizeMask;
		Result := HashBuckets[Hash].HashFirst;
		while assigned(Result) and (Result^.Key <> Key) do begin
			Result := Result^.HashNext;
		end;
	end;
	if assigned(Result) then begin
		LastUsedItem := Result;
		if HashBuckets[Hash].HashFirst <> Result then begin
			if assigned(Result^.HashPrevious) then begin
				Result^.HashPrevious^.HashNext := Result^.HashNext;
			end;
			if assigned(Result^.HashNext) then begin
				Result^.HashNext^.HashPrevious := Result^.HashPrevious;
			end else if HashBuckets[Hash].HashLast = Result then begin
				HashBuckets[Hash].HashLast := Result^.HashPrevious;
			end;
			HashBuckets[Hash].HashFirst^.HashPrevious := Result;
			Result^.HashNext := HashBuckets[Hash].HashFirst;
			Result^.HashPrevious := nil;
			HashBuckets[Hash].HashFirst := Result;
		end;
	end;
end;

function TBESENHashMap.NewKey(const Key: TBESENString; Force: boolean = False; Hash: TBESENHash = 0): PBESENHashMapItem;
begin

	if Force then begin
		Result := nil;
		if Hash = 0 then begin
			Hash := BESENHashKey(Key);
		end;
		Hash := Hash and HashSizeMask;
	end else if assigned(LastUsedItem) and (LastUsedItem^.Key = Key) then begin
		Result := LastUsedItem;
		Hash := Result^.Hash;
	end else begin
		if Hash = 0 then begin
			Hash := BESENHashKey(Key);
		end;
		Hash := Hash and HashSizeMask;
		Result := HashBuckets[Hash].HashFirst;
		if not assigned(Result) then begin
			Inc(HashBucketsUsed);
		end;

		// i've changed this to be same as in besendeclarativeenvironmentrecord, looks like it was a bug.

		while assigned(Result) and (Result^.Key <> Key) do begin   // original meaning: while assigned(result) and (result^.Key = Key) do // original: while assigned(result) and not (result^.Key <> Key) do begin   // while assigned(result) and (result^.Key = Key) do
			Result := Result^.HashNext;
		end;

	end;

	if not assigned(Result) then begin
		Inc(HashedItems);
		New(Result);
		fillchar(Result^, sizeof(TBESENHashMapItem), #0);
		Result^.Hash := Hash;
		Result^.Key := Key;
		if assigned(HashBuckets[Hash].HashLast) then begin
			HashBuckets[Hash].HashLast^.HashNext := Result;
			Result^.HashPrevious := HashBuckets[Hash].HashLast;
			Result^.HashNext := nil;
			HashBuckets[Hash].HashLast := Result;
		end else begin
			HashBuckets[Hash].HashFirst := Result;
			HashBuckets[Hash].HashLast := Result;
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
end;

function TBESENHashMap.DeleteKey(const Item: PBESENHashMapItem): TBESENBoolean;
begin
	Result := assigned(Item);
	if Result then begin
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
		if assigned(Item^.HashPrevious) then begin
			Item^.HashPrevious^.HashNext := Item^.HashNext;
		end else if HashBuckets[Item^.Hash].HashFirst = Item then begin
			HashBuckets[Item^.Hash].HashFirst := Item^.HashNext;
		end;
		if assigned(Item^.HashNext) then begin
			Item^.HashNext^.HashPrevious := Item^.HashPrevious;
		end else if HashBuckets[Item^.Hash].HashLast = Item then begin
			HashBuckets[Item^.Hash].HashLast := Item^.HashPrevious;
		end;
		Item^.HashNext := nil;
		Item^.HashPrevious := nil;
		Item^.Key := '';
		Dispose(Item);
	end;
end;

end.

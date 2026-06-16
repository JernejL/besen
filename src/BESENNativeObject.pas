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

// regex to get typinfo methods: (AddEnumElementAliases|AddEnumeratedAliases|aligntoptr|AlignTypeData|CheckVariantEvent|DerefTypeInfoPtr|FindPropInfo|GetBaseType|GetCompType|GetDims|GetDynArrayProp|GetElType|GetElType2|GetEntry|GetEnumeratedAliases|GetEnumeratedAliasValue|GetEnumName|GetEnumNameCount|GetEnumProp|GetEnumValue|GetExtendedInfo|GetField|GetFlags|GetFloatProp|GetHelperParent|GetIIDStr|GetInstanceType|GetInt64Prop|GetInterfaceProp|GetIntfParent|GetLocation|GetMethod|GetMethodProp|GetMethodTable|GetName|GetNext|GetNextElement|GetObjectProp|GetObjectPropClass|GetOrdProp|GetParam|GetParamType|GetParentInfo|GetPointerProp|GetProp|GetPropertyTable|GetPropInfo|GetPropInfos|GetPropList|GetPropType|GetPropValue|GetRawbyteStrProp|GetRawByteStrProp|GetRawInterfaceProp|GetRawIntfParent|GetRecInitData|GetReference|GetRefType|GetRegType|GetResultLocs|GetResultType|GetSetProp|GetShiftVal|GetStrProp|GetTail|GetTypeData|GetTypeRef|GetUnicodeStrProp|GetUnitName|GetVariantProp|GetWideStrProp|IndexOfEnumeratedAliases|InsertProp|InsertPropnosort|IsPublishedProp|IsReadableProp|IsStoredProp|IsWriteableProp|PropIsType|PropType|RemoveEnumElementAliases|SetDynArrayProp|SetEnumProp|SetFloatProp|SetInt64Prop|SetInterfaceProp|SetMethodProp|SetObjectProp|SetOrdProp|SetPointerProp|SetPropValue|SetRawByteStrProp|SetRawInterfaceProp|SetSetProp|SetStrProp|SetToString|SetUnicodeStrProp|SetVariantProp|SetWideStrProp|StringToSet|GetBaseType|GetCompType|GetDims|GetElType|GetElType2|GetEntry|GetExtendedInfo|GetField|GetFlags|GetHelperParent|GetIIDStr|GetInstanceType|GetIntfParent|GetLocation|GetMethod|GetMethodTable|GetName|GetNext|GetParam|GetParamType|GetParentInfo|GetProp|GetPropertyTable|GetPropType|GetRawIntfParent|GetRecInitData|GetReference|GetRefType|GetRegType|GetResultLocs|GetResultType|GetShiftVal|GetTail|GetTypeRef|GetUnitName)

unit BESENNativeObject;
{$i BESEN.inc}

interface

uses windows, Classes, TypInfo, Rtti, sysutils, Variants, BESENConstants,BESENTypes,BESENObject,BESENObjectFunction, BESENObjectDeclaredFunction, BESENValue,BESENObjectPropertyDescriptor,
     BESENEnvironmentRecord;

const

	AddNativeObjectMarker		= '$Instance';
    AddNativeConstructorMarker	= '$Constructor';

type

     {$ifdef fpc}
     PShortString=^ShortString;
     {$endif}

     PMethodNameRec=^TMethodNameRec;

     TMethodNameRec=packed record
     {$ifdef fpc}
           Name:PShortString;
           Address:pointer;
     {$else}
           Size:word;
           Address:pointer;
           Name:{$ifdef BESENEmbarcaderoNextGen}TSymbolName{$else}ShortString{$endif};
     {$endif}
     end;
      TMethodNameRecs=packed array[word] of TMethodNameRec;
      PMethodNameTable=^TMethodNameTable;
      TMethodNameTable=packed record
       Count:{$ifdef fpc}longword{$else}word{$endif};
       Methods:TMethodNameRecs;
      end;

	 { TBESENNativeObject }

     TBESENNativeObject=class(TBESENObjectFunction)
      private
       PropList:PPropList;
       PropListLen:integer;
       Dispatchers: TList; // Holds TBESENRTTIDispatcher instances for auto-wrapped non-native methods
       function GetProp(const Prop:TBESENObjectProperty;var V:TBESENValue;Throw:boolean):boolean;
       function PutProp(const Prop:TBESENObjectProperty;const V:TBESENValue;Throw:boolean):boolean;
      protected
       procedure ConstructObject(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer); virtual;
       procedure InitializeObject; virtual;
       procedure FinalizeObject; virtual;
       procedure CopyPrototypeRTTI(var fromobjectprototype: TBESENObject);
      public
       Initialized:TBESENBoolean;
       procedure OnDeleteOperator; virtual;
       constructor Create(AInstance:TObject;APrototype:TBESENObject=nil;AHasPrototypeProperty:longbool=false); overload; override;
       destructor Destroy; override;
       function GetOwnProperty(const P:TBESENString;var Descriptor:TBESENObjectPropertyDescriptor;Hash:TBESENHash=0):boolean; override;
       function GetEx(const P:TBESENString;var AResult:TBESENValue;var Descriptor:TBESENObjectPropertyDescriptor;Base:TBESENObject=nil;Hash:TBESENHash=0):boolean; override;
       function GetIndex(const Index,ID:integer;var AResult:TBESENValue;Base:TBESENObject=nil):boolean; override;
       procedure PutEx(const P:TBESENString;const V:TBESENValue;Throw:TBESENBoolean;var Descriptor,OwnDescriptor:TBESENObjectPropertyDescriptor;var TempValue:TBESENValue;Hash:TBESENHash=0); override;
       procedure PutIndex(const Index,ID:integer;const V:TBESENValue;Throw:TBESENBoolean); override;
       function HasPropertyEx(const P:TBESENString;var Descriptor:TBESENObjectPropertyDescriptor;Hash:TBESENHash=0):TBESENBoolean; override;
       function DeleteEx(const P:TBESENString;Throw:TBESENBoolean;var Descriptor:TBESENObjectPropertyDescriptor;Hash:TBESENHash=0):TBESENBoolean; override;
       function DefineOwnPropertyEx(const P:TBESENString;const Descriptor:TBESENObjectPropertyDescriptor;Throw:TBESENBoolean;var Current:TBESENObjectPropertyDescriptor;Hash:TBESENHash=0):TBESENBoolean; override;
       procedure Construct(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var AResult:TBESENValue); override;
       procedure Call(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var AResult:TBESENValue); override;
       function HasConstruct:TBESENBoolean; override;
       function HasCall:TBESENBoolean; override;
       procedure Finalize; override;
       procedure Mark; override;
     end;

     TBESENNativeObjectClass=class of TBESENNativeObject;

implementation

uses {$ifdef BESENEmbarcaderoNextGen}System.SysUtils,{$endif}BESEN,BESENErrors,BESENHashUtils,BESENStringUtils, BESENGarbageCollector, BESENNativeObjectRttiMethodDispatcher, BESENObjectPrototype, BESENObjectNativeFunction;

{$ifdef BESENEmbarcaderoNextGen}
function PByteToString(Src:pbyte):string;
???
end;
{$endif}


constructor TBESENNativeObject.Create(AInstance:TObject;APrototype:TBESENObject=nil;AHasPrototypeProperty:longbool=false);
begin

 inherited Create(AInstance,APrototype,AHasPrototypeProperty);
 Initialized:=false;
 PropList:=nil;
 PropListLen:=0;
 ObjectClassName:=ClassName + AddNativeConstructorMarker;
 Dispatchers:=TList.Create;

 InitializeObject(); // init prototype too.

end;

destructor TBESENNativeObject.Destroy;
begin
 if Initialized then begin

  TBESENNativeObject(self).FinalizeObject();

  FinalizeObject;
 end;
 if assigned(PropList) then begin
  FreeMem(PropList);
  PropList:=nil;
  PropListLen:=0;
 end;
 FreeAndNil(Dispatchers);
 inherited Destroy;
end;

procedure TBESENNativeObject.OnDeleteOperator;
begin

	// delete was called on object.
	inherited;

end;

procedure TBESENNativeObject.ConstructObject(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer);
begin
end;


// Returns true if the method already matches TBESENNativeFunction signature:

// const ThisArgument:TBESENValue;
// Arguments:PPBESENValues;
// CountArguments:integer;
// var AResult:TBESENValue
// THIS IS SLOW WHEN IT CALLS "FIND" ?!

function IsNativeBESENSignature(const M:TRttiMethod):boolean; // inline;
var
	P:TArray<TRttiParameter>;
const
    besenvaluecgk = 'TBESENValue';
begin

	P:= M.GetParameters;

    if (Length(P) <> 4) then exit(false);
    if (assigned(P[0].ParamType) = false) then exit(false);
    if (assigned(P[3].ParamType) = false) then exit(false);
    if (not ( (pfConst in P[0].Flags) and (pfVar in P[3].Flags) ) ) then exit(false);

    // check strings now
    result:= (P[0].ParamType.Name= besenvaluecgk ) and (P[3].ParamType.Name= besenvaluecgk) ;

    {

    if (Length(P) <>4) then exit(false);

    result:= assigned(P[0].ParamType) and (P[0].ParamType.Name= 'TBESENValue' ) and (pfConst in P[0].Flags) and assigned(P[3].ParamType) and (P[3].ParamType.Name= 'TBESENValue') and (pfVar in P[3].Flags);

    }

end;

procedure TBESENNativeObject.InitializeObject;


	procedure AddRTTIMethods();
	var
		NativeFunction:TBESENNativeFunction;
		// Use extended RTTI to enumerate public methods on this exact class.
		// - Methods that already carry the BESEN native function signature are
		//   registered directly via their CodeAddress (zero-overhead path).
		// - All other public methods are wrapped by a TBESENRTTIDispatcher that
		//   auto-marshals TBESENValue <-> typed Pascal args through TRttiMethod.Invoke.
		//   This lets you write normal typed Pascal methods and expose them to JS:
		//     function  Add(A,B:integer):integer;
		//     function  Greet(const Name:string):string;
		//     procedure SetFlag(Value:boolean);
		//   They are accessible from JavaScript exactly like native methods.
		Ctx:TRttiContext;
		RttiType:TRttiType;
		RttiMethod:TRttiMethod;
		IsNative:boolean;
		Dispatcher:TBESENRTTIDispatcher;
		rttimethods: TRttiMethodArray;

	begin
		try
			Ctx:=TRttiContext.Create;
			try
				RttiType:=Ctx.GetType(Self.ClassType);

	            rttimethods:= RttiType.GetMethods;

	            // OutputDebugStringW(pwidechar(wideformat('class %s has %d methods', [ Self.ClassName, length(rttimethods)  ])));

	            for RttiMethod in rttimethods do begin

					// Only expose public methods

	                if ((RttiMethod.IsConstructor = true) or (RttiMethod.IsDestructor = true) ) then continue;

					if not (RttiMethod.Visibility in [ mvPublic, mvPublished]) then
						continue;

					if length(RttiMethod.Name)=0 then
						continue;

	                IsNative:= IsNativeBESENSignature(RttiMethod);

					if IsNative then begin

                     	// OutputDebugStringW(pwidechar(wideformat('adding native besen rtti method %s native besen: %d, destructor %d, constructor %d, classmethod %d, staticclassmethod %d', [ RttiMethod.Name, ord(IsNative), ord(RttiMethod.IsDestructor), ord(RttiMethod.IsDestructor), ord(RttiMethod.IsClassMethod), ord(RttiMethod.IsClassMethod) ])));

	                	// Method is a native besen method.

						TMethod(NativeFunction).Code:= RttiMethod.CodeAddress;
						TMethod(NativeFunction).Data:= self;
						RegisterNativeFunction(RttiMethod.Name,NativeFunction,0,[],false);

					end else begin

                        {
	                    if RttiMethod.Name <> 'FreeObject' then begin

	                        OutputDebugStringW(pwidechar(wideformat('adding marshalled rtti method %s native besen: %d, destructor %d, constructor %d, classmethod %d, staticclassmethod %d', [ RttiMethod.Name, ord(IsNative), ord(RttiMethod.IsDestructor), ord(RttiMethod.IsDestructor), ord(RttiMethod.IsClassMethod), ord(RttiMethod.IsClassMethod) ])));

                            // todo: not if it's methods?

							// Wrapper path: create a dispatcher that marshals arguments
							// and return value through TRttiMethod.Invoke.
							Dispatcher:=TBESENRTTIDispatcher.Create(self,RttiMethod);
							Dispatchers.Add(Dispatcher);
							TMethod(NativeFunction).Code:=@TBESENRTTIDispatcher.Dispatch;
							TMethod(NativeFunction).Data:=Dispatcher;
							RegisterNativeFunction(RttiMethod.Name,NativeFunction,0,[],false);

						end;

                        }

					end;
				end;
			finally
				Ctx.Free;
			end;
		except
			raise;
		end;
	end;

    procedure AddRTTIProperties;
    var
        i: integer;
        Prop:TBESENObjectProperty;
        classproperty:PPropInfo;
    begin

	  PropListLen:=GetPropList(self,PropList);
	  try
	   for i:=0 to PropListLen-1 do begin

        classproperty:= PropList^[i];

	    if assigned(classproperty^.PropType) then begin
			case classproperty^.PropType^.Kind of tkLString,tkWString{$ifdef fpc},tkAString{$endif},tkVariant{$ifdef fpc},tkUString{$endif}, tkInteger,tkBool, tkChar,tkFloat,tkEnumeration,tkWChar,tkSet{$ifdef fpc},tkSString{$endif}, tkInt64{$ifdef fpc},tkQWORD{$endif},tkClass:begin

				{$ifdef BESENEmbarcaderoNextGen}
		       if not assigned(Item^.GetProc) then begin
		        BESENThrowNotReadable(PByteToString(@(Item^.Name)));
		       end;
		       Prop:=Properties.Get(PByteToString(@(Item^.Name)));
		       if not assigned(Prop) then begin
		        Prop:=Properties.Put(PByteToString(@(Item^.Name)));
		       end;
				{$else}
		       if not assigned(classproperty^.GetProc) then begin
		        BESENThrowNotReadable(TBESENString(classproperty^.Name));
		       end;
		       Prop:=Properties.Get(TBESENString(classproperty^.Name));
		       if not assigned(Prop) then begin
		        Prop:=Properties.Put(TBESENString(classproperty^.Name));
		       end;
				{$endif}
		       Prop.PropIndex:=i;
		       Prop.Descriptor.Value.ValueType:=bvtUNDEFINED;
		       Prop.Descriptor.Getter:=nil;
		       Prop.Descriptor.Setter:=nil;
		       if assigned(classproperty^.SetProc) then begin
		        Prop.Descriptor.Attributes:=[bopaWRITABLE,bopaENUMERABLE];
		       end else begin
		        Prop.Descriptor.Attributes:=[bopaENUMERABLE];
		       end;
		       	Prop.Descriptor.Presents:=[boppVALUE,boppWRITABLE,boppENUMERABLE,boppCONFIGURABLE];
			end else begin

	         	EBESENError.Create( wideformat('unsupported property: %s', [classproperty^.Name] ));

	            //BESENThrowTypeError(self, 'Unknown native property data type');

	           {
	           TTypeKind = (tkUnknown,tkInteger,tkChar,tkEnumeration,tkFloat,
	                 tkSet,tkMethod,tkSString,tkLString,tkAString,
	                 tkWString,tkVariant,tkArray,tkRecord,tkInterface,
	                 tkClass,tkObject,tkWChar,tkBool,tkInt64,tkQWord,
	                 tkDynArray,tkInterfaceRaw,tkProcVar,tkUString,tkUChar,
	                 tkHelper,tkFile,tkClassRef,tkPointer);
	           }

	      end;
	     end;
	    end;
	   end;
	  except
	   FreeMem(PropList);
	   PropList:=nil;
	   PropListLen:=0;
	   raise;
	  end;

	end;

var
	protoinstance: TBESENObject;
begin

	if not Initialized then begin

		Initialized:= true;

		ObjectClassName:= ClassName + AddNativeObjectMarker;

        protoinstance:= BESENObjectIsInstance(self);

        if assigned( protoinstance ) then begin

            // instance of prototype created

        	CopyPrototypeRTTI(protoinstance);
            AddRTTIProperties();

		end else begin

        	// prototype created
	 		AddRTTIMethods();
	 		AddRTTIProperties();

		end;

		InvalidateStructure;
	end;

end;

procedure TBESENNativeObject.FinalizeObject;
var i:integer;
begin
 if Initialized then begin
  Initialized:=false;
  if assigned(PropList) then begin
   FreeMem(PropList);
   PropList:=nil;
   PropListLen:=0;
  end;
  // Free all RTTI dispatcher wrappers created during InitializeObject
  if assigned(Dispatchers) then begin
   for i:=0 to Dispatchers.Count-1 do begin
    TBESENRTTIDispatcher(Dispatchers[i]).Free;
   end;
   Dispatchers.Clear;
  end;
 end;
end;

procedure TBESENNativeObject.CopyPrototypeRTTI( var fromobjectprototype: TBESENObject);
var
//	methodlist: TBESENNativeFunctionObjects;
//	i: Integer;
	Prop:TBESENObjectProperty;
	tempfunction: TBESENObjectNativeFunction;
    NewNative: TBESENNativeFunction;
begin

	// iterate TBESENObjectNativeFunction on prototype and set TBESENObjectNativeFunction.Native to this instance.

	// OutputDebugStringW(pwidechar(wideformat('copying rtti method from prototype %s', [ fromobjectprototype.ClassName ])));

	Prop:= fromobjectprototype.Properties.First;

	while assigned(Prop) do begin

    	// OutputDebugStringW(pwidechar(wideformat('prototype %s property %s valuetype %s', [ fromobjectprototype.ClassName, prop.Key, besenvaluetypetostring(Prop.Descriptor.Value.ValueType) ])));

		if (boppVALUE in Prop.Descriptor.Presents) and (Prop.Descriptor.Value.ValueType=bvtOBJECT) and assigned(Prop.Descriptor.Value.Obj) then begin

         	// OutputDebugStringW(pwidechar(wideformat('prototype %s property %s class %s', [ fromobjectprototype.ClassName, prop.Key, TObject(Prop.Descriptor.Value.Obj).ClassName ])));

            // there should be no TBESENObjectDeclaredFunction here, or ignored.

         	if (TObject(Prop.Descriptor.Value.Obj) is TBESENObjectNativeFunction) then begin

	        	tempfunction:= TBESENObjectNativeFunction(Prop.Descriptor.Value.Obj);

	            NewNative:= tempfunction.Native;

	            // if address is on dispatcher, the dispatcher has to be copied.

	            // TMethod(newnative).code - this can stay same as methods don't really move.
	            TMethod(newnative).Data:= self; // this instance

	            // dispatchers are then reused from prototype too, it is assumed a prototype will not be freed before child instances.

	            // OutputDebugStringW(pwidechar(wideformat('copying rtti method %s ', [ Prop.Key ])));

	            RegisterNativeFunction(Prop.Key, newnative, 0,[],false);
	            // RegisterNativeFunction(RttiMethod.Name,NativeFunction,0,[],false);

            end else if (TObject(Prop.Descriptor.Value.Obj) is TBESENObjectDeclaredFunction) then begin

             	// ?

			end else begin

                // OutputDebugStringW(pwidechar(wideformat('what is class %s ', [ TObject(Prop.Descriptor.Value.Obj).ClassName ])));

				DebugBreak;

			end;
		end;

		Prop:=Prop.Next;
	end;

    // todo: copy PropListLen:=GetPropList(self,PropList); ?

end;

function TBESENNativeObject.GetProp(const Prop:TBESENObjectProperty;var V:TBESENValue;Throw:boolean):boolean;
var Item:PPropInfo;
    O:TObject;
    Index:integer;
begin
 result:=false;
 if not Initialized then begin
  exit;
 end;

 Index:=Prop.PropIndex;
 if (Index>=0) and (Index<PropListLen) then begin
  Item:=PropList^[Index];
 end else begin
  exit;
 end;

 if not assigned(Item^.GetProc) then begin
  if Throw then begin
{$ifdef BESENEmbarcaderoNextGen}
   BESENThrowNotReadable(PByteToString(@(Item^.Name)));
{$else}
   BESENThrowNotReadable(TBESENString(Item^.Name));
{$endif}
  end;
  exit;
 end;

 case Item^.PropType^.Kind of
  tkLString{$ifdef fpc},tkAString,tkSString{$endif}:begin
   V.ValueType:=bvtSTRING;
{$ifdef Delphi2009AndUp}
   V.Str:=GetStrProp(self,Item);
{$else}
   V.Str:=BESENConvertToUTF8(GetStrProp(self,Item));
{$endif}
  end;
  tkWString{$ifdef fpc},tkUString{$endif}{$ifdef BESENEmbarcaderoNextGen},tkUString{$endif}:begin
   V.ValueType:=bvtSTRING;
   V.Str:={$ifdef BESENEmbarcaderoNextGen}GetStrProp{$else}GetWideStrProp{$endif}(self,Item);
  end;
  tkBool:begin
   V.ValueType:=bvtBOOLEAN;
   V.Bool:=(GetOrdProp(self,Item) <> 0);
  end;
  tkEnumeration:begin
   V.ValueType:=bvtSTRING;
   V.Str:=GetEnumProp(self,Item);
  end;
  tkSet:begin
   V.ValueType:=bvtSTRING;
   V.Str:=GetSetProp(self,Item,false);
  end;
  tkInteger:begin
   V.ValueType:=bvtNUMBER;
   V.Num:=GetOrdProp(self,Item);
  end;
  tkChar:begin
   V.ValueType:=bvtSTRING;
   V.Str:=WideChar({$ifndef BESENEmbarcaderoNextGen}TBESENCHAR({$endif}byte(GetOrdProp(self,Item)){$ifndef BESENEmbarcaderoNextGen}){$endif});
  end;
  tkWChar:begin
   V.ValueType:=bvtSTRING;
   V.Str:=widechar(word(GetOrdProp(self,Item)));
  end;
  tkInt64{$ifdef fpc},tkQWORD{$endif}:begin
   V.ValueType:=bvtNUMBER;
   V.Num:=GetInt64Prop(self,Item);
  end;
  tkFloat:begin
   V.ValueType:=bvtNUMBER;
   V.Num:=GetFloatProp(self,Item);
  end;
  tkClass:begin
   O:=GetObjectProp(self,Item);
   if assigned(O) then begin
    if O is TBESENObject then begin
     V.ValueType:=bvtOBJECT;
     TBESENObject(v.Obj):=TBESENObject(o);
    end else begin
     V.ValueType:=bvtUNDEFINED;
    end;
   end else begin
    V.ValueType:=bvtNULL;
   end;
  end;
  tkVariant:begin
   BESENVariantToValue(GetVariantProp(self,Item),V);
  end;
  else begin
   if Throw then begin
    BESENThrowTypeError(self, 'Unknown native property data type');
   end;
   exit;
  end;
 end;

 result:=true;
end;

function TBESENNativeObject.PutProp(const Prop:TBESENObjectProperty;const V:TBESENValue;Throw:boolean):boolean;
var Item:PPropInfo;
    Index:integer;
	setting_value: TBESENString;
begin
 result:=false;
 if not Initialized then begin
  exit;
 end;

 Index:=Prop.PropIndex;
 if (Index>=0) and (Index<PropListLen) then begin
  Item:=PropList^[Index];
 end else begin
  exit;
 end;

 if not (assigned(Item^.SetProc) and ((boppWRITABLE in Prop.Descriptor.Presents) and (bopaWRITABLE in Prop.Descriptor.Attributes))) then begin
  if Throw then begin
{$ifdef BESENEmbarcaderoNextGen}
   BESENThrowNotWritable(PByteToString(@(Item^.Name)));
{$else}
   BESENThrowNotWritable(TBESENString(Item^.Name));
{$endif}
  end;
  exit;
 end;

 case Item^.PropType^.Kind of
  tkLString{$ifdef fpc},tkAString,tkSString{$endif}:begin
{$ifdef Delphi2009AndUp}
   SetStrProp(self,Item,TBESEN(Instance).ToStr(V));
{$else}
   SetStrProp(self,Item,BESENUTF16ToUTF8(TBESEN(Instance).ToStr(V)));
{$endif}
  end;
  tkWString{$ifdef fpc},tkUString{$endif}{$ifdef BESENEmbarcaderoNextGen},tkUString{$endif}:begin
   {$ifdef BESENEmbarcaderoNextGen}SetStrProp{$else}SetWideStrProp{$endif}(self,Item,TBESEN(Instance).ToStr(V));
  end;
  tkBool:begin
   SetOrdProp(self,Item,ord(TBESEN(Instance).ToBool(V)));
  end;
  tkEnumeration:begin

   setting_value:= TBESEN(Instance).ToStr(V);

   try

    SetEnumProp(self,Item,setting_value);

   except on e: exception do

    raise EBESENError.Create(wideformat('on class %s enum property value %s of type %s cannot be set to %s (  %s ). setenumprop error: %s - USE THE STRING VALUE AND NOT NUMERIC VALUE.', [ self.ClassName, Item^.Name,  Item^.PropType.Name, setting_value, GetEnumName(Item.PropType, Ord( TBESEN(Instance).ToInt(V) )), e.Message ] ));

   end;

  end;
  tkSet:begin
   SetSetProp(self,Item,TBESEN(Instance).ToStr(V));
  end;
  tkInteger:begin
   SetOrdProp(self,Item,TBESEN(Instance).ToInt32(V));
  end;
  tkChar:begin
   if (V.ValueType=bvtSTRING) and (length(V.Str)>0) then begin
    SetOrdProp(self,Item,byte(word(widechar(V.Str[1]))));
   end else begin
    SetOrdProp(self,Item,TBESEN(Instance).ToInt32(V));
   end;
  end;
  tkWChar:begin
   if (V.ValueType=bvtSTRING) and (length(V.Str)>0) then begin
    SetOrdProp(self,Item,word(widechar(V.Str[1])));
   end else begin
    SetOrdProp(self,Item,TBESEN(Instance).ToInt32(V));
   end;
  end;
  tkInt64{$ifdef fpc},tkQWORD{$endif}:begin
   SetInt64Prop(self,Item,TBESEN(Instance).ToInt(V));
  end;
  tkFloat:begin
   SetFloatProp(self,Item,TBESEN(Instance).ToNum(V));
  end;
  tkClass:begin
   SetObjectProp(self,Item,TBESEN(Instance).ToObj(V));
  end;
  tkVariant:begin
   SetVariantProp(self,Item,BESENValueToVariant(V));
  end;
  else begin
   if Throw then begin
    BESENThrowTypeError(self, 'Wrong native property data type');
   end;
   exit;
  end;
 end;

 result:=true;
end;

function TBESENNativeObject.GetOwnProperty(const P:TBESENString;var Descriptor:TBESENObjectPropertyDescriptor;Hash:TBESENHash=0):boolean;
begin
 LastProp:=Properties.Get(P,Hash);
 if assigned(LastProp) and (LastProp.PropIndex>=0) then begin
  if GetProp(LastProp,Descriptor.Value,true) then begin
   Descriptor.Getter:=LastProp.Descriptor.Getter;
   Descriptor.Setter:=LastProp.Descriptor.Setter;
   Descriptor.Attributes:=LastProp.Descriptor.Attributes;
   Descriptor.Presents:=LastProp.Descriptor.Presents;
   result:=true;
  end else begin
   result:=false;
  end;
 end else begin
  result:=inherited GetOwnProperty(P,Descriptor);
 end;
end;

function TBESENNativeObject.GetEx(const P:TBESENString;var AResult:TBESENValue;var Descriptor:TBESENObjectPropertyDescriptor;Base:TBESENObject=nil;Hash:TBESENHash=0):boolean;
begin
 if not assigned(Base) then begin
  Base:=self;
 end;
 LastProp:=Properties.Get(P,Hash);
 if assigned(LastProp) and (LastProp.PropIndex>=0) then begin
  result:=GetProp(LastProp,AResult,true);
 end else begin
  result:=inherited GetEx(P,AResult,Descriptor,Base,Hash);
 end;
end;

function TBESENNativeObject.GetIndex(const Index,ID:integer;var AResult:TBESENValue;Base:TBESENObject=nil):boolean;
begin
 if not assigned(Base) then begin
  Base:=self;
 end;
 if (((Index>=0) and (Index<Properties.ItemCount)) and (Properties.Items[Index].ID=ID)) and (Properties.Items[Index].PropIndex>=0) then begin
  result:=GetProp(Properties.Items[Index],AResult,true);
 end else begin
  result:=Get(TBESEN(Instance).KeyIDManager.List[ID],AResult,Base);
 end;
end;

procedure TBESENNativeObject.PutEx(const P:TBESENString;const V:TBESENValue;Throw:TBESENBoolean;var Descriptor,OwnDescriptor:TBESENObjectPropertyDescriptor;var TempValue:TBESENValue;Hash:TBESENHash=0);
begin
 LastProp:=Properties.Get(P,Hash);
 if assigned(LastProp) and (LastProp.PropIndex>=0) then begin
  PutProp(LastProp,V,Throw);
 end else begin
  inherited PutEx(P,V,Throw,Descriptor,OwnDescriptor,TempValue,Hash);
 end;
end;

procedure TBESENNativeObject.PutIndex(const Index,ID:integer;const V:TBESENValue;Throw:TBESENBoolean);
begin
 if (((Index>=0) and (Index<Properties.ItemCount)) and (Properties.Items[Index].ID=ID)) and (Properties.Items[Index].PropIndex>=0) then begin
  PutProp(Properties.Items[Index],V,Throw);
 end else begin
  Put(TBESEN(Instance).KeyIDManager.List[ID],V,Throw);
 end;
end;

function TBESENNativeObject.HasPropertyEx(const P:TBESENString;var Descriptor:TBESENObjectPropertyDescriptor;Hash:TBESENHash=0):TBESENBoolean;
begin
 LastProp:=Properties.Get(P,Hash);
 if assigned(LastProp) and (LastProp.PropIndex>=0) then begin
  result:=true;
 end else begin
  result:=inherited HasPropertyEx(P,Descriptor,Hash);
 end;
end;

function TBESENNativeObject.DeleteEx(const P:TBESENString;Throw:TBESENBoolean;var Descriptor:TBESENObjectPropertyDescriptor;Hash:TBESENHash=0):TBESENBoolean;

	procedure BESENThrowIt;
	begin
		BESENThrowTypeError(self, 'Delete for "'+P+'" failed');
	end;

begin
 LastProp:=Properties.Get(P,Hash);
 if assigned(LastProp) and (LastProp.PropIndex>=0) then begin
  result:=false;
  if Throw then begin
   BESENThrowIt;
  end;
 end else begin
  result:=DeleteEx(P,Throw,Descriptor,Hash);
 end;
end;

function TBESENNativeObject.DefineOwnPropertyEx(const P:TBESENString;const Descriptor:TBESENObjectPropertyDescriptor;Throw:TBESENBoolean;var Current:TBESENObjectPropertyDescriptor;Hash:TBESENHash=0):TBESENBoolean;
begin
 LastProp:=Properties.Get(P,Hash);
 if assigned(LastProp) and (LastProp.PropIndex>=0) then begin
  if (boppVALUE in Descriptor.Presents) and ((boppWRITABLE in Descriptor.Presents) and (bopaWRITABLE in Descriptor.Attributes)) then begin
   PutProp(LastProp,Descriptor.Value,Throw);
   result:=true;
  end else begin
   if Throw then begin
    BESENThrowDefineOwnProperty(P);
   end;
   result:=false;
  end;
 end else begin
  result:=inherited DefineOwnPropertyEx(P,Descriptor,Throw,Current,Hash);
 end;
end;

procedure TBESENNativeObject.Construct(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var AResult:TBESENValue);
begin
 AResult.ValueType:=bvtOBJECT;
 AResult.Obj:=TBESENNativeObjectClass(ClassType).Create(Instance,self,false);
 TBESEN(Instance).GarbageCollector.Add(TBESENObject(AResult.Obj));
 TBESENObject(AResult.Obj).GarbageCollectorLock;
 try
  TBESENNativeObject(AResult.Obj).ObjectClassName:=AResult.Obj.ClassName;
  TBESENNativeObject(AResult.Obj).InitializeObject;
  TBESENNativeObject(AResult.Obj).ConstructObject(ThisArgument,Arguments,CountArguments);
 finally
  TBESENObject(AResult.Obj).GarbageCollectorUnlock;
 end;
end;

procedure TBESENNativeObject.Call(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var AResult:TBESENValue);
begin
 BESENThrowTypeError(self, 'Not a function');
end;

function TBESENNativeObject.HasConstruct:TBESENBoolean;
begin
 result:=true;
end;

function TBESENNativeObject.HasCall:TBESENBoolean;
begin
 result:=false;
end;

procedure TBESENNativeObject.Finalize;
var i:integer;
    o:TObject;
    Item:PPropInfo;
begin
 if assigned(PropList) then begin
  for i:=0 to PropListLen-1 do begin
   Item:=PropList^[i];
   if assigned(Item^.PropType) then begin
    case Item^.PropType^.Kind of
     tkCLASS:begin
      if assigned(Item^.SetProc) then begin
       o:=GetObjectProp(self,Item);
       if o is TBESENGarbageCollectorObject then begin
        SetObjectProp(self,Item,nil);
       end;
      end;
     end;
    end;
   end;
  end;
 end;
 inherited Finalize;
end;

procedure TBESENNativeObject.Mark;
var i:integer;
    o:TObject;
begin
 if assigned(PropList) then begin
  for i:=0 to PropListLen-1 do begin
   if assigned(PropList^[i].PropType) then begin
    case PropList^[i].PropType^.Kind of
     tkCLASS:begin
      o:=GetObjectProp(self,PropList^[i]);
      if o is TBESENGarbageCollectorObject then begin
       TBESEN(Instance).GarbageCollector.GrayIt(TBESENObject(o));
      end;
     end;
    end;
   end;
  end;
 end;
 inherited Mark;
end;

end.


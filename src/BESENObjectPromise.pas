unit BESENObjectPromise;
{$i BESEN.inc}

// author: gpt 5.5

interface

uses
	SysUtils, Classes,
	BESENConstants, BESENTypes, BESENValue, BESENObject,
	BESENObjectFunction, BESENObjectPropertyDescriptor;

type
	TBESENPromiseState = (bpsPending, bpsFulfilled, bpsRejected);
	TBESENPromiseReactionType = (bprtFulfill, bprtReject);
	TBESENPromiseResolveKind = (bprkResolve, bprkReject);

	TBESENObjectPromise = class;
	TBESENObjectPromiseConstructor = class;

	TBESENPromiseCapability = class
	public
		Instance: TObject;
		Promise: TBESENValue;
		Resolve: TBESENValue;
		Reject: TBESENValue;
		RefCount: integer;
		constructor Create(AInstance: TObject; const APromise, AResolve, AReject: TBESENValue);
		destructor Destroy; override;
		procedure AddRef;
		procedure Release;
	end;

	TBESENPromiseReaction = class
	public
		Instance: TObject;
		ReactionType: TBESENPromiseReactionType;
		Handler: TBESENValue;
		Capability: TBESENPromiseCapability;
		constructor Create(AInstance: TObject; AReactionType: TBESENPromiseReactionType; const AHandler: TBESENValue; ACapability: TBESENPromiseCapability);
		destructor Destroy; override;
	end;

	TBESENPromiseJob = class
	public
		Instance: TObject;
		constructor Create(AInstance: TObject); virtual;
		procedure Execute; virtual; abstract;
	end;

	TBESENPromiseReactionJob = class(TBESENPromiseJob)
	public
		Reaction: TBESENPromiseReaction;
		Argument: TBESENValue;
		constructor Create(AInstance: TObject; AReaction: TBESENPromiseReaction; const AArgument: TBESENValue);
		destructor Destroy; override;
		procedure Execute; override;
	end;

	TBESENPromiseResolveThenableJob = class(TBESENPromiseJob)
	public
		Promise: TBESENObjectPromise;
		Thenable: TBESENValue;
		ThenAction: TBESENValue;
		constructor Create(AInstance: TObject; APromise: TBESENObjectPromise; const AThenable, AThenAction: TBESENValue);
		destructor Destroy; override;
		procedure Execute; override;
	end;

	TBESENPromiseResolvingState = class
	public
		AlreadyResolved: TBESENBoolean;
		RefCount: integer;
		constructor Create;
		procedure AddRef;
		procedure Release;
	end;

	TBESENObjectPromiseResolvingFunction = class(TBESENObjectFunction)
	public
		Promise: TBESENObjectPromise;
		Kind: TBESENPromiseResolveKind;
		State: TBESENPromiseResolvingState;
		constructor Create(AInstance: TObject; APromise: TBESENObjectPromise; AKind: TBESENPromiseResolveKind; AState: TBESENPromiseResolvingState); reintroduce;
		destructor Destroy; override;
		procedure Call(const ThisArgument: TBESENValue; Arguments: PPBESENValues; CountArguments: integer; var AResult: TBESENValue); override;
		function HasCall: TBESENBoolean; override;
		procedure Mark; override;
	end;

	TBESENObjectPromise = class(TBESENObject)
	public
		State: TBESENPromiseState;
		ResultValue: TBESENValue;
		FulfillReactions: TList;
		RejectReactions: TList;
		constructor Create(AInstance: TObject; APrototype: TBESENObject = nil; AHasPrototypeProperty: longbool = False); overload; override;
		destructor Destroy; override;
		procedure Resolve(const Resolution: TBESENValue);
		procedure Fulfill(const Value: TBESENValue);
		procedure Reject(const Reason: TBESENValue);
		procedure AddReaction(Reaction: TBESENPromiseReaction);
		procedure ClearReactions(Reactions: TList);
		procedure TriggerReactions(Reactions: TList; const Argument: TBESENValue);
		function GetPromiseConstructor: TBESENObjectPromiseConstructor;
		procedure Mark; override;
	end;

	TBESENObjectPromisePrototype = class(TBESENObject)
	public
		constructor Create(AInstance: TObject; APrototype: TBESENObject = nil; AHasPrototypeProperty: longbool = False); overload; override;
		procedure NativeThen(const ThisArgument: TBESENValue; Arguments: PPBESENValues; CountArguments: integer; var ResultValue: TBESENValue);
		procedure NativeCatch(const ThisArgument: TBESENValue; Arguments: PPBESENValues; CountArguments: integer; var ResultValue: TBESENValue);
	end;

	TBESENObjectPromiseConstructor = class(TBESENObjectFunction)
	public
		Jobs: TList;
		constructor Create(AInstance: TObject; APrototype: TBESENObject = nil; AHasPrototypeProperty: longbool = False); overload; override;
		destructor Destroy; override;
		procedure Construct(const ThisArgument: TBESENValue; Arguments: PPBESENValues; CountArguments: integer; var AResult: TBESENValue); override;
		procedure Call(const ThisArgument: TBESENValue; Arguments: PPBESENValues; CountArguments: integer; var AResult: TBESENValue); override;
		function HasConstruct: TBESENBoolean; override;
		function HasCall: TBESENBoolean; override;
		function NewPromiseCapability: TBESENPromiseCapability;
		function PromiseResolve(const Value: TBESENValue): TBESENValue;
		procedure EnqueueJob(Job: TBESENPromiseJob);
		procedure RunJobs;
		procedure NativeResolve(const ThisArgument: TBESENValue; Arguments: PPBESENValues; CountArguments: integer; var ResultValue: TBESENValue);
		procedure NativeReject(const ThisArgument: TBESENValue; Arguments: PPBESENValues; CountArguments: integer; var ResultValue: TBESENValue);
	end;

implementation

uses
	BESEN, BESENErrors, BESENObjectNativeFunction;

constructor TBESENPromiseCapability.Create(AInstance: TObject; const APromise, AResolve, AReject: TBESENValue);
begin
	inherited Create;
	Instance := AInstance;
	Promise := APromise;
	Resolve := AResolve;
	Reject := AReject;
	RefCount := 1;
	TBESEN(Instance).GarbageCollector.LockValue(Promise);
	TBESEN(Instance).GarbageCollector.LockValue(Resolve);
	TBESEN(Instance).GarbageCollector.LockValue(Reject);
end;

destructor TBESENPromiseCapability.Destroy;
begin
	TBESEN(Instance).GarbageCollector.UnlockValue(Reject);
	TBESEN(Instance).GarbageCollector.UnlockValue(Resolve);
	TBESEN(Instance).GarbageCollector.UnlockValue(Promise);
	inherited Destroy;
end;

procedure TBESENPromiseCapability.AddRef;
begin
	Inc(RefCount);
end;

procedure TBESENPromiseCapability.Release;
begin
	Dec(RefCount);
	if RefCount <= 0 then begin
		Free;
	 end;
end;

constructor TBESENPromiseReaction.Create(AInstance: TObject; AReactionType: TBESENPromiseReactionType; const AHandler: TBESENValue; ACapability: TBESENPromiseCapability);
begin
	inherited Create;
	Instance := AInstance;
	ReactionType := AReactionType;
	Handler := AHandler;
	Capability := ACapability;
	Capability.AddRef;
	TBESEN(Instance).GarbageCollector.LockValue(Handler);
end;

destructor TBESENPromiseReaction.Destroy;
begin
	TBESEN(Instance).GarbageCollector.UnlockValue(Handler);
	Capability.Release;
	inherited Destroy;
end;

constructor TBESENPromiseJob.Create(AInstance: TObject);
begin
	inherited Create;
	Instance := AInstance;
end;

constructor TBESENPromiseReactionJob.Create(AInstance: TObject; AReaction: TBESENPromiseReaction; const AArgument: TBESENValue);
begin
	inherited Create(AInstance);
	Reaction := AReaction;
	Argument := AArgument;
	TBESEN(Instance).GarbageCollector.LockValue(Argument);
end;

destructor TBESENPromiseReactionJob.Destroy;
begin
	TBESEN(Instance).GarbageCollector.UnlockValue(Argument);
	Reaction.Free;
	inherited Destroy;
end;

procedure TBESENPromiseReactionJob.Execute;
var
	HandlerResult, Temp: TBESENValue;
	Args: array[0..0] of TBESENValue;
	ArgPtrs: array[0..0] of PBESENValue;
begin
	HandlerResult := BESENUndefinedValue;

	 try
		if BESENIsCallable(Reaction.Handler) then begin
			Args[0] := Argument;
			ArgPtrs[0] := @Args[0];

			TBESEN(Instance).ObjectCall(
				TBESENObject(Reaction.Handler.Obj),
				BESENUndefinedValue,
				@ArgPtrs,
				1,
				HandlerResult
				);

			Args[0] := HandlerResult;
			ArgPtrs[0] := @Args[0];

			TBESEN(Instance).ObjectCall(
				TBESENObject(Reaction.Capability.Resolve.Obj),
				BESENUndefinedValue,
				@ArgPtrs,
				1,
				Temp
				);
		 end else if Reaction.ReactionType = bprtFulfill then begin
			Args[0] := Argument;
			ArgPtrs[0] := @Args[0];

			TBESEN(Instance).ObjectCall(
				TBESENObject(Reaction.Capability.Resolve.Obj),
				BESENUndefinedValue,
				@ArgPtrs,
				1,
				Temp
				);
		 end else begin
			Args[0] := Argument;
			ArgPtrs[0] := @Args[0];

			TBESEN(Instance).ObjectCall(
				TBESENObject(Reaction.Capability.Reject.Obj),
				BESENUndefinedValue,
				@ArgPtrs,
				1,
				Temp
				);
		 end;
	 except
		on E: EBESENThrowException do begin
			Args[0] := E.Value;
			ArgPtrs[0] := @Args[0];
			TBESEN(Instance).ObjectCall(TBESENObject(Reaction.Capability.Reject.Obj), BESENUndefinedValue, @ArgPtrs, 1, Temp);
		 end;
		on E: EBESENError do begin
			Args[0] := BESENStringValue(E.OriginalMessage);
			ArgPtrs[0] := @Args[0];
			TBESEN(Instance).ObjectCall(TBESENObject(Reaction.Capability.Reject.Obj), BESENUndefinedValue, @ArgPtrs, 1, Temp);
		 end;
	 end;
end;

constructor TBESENPromiseResolveThenableJob.Create(AInstance: TObject; APromise: TBESENObjectPromise; const AThenable, AThenAction: TBESENValue);
begin
	inherited Create(AInstance);
	Promise := APromise;
	Thenable := AThenable;
	ThenAction := AThenAction;
	Promise.GarbageCollectorLock;
	TBESEN(Instance).GarbageCollector.LockValue(Thenable);
	TBESEN(Instance).GarbageCollector.LockValue(ThenAction);
end;

destructor TBESENPromiseResolveThenableJob.Destroy;
begin
	TBESEN(Instance).GarbageCollector.UnlockValue(ThenAction);
	TBESEN(Instance).GarbageCollector.UnlockValue(Thenable);
	Promise.GarbageCollectorUnlock;
	inherited Destroy;
end;

procedure TBESENPromiseResolveThenableJob.Execute;
var
	ResolvingState: TBESENPromiseResolvingState;
	ResolveFunction, RejectFunction: TBESENObjectPromiseResolvingFunction;
	ResolveValue, RejectValue, Temp: TBESENValue;
	Args: array[0..1] of TBESENValue;
	ArgPtrs: array[0..1] of PBESENValue;
begin
	ResolvingState := TBESENPromiseResolvingState.Create;
	ResolveFunction := TBESENObjectPromiseResolvingFunction.Create(Instance, Promise, bprkResolve, ResolvingState);
	RejectFunction := TBESENObjectPromiseResolvingFunction.Create(Instance, Promise, bprkReject, ResolvingState);
	TBESEN(Instance).GarbageCollector.Add(ResolveFunction);
	TBESEN(Instance).GarbageCollector.Add(RejectFunction);

	ResolveValue := BESENObjectValue(ResolveFunction);
	RejectValue := BESENObjectValue(RejectFunction);

	Args[0] := ResolveValue;
	Args[1] := RejectValue;
	ArgPtrs[0] := @Args[0];
	ArgPtrs[1] := @Args[1];

	 try
		TBESEN(Instance).ObjectCall(TBESENObject(ThenAction.Obj), Thenable, @ArgPtrs, 2, Temp);
	 except
		on E: EBESENThrowException do begin
			if not ResolvingState.AlreadyResolved then begin
				ResolvingState.AlreadyResolved := True;
				Promise.Reject(E.Value);
			 end;
		 end;
		on E: EBESENError do begin
			if not ResolvingState.AlreadyResolved then begin
				ResolvingState.AlreadyResolved := True;
				Promise.Reject(BESENStringValue(E.OriginalMessage));
			 end;
		 end;
	 end;

	ResolvingState.Release;
end;

constructor TBESENPromiseResolvingState.Create;
begin
	inherited Create;
	AlreadyResolved := False;
	RefCount := 1;
end;

procedure TBESENPromiseResolvingState.AddRef;
begin
	Inc(RefCount);
end;

procedure TBESENPromiseResolvingState.Release;
begin
	Dec(RefCount);
	if RefCount <= 0 then begin
		Free;
	 end;
end;

constructor TBESENObjectPromiseResolvingFunction.Create(AInstance: TObject; APromise: TBESENObjectPromise; AKind: TBESENPromiseResolveKind; AState: TBESENPromiseResolvingState);
begin
	inherited Create(AInstance, TBESEN(AInstance).ObjectFunctionPrototype, False);
	ObjectClassName := 'Function';
	ObjectName := 'Promise resolving function';
	Promise := APromise;
	Kind := AKind;
	State := AState;
	State.AddRef;
end;

destructor TBESENObjectPromiseResolvingFunction.Destroy;
begin
	State.Release;
	inherited Destroy;
end;

procedure TBESENObjectPromiseResolvingFunction.Call(const ThisArgument: TBESENValue; Arguments: PPBESENValues; CountArguments: integer; var AResult: TBESENValue);
var
	V: TBESENValue;
begin
	AResult := BESENUndefinedValue;

	if State.AlreadyResolved then begin
		exit;
	 end;

	State.AlreadyResolved := True;

	if CountArguments > 0 then begin
		V := Arguments^[0]^;
	 end else begin
		V := BESENUndefinedValue;
	 end;

	if Kind = bprkResolve then begin
		Promise.Resolve(V);
	 end else begin
		Promise.Reject(V);
	 end;
end;

function TBESENObjectPromiseResolvingFunction.HasCall: TBESENBoolean;
begin
	Result := True;
end;

procedure TBESENObjectPromiseResolvingFunction.Mark;
begin
	TBESEN(Instance).GarbageCollector.GrayIt(Promise);
	inherited Mark;
end;

constructor TBESENObjectPromise.Create(AInstance: TObject; APrototype: TBESENObject; AHasPrototypeProperty: longbool);
begin
	inherited Create(AInstance, APrototype, AHasPrototypeProperty);
	ObjectClassName := 'Promise';
	ObjectName := 'Promise';
	State := bpsPending;
	ResultValue := BESENUndefinedValue;
	FulfillReactions := TList.Create;
	RejectReactions := TList.Create;
end;

destructor TBESENObjectPromise.Destroy;
begin
	ClearReactions(FulfillReactions);
	ClearReactions(RejectReactions);
	FulfillReactions.Free;
	RejectReactions.Free;
	inherited Destroy;
end;

function TBESENObjectPromise.GetPromiseConstructor: TBESENObjectPromiseConstructor;
var
	V: TBESENValue;
begin
	Result := nil;
	if TBESEN(Instance).ObjectGlobal.Get('Promise', V) and
		(V.ValueType = bvtOBJECT) and
		assigned(V.Obj) and
		(TObject(V.Obj) is TBESENObjectPromiseConstructor) then begin
		Result := TBESENObjectPromiseConstructor(V.Obj);
	 end;
end;

procedure TBESENObjectPromise.Resolve(const Resolution: TBESENValue);
var
	ThenValue: TBESENValue;
	ConstructorObject: TBESENObjectPromiseConstructor;
begin
	if State <> bpsPending then begin
		exit;
	 end;

	if (Resolution.ValueType = bvtOBJECT) and (Resolution.Obj = Self) then begin
		Reject(BESENStringValue('A promise cannot be resolved with itself'));
		exit;
	 end;

	if (Resolution.ValueType = bvtOBJECT) and assigned(Resolution.Obj) then begin
		TBESENObject(Resolution.Obj).Get('then', ThenValue);
		if BESENIsCallable(ThenValue) then begin
			ConstructorObject := GetPromiseConstructor;
			if assigned(ConstructorObject) then begin
				ConstructorObject.EnqueueJob(TBESENPromiseResolveThenableJob.Create(Instance, Self, Resolution, ThenValue));
				exit;
			 end;
		 end;
	 end;

	Fulfill(Resolution);
end;

procedure TBESENObjectPromise.Fulfill(const Value: TBESENValue);
begin
	if State <> bpsPending then begin
		exit;
	 end;

	State := bpsFulfilled;
	BESENCopyValue(ResultValue, Value);

	TriggerReactions(FulfillReactions, ResultValue);
	ClearReactions(RejectReactions);
end;

procedure TBESENObjectPromise.Reject(const Reason: TBESENValue);
begin
	if State <> bpsPending then begin
		exit;
	 end;

	State := bpsRejected;
	BESENCopyValue(ResultValue, Reason);

	TriggerReactions(RejectReactions, ResultValue);
	ClearReactions(FulfillReactions);
end;

procedure TBESENObjectPromise.AddReaction(Reaction: TBESENPromiseReaction);
var
	ConstructorObject: TBESENObjectPromiseConstructor;
begin
	if State = bpsPending then begin
		if Reaction.ReactionType = bprtFulfill then begin
			FulfillReactions.Add(Reaction);
		 end else begin
			RejectReactions.Add(Reaction);
		 end;
	 end else begin
		ConstructorObject := GetPromiseConstructor;
		if assigned(ConstructorObject) then begin
			ConstructorObject.EnqueueJob(TBESENPromiseReactionJob.Create(Instance, Reaction, ResultValue));
		 end else begin
			Reaction.Free;
		 end;
	 end;
end;

procedure TBESENObjectPromise.ClearReactions(Reactions: TList);
begin
	while Reactions.Count > 0 do begin
		TObject(Reactions[0]).Free;
		Reactions.Delete(0);
	 end;
end;

procedure TBESENObjectPromise.TriggerReactions(Reactions: TList; const Argument: TBESENValue);
var
	ConstructorObject: TBESENObjectPromiseConstructor;
	Reaction: TBESENPromiseReaction;
begin
	ConstructorObject := GetPromiseConstructor;

	while Reactions.Count > 0 do begin
		Reaction := TBESENPromiseReaction(Reactions[0]);
		Reactions.Delete(0);

		if assigned(ConstructorObject) then begin
			ConstructorObject.EnqueueJob(TBESENPromiseReactionJob.Create(Instance, Reaction, Argument));
		 end else begin
			Reaction.Free;
		 end;
	 end;
end;

procedure TBESENObjectPromise.Mark;
var
	I: integer;
	Reaction: TBESENPromiseReaction;
begin
	TBESEN(Instance).GarbageCollector.GrayValue(ResultValue);

	for I := 0 to FulfillReactions.Count - 1 do begin
		Reaction := TBESENPromiseReaction(FulfillReactions[I]);
		TBESEN(Instance).GarbageCollector.GrayValue(Reaction.Handler);
		TBESEN(Instance).GarbageCollector.GrayValue(Reaction.Capability.Promise);
		TBESEN(Instance).GarbageCollector.GrayValue(Reaction.Capability.Resolve);
		TBESEN(Instance).GarbageCollector.GrayValue(Reaction.Capability.Reject);
	 end;

	for I := 0 to RejectReactions.Count - 1 do begin
		Reaction := TBESENPromiseReaction(RejectReactions[I]);
		TBESEN(Instance).GarbageCollector.GrayValue(Reaction.Handler);
		TBESEN(Instance).GarbageCollector.GrayValue(Reaction.Capability.Promise);
		TBESEN(Instance).GarbageCollector.GrayValue(Reaction.Capability.Resolve);
		TBESEN(Instance).GarbageCollector.GrayValue(Reaction.Capability.Reject);
	 end;

	inherited Mark;
end;

constructor TBESENObjectPromisePrototype.Create(AInstance: TObject; APrototype: TBESENObject; AHasPrototypeProperty: longbool);
begin
	inherited Create(AInstance, APrototype, AHasPrototypeProperty);
	ObjectClassName := 'Promise';

	RegisterNativeFunction('then', NativeThen, 2, [bopaWRITABLE, bopaCONFIGURABLE], False);
	RegisterNativeFunction('catch', NativeCatch, 1, [bopaWRITABLE, bopaCONFIGURABLE], False);
end;

procedure TBESENObjectPromisePrototype.NativeThen(const ThisArgument: TBESENValue; Arguments: PPBESENValues; CountArguments: integer; var ResultValue: TBESENValue);
var
	Promise: TBESENObjectPromise;
	ConstructorObject: TBESENObjectPromiseConstructor;
	Capability: TBESENPromiseCapability;
	OnFulfilled, OnRejected: TBESENValue;
begin
	if not ((ThisArgument.ValueType = bvtOBJECT) and assigned(ThisArgument.Obj) and (TObject(ThisArgument.Obj) is TBESENObjectPromise)) then begin
		raise EBESENTypeError.Create('Promise.prototype.then called on non-Promise');
	 end;

	Promise := TBESENObjectPromise(ThisArgument.Obj);
	ConstructorObject := Promise.GetPromiseConstructor;
	if not assigned(ConstructorObject) then begin
		raise EBESENTypeError.Create('Promise constructor unavailable');
	 end;

	if (CountArguments > 0) and BESENIsCallable(Arguments^[0]^) then begin
		OnFulfilled := Arguments^[0]^;
	 end else begin
		OnFulfilled := BESENUndefinedValue;
	 end;

	if (CountArguments > 1) and BESENIsCallable(Arguments^[1]^) then begin
		OnRejected := Arguments^[1]^;
	 end else begin
		OnRejected := BESENUndefinedValue;
	 end;

	Capability := ConstructorObject.NewPromiseCapability;
	 try
		ResultValue := Capability.Promise;

		Promise.AddReaction(TBESENPromiseReaction.Create(Instance, bprtFulfill, OnFulfilled, Capability));
		Promise.AddReaction(TBESENPromiseReaction.Create(Instance, bprtReject, OnRejected, Capability));
	 finally
		Capability.Release;
	 end;
end;

procedure TBESENObjectPromisePrototype.NativeCatch(const ThisArgument: TBESENValue; Arguments: PPBESENValues; CountArguments: integer; var ResultValue: TBESENValue);
var
	ThenValue: TBESENValue;
	Args: array[0..1] of TBESENValue;
	ArgPtrs: array[0..1] of PBESENValue;
begin
	if not ((ThisArgument.ValueType = bvtOBJECT) and assigned(ThisArgument.Obj)) then begin
		raise EBESENTypeError.Create('Promise.prototype.catch called on non-object');
	 end;

	TBESENObject(ThisArgument.Obj).Get('then', ThenValue);
	if not BESENIsCallable(ThenValue) then begin
		raise EBESENTypeError.Create('Promise then is not callable');
	 end;

	Args[0] := BESENUndefinedValue;

	if CountArguments > 0 then begin
		Args[1] := Arguments^[0]^;
	 end else begin
		Args[1] := BESENUndefinedValue;
	 end;

	ArgPtrs[0] := @Args[0];
	ArgPtrs[1] := @Args[1];

	TBESEN(Instance).ObjectCall(TBESENObject(ThenValue.Obj), ThisArgument, @ArgPtrs, 2, ResultValue);
end;

constructor TBESENObjectPromiseConstructor.Create(AInstance: TObject; APrototype: TBESENObject; AHasPrototypeProperty: longbool);
begin
	inherited Create(AInstance, APrototype, AHasPrototypeProperty);
	ObjectClassName := 'Function';
	ObjectName := 'Promise';

	Jobs := TList.Create;

	RegisterNativeFunction('resolve', NativeResolve, 1, [bopaWRITABLE, bopaCONFIGURABLE], False);
	RegisterNativeFunction('reject', NativeReject, 1, [bopaWRITABLE, bopaCONFIGURABLE], False);
end;

destructor TBESENObjectPromiseConstructor.Destroy;
var
	I: integer;
begin
	for I := 0 to Jobs.Count - 1 do begin
		TObject(Jobs[I]).Free;
	 end;
	Jobs.Free;
	inherited Destroy;
end;

procedure TBESENObjectPromiseConstructor.Construct(const ThisArgument: TBESENValue; Arguments: PPBESENValues; CountArguments: integer; var AResult: TBESENValue);
var
	Executor: TBESENValue;
	Promise: TBESENObjectPromise;
	ResolvingState: TBESENPromiseResolvingState;
	ResolveFunction, RejectFunction: TBESENObjectPromiseResolvingFunction;
	ResolveValue, RejectValue, Temp: TBESENValue;
	Args: array[0..1] of TBESENValue;
	ArgPtrs: array[0..1] of PBESENValue;
	ProtoValue: TBESENValue;
	ProtoObject: TBESENObject;
begin
	if (CountArguments = 0) or not BESENIsCallable(Arguments^[0]^) then begin
		raise EBESENTypeError.Create('Promise resolver is not callable');
	 end;

	Executor := Arguments^[0]^;

	Get('prototype', ProtoValue);
	if ProtoValue.ValueType = bvtOBJECT then begin
		ProtoObject := TBESENObject(ProtoValue.Obj);
	 end else begin
		ProtoObject := TBESEN(Instance).ObjectPrototype;
	 end;

	Promise := TBESENObjectPromise.Create(Instance, ProtoObject, False);
	TBESEN(Instance).GarbageCollector.Add(Promise);

	ResolvingState := TBESENPromiseResolvingState.Create;
	ResolveFunction := TBESENObjectPromiseResolvingFunction.Create(Instance, Promise, bprkResolve, ResolvingState);
	RejectFunction := TBESENObjectPromiseResolvingFunction.Create(Instance, Promise, bprkReject, ResolvingState);
	TBESEN(Instance).GarbageCollector.Add(ResolveFunction);
	TBESEN(Instance).GarbageCollector.Add(RejectFunction);

	ResolveValue := BESENObjectValue(ResolveFunction);
	RejectValue := BESENObjectValue(RejectFunction);

	Args[0] := ResolveValue;
	Args[1] := RejectValue;
	ArgPtrs[0] := @Args[0];
	ArgPtrs[1] := @Args[1];

	 try
		TBESEN(Instance).ObjectCall(TBESENObject(Executor.Obj), BESENUndefinedValue, @ArgPtrs, 2, Temp);
	 except
		on E: EBESENThrowException do begin
			if not ResolvingState.AlreadyResolved then begin
				ResolvingState.AlreadyResolved := True;
				Promise.Reject(E.Value);
			 end;
		 end;
		on E: EBESENError do begin
			if not ResolvingState.AlreadyResolved then begin
				ResolvingState.AlreadyResolved := True;
				Promise.Reject(BESENStringValue(E.OriginalMessage));
			 end;
		 end;
	 end;

	ResolvingState.Release;

	AResult := BESENObjectValue(Promise);
end;

procedure TBESENObjectPromiseConstructor.Call(const ThisArgument: TBESENValue; Arguments: PPBESENValues; CountArguments: integer; var AResult: TBESENValue);
begin
	raise EBESENTypeError.Create('Promise constructor cannot be called without new');
end;

function TBESENObjectPromiseConstructor.HasConstruct: TBESENBoolean;
begin
	Result := True;
end;

function TBESENObjectPromiseConstructor.HasCall: TBESENBoolean;
begin
	Result := True;
end;

function TBESENObjectPromiseConstructor.NewPromiseCapability: TBESENPromiseCapability;
var
	Promise: TBESENObjectPromise;
	ResolvingState: TBESENPromiseResolvingState;
	ResolveFunction, RejectFunction: TBESENObjectPromiseResolvingFunction;
	ProtoValue: TBESENValue;
	ProtoObject: TBESENObject;
begin
	Get('prototype', ProtoValue);
	if ProtoValue.ValueType = bvtOBJECT then begin
		ProtoObject := TBESENObject(ProtoValue.Obj);
	 end else begin
		ProtoObject := TBESEN(Instance).ObjectPrototype;
	 end;

	Promise := TBESENObjectPromise.Create(Instance, ProtoObject, False);
	TBESEN(Instance).GarbageCollector.Add(Promise);

	ResolvingState := TBESENPromiseResolvingState.Create;
	ResolveFunction := TBESENObjectPromiseResolvingFunction.Create(Instance, Promise, bprkResolve, ResolvingState);
	RejectFunction := TBESENObjectPromiseResolvingFunction.Create(Instance, Promise, bprkReject, ResolvingState);
	TBESEN(Instance).GarbageCollector.Add(ResolveFunction);
	TBESEN(Instance).GarbageCollector.Add(RejectFunction);
	ResolvingState.Release;

	Result := TBESENPromiseCapability.Create(
		Instance,
		BESENObjectValue(Promise),
		BESENObjectValue(ResolveFunction),
		BESENObjectValue(RejectFunction)
		);
end;

function TBESENObjectPromiseConstructor.PromiseResolve(const Value: TBESENValue): TBESENValue;
var
	Capability: TBESENPromiseCapability;
	Args: array[0..0] of TBESENValue;
	ArgPtrs: array[0..0] of PBESENValue;
	Temp: TBESENValue;
begin
	if (Value.ValueType = bvtOBJECT) and assigned(Value.Obj) and (TObject(Value.Obj) is TBESENObjectPromise) then begin
		Result := Value;
		exit;
	 end;

	Capability := NewPromiseCapability;
	 try
		Args[0] := Value;
		ArgPtrs[0] := @Args[0];
		TBESEN(Instance).ObjectCall(TBESENObject(Capability.Resolve.Obj), BESENUndefinedValue, @ArgPtrs, 1, Temp);
		Result := Capability.Promise;
	 finally
		Capability.Release;
	 end;
end;

procedure TBESENObjectPromiseConstructor.EnqueueJob(Job: TBESENPromiseJob);
begin
	Jobs.Add(Job);
end;

procedure TBESENObjectPromiseConstructor.RunJobs;
var
	Job: TBESENPromiseJob;
begin
	while Jobs.Count > 0 do begin
		Job := TBESENPromiseJob(Jobs[0]);
		Jobs.Delete(0);
		 try
			Job.Execute;
		 finally
			Job.Free;
		 end;
	 end;
end;

procedure TBESENObjectPromiseConstructor.NativeResolve(const ThisArgument: TBESENValue; Arguments: PPBESENValues; CountArguments: integer; var ResultValue: TBESENValue);
begin
	if CountArguments > 0 then begin
		ResultValue := PromiseResolve(Arguments^[0]^);
	 end else begin
		ResultValue := PromiseResolve(BESENUndefinedValue);
	 end;
end;

procedure TBESENObjectPromiseConstructor.NativeReject(const ThisArgument: TBESENValue; Arguments: PPBESENValues; CountArguments: integer; var ResultValue: TBESENValue);
var
	Capability: TBESENPromiseCapability;
	Args: array[0..0] of TBESENValue;
	ArgPtrs: array[0..0] of PBESENValue;
	Temp: TBESENValue;
begin
	Capability := NewPromiseCapability;
	 try
		if CountArguments > 0 then begin
			Args[0] := Arguments^[0]^;
		 end else begin
			Args[0] := BESENUndefinedValue;
		 end;

		ArgPtrs[0] := @Args[0];
		TBESEN(Instance).ObjectCall(TBESENObject(Capability.Reject.Obj), BESENUndefinedValue, @ArgPtrs, 1, Temp);
		ResultValue := Capability.Promise;
	 finally
		Capability.Release;
	 end;
end;

end.

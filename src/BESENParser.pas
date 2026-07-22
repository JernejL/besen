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
unit BESENParser;
{$i BESEN.inc}

interface

uses
	BESENConstants, BESENTypes, BESENValue, BESENBaseObject, BESENCollectorObject, BESENObjectPropertyDescriptor, BESENLexicalEnvironment, BESENASTNodes, BESENEnvironmentRecord, BESENStringTree, BESENPointerList, BESENLexer;

type TBESENParserLabelSet = class(TBESENCollectorObject)
	public
		Next: TBESENParserLabelSet;
		Target: TBESENTarget;
		Continuable: longbool;
		Index: integer;
		constructor Create(AInstance: TObject); overload; override;
		destructor Destroy; override;
	end;

	TBESENParserLabel = class(TBESENCollectorObject)
	public
		Next: TBESENParserLabel;
		Name: TBESENString;
		LabelSet: TBESENParserLabelSet;
		Node: TBESENASTNode;
		LineNumber: integer; // why is this here?
		Columnnumber: integer;
		Index: integer;
		constructor Create(AInstance: TObject); overload; override;
		destructor Destroy; override;
	end;

	TBESENParser = class(TBESENBaseObject)
	public
		Lexer: TBESENLexer;
		WarningProc: TBESENWarningProc;
		constructor Create(AInstance: TObject); overload; override;
		destructor Destroy; override;
		procedure Init;
		function Parse(IsFunction, IsJSON: boolean): TBESENASTNode; // todo: add input filename
	end;

implementation

uses typinfo,{$ifdef BESENEmbarcaderoNextGen}System.Character,{$endif}BESEN, BESENUtils, BESENStringUtils, BESENErrors, SysUtils;

constructor TBESENParserLabelSet.Create(AInstance: TObject);
begin
	inherited Create(AInstance);
	Next := nil;
	Target := -1;
	Continuable := False;
	Index := -1;
end;

destructor TBESENParserLabelSet.Destroy;
begin
	Next := nil;
	inherited Destroy;
end;

constructor TBESENParserLabel.Create(AInstance: TObject);
begin
	inherited Create(AInstance);
	Next := nil;
	Name := '';
	LabelSet := nil;
	Node := nil;
	LineNumber := 0;
	Index := -1;
end;

destructor TBESENParserLabel.Destroy;
begin
	Next := nil;
	Node := nil;
	LabelSet := nil;
	Name := '';
	inherited Destroy;
end;

constructor TBESENParser.Create(AInstance: TObject);
begin
	inherited Create(AInstance);
	Lexer := TBESENLexer.Create(Instance);
	//ErrorProc:=nil; - fix for overriding internal pascal rtl error reporting
	WarningProc := nil;
end;

destructor TBESENParser.Destroy;
begin
	Lexer.Free;
	inherited Destroy;
end;

procedure TBESENParser.Init;
begin
	Lexer.NextChar;
end;

function TBESENParser.Parse(IsFunction, IsJSON: boolean): TBESENASTNode;
var CurrentToken: TBESENLexerToken;
	InForHeader: boolean;
	Labels: TBESENParserLabel;
	LabelSets, CurrentLabelSet: TBESENParserLabelSet;
	LabelSetList, LabelList: TBESENPointerList;
	IsInFunction, UseStrictAlreadyParsed: boolean;

	procedure AddError(const Msg: TBESENSTRING);
	begin

		// todo: file index

		TBESEN(Instance).LineNumber := lexer.LineNumber;
		TBESEN(Instance).ColumnNumber := lexer.CurrentColumn;
		// parser does not override file info in TBESEN(Instance).

		TBESEN(Instance).CurrentParserToken := BESENTokenStrings[currenttoken.TokenType];

		raise EBESENSyntaxError.CreateUTF16(Msg);

	end;

	procedure AddWarning(const Msg: TBESENSTRING);
	begin
		if assigned(WarningProc) then begin
			WarningProc(Lexer.LineNumber, Msg);
		end;
	end;

	procedure NextToken;
	begin
		Lexer.GetToken(CurrentToken);
	end;

	procedure SkipToken(TokenType: TBESENLexerTokenType);
	begin
		if CurrentToken.TokenType <> TokenType then begin
			AddError('"' + BESENTokenStrings[TokenType] + '" expected, "' + BESENTokenStrings[currenttoken.TokenType] + '" found.');
		end;
		NextToken;
	end;

	procedure CleanUpLabels;
	var i: integer;
	begin
		for i := 0 to LabelSetList.Count - 1 do begin
			TBESENParserLabelSet(LabelSetList[i]).Free;
			LabelSetList[i] := nil;
		end;
		LabelSetList.Clear;
		for i := 0 to LabelList.Count - 1 do begin
			TBESENParserLabelSet(LabelList[i]).Free;
			LabelList[i] := nil;
		end;
		LabelList.Clear;
	end;

	function LabelSetCurrent: TBESENParserLabelSet;
	begin
		if not assigned(CurrentLabelSet) then begin
			CurrentLabelSet := TBESENParserLabelSet.Create(Instance);
			CurrentLabelSet.Index := LabelSetList.Add(CurrentLabelSet);
			if assigned(LabelSets) then begin
				CurrentLabelSet.Target := LabelSets.Target + 1;
			end else begin
				CurrentLabelSet.Target := 1;
			end;
			CurrentLabelSet.Next := LabelSets;
			LabelSets := CurrentLabelSet;
		end;
		Result := CurrentLabelSet;
	end;

	function LabelEnter(const Name: TBESENString = ''; const Node: TBESENASTNode = nil): TBESENParserLabel;
		var l: TBESENParserLabel;
	begin
		Result := nil;
		try
			if length(Name) <> 0 then begin
				l := Labels;
				while assigned(l) do begin
					if l.Name = Name then begin

						TBESEN(Instance).LineNumber := Lexer.LineNumber;
						TBESEN(Instance).ColumnNumber := lexer.CurrentColumn();
						// parser does not override file info in TBESEN(Instance).

						TBESEN(Instance).CurrentParserLine := lexer.CurrentLine();
						TBESEN(Instance).CurrentParserToken := BESENTokenStrings[CurrentToken.TokenType];

						raise EBESENSyntaxError.CreateUTF16('Duplicate label "' + Name + '"');

					end;
					l := l.Next;
				end;
			end;
			Result := TBESENParserLabel.Create(Instance);
			Result.Name := Name;
			Result.LabelSet := LabelSetCurrent;
			Result.Node := Node;

			Result.LineNumber := Lexer.LineNumber; // careful!!
			Result.ColumnNumber := lexer.CurrentColumn;

			Result.Next := Labels;
			Result.Index := LabelList.Add(Result);
			Labels := Result;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	procedure LabelLeave;
	var OldLabels: TBESENParserLabel;
	begin
		{$ifdef UseAssert}
		Assert(assigned(Labels));
		{$endif}
		if assigned(Labels) then begin
			OldLabels := Labels;
			Labels := OldLabels.Next;
			LabelList[OldLabels.Index] := nil;
			BESENFreeAndNil(OldLabels);
		end;
	end;

	function LabelTargetLookup(const Name: TBESENString = ''; const Continuable: boolean = False): TBESENTarget;
	var l: TBESENParserLabel;
	begin
		try
			l := Labels;
			while assigned(l) do begin
				if l.Name = Name then begin
					if Continuable and not l.LabelSet.Continuable then begin
						if length(Name) = 0 then begin
							continue;
						end;

							TBESEN(Instance).LineNumber := lexer.LineNumber;
						TBESEN(Instance).ColumnNumber := lexer.CurrentColumn();

							TBESEN(Instance).CurrentParserToken := BESENTokenStrings[CurrentToken.TokenType];

						raise EBESENSyntaxError.CreateUTF16('Label name "' + Name + '" not suitable for continue');
					end;
					Result := l.LabelSet.Target;
					exit;
				end;
				l := l.Next;
			end;
			if length(Name) <> 0 then begin

 					TBESEN(Instance).LineNumber := lexer.LineNumber;
				TBESEN(Instance).ColumnNumber := lexer.CurrentColumn;

					TBESEN(Instance).CurrentParserLine := lexer.CurrentLine();
					TBESEN(Instance).CurrentParserToken := BESENTokenStrings[CurrentToken.TokenType];

				raise EBESENSyntaxError.CreateUTF16('Label name "' + Name + '" not defined, or not reachable');
			end else if Continuable then begin

				TBESEN(Instance).LineNumber := lexer.LineNumber;
				TBESEN(Instance).ColumnNumber := lexer.CurrentColumn;

					TBESEN(Instance).CurrentParserLine := lexer.CurrentLine();
					TBESEN(Instance).CurrentParserToken := BESENTokenStrings[CurrentToken.TokenType];

				raise EBESENSyntaxError.Create('Continue statement not within a loop');
			end else begin
				TBESEN(Instance).LineNumber := lexer.LineNumber;
				TBESEN(Instance).ColumnNumber := lexer.CurrentColumn;

					TBESEN(Instance).CurrentParserLine := lexer.CurrentLine();
					TBESEN(Instance).CurrentParserToken := BESENTokenStrings[CurrentToken.TokenType];

				raise EBESENSyntaxError.Create('Break statement not within a loop or switch');
			end;
		except
			raise;
		end;
	end;

	function ParseSourceElement: TBESENASTNodeStatement; forward;
	function ParseStatement(ResetCurrentLabelSet: boolean): TBESENASTNodeStatement; forward;
	function ParseAssignmentExpression(InFlag: boolean): TBESENASTNodeExpression; forward;
	function ParseExpression(InFlag: boolean): TBESENASTNodeExpression; forward;

	function NextIsSemicolon: boolean;
	begin
		Result := (CurrentToken.TokenType in [ltEOF, ltoCLOSEBRACE, ltoSEMICOLON]) or (CurrentToken.WasLineEnd and not InForHeader);
	end;

	procedure ParseOptionalSemicolon;
	begin
		case CurrentToken.TokenType of
			ltEOF: begin
			end;
			ltoCLOSEBRACE: begin
			end;
			ltoSEMICOLON: begin
				SkipToken(ltoSEMICOLON);
			end;
			else
			begin
				if not (CurrentToken.WasLineEnd and not InForHeader) then begin
					SkipToken(ltoSEMICOLON);
				end;
			end;
		end;
	end;

	procedure ParseDirective(var IsDirectivePrologue, FirstDirective: boolean; Body: TBESENASTNodeFunctionBody);
	var OldToken: TBESENLexerToken;
	begin
		if IsDirectivePrologue then begin
			if CurrentToken.TokenType = lttSTRING then begin
				OldToken := CurrentToken;
				NextToken;
				if NextIsSemicolon then begin
					if (length(OldToken.StringValue) = 10) and (copy(Lexer.Source, OldToken.OldPosition, 10) = 'use strict') then begin
						if UseStrictAlreadyParsed then begin
							AddWarning('"use strict"/''use strict'' already seen!');
						end else begin
							UseStrictAlreadyParsed := True;
							if not TBESEN(Instance).IsStrict then begin
								TBESEN(Instance).IsStrict := True;
								Body.IsStrict := True;
								if not FirstDirective then begin
									raise EBESENUseStrict.Create('Wrong "use strict"/''use strict'' position!');
								end;
							end else begin
								TBESEN(Instance).IsStrict := True;
							end;
						end;
					end;
					FirstDirective := False;
				end else begin
					IsDirectivePrologue := False;
				end;
				Lexer.Restore(OldToken);
				NextToken;
			end else begin
				IsDirectivePrologue := False;
			end;
		end;
	end;

	function ParseIdentifier(AllowEvalArguments: boolean): TBESENASTNodeIdentifier;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeIdentifier.Create(Instance);

			//result.CodeLocation.LineNumber:= CurrentToken.LineNumber;
			//result.CodeLocation.ColumnNumber:= CurrentToken.LineColumn;

			TBESEN(Instance).codelocation_SetInfo(CurrentToken.GLineNumber, CurrentToken.GLineColumn, TBESEN(Instance).CurrentFile, 'parser'); // was FilenameSet

			// TBESEN(Instance).LineNumber:= CurrentToken.GLineNumber;
			// TBESEN(Instance).ColumnNumber:= CurrentToken.GLineColumn;

			{
			if result.CodeLocation.LineNumber > 0 then begin

			TBESEN(Instance).SetLineLocation( result.CodeLocation );

			end;
			}

			if CurrentToken.TokenType = lttIDENTIFIER then begin
				Result.Name := CurrentToken.Name;
			end else begin
				AddError('identifier literal expected, "' + BESENTokenStrings[CurrentToken.TokenType] + '" found.');
			end;
			if (TBESEN(Instance).IsStrict and not AllowEvalArguments) and ((Result.Name = 'eval') or (Result.Name = 'arguments')) then begin
				AddError('"' + Result.Name + '" not allowed here');
			end;
			NextToken;
		except
			BESENFreeAndNil(Result);

			raise;
		end;
	end;

	function ParseIdentifierName(AllowEvalArguments: boolean): TBESENASTNodeIdentifier;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeIdentifier.Create(Instance);

			Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, CurrentToken.GLineColumn, TBESEN(Instance).CurrentFile);// was FilenameSet

			if CurrentToken.TokenType in BESENLexerKeywordsTokens then begin
				Result.Name := BESENTokenStrings[CurrentToken.TokenType];
			end else if CurrentToken.TokenType = lttIDENTIFIER then begin
				Result.Name := CurrentToken.Name;
			end else begin
				AddError('identifier literal expected, ' + BESENTokenStrings[CurrentToken.TokenType] + ' found.');
			end;
			if (TBESEN(Instance).IsStrict and not AllowEvalArguments) and ((Result.Name = 'eval') or (Result.Name = 'arguments')) then begin
				AddError('"' + Result.Name + '" not allowed here');
			end;
			NextToken;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseFunctionLiteral(WithFunction, WithName: boolean): TBESENASTNodeFunctionLiteral;
	var i, j: integer;
		OldIsInFunction, OldIsStrict, OldUseStrictAlreadyParsed: boolean;
		OldToken: TBesenLexerToken;

		procedure ParseFunctionStatements;
		var IsDirectivePrologue, FirstDirective: boolean;
			Statements, i: integer;
		begin
			Statements := 0;
			try
				IsDirectivePrologue := True;
				FirstDirective := True;
				UseStrictAlreadyParsed := False;
				while (CurrentToken.TokenType <> ltoCLOSEBRACE) and not Lexer.IsEOF do begin
					if IsDirectivePrologue then begin
						ParseDirective(IsDirectivePrologue, FirstDirective, Result.Body);
					end;
					if Statements >= length(Result.Body.Statements) then begin
						SetLength(Result.Body.Statements, Statements + 256);
					end;
					Result.Body.Statements[Statements] := ParseSourceElement;
					Inc(Statements);
				end;
				SetLength(Result.Body.Statements, Statements);
				SkipToken(ltoCLOSEBRACE);
			except
				for i := 0 to Statements - 1 do begin
					BesenFreeAndNil(Result.Body.Statements[i]);
				end;
				SetLength(Result.Body.Statements, 0);
				Statements := 0;
				raise;
			end;
		end;

		function ParseFakeReturnStatement: TBESENASTNodeReturnStatement;
		begin
			Result := nil;
			try
				Result := TBESENASTNodeReturnStatement.Create(Instance);

				Result.CodeLocation.SetInfo(lexer.LineNumber, lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet

				if not NextIsSemicolon then begin
					Result.Expression := ParseExpression(True);
				end;
				if NextIsSemicolon then begin
					ParseOptionalSemicolon;
				end;
			except
				BESENFreeAndNil(Result);
				raise;
			end;
		end;

	var FakeReturnStatement: TBESENASTNodeReturnStatement;
	begin
		Result := nil;
		try
			OldUseStrictAlreadyParsed := UseStrictAlreadyParsed;
			OldIsInFunction := IsInFunction;
			OldIsStrict := TBESEN(Instance).IsStrict;
			IsInFunction := True;
			try
				Result := TBESENASTNodeFunctionLiteral.Create(Instance);

				Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet

				if WithFunction then begin
					SkipToken(ltkFUNCTION);
				end;

				if WithName or (CurrentToken.TokenType <> ltoOPENPAREN) then begin
					Result.Name := ParseIdentifier(not TBESEN(Instance).IsStrict);
				end;

				SkipToken(ltoOPENPAREN);
				i := 0;
				if (CurrentToken.TokenType <> ltoCLOSEPAREN) and not Lexer.IsEOF then begin
					while True do begin
						if i >= length(Result.Body.Parameters) then begin
							SetLength(Result.Body.Parameters, i + 256);
						end;
						Result.Body.Parameters[i] := ParseIdentifier(not TBESEN(Instance).IsStrict);
						if TBESEN(Instance).IsStrict and (Result.Body.Parameters[i] is TBESENASTNodeIdentifier) then begin
							for j := 0 to i - 1 do begin
								if TBESENASTNodeIdentifier(Result.Body.Parameters[i]).Name = TBESENASTNodeIdentifier(Result.Body.Parameters[j]).Name then begin
									AddError('Duplicate parameter "' + TBESENASTNodeIdentifier(Result.Body.Parameters[i]).Name + '"');
								end;
							end;
						end;
						Inc(i);
						if Lexer.IsEOF or (CurrentToken.TokenType = ltoCLOSEPAREN) then begin
							break;
						end else if CurrentToken.TokenType = ltoCOMMA then begin
							SkipToken(ltoCOMMA);
						end;
					end;
				end;
				SetLength(Result.Body.Parameters, i);
				SkipToken(ltoCLOSEPAREN);

				if ((TBESEN(Instance).Compatibility and COMPAT_JS) <> 0) and (CurrentToken.TokenType <> ltoOPENBRACE) then begin
					UseStrictAlreadyParsed := False;
					Result.Body.IsStrict := TBESEN(Instance).IsStrict;
					if CurrentToken.WasLineEnd then begin
						CurrentToken.WasLineEnd := False;
					end;
					FakeReturnStatement := ParseFakeReturnStatement;
					SetLength(Result.Body.Statements, 1);
					Result.Body.Statements[0] := FakeReturnStatement;
				end else begin
					SkipToken(ltoOPENBRACE);
					if IsFunction then begin
						IsFunction := False;
						Lexer.LineNumber := 1;
						//Lexer.CurrentColumn:= 1;

					end;
					OldToken := CurrentToken;
					Result.Body.IsStrict := TBESEN(Instance).IsStrict;
					try
						ParseFunctionStatements;
					except
						on e: EBESENUseStrict do begin
							Result.Body.IsStrict := TBESEN(Instance).IsStrict;
							Lexer.Restore(OldToken);
							NextToken;
							ParseFunctionStatements;
						end;
					end;
				end;

				// todo: except

			finally
				IsInFunction := OldIsInFunction;
				TBESEN(Instance).IsStrict := OldIsStrict;
				UseStrictAlreadyParsed := OldUseStrictAlreadyParsed;
			end;
			if Result.Body.IsStrict then begin
				if assigned(Result.Name) and ((Result.Name.Name = 'eval') or (Result.Name.Name = 'arguments')) then begin
					AddError('"' + Result.Name.Name + '" not allowed here as function parameter name');
				end;
				for i := 0 to length(Result.Body.Parameters) - 1 do begin
					if (Result.Body.Parameters[i].Name = 'eval') or (Result.Body.Parameters[i].Name = 'arguments') then begin
						AddError('"' + Result.Body.Parameters[i].Name + '" not allowed here as function parameter name');
					end;
					for j := 0 to i - 1 do begin
						if Result.Body.Parameters[i].Name = Result.Body.Parameters[j].Name then begin
							AddError('Duplicate parameter "' + TBESENASTNodeIdentifier(Result.Body.Parameters[i]).Name + '"');
						end;
					end;
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseFunctionDeclaration: TBESENASTNodeFunctionDeclaration;
	var Literal: TBESENASTNodeFunctionLiteral;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeFunctionDeclaration.Create(Instance);
			Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet

			Literal := ParseFunctionLiteral(True, True);
			Result.Container := Literal.Container;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseFunctionExpression(WithFunction, WithName: boolean): TBESENASTNodeFunctionExpression;
	var Literal: TBESENASTNodeFunctionLiteral;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeFunctionExpression.Create(Instance);
			Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet

			Literal := ParseFunctionLiteral(WithFunction, WithName);
			Result.Container := Literal.Container;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseStatementList(InSwitch: boolean): TBESENASTNodeStatements;
	var Count: integer;
	begin
		Result := nil;
		try
			Count := 0;
			while (not ((CurrentToken.TokenType = ltoCLOSEBRACE) or (InSwitch and (CurrentToken.TokenType = ltkCASE) or (CurrentToken.TokenType = ltkDEFAULT)))) and not Lexer.IsEOF do begin
				if Count >= length(Result) then begin
					SetLength(Result, Count + 256);
				end;
				Result[Count] := ParseStatement(True);
				Inc(Count);
				if CurrentToken.TokenType = ltkFUNCTION then begin
					if (TBESEN(Instance).Compatibility and COMPAT_JS) = 0 then begin
						break;
					end;
				end;
			end;
			SetLength(Result, Count);
		except
			for Count := 0 to length(Result) - 1 do begin
				BESENFreeAndNil(Result[Count]);
			end;
			SetLength(Result, 0);
			raise;
		end;
	end;

	function ParseBlockStatement: TBESENASTNodeBlockStatement;
	begin
		Result := nil;
		try
			SkipToken(ltoOPENBRACE);
			Result := TBESENASTNodeBlockStatement.Create(Instance);

			Result.CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet

			Result.Statements := ParseStatementList(False);
			SkipToken(ltoCLOSEBRACE);
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseDebuggerStatement: TBESENASTNodeDebuggerStatement;
	begin
		Result := nil;
		try
			SkipToken(ltkDEBUGGER);
			Result := TBESENASTNodeDebuggerStatement.Create(Instance);
			Result.CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet
			ParseOptionalSemicolon;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseBreakStatement: TBESENASTNodeBreakStatement;
	begin
		Result := nil;
		try
			SkipToken(ltkBREAK);
			Result := TBESENASTNodeBreakStatement.Create(Instance);
			Result.CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet
			if NextIsSemicolon then begin
				Result.Target := LabelTargetLookup('', False);
			end else begin
				if CurrentToken.TokenType = lttIDENTIFIER then begin
					if CurrentToken.WasLineEnd then begin
						AddError('Illegal line terminator after break');
					end;
					Result.Identifier := ParseIdentifier(True);
					if assigned(Result.Identifier) then begin
						Result.Target := LabelTargetLookup(Result.Identifier.Name, False);
					end else begin
						Result.Target := LabelTargetLookup('', False);
					end;
				end;
				ParseOptionalSemicolon;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseContinueStatement: TBESENASTNodeContinueStatement;
	begin
		Result := nil;
		try
			SkipToken(ltkCONTINUE);
			Result := TBESENASTNodeContinueStatement.Create(Instance);
			Result.CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet
			if NextIsSemicolon then begin
				Result.Target := LabelTargetLookup('', True);
			end else begin
				if CurrentToken.TokenType = lttIDENTIFIER then begin
					if CurrentToken.WasLineEnd then begin
						AddError('Illegal line terminator after continue');
					end;
					Result.Identifier := ParseIdentifier(True);
					if assigned(Result.Identifier) then begin
						Result.Target := LabelTargetLookup(Result.Identifier.Name, True);
					end else begin
						Result.Target := LabelTargetLookup('', True);
					end;
				end;
				ParseOptionalSemicolon;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseExpression(InFlag: boolean): TBESENASTNodeExpression;
	var Left: TBESENASTNodeExpression;
	begin
		Result := nil;
		try
			Result := ParseAssignmentExpression(InFlag);
			while not Lexer.IsEOF do begin
				case CurrentToken.TokenType of
					ltoCOMMA: begin
						SkipToken(ltoCOMMA);
						Left := Result;
						Result := TBESENASTNodeBinaryCommaExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet

						TBESENASTNodeBinaryCommaExpression(Result).LeftExpression := Left;
						TBESENASTNodeBinaryCommaExpression(Result).RightExpression := ParseAssignmentExpression(InFlag);
					end;
					else
					begin
						break;
					end;
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseDoStatement: TBESENASTNodeDoStatement;
	var LabelSet: TBESENParserLabelSet;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeDoStatement.Create(Instance);
			Result.CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet
			LabelSet := LabelSetCurrent;
			LabelSet.Continuable := True;
			LabelEnter('', Result);
			Result.Target := LabelSet.Target;
			SkipToken(ltkDO);
			Result.Statement := ParseStatement(True);
			SkipToken(ltkWHILE);
			Result.Expression := ParseExpression(True);
			ParseOptionalSemicolon;
			LabelLeave;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseRegExpLiteral: TBESENASTNodeRegExpLiteral;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeRegExpLiteral.Create(Instance);
			Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet

			if CurrentToken.TokenType in [ltoDIVIDE, ltoDIVIDEASSIGNMENT] then begin
				Lexer.Restore(CurrentToken);
				if not Lexer.ParseRegExpLiteral(CurrentToken, Result.Source, Result.Flags) then begin
					AddError('regex literal expected, "' + BESENTokenStrings[currenttoken.TokenType] + '" found.');
				end;
			end else begin
				AddError('regex literal expected, "' + BESENTokenStrings[currenttoken.TokenType] + '" found.');
			end;
			NextToken;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseStringLiteral: TBESENASTNodeStringLiteral;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeStringLiteral.Create(Instance);

			Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet

			if CurrentToken.TokenType = lttSTRING then begin
				Result.Value := CurrentToken.StringValue;
			end else begin
				AddError('string literal expected, "' + BESENTokenStrings[currenttoken.TokenType] + '" found.');
			end;
			NextToken;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseNumbericLiteral: TBESENASTNodeNumberLiteral;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeNumberLiteral.Create(Instance);
			Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


			case CurrentToken.TokenType of
				lttINTEGER: begin
					Result.Value := CurrentToken.IntValue;
				end;
				lttFLOAT: begin
					Result.Value := CurrentToken.FloatValue;
				end;
				else
				begin
					AddError('numberic literal expected, "' + BESENTokenStrings[currenttoken.TokenType] + '" found.');
				end;
			end;
			NextToken;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseObjectLiteralProperty(const Parent: TBESENASTNodeObjectLiteral; const Count: integer): TBESENASTNodeObjectLiteralProperty;
	var PropertyType: TBESENASTNodeObjectLiteralPropertyType;
		PropertyAccessorType: TBESENASTNodeObjectLiteralPropertyAccessorType;
		OldToken: TBESENLexerToken;
		i: integer;
		Key: TBESENString;
		function ParseObjectLiteralPropertyName: TBESENString;
		begin
			case CurrentToken.TokenType of
				lttIDENTIFIER: begin
					Result := CurrentToken.Name;
					NextToken;
				end;
				lttSTRING: begin
					Result := CurrentToken.StringValue;
					NextToken;
				end;
				lttINTEGER: begin
					Result := TBESEN(Instance).ToStr(BESENNumberValue(CurrentToken.IntValue));
					NextToken;
				end;
				lttFLOAT: begin
					Result := TBESEN(Instance).ToStr(BESENNumberValue(CurrentToken.FloatValue));
					NextToken;
				end;
				else
				begin
					if CurrentToken.TokenType in BESENLexerKeywordsTokens then begin
						Result := BESENTokenStrings[CurrentToken.TokenType];
						NextToken;
					end else begin
						AddError('identifier or numeric literal expected, "' + BESENTokenStrings[currenttoken.TokenType] + '" found.');
					end;
				end;
			end;
		end;
	var Literal: TBESENASTNodeFunctionLiteral;
	begin
		Result := nil;
		try
			PropertyType := banolptDATA;
			PropertyAccessorType := banolpatNONE;
			if (CurrentToken.TokenType = lttIDENTIFIER) and ((CurrentToken.Name = 'get') or (CurrentToken.Name = 'set')) then begin
				OldToken := CurrentToken;
				if CurrentToken.Name = 'get' then begin
					PropertyType := banolptACCESSOR;
					PropertyAccessorType := banolpatGET;
				end else if CurrentToken.Name = 'set' then begin
					PropertyType := banolptACCESSOR;
					PropertyAccessorType := banolpatSET;
				end;
				if PropertyType = banolptACCESSOR then begin
					NextToken;
					if not (CurrentToken.TokenType in [lttIDENTIFIER, lttSTRING, lttINTEGER, lttFLOAT]) then begin
						PropertyType := banolptDATA;
						Lexer.Restore(OldToken);
						NextToken;
					end;
				end;
			end;
			Key := ParseObjectLiteralPropertyName;
			case PropertyType of
				banolptACCESSOR: begin
					for i := 0 to Count - 1 do begin
						if Key = Parent.Properties[i].Name then begin
							case Parent.Properties[i].PropertyType of
								banolptACCESSOR: begin
									if Parent.Properties[i].PropertyAccessorType = PropertyAccessorType then begin
										case PropertyAccessorType of
											banolpatGET: begin
												AddError('Duplicate accessor property getter "' + Key + '"');
											end;
											banolpatSET: begin
												AddError('Duplicate accessor property setter "' + Key + '"');
											end;
											else
											begin
												AddError('Invalid property "' + Key + '"');
											end;
										end;
									end;
								end;
								banolptDATA: begin
									AddError('Invalid property "' + Key + '"');
								end;
							end;
						end;
					end;
					Result := TBESENASTNodeObjectLiteralProperty.Create(Instance);
					Result.PropertyType := PropertyType;
					Result.PropertyAccessorType := PropertyAccessorType;
					Result.Name := Key;
					Literal := ParseFunctionLiteral(False, False);
					Result.Container := Literal.Container;
					if not ((PropertyAccessorType in [banolpatGET, banolpatSET]) and (assigned(Literal) and assigned(Literal.Body))) then begin
						AddError('Invalid property "' + Key + '"');
					end else begin
						case PropertyAccessorType of
							banolpatGET: begin
								if length(Literal.Body.Parameters) > 0 then begin
									AddError('Getter must have no parameters');
								end;
							end;
							banolpatSET: begin
								if length(Literal.Body.Parameters) <> 1 then begin
									AddError('Setter must have only one parameter');
								end;
							end;
							else
							begin
								AddError('Invalid property "' + Key + '"');
							end;
						end;
					end;
				end;
				banolptDATA: begin
					for i := 0 to Count - 1 do begin
						if Key = Parent.Properties[i].Name then begin
							case Parent.Properties[i].PropertyType of
								banolptACCESSOR: begin
									AddError('Invalid property "' + Key + '"');
								end;
								banolptDATA: begin
									if TBESEN(Instance).IsStrict then begin
										AddError('Duplicate data property "' + Key + '"');
									end;
								end;
							end;
						end;
					end;
					Result := TBESENASTNodeObjectLiteralProperty.Create(Instance);
					Result.PropertyType := banolptDATA;
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					Result.Name := Key;
					SkipToken(ltoCOLON);
					Result.Value := ParseAssignmentExpression(True);
				end;
				else
				begin
					AddError('Invalid property "' + Key + '"');
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseObjectLiteral: TBESENASTNodeObjectLiteral;
	var Count: integer;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeObjectLiteral.Create(Instance);
			Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


			Result.Properties := nil;
			Count := 0;
			SkipToken(ltoOPENBRACE);
			while (CurrentToken.TokenType <> ltoCLOSEBRACE) and not Lexer.IsEOF do begin
				if Count >= length(Result.Properties) then begin
					SetLength(Result.Properties, Count + 256);
				end;
				Result.Properties[Count] := ParseObjectLiteralProperty(Result, Count);
				Inc(Count);
				if CurrentToken.TokenType <> ltoCLOSEBRACE then begin
					if CurrentToken.TokenType = ltoCOMMA then begin
						SkipToken(ltoCOMMA);
					end else begin
						AddError(''','' or ''}'' expected, "' + BESENTokenStrings[currenttoken.TokenType] + '" found.');
						break;
					end;
				end;
			end;
			SetLength(Result.Properties, Count);
			SkipToken(ltoCLOSEBRACE);
		except
			for Count := 0 to length(Result.Properties) - 1 do begin
				BESENFreeAndNil(Result.Properties[Count]);
			end;
			SetLength(Result.Properties, 0);
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseArrayLiteral: TBESENASTNodeArrayLiteral;
	var Count: integer;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeArrayLiteral.Create(Instance);
			Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


			SkipToken(ltoOPENSQUARE);
			Result.Elements := nil;
			Count := 0;
			while (CurrentToken.TokenType <> ltoCLOSESQUARE) and not Lexer.IsEOF do begin
				if Count >= length(Result.Elements) then begin
					SetLength(Result.Elements, Count + 256);
				end;
				if CurrentToken.TokenType = ltoCOMMA then begin
					Result.Elements[Count] := nil;
				end else begin
					Result.Elements[Count] := ParseAssignmentExpression(True);
				end;
				Inc(Count);
				if CurrentToken.TokenType <> ltoCLOSESQUARE then begin
					if CurrentToken.TokenType = ltoCOMMA then begin
						SkipToken(ltoCOMMA);
					end else begin
						AddError(''','' or '']'' expected, "' + BESENTokenStrings[currenttoken.TokenType] + '" found.');
						break;
					end;
				end;
			end;
			SetLength(Result.Elements, Count);
			SkipToken(ltoCLOSESQUARE);
		except
			for Count := 0 to length(Result.Elements) - 1 do begin
				BESENFreeAndNil(Result.Elements[Count]);
			end;
			SetLength(Result.Elements, 0);
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParsePrimaryExpression: TBESENASTNodeExpression;
	begin
		Result := nil;
		try
			case CurrentToken.TokenType of
				ltkTHIS: begin
					Result := TBESENASTNodeThisLiteral.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					SkipToken(ltkTHIS);
				end;
				ltkNULL: begin
					Result := TBESENASTNodeNullLiteral.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					SkipToken(ltkNULL);
				end;
				ltkTRUE: begin
					Result := TBESENASTNodeBooleanLiteral.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeBooleanLiteral(Result).Value := True;
					SkipToken(ltkTRUE);
				end;
				ltkFALSE: begin
					Result := TBESENASTNodeBooleanLiteral.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeBooleanLiteral(Result).Value := False;
					SkipToken(ltkFALSE);
				end;
				ltoOPENPAREN: begin
					SkipToken(ltoOPENPAREN);
					Result := ParseExpression(True);
					SkipToken(ltoCLOSEPAREN);
				end;
				ltoOPENBRACE: begin
					Result := ParseObjectLiteral;
				end;
				ltoOPENSQUARE: begin
					Result := ParseArrayLiteral;
				end;
				lttIDENTIFIER: begin
					Result := ParseIdentifier(True);
				end;
				ltoDIVIDE, ltoDIVIDEASSIGNMENT: begin
					Result := ParseRegExpLiteral;
				end;
				lttSTRING: begin
					Result := ParseStringLiteral;
				end;
				lttINTEGER, lttFLOAT: begin
					Result := ParseNumbericLiteral;
				end;
				else
				begin
					AddError('identifier or literal expected, "' + BESENTokenStrings[currenttoken.TokenType] + '" found.');
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseArgumentList: TBESENASTNodeExpressions;
	var Count: integer;
	begin
		Result := nil;
		try
			Count := 0;
			SkipToken(ltoOPENPAREN);
			if (CurrentToken.TokenType <> ltoCLOSEPAREN) and not Lexer.IsEOF then begin
				while True do begin
					if Count >= length(Result) then begin
						SetLength(Result, Count + 256);
					end;
					Result[Count] := ParseAssignmentExpression(True);
					Inc(Count);
					if Lexer.IsEOF or (CurrentToken.TokenType = ltoCLOSEPAREN) then begin
						break;
					end else if CurrentToken.TokenType = ltoCOMMA then begin
						SkipToken(ltoCOMMA);
					end else begin
						break;
					end;
				end;
			end;
			SkipToken(ltoCLOSEPAREN);
			SetLength(Result, Count);
		except
			for Count := 0 to length(Result) - 1 do begin
				BESENFreeAndNil(Result[Count]);
			end;
			SetLength(Result, 0);
			raise;
		end;
	end;

	function ParseLeftHandSideAndMemberExpression(IsLeftHandSideExpression: boolean = True): TBESENASTNodeExpression;
	var Expression: TBESENASTNodeExpression;
		Identifier: TBESENASTNodeIdentifier;
	begin
		Result := nil;
		try
			case CurrentToken.TokenType of
				ltkNEW: begin
					SkipToken(ltkNEW);
					Result := TBESENASTNodeNewExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeNewExpression(Result).TheFunction := ParseLeftHandSideAndMemberExpression(False);
					if CurrentToken.TokenType = ltoOPENPAREN then begin
						TBESENASTNodeNewExpression(Result).Arguments := ParseArgumentList;
					end else begin
						TBESENASTNodeNewExpression(Result).Arguments := nil;
					end;
				end;
				ltkFUNCTION: begin
					Result := ParseFunctionExpression(True, False);
				end;
				else
				begin
					Result := ParsePrimaryExpression;
				end;
			end;
			while not Lexer.IsEOF do begin
				if IsLeftHandSideExpression and (CurrentToken.TokenType = ltoOPENPAREN) then begin
					Expression := Result;
					Result := TBESENASTNodeCallExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeCallExpression(Result).TheFunction := Expression;
					TBESENASTNodeCallExpression(Result).Arguments := ParseArgumentList;
				end else if CurrentToken.TokenType = ltoOPENSQUARE then begin
					Expression := Result;
					Result := TBESENASTNodePropertyExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodePropertyExpression(Result).Dot := False;
					TBESENASTNodePropertyExpression(Result).LeftExpression := Expression;
					SkipToken(ltoOPENSQUARE);
					TBESENASTNodePropertyExpression(Result).RightExpression := ParseExpression(True);
					if TBESEN(Instance).IsStrict then begin
						if assigned(TBESENASTNodePropertyExpression(Result).RightExpression) then begin
							if TBESENASTNodePropertyExpression(Result).RightExpression is TBESENASTNodeStringLiteral then begin
								if ((TBESENASTNodeStringLiteral(TBESENASTNodePropertyExpression(Result).RightExpression).Value = 'eval') or (TBESENASTNodeStringLiteral(TBESENASTNodePropertyExpression(Result).RightExpression).Value = 'arguments')) then begin
									AddError('"' + TBESENASTNodeStringLiteral(TBESENASTNodePropertyExpression(Result).RightExpression).Value + '" not allowed here');
								end;
							end;
						end;
					end;
					SkipToken(ltoCLOSESQUARE);
				end else if CurrentToken.TokenType = ltoDOT then begin
					Expression := Result;
					Result := TBESENASTNodePropertyExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodePropertyExpression(Result).Dot := True;
					TBESENASTNodePropertyExpression(Result).LeftExpression := Expression;
					SkipToken(ltoDOT);
					TBESENASTNodePropertyExpression(Result).RightExpression := TBESENASTNodeStringLiteral.Create(Instance);
					Identifier := ParseIdentifierName(True);
					TBESENASTNodeStringLiteral(TBESENASTNodePropertyExpression(Result).RightExpression).Value := Identifier.Name;
					Identifier.Free;
				end else begin
					break;
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParsePostfixExpression: TBESENASTNodeExpression;
	var Expression: TBESENASTNodeExpression;
	begin
		Result := nil;
		try
			Result := ParseLeftHandSideAndMemberExpression;
			case CurrentToken.TokenType of
				ltoPLUSPLUS: begin
					if CurrentToken.WasLineEnd then begin
						AddError('Illegal line terminator before postfix increment');
					end;
					Expression := Result;
					Result := TBESENASTNodePostfixIncExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					SkipToken(ltoPLUSPLUS);
					TBESENASTNodePostfixIncExpression(Result).SubExpression := Expression;
				end;
				ltoMINUSMINUS: begin
					if CurrentToken.WasLineEnd then begin
						AddError('Illegal line terminator before postfix decrement');
					end;
					Expression := Result;
					Result := TBESENASTNodePostfixDecExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					SkipToken(ltoMINUSMINUS);
					TBESENASTNodePostfixDecExpression(Result).SubExpression := Expression;
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseUnaryExpression: TBESENASTNodeExpression;
	begin
		Result := nil;
		try
			case CurrentToken.TokenType of
				ltoPLUSPLUS: begin
					Result := TBESENASTNodePrefixIncExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					SkipToken(ltoPLUSPLUS);
					TBESENASTNodePrefixIncExpression(Result).SubExpression := ParseUnaryExpression;
				end;
				ltoMINUSMINUS: begin
					Result := TBESENASTNodePrefixDecExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					SkipToken(ltoMINUSMINUS);
					TBESENASTNodePrefixdecExpression(Result).SubExpression := ParseUnaryExpression;
				end;
				ltoPLUS: begin
					Result := TBESENASTNodeUnaryPlusExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					SkipToken(ltoPLUS);
					TBESENASTNodeUnaryPlusExpression(Result).SubExpression := ParseUnaryExpression;
				end;
				ltoMINUS: begin
					Result := TBESENASTNodeUnaryMinusExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					SkipToken(ltoMINUS);
					TBESENASTNodeUnaryMinusExpression(Result).SubExpression := ParseUnaryExpression;
				end;
				ltoBITWISENOT: begin
					Result := TBESENASTNodeUnaryBitwiseNotExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					SkipToken(ltoBITWISENOT);
					TBESENASTNodeUnaryBitwiseNotExpression(Result).SubExpression := ParseUnaryExpression;
				end;
				ltoLOGICALNOT: begin
					Result := TBESENASTNodeUnaryLogicalNotExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					SkipToken(ltoLOGICALNOT);
					TBESENASTNodeUnaryLogicalNotExpression(Result).SubExpression := ParseUnaryExpression;
				end;
				ltkVOID: begin
					Result := TBESENASTNodeUnaryVoidExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					SkipToken(ltkVOID);
					TBESENASTNodeUnaryVoidExpression(Result).SubExpression := ParseUnaryExpression;
				end;
				ltkTYPEOF: begin
					Result := TBESENASTNodeUnaryTypeOfExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					SkipToken(ltkTYPEOF);
					TBESENASTNodeUnaryTypeOfExpression(Result).SubExpression := ParseUnaryExpression;
				end;
				ltkDELETE: begin
					Result := TBESENASTNodeDeleteExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					SkipToken(ltkDELETE);
					TBESENASTNodeDeleteExpression(Result).SubExpression := ParseUnaryExpression;
				end;
				else
				begin
					Result := ParsePostfixExpression;
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseMultiplyExpression: TBESENASTNodeExpression;
	var Left: TBESENASTNodeExpression;
	begin
		Result := nil;
		try
			Result := ParseUnaryExpression;
			while not Lexer.IsEOF do begin
				case CurrentToken.TokenType of
					ltoDIVIDE: begin
						Left := Result;
						Result := TBESENASTNodeBinaryDivideExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


						TBESENASTNodeBinaryDivideExpression(Result).LeftExpression := Left;
						SkipToken(ltoDIVIDE);
						TBESENASTNodeBinaryDivideExpression(Result).RightExpression := ParseUnaryExpression;
					end;
					ltoMODULO: begin
						Left := Result;
						Result := TBESENASTNodeBinaryModuloExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


						TBESENASTNodeBinaryModuloExpression(Result).LeftExpression := Left;
						SkipToken(ltoMODULO);
						TBESENASTNodeBinaryModuloExpression(Result).RightExpression := ParseUnaryExpression;
					end;
					ltoMULTIPLY: begin
						Left := Result;
						Result := TBESENASTNodeBinaryMultiplyExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


						TBESENASTNodeBinaryMultiplyExpression(Result).LeftExpression := Left;
						SkipToken(ltoMULTIPLY);
						TBESENASTNodeBinaryMultiplyExpression(Result).RightExpression := ParseUnaryExpression;
					end;
					else
					begin
						break;
					end;
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseAdditionExpression: TBESENASTNodeExpression;
	var Left: TBESENASTNodeExpression;
	begin
		Result := nil;
		try
			Result := ParseMultiplyExpression;
			while not Lexer.IsEOF do begin
				case CurrentToken.TokenType of
					ltoPLUS: begin
						Left := Result;
						Result := TBESENASTNodeBinaryPlusExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


						TBESENASTNodeBinaryPlusExpression(Result).LeftExpression := Left;
						SkipToken(ltoPLUS);
						TBESENASTNodeBinaryPlusExpression(Result).RightExpression := ParseMultiplyExpression;
					end;
					ltoMINUS: begin
						Left := Result;
						Result := TBESENASTNodeBinaryMinusExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


						TBESENASTNodeBinaryMinusExpression(Result).LeftExpression := Left;
						SkipToken(ltoMINUS);
						TBESENASTNodeBinaryMinusExpression(Result).RightExpression := ParseMultiplyExpression;
					end;
					else
					begin
						break;
					end;
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseShiftExpression: TBESENASTNodeExpression;
	var Left: TBESENASTNodeExpression;
	begin
		Result := nil;
		try
			Result := ParseAdditionExpression;
			while not Lexer.IsEOF do begin
				case CurrentToken.TokenType of
					ltoSHIFTLEFT: begin
						Left := Result;
						Result := TBESENASTNodeBinaryShiftLeftExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


						TBESENASTNodeBinaryShiftLeftExpression(Result).LeftExpression := Left;
						SkipToken(ltoSHIFTLEFT);
						TBESENASTNodeBinaryShiftLeftExpression(Result).RightExpression := ParseAdditionExpression;
					end;
					ltoSHIFTRIGHT: begin
						Left := Result;
						Result := TBESENASTNodeBinaryShiftRightExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


						TBESENASTNodeBinaryShiftRightExpression(Result).LeftExpression := Left;
						SkipToken(ltoSHIFTRIGHT);
						TBESENASTNodeBinaryShiftRightExpression(Result).RightExpression := ParseAdditionExpression;
					end;
					ltoSHIFTRIGHTUNSIGNED: begin
						Left := Result;
						Result := TBESENASTNodeBinaryShiftRightUnsignedExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


						TBESENASTNodeBinaryShiftRightUnsignedExpression(Result).LeftExpression := Left;
						SkipToken(ltoSHIFTRIGHTUNSIGNED);
						TBESENASTNodeBinaryShiftRightUnsignedExpression(Result).RightExpression := ParseAdditionExpression;
					end;
					else
					begin
						break;
					end;
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseRelationalExpression(InFlag: boolean): TBESENASTNodeExpression;
	var Left: TBESENASTNodeExpression;
	begin
		Result := nil;
		try
			Result := ParseShiftExpression;
			while not Lexer.IsEOF do begin
				case CurrentToken.TokenType of
					ltoGREATERTHAN: begin
						Left := Result;
						Result := TBESENASTNodeBinaryGreaterThanExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


						TBESENASTNodeBinaryGreaterThanExpression(Result).LeftExpression := Left;
						SkipToken(ltoGREATERTHAN);
						TBESENASTNodeBinaryGreaterThanExpression(Result).RightExpression := ParseShiftExpression;
					end;
					ltoGREATERTHANOREQUAL: begin
						Left := Result;
						Result := TBESENASTNodeBinaryGreaterThanOrEqualExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


						TBESENASTNodeBinaryGreaterThanOrEqualExpression(Result).LeftExpression := Left;
						SkipToken(ltoGREATERTHANOREQUAL);
						TBESENASTNodeBinaryGreaterThanOrEqualExpression(Result).RightExpression := ParseShiftExpression;
					end;
					ltoLESSTHAN: begin
						Left := Result;
						Result := TBESENASTNodeBinaryLessThanExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


						TBESENASTNodeBinaryLessThanExpression(Result).LeftExpression := Left;
						SkipToken(ltoLESSTHAN);
						TBESENASTNodeBinaryLessThanExpression(Result).RightExpression := ParseShiftExpression;
					end;
					ltoLESSTHANOREQUAL: begin
						Left := Result;
						Result := TBESENASTNodeBinaryLessThanOrEqualExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


						TBESENASTNodeBinaryLessThanOrEqualExpression(Result).LeftExpression := Left;
						SkipToken(ltoLESSTHANOREQUAL);
						TBESENASTNodeBinaryLessThanOrEqualExpression(Result).RightExpression := ParseShiftExpression;
					end;
					ltkINSTANCEOF: begin
						Left := Result;
						Result := TBESENASTNodeBinaryInstanceOfExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


						TBESENASTNodeBinaryInstanceOfExpression(Result).LeftExpression := Left;
						SkipToken(ltkINSTANCEOF);
						TBESENASTNodeBinaryInstanceOfExpression(Result).RightExpression := ParseShiftExpression;
					end;
					ltkIN: begin
						if InFlag then begin
							Left := Result;
							Result := TBESENASTNodeBinaryInExpression.Create(Instance);
							Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


							TBESENASTNodeBinaryInExpression(Result).LeftExpression := Left;
							SkipToken(ltkIN);
							TBESENASTNodeBinaryInExpression(Result).RightExpression := ParseShiftExpression;
						end else begin
							break;
						end;
					end;
					else
					begin
						break;
					end;
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseEqualityExpression(InFlag: boolean): TBESENASTNodeExpression;
	var Left: TBESENASTNodeExpression;
	begin
		Result := nil;
		try
			Result := ParseRelationalExpression(InFlag);
			while not Lexer.IsEOF do begin
				case CurrentToken.TokenType of
					ltoEQUALEQUAL: begin
						Left := Result;
						Result := TBESENASTNodeBinaryEqualEqualExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


						TBESENASTNodeBinaryEqualEqualExpression(Result).LeftExpression := Left;
						SkipToken(ltoEQUALEQUAL);
						TBESENASTNodeBinaryEqualEqualExpression(Result).RightExpression := ParseRelationalExpression(InFlag);
					end;
					ltoEQUALEQUALEQUAL: begin
						Left := Result;
						Result := TBESENASTNodeBinaryEqualEqualEqualExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


						TBESENASTNodeBinaryEqualEqualEqualExpression(Result).LeftExpression := Left;
						SkipToken(ltoEQUALEQUALEQUAL);
						TBESENASTNodeBinaryEqualEqualEqualExpression(Result).RightExpression := ParseRelationalExpression(InFlag);
					end;
					ltoNOTEQUAL: begin
						Left := Result;
						Result := TBESENASTNodeBinaryNotEqualExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


						TBESENASTNodeBinaryNotEqualExpression(Result).LeftExpression := Left;
						SkipToken(ltoNOTEQUAL);
						TBESENASTNodeBinaryNotEqualExpression(Result).RightExpression := ParseRelationalExpression(InFlag);
					end;
					ltoNOTEQUALEQUAL: begin
						Left := Result;
						Result := TBESENASTNodeBinaryNotEqualEqualExpression.Create(Instance);
						Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


						TBESENASTNodeBinaryNotEqualEqualExpression(Result).LeftExpression := Left;
						SkipToken(ltoNOTEQUALEQUAL);
						TBESENASTNodeBinaryNotEqualEqualExpression(Result).RightExpression := ParseRelationalExpression(InFlag);
					end;
					else
					begin
						break;
					end;
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseBitwiseAndExpression(InFlag: boolean): TBESENASTNodeExpression;
	var Left: TBESENASTNodeExpression;
	begin
		Result := nil;
		try
			Result := ParseEqualityExpression(InFlag);
			while not Lexer.IsEOF do begin
				if CurrentToken.TokenType = ltoBITWISEAND then begin
					Left := Result;
					Result := TBESENASTNodeBinaryBitwiseAndExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeBinaryBitwiseAndExpression(Result).LeftExpression := Left;
					SkipToken(ltoBITWISEAND);
					TBESENASTNodeBinaryBitwiseAndExpression(Result).RightExpression := ParseEqualityExpression(InFlag);
				end else begin
					break;
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseBitwiseXorExpression(InFlag: boolean): TBESENASTNodeExpression;
	var Left: TBESENASTNodeExpression;
	begin
		Result := nil;
		try
			Result := ParseBitwiseAndExpression(InFlag);
			while not Lexer.IsEOF do begin
				if CurrentToken.TokenType = ltoBITWISEXOR then begin
					Left := Result;
					Result := TBESENASTNodeBinaryBitwiseXorExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeBinaryBitwiseXorExpression(Result).LeftExpression := Left;
					SkipToken(ltoBITWISEXOR);
					TBESENASTNodeBinaryBitwiseXorExpression(Result).RightExpression := ParseBitwiseAndExpression(InFlag);
				end else begin
					break;
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseBitwiseOrExpression(InFlag: boolean): TBESENASTNodeExpression;
	var Left: TBESENASTNodeExpression;
	begin
		Result := nil;
		try
			Result := ParseBitwiseXorExpression(InFlag);
			while not Lexer.IsEOF do begin
				if CurrentToken.TokenType = ltoBITWISEOR then begin
					Left := Result;
					Result := TBESENASTNodeBinaryBitwiseOrExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeBinaryBitwiseOrExpression(Result).LeftExpression := Left;
					SkipToken(ltoBITWISEOR);
					TBESENASTNodeBinaryBitwiseOrExpression(Result).RightExpression := ParseBitwiseXorExpression(InFlag);
				end else begin
					break;
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseLogicalAndExpression(InFlag: boolean): TBESENASTNodeExpression;
	var Left: TBESENASTNodeExpression;
	begin
		Result := nil;
		try
			Result := ParseBitwiseOrExpression(InFlag);
			while not Lexer.IsEOF do begin
				if CurrentToken.TokenType = ltoLOGICALAND then begin
					Left := Result;
					Result := TBESENASTNodeLogicalAndExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeLogicalAndExpression(Result).LeftExpression := Left;
					SkipToken(ltoLOGICALAND);
					TBESENASTNodeLogicalAndExpression(Result).RightExpression := ParseBitwiseOrExpression(InFlag);
				end else begin
					break;
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseLogicalOrExpression(InFlag: boolean): TBESENASTNodeExpression;
	var Left: TBESENASTNodeExpression;
	begin
		Result := nil;
		try
			Result := ParseLogicalAndExpression(InFlag);
			while not Lexer.IsEOF do begin
				if CurrentToken.TokenType = ltoLOGICALOR then begin
					Left := Result;
					Result := TBESENASTNodeLogicalOrExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeLogicalOrExpression(Result).LeftExpression := Left;
					SkipToken(ltoLOGICALOR);
					TBESENASTNodeLogicalOrExpression(Result).RightExpression := ParseLogicalAndExpression(InFlag);
				end else begin
					break;
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseConditionalExpression(InFlag: boolean): TBESENASTNodeExpression;
	var Expression: TBESENASTNodeExpression;
	begin
		Result := nil;
		try
			Result := ParseLogicalOrExpression(InFlag);
			if CurrentToken.TokenType = ltoCONDITIONAL then begin
				Expression := Result;
				Result := TBESENASTNodeConditionalExpression.Create(Instance);
				Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


				TBESENASTNodeConditionalExpression(Result).Expression := Expression;
				SkipToken(ltoCONDITIONAL);
				TBESENASTNodeConditionalExpression(Result).TrueExpression := ParseAssignmentExpression(InFlag);
				SkipToken(ltoCOLON);
				TBESENASTNodeConditionalExpression(Result).FalseExpression := ParseAssignmentExpression(InFlag);
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseAssignmentExpression(InFlag: boolean): TBESENASTNodeExpression;
	var Left: TBESENASTNodeExpression;
	begin
		Result := nil;
		Left := nil;
		try
			Result := ParseConditionalExpression(InFlag);
			case CurrentToken.TokenType of
				ltoASSIGNMENT: begin
					Left := Result;
					Result := TBESENASTNodeAssignmentExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeAssignmentExpression(Result).LeftExpression := Left;
					SkipToken(ltoASSIGNMENT);
					TBESENASTNodeAssignmentExpression(Result).RightExpression := ParseAssignmentExpression(InFlag);
				end;
				ltoMULTIPLYASSIGNMENT: begin
					Left := Result;
					Result := TBESENASTNodeAssignmentMultiplyExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeAssignmentMultiplyExpression(Result).LeftExpression := Left;
					SkipToken(ltoMULTIPLYASSIGNMENT);
					TBESENASTNodeAssignmentMultiplyExpression(Result).RightExpression := ParseAssignmentExpression(InFlag);
				end;
				ltoDIVIDEASSIGNMENT: begin
					Left := Result;
					Result := TBESENASTNodeAssignmentDivideExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeAssignmentDivideExpression(Result).LeftExpression := Left;
					SkipToken(ltoDIVIDEASSIGNMENT);
					TBESENASTNodeAssignmentDivideExpression(Result).RightExpression := ParseAssignmentExpression(InFlag);
				end;
				ltoMODULOASSIGNMENT: begin
					Left := Result;
					Result := TBESENASTNodeAssignmentModuloExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeAssignmentModuloExpression(Result).LeftExpression := Left;
					SkipToken(ltoMODULOASSIGNMENT);
					TBESENASTNodeAssignmentModuloExpression(Result).RightExpression := ParseAssignmentExpression(InFlag);
				end;
				ltoPLUSASSIGNMENT: begin
					Left := Result;
					Result := TBESENASTNodeAssignmentPlusExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeAssignmentPlusExpression(Result).LeftExpression := Left;
					SkipToken(ltoPLUSASSIGNMENT);
					TBESENASTNodeAssignmentPlusExpression(Result).RightExpression := ParseAssignmentExpression(InFlag);
				end;
				ltoMINUSASSIGNMENT: begin
					Left := Result;
					Result := TBESENASTNodeAssignmentMinusExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeAssignmentMinusExpression(Result).LeftExpression := Left;
					SkipToken(ltoMINUSASSIGNMENT);
					TBESENASTNodeAssignmentMinusExpression(Result).RightExpression := ParseAssignmentExpression(InFlag);
				end;
				ltoSHIFTLEFTASSIGNMENT: begin
					Left := Result;
					Result := TBESENASTNodeAssignmentShiftLeftExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeAssignmentShiftLeftExpression(Result).LeftExpression := Left;
					SkipToken(ltoSHIFTLEFTASSIGNMENT);
					TBESENASTNodeAssignmentShiftLeftExpression(Result).RightExpression := ParseAssignmentExpression(InFlag);
				end;
				ltoSHIFTRIGHTASSIGNMENT: begin
					Left := Result;
					Result := TBESENASTNodeAssignmentShiftRightExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeAssignmentShiftRightExpression(Result).LeftExpression := Left;
					SkipToken(ltoSHIFTRIGHTASSIGNMENT);
					TBESENASTNodeAssignmentShiftRightExpression(Result).RightExpression := ParseAssignmentExpression(InFlag);
				end;
				ltoSHIFTRIGHTUNSIGNEDASSIGNMENT: begin
					Left := Result;
					Result := TBESENASTNodeAssignmentShiftRightUnsignedExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeAssignmentShiftRightUnsignedExpression(Result).LeftExpression := Left;
					SkipToken(ltoSHIFTRIGHTUNSIGNEDASSIGNMENT);
					TBESENASTNodeAssignmentShiftRightUnsignedExpression(Result).RightExpression := ParseAssignmentExpression(InFlag);
				end;
				ltoBITWISEANDASSIGNMENT: begin
					Left := Result;
					Result := TBESENASTNodeAssignmentBitwiseAndExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeAssignmentBitwiseAndExpression(Result).LeftExpression := Left;
					SkipToken(ltoBITWISEANDASSIGNMENT);
					TBESENASTNodeAssignmentBitwiseAndExpression(Result).RightExpression := ParseAssignmentExpression(InFlag);
				end;
				ltoBITWISEXORASSIGNMENT: begin
					Left := Result;
					Result := TBESENASTNodeAssignmentBitwiseXorExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeAssignmentBitwiseXorExpression(Result).LeftExpression := Left;
					SkipToken(ltoBITWISEXORASSIGNMENT);
					TBESENASTNodeAssignmentBitwiseXorExpression(Result).RightExpression := ParseAssignmentExpression(InFlag);
				end;
				ltoBITWISEORASSIGNMENT: begin
					Left := Result;
					Result := TBESENASTNodeAssignmentBitwiseOrExpression.Create(Instance);
					Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


					TBESENASTNodeAssignmentBitwiseOrExpression(Result).LeftExpression := Left;
					SkipToken(ltoBITWISEORASSIGNMENT);
					TBESENASTNodeAssignmentBitwiseOrExpression(Result).RightExpression := ParseAssignmentExpression(InFlag);
				end;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseVariableDeclaration(InFlag: boolean): TBESENASTNodeVariableDeclaration;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeVariableDeclaration.Create(Instance);
			Result.CodeLocation.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet


			Result.Identifier := ParseIdentifier(not TBESEN(Instance).IsStrict);
			if CurrentToken.TokenType = ltoASSIGNMENT then begin
				SkipToken(ltoASSIGNMENT);
				Result.Expression := ParseAssignmentExpression(InFlag);
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseForStatement: TBESENASTNodeStatement;
	var OldInForHeader: boolean;
		State, i: integer;
		Declaration: TBESENASTNodeVariableDeclaration;
		Initial, Expression, Variable: TBESENASTNodeExpression;
		VariableExpression: TBESENASTNodeVariableExpression;
		LabelSet: TBESENParserLabelSet;
		ALabel: TBESENParserLabel;
	begin
		//ln:=Lexer.LineNumber;
		Result := nil;
		Initial := nil;
		Declaration := nil;
		Variable := nil;
		Expression := nil;
		try
			LabelSet := LabelSetCurrent;
			LabelSet.Continuable := True;
			ALabel := LabelEnter('', nil);

			SkipToken(ltkFOR);

			SkipToken(ltoOPENPAREN);
			OldInForHeader := InForHeader;
			InForHeader := True;
			State := 0;
			while not Lexer.IsEOF do begin
				case State of
					0: begin
						if CurrentToken.TokenType = ltkVAR then begin
							State := 1;
						end else if CurrentToken.TokenType <> ltoSEMICOLON then begin
							State := 2;
						end else begin
							State := 5;
						end;
					end;
					1: begin
						SkipToken(ltkVAR);
						Declaration := ParseVariableDeclaration(False);
						if (CurrentToken.TokenType = ltkIN) and (assigned(Declaration) and not assigned(Declaration.Expression)) then begin
							Variable := Declaration;
							Declaration := nil;
							State := 3;
						end else begin
							State := 4;
						end;
					end;
					2: begin
						Initial := ParseExpression(False);
						if CurrentToken.TokenType = ltkIN then begin
							Variable := Initial;
							Initial := nil;
							State := 3;
						end else begin
							State := 5;
						end;
					end;
					3: begin
						SkipToken(ltkIN);
						Expression := ParseExpression(True);
						SkipToken(ltoCLOSEPAREN);
						InForHeader := OldInForHeader;
						Result := TBESENASTNodeForInStatement.Create(Instance);
						TBESENASTNodeForInStatement(Result).Target := LabelSet.Target;
						TBESENASTNodeForInStatement(Result).Variable := Variable;
						TBESENASTNodeForInStatement(Result).Expression := Expression;
						ALabel.Node := Result;
						Variable := nil;
						Expression := nil;
						break;
					end;
					4: begin
						VariableExpression := TBESENASTNodeVariableExpression.Create(Instance);
						Initial := VariableExpression;
						SetLength(VariableExpression.Declarations, 1);
						VariableExpression.Declarations[0] := Declaration;
						Declaration := nil;
						i := 1;
						while (CurrentToken.TokenType = ltoCOMMA) and not Lexer.IsEOF do begin
							SkipToken(ltoCOMMA);
							if i >= length(VariableExpression.Declarations) then begin
								SetLength(VariableExpression.Declarations, i + 256);
							end;
							VariableExpression.Declarations[i] := ParseVariableDeclaration(False);
							Inc(i);
						end;
						SetLength(VariableExpression.Declarations, i);
						State := 5;
					end;
					5: begin
						Result := TBESENASTNodeForStatement.Create(Instance);
						TBESENASTNodeForStatement(Result).Initial := Initial;
						TBESENASTNodeForStatement(Result).Target := LabelSet.Target;
						ALabel.Node := Result;
						Initial := nil;
						SkipToken(ltoSEMICOLON);
						if CurrentToken.TokenType <> ltoSEMICOLON then begin
							TBESENASTNodeForStatement(Result).Condition := ParseExpression(True);
						end;
						SkipToken(ltoSEMICOLON);
						if CurrentToken.TokenType <> ltoCLOSEPAREN then begin
							TBESENASTNodeForStatement(Result).Increment := ParseExpression(True);
						end;
						SkipToken(ltoCLOSEPAREN);
						break;
					end;
				end;
			end;
			InForHeader := OldInForHeader;
			if assigned(Result) then begin
				if Result is TBESENASTNodeForStatement then begin
					TBESENASTNodeForStatement(Result).Statement := ParseStatement(True);
				end else if Result is TBESENASTNodeForInStatement then begin
					TBESENASTNodeForInStatement(Result).Statement := ParseStatement(True);
				end;
			end else begin
				Result := TBESENASTNodeEmptyStatement.Create(Instance);
			end;
			Result.CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet
			LabelLeave;
		except
			BESENFreeAndNil(Initial);
			BESENFreeAndNil(Declaration);
			BESENFreeAndNil(Variable);
			BESENFreeAndNil(Expression);
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseIfStatement: TBESENASTNodeIfStatement;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeIfStatement.Create(Instance);
			Result.CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet
			SkipToken(ltkIF);
			SkipToken(ltoOPENPAREN);
			Result.Expression := ParseExpression(True);
			SkipToken(ltoCLOSEPAREN);
			Result.TrueStatement := ParseStatement(True);
			if CurrentToken.TokenType = ltkELSE then begin
				SkipToken(ltkELSE);
				Result.FalseStatement := ParseStatement(True);
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseReturnStatement: TBESENASTNodeReturnStatement;
	begin
		Result := nil;
		try
			if not IsInFunction then begin
				raise EBESENSyntaxError.Create('Return outside a function');
			end;
			Result := TBESENASTNodeReturnStatement.Create(Instance);
			Result.CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet
			SkipToken(ltkRETURN);
			if not NextIsSemicolon then begin
				if CurrentToken.WasLineEnd then begin
					AddError('Illegal line terminator after return');
				end;
				Result.Expression := ParseExpression(True);
			end;
			ParseOptionalSemicolon;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseThrowStatement: TBESENASTNodeThrowStatement;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeThrowStatement.Create(Instance);
			Result.CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet
			SkipToken(ltkTHROW);
			if CurrentToken.WasLineEnd then begin
				AddError('Illegal line terminator after throw');
			end;
			Result.Expression := ParseExpression(True);
			ParseOptionalSemicolon;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseTryStatement: TBESENASTNodeTryStatement;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeTryStatement.Create(Instance);
			Result.CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet
			SkipToken(ltkTRY);

			Result.CatchBlock := nil;
			Result.FinallyBlock := nil;
			Result.CatchIdentifier := nil;

			Result.TryBlock := ParseBlockStatement;

			if (CurrentToken.TokenType <> ltkCATCH) and (CurrentToken.TokenType <> ltkFINALLY) then begin
				AddError('catch or finally expected after try, "' + BESENTokenStrings[currenttoken.TokenType] + '" found.');
			end;

			if CurrentToken.TokenType = ltkCATCH then begin
				SkipToken(ltkCATCH);
				SkipToken(ltoOPENPAREN);
				Result.CatchIdentifier := ParseIdentifier(not TBESEN(Instance).IsStrict);
				SkipToken(ltoCLOSEPAREN);
				Result.CatchBlock := ParseBlockStatement;
			end;

			if CurrentToken.TokenType = ltkFINALLY then begin
				SkipToken(ltkFINALLY);
				Result.FinallyBlock := ParseBlockStatement;
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseSwitchStatement: TBESENASTNodeSwitchStatement;
	var CaseStatements: integer;
		CaseStatement: TBESENASTNodeCaseStatement;
		DefaultSeen: boolean;
		LabelSet: TBESENParserLabelSet;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeSwitchStatement.Create(Instance);
			Result.CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet
			SkipToken(ltkSWITCH);

			LabelSet := LabelSetCurrent;
			LabelSet.Continuable := True;
			LabelEnter('', Result);

			Result.Target := LabelSet.Target;

			DefaultSeen := False;

			SkipToken(ltoOPENPAREN);
			Result.Expression := ParseExpression(True);
			SkipToken(ltoCLOSEPAREN);

			CaseStatements := 0;
			SkipToken(ltoOPENBRACE);
			while (CurrentToken.TokenType <> ltoCLOSEBRACE) and not Lexer.IsEOF do begin
				if CaseStatements >= length(Result.CaseStatements) then begin
					SetLength(Result.CaseStatements, CaseStatements + 256);
				end;
				Result.CaseStatements[CaseStatements] := TBESENASTNodeCaseStatement.Create(Instance);
				Result.CaseStatements[CaseStatements].CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet

				CaseStatement := Result.CaseStatements[CaseStatements];
				Inc(CaseStatements);

				CaseStatement.Expression := nil;

				if CurrentToken.TokenType = ltkCASE then begin
					SkipToken(ltkCASE);
					CaseStatement.Expression := ParseExpression(True);
					SkipToken(ltoCOLON);
				end else begin
					if DefaultSeen then begin
						AddError('duplication default clause in switch statement');
					end else begin
						DefaultSeen := True;
						SkipToken(ltkDEFAULT);
						SkipToken(ltoCOLON);
					end;
				end;

				CaseStatement.Statements := ParseStatementList(True);
			end;
			SetLength(Result.CaseStatements, CaseStatements);

			SkipToken(ltoCLOSEBRACE);
			LabelLeave;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseVariableStatement: TBESENASTNodeVariableStatement;
	var Count: integer;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeVariableStatement.Create(Instance);
			Result.CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet
			SkipToken(ltkVAR);

			Result.Declarations := nil;
			Count := 1;
			SetLength(Result.Declarations, Count);
			Result.Declarations[0] := ParseVariableDeclaration(True);
			while (CurrentToken.TokenType = ltoCOMMA) and not Lexer.IsEOF do begin
				SkipToken(ltoCOMMA);
				if Count >= length(Result.Declarations) then begin
					SetLength(Result.Declarations, Count + 256);
				end;
				Result.Declarations[Count] := ParseVariableDeclaration(True);
				Inc(Count);
			end;
			SetLength(Result.Declarations, Count);

			ParseOptionalSemicolon;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseWhileStatement: TBESENASTNodeWhileStatement;
	var LabelSet: TBESENParserLabelSet;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeWhileStatement.Create(Instance);
			Result.CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet
			LabelSet := LabelSetCurrent;
			LabelSet.Continuable := True;
			LabelEnter('', Result);
			Result.Target := LabelSet.Target;
			SkipToken(ltkWHILE);

			SkipToken(ltoOPENPAREN);
			Result.Expression := ParseExpression(True);
			SkipToken(ltoCLOSEPAREN);

			Result.Statement := ParseStatement(True);
			LabelLeave;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseWithStatement: TBESENASTNodeWithStatement;
	begin
		Result := nil;
		try
			if TBESEN(Instance).IsStrict then begin
				AddError('WITH isn''t allowed in strict mode');
			end;
			Result := TBESENASTNodeWithStatement.Create(Instance);
			Result.CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet
			SkipToken(ltkWITH);

			SkipToken(ltoOPENPAREN);
			Result.Expression := ParseExpression(True);
			SkipToken(ltoCLOSEPAREN);

			Result.Statement := ParseStatement(True);
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseExpressionStatement: TBESENASTNodeStatement;
	var Expression: TBESENASTNodeExpression;
		LabelSet, OldLabelSet: TBESENParserLabelSet;
		LabelCount: integer;
		OldToken: TBESENLexerToken;
	begin

		Result := nil;
		Expression := nil;
		try
			Expression := ParseExpression(True);
			if (Expression is TBESENASTNodeIdentifier) and (CurrentToken.TokenType = ltoCOLON) then begin
				SkipToken(ltoCOLON);

				Result := TBESENASTNodeLabelledStatement.Create(Instance);
				Result.CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet

				SetLength(TBESENASTNodeLabelledStatement(Result).Identifiers, 1);
				TBESENASTNodeLabelledStatement(Result).Identifiers[0] := TBESENASTNodeIdentifier(Expression);

				Expression := nil;

				OldLabelSet := CurrentLabelSet;
				CurrentLabelSet := nil;

				LabelSet := LabelSetCurrent;
				LabelSet.Continuable := True;

				LabelCount := 1;
				LabelEnter(TBESENASTNodeLabelledStatement(Result).Identifiers[0].Name, Result);
				while True do begin
					OldToken := CurrentToken;
					if CurrentToken.TokenType = lttIDENTIFIER then begin
						Expression := ParseIdentifier(True);
						if assigned(Expression) and (Expression is TBESENASTNodeIdentifier) and (CurrentToken.TokenType = ltoCOLON) then begin
							SkipToken(ltoCOLON);
							if LabelCount >= length(TBESENASTNodeLabelledStatement(Result).Identifiers) then begin
								SetLength(TBESENASTNodeLabelledStatement(Result).Identifiers, LabelCount + 256);
							end;
							TBESENASTNodeLabelledStatement(Result).Identifiers[LabelCount] := TBESENASTNodeIdentifier(Expression);
							LabelEnter(TBESENASTNodeLabelledStatement(Result).Identifiers[LabelCount].Name, Result);
							Inc(LabelCount);
						end else begin
							if assigned(Expression) then begin
								BESENFreeAndNil(Expression);
							end;
							Lexer.Restore(OldToken);
							NextToken;
							break;
						end;
					end else begin
						break;
					end;
				end;
				SetLength(TBESENASTNodeLabelledStatement(Result).Identifiers, LabelCount);

				TBESENASTNodeLabelledStatement(Result).Target := LabelSet.Target;
				TBESENASTNodeLabelledStatement(Result).Statement := ParseStatement(not (CurrentToken.TokenType in [ltkFOR, ltkWHILE, ltkDO]));

				while LabelCount > 0 do begin
					Dec(LabelCount);
					LabelLeave;
				end;

				if assigned(CurrentLabelSet) then begin
					LabelSetList[CurrentLabelSet.Index] := nil;
					BESENFreeAndNil(CurrentLabelSet);
				end;
				CurrentLabelSet := OldLabelSet;

			end else begin
				ParseOptionalSemicolon;
				Result := TBESENASTNodeExpressionStatement.Create(Instance);
				Result.CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet
				TBESENASTNodeExpressionStatement(Result).Expression := Expression;
				Expression := nil;
			end;
		except
			BESENFreeAndNil(Result);
			BESENFreeAndNil(Expression);
			raise;
		end;
	end;

	function ParseFunctionStatement: TBESENASTNodeStatement;
	var Expression: TBESENASTNodeAssignmentExpression;
	begin
		Result := nil;
		try
			Result := TBESENASTNodeExpressionStatement.Create(Instance);
			Result.CodeLocation.SetInfo(Lexer.LineNumber, Lexer.CurrentColumn, TBESEN(Instance).CurrentFile); // was FilenameSet
			TBESENASTNodeExpressionStatement(Result).Expression := TBESENASTNodeAssignmentExpression.Create(Instance);
			Expression := TBESENASTNodeAssignmentExpression(TBESENASTNodeExpressionStatement(Result).Expression);
			Expression.LeftExpression := ParseIdentifier(not TBESEN(Instance).IsStrict);
			Expression.RightExpression := ParseFunctionExpression(False, False);
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseStatement(ResetCurrentLabelSet: boolean): TBESENASTNodeStatement;
	var LineInfo: TBESENLocation;
		OldToken: TBESENLexerToken;
	begin
		Result := nil;
		try
			if ResetCurrentLabelSet then begin
				CurrentLabelSet := nil;
			end;

			LineInfo.SetInfo(CurrentToken.GLineNumber, currenttoken.GLineColumn, TBESEN(Instance).CurrentFile); // was FilenameSet

			case CurrentToken.TokenType of
				ltoSEMICOLON: begin
					SkipToken(ltoSEMICOLON);
					Result := TBESENASTNodeEmptyStatement.Create(Instance);
				end;
				ltoOPENBRACE: begin
					Result := ParseBlockStatement;
				end;
				ltkDEBUGGER: begin
					Result := ParseDebuggerStatement;
				end;
				ltkBREAK: begin
					Result := ParseBreakStatement;
				end;
				ltkCONTINUE: begin
					Result := ParseContinueStatement;
				end;
				ltkDO: begin
					Result := ParseDoStatement;
				end;
				ltkFOR: begin
					Result := ParseForStatement;
				end;
				ltkIF: begin
					Result := ParseIfStatement;
				end;
				ltkRETURN: begin
					Result := ParseReturnStatement;
				end;
				ltkTHROW: begin
					Result := ParseThrowStatement;
				end;
				ltkTRY: begin
					Result := ParseTryStatement;
				end;
				ltkSWITCH: begin
					Result := ParseSwitchStatement;
				end;
				ltkVAR: begin
					Result := ParseVariableStatement;
				end;
				ltkWHILE: begin
					Result := ParseWhileStatement;
				end;
				ltkWITH: begin
					Result := ParseWithStatement;
				end;
				else
				begin
					if CurrentToken.TokenType = ltkFUNCTION then begin
						OldToken := CurrentToken;
						SkipToken(ltkFUNCTION);
						if (TBESEN(Instance).Compatibility and COMPAT_JS) <> 0 then begin
							if CurrentToken.TokenType <> ltoOPENPAREN then begin
								Result := ParseFunctionStatement;
							end else begin
								Lexer.Restore(OldToken);
								NextToken;
								Result := ParseExpressionStatement;
							end;
						end else begin
							AddError('function keyword not allowed here');
							Result := nil;
						end;
					end else begin
						Result := ParseExpressionStatement;
					end;
				end;
			end;
			if assigned(Result) then begin
				Result.CodeLocation.copy(LineInfo);
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	function ParseSourceElement: TBESENASTNodeStatement;
	begin
		Result := nil;
		try
			if CurrentToken.TokenType = ltkFUNCTION then begin
				Result := ParseFunctionDeclaration;
			end else begin
				Result := ParseStatement(True);
			end;
		except
			BESENFreeAndNil(Result);
			raise;
		end;
	end;

	procedure CheckJSON(Source:{$ifdef BESENSingleStringType}TBESENSTRING{$else}TBESENUTF8STRING{$endif});
	var Position: integer;
		CurrentChar: TBESENUTF32CHAR;
		CharEOF: boolean;
		procedure NextChar;
		{$ifdef BESENSingleStringType}
  var Len:integer;
		{$else}
		var b: byte;
		{$endif}
		begin
			if (Position >= 1) and (Position <= length(Source)) then begin
				{$ifdef BESENSingleStringType}
{$ifdef BESENEmbarcaderoNextGen}
    CurrentChar:=Char.ConvertToUTF32(s,Position-1,Len);
    inc(Position,Len);
{$else}
    CurrentChar:=ord(Source[Position]);
    inc(Position);
    if (Position<=length(Source)) and ((SizeOf(Source[Position])=SizeOf(word)) and (((CurrentChar and $fc00)=$d800) and ((ord(Source[Position]) and $fc00)=$dc00))) then begin
     // UTF16
     CurrentChar:=(((CurrentChar and $3ff) shl 10) or (ord(Source[Position]) and $3ff))+$10000;
     inc(Position);
    end;
{$endif}
				{$else}
				b := byte(Source[Position]);
				if (b and $80) = 0 then begin
					CurrentChar := b;
					Inc(Position);
				end else if ((Position + 1) <= length(Source)) and ((b and $e0) = $c0) and ((byte(Source[Position + 1]) and $c0) = $80) then begin
					CurrentChar := ((byte(Source[Position]) and $1f) shl 6) or (byte(Source[Position + 1]) and $3f);
					Inc(Position, 2);
				end else if ((Position + 2) <= length(Source)) and ((b and $f0) = $e0) and ((byte(Source[Position + 1]) and $c0) = $80) and ((byte(Source[Position + 2]) and $c0) = $80) then begin
					CurrentChar := ((byte(Source[Position]) and $0f) shl 12) or ((byte(Source[Position + 1]) and $3f) shl 6) or (byte(Source[Position + 2]) and $3f);
					Inc(Position, 3);
				end else if ((Position + 3) <= length(Source)) and ((b and $f8) = $f0) and ((byte(Source[Position + 1]) and $c0) = $80) and ((byte(Source[Position + 2]) and $c0) = $80) and ((byte(Source[Position + 3]) and $c0) = $80) then begin
					CurrentChar := ((byte(Source[Position]) and $07) shl 18) or ((byte(Source[Position + 1]) and $3f) shl 12) or ((byte(Source[Position + 2]) and $3f) shl 6) or (byte(Source[Position + 3]) and $3f);
					Inc(Position, 4);
				end else if {$ifdef strictutf8}((TBESEN(Instance).Compatibility and COMPAT_UTF8_UNSAFE) <> 0) and{$endif} ((Position + 4) <= length(Source)) and ((b and $fc) = $f8) and ((byte(Source[Position + 1]) and $c0) = $80) and ((byte(Source[Position + 2]) and $c0) = $80) and ((byte(Source[Position + 3]) and $c0) = $80) and ((byte(Source[Position + 4]) and $c0) = $80) then begin
					CurrentChar := ((byte(Source[Position]) and $03) shl 24) or ((byte(Source[Position + 1]) and $3f) shl 18) or ((byte(Source[Position + 2]) and $3f) shl 12) or ((byte(Source[Position + 3]) and $3f) shl 6) or (byte(Source[Position + 4]) and $3f);
					Inc(Position, 5);
				end else if {$ifdef strictutf8}((TBESEN(Instance).Compatibility and COMPAT_UTF8_UNSAFE) <> 0) and{$endif} ((Position + 5) <= length(Source)) and ((b and $fe) = $fc) and ((byte(Source[Position + 1]) and $c0) = $80) and ((byte(Source[Position + 2]) and $c0) = $80) and ((byte(Source[Position + 3]) and $c0) = $80) and ((byte(Source[Position + 4]) and $c0) = $80) and ((byte(Source[Position + 5]) and $c0) = $80) then begin
					CurrentChar := ((byte(Source[Position]) and $01) shl 30) or ((byte(Source[Position + 1]) and $3f) shl 24) or ((byte(Source[Position + 2]) and $3f) shl 18) or ((byte(Source[Position + 3]) and $3f) shl 12) or ((byte(Source[Position + 4]) and $3f) shl 6) or (byte(Source[Position + 5]) and $3f);
					Inc(Position, 6);
				end else begin
					CurrentChar := $fffd;
					Inc(Position);
				end;
				{$endif}
			end else begin
				CurrentChar := 0;
				CharEOF := True;
			end;
		end;

		procedure JSONError;
		begin
			raise EBESENSyntaxError.Create('JSON.parse');
		end;

		procedure SkipWhite;
		begin
			while (not CharEOF) and ((CurrentChar = $0009) or (CurrentChar = $000a) or (CurrentChar = $000d) or (CurrentChar = $0020)) do begin
				NextChar;
			end;
		end;

		function IsChar(c: widechar): boolean;
		begin
			Result := (not CharEOF) and (CurrentChar = word(c));
		end;

		procedure ExpectChar(c: widechar);
		begin
			if IsChar(c) then begin
				NextChar;
			end else begin
				JSONError;
			end;
		end;

		procedure CheckValue;
			procedure CheckString;
			begin
				if IsChar('"') then begin
					NextChar;
					while not (CharEOF or IsChar('"')) do begin
						case CurrentChar of
							$0000..$001f: begin
								JSONError;
							end;
							Ord('\'): begin
								NextChar;
								case CurrentChar of
									Ord('"'), Ord('\'), Ord('/'), Ord('b'), Ord('f'), Ord('n'), Ord('r'), Ord('t'): begin
										NextChar;
									end;
									Ord('u'): begin
										NextChar;
										if (((CurrentChar >= Ord('0')) and (CurrentChar <= Ord('9'))) or ((CurrentChar >= Ord('a')) and (CurrentChar <= Ord('f'))) or ((CurrentChar >= Ord('A')) and (CurrentChar <= Ord('F')))) and not CharEOF then begin
											NextChar;
											if (((CurrentChar >= Ord('0')) and (CurrentChar <= Ord('9'))) or ((CurrentChar >= Ord('a')) and (CurrentChar <= Ord('f'))) or ((CurrentChar >= Ord('A')) and (CurrentChar <= Ord('F')))) and not CharEOF then begin
												NextChar;
												if (((CurrentChar >= Ord('0')) and (CurrentChar <= Ord('9'))) or ((CurrentChar >= Ord('a')) and (CurrentChar <= Ord('f'))) or ((CurrentChar >= Ord('A')) and (CurrentChar <= Ord('F')))) and not CharEOF then begin
													NextChar;
													if (((CurrentChar >= Ord('0')) and (CurrentChar <= Ord('9'))) or ((CurrentChar >= Ord('a')) and (CurrentChar <= Ord('f'))) or ((CurrentChar >= Ord('A')) and (CurrentChar <= Ord('F')))) and not CharEOF then begin
														NextChar;
													end else begin
														JSONError;
													end;
												end else begin
													JSONError;
												end;
											end else begin
												JSONError;
											end;
										end else begin
											JSONError;
										end;
									end;
									else
									begin
										JSONError;
									end;
								end;
							end;
							else
							begin
								NextChar;
							end;
						end;
					end;
					ExpectChar('"');
				end else begin
					JSONError;
				end;
				SkipWhite;
			end;
			procedure CheckNumber;
			begin
				if CharEOF then begin
					JSONError;
				end;
				case CurrentChar of
					Ord('-'), Ord('0')..Ord('9'): begin
						if IsChar('-') then begin
							NextChar;
							if CharEOF or not ((CurrentChar >= Ord('0')) and (CurrentChar <= Ord('9'))) then begin
								JSONError;
							end;
						end;
						if (not CharEOF) and (CurrentChar = Ord('0')) then begin
							NextChar;
							if (not CharEOF) and ((CurrentChar >= Ord('0')) and (CurrentChar <= Ord('9'))) then begin
								JSONError;
							end;
						end else begin
							while (not CharEOF) and ((CurrentChar >= Ord('0')) and (CurrentChar <= Ord('9'))) do begin
								NextChar;
							end;
						end;
						if IsChar('.') then begin
							NextChar;
							if CharEOF or not ((CurrentChar >= Ord('0')) and (CurrentChar <= Ord('9'))) then begin
								JSONError;
							end;
							while (not CharEOF) and ((CurrentChar >= Ord('0')) and (CurrentChar <= Ord('9'))) do begin
								NextChar;
							end;
						end;
						if (not CharEOF) and ((CurrentChar = Ord('e')) or (CurrentChar = Ord('E'))) then begin
							NextChar;
							if (not CharEOF) and ((CurrentChar = Ord('-')) or (CurrentChar = Ord('+'))) then begin
								NextChar;
							end;
							if CharEOF or not ((CurrentChar >= Ord('0')) and (CurrentChar <= Ord('9'))) then begin
								JSONError;
							end;
							while (not CharEOF) and ((CurrentChar >= Ord('0')) and (CurrentChar <= Ord('9'))) do begin
								NextChar;
							end;
						end;
					end else
					begin
						JSONError;
					end;
				end;
			end;
			procedure CheckObjectProperty;
			begin
				CheckString;
				SkipWhite;
				ExpectChar(':');
				SkipWhite;
				CheckValue;
			end;
			procedure CheckObject;
			begin
				ExpectChar('{');
				SkipWhite;
				while not (CharEOF or IsChar('}')) do begin
					CheckObjectProperty;
					SkipWhite;
					if IsChar(',') then begin
						NextChar;
						SkipWhite;
						if (not CharEOF) and IsChar('}') then begin
							JSONError;
						end;
					end;
				end;
				ExpectChar('}');
			end;
			procedure CheckArray;
			begin
				ExpectChar('[');
				SkipWhite;
				while not (CharEOF or IsChar(']')) do begin
					CheckValue;
					SkipWhite;
					if IsChar(',') then begin
						NextChar;
						SkipWhite;
						if (not CharEOF) and IsChar(']') then begin
							JSONError;
						end;
					end;
				end;
				ExpectChar(']');
			end;
			procedure CheckKeyword(const Keyword: TBESENString);
			var i: integer;
			begin
				for i := 1 to length(Keyword) do begin
					ExpectChar(Keyword[i]);
				end;
			end;
		begin
			SkipWhite;
			if CharEOF then begin
				JSONError;
			end;
			case CurrentChar of
				Ord('{'): begin
					CheckObject;
				end;
				Ord('['): begin
					CheckArray;
				end;
				Ord('"'): begin
					CheckString;
				end;
				Ord('-'), Ord('0')..Ord('9'): begin
					CheckNumber;
				end;
				Ord('t'): begin
					CheckKeyword('true');
				end;
				Ord('f'): begin
					CheckKeyword('false');
				end;
				Ord('n'): begin
					CheckKeyword('null');
				end;
				else
				begin
					JSONError;
				end;
			end;
		end;
	begin
		CharEOF := False;
		Position := 1;
		NextChar;
		CheckValue;
		SkipWhite;
		if not CharEOF then begin
			JSONError;
		end;
	end;
var Statement: TBESENASTNodeStatement;
	OldIsStrict: boolean;
	OldToken: TBesenLexerToken;

	procedure ParseJSONStatements;
	var i: integer;
	begin
		try
			SetLength(TBESENASTNodeProgram(Result).Body.Statements, 0);
			if not Lexer.IsEOF then begin
				Statement := ParseExpressionStatement;
				if assigned(Statement) then begin
					SetLength(TBESENASTNodeProgram(Result).Body.Statements, 1);
					TBESENASTNodeProgram(Result).Body.Statements[0] := Statement;
				end else begin
					AddError('Fatal error');
				end;
			end;
		except
			for i := 0 to length(TBESENASTNodeProgram(Result).Body.Statements) - 1 do begin
				BesenFreeAndNil(TBESENASTNodeProgram(Result).Body.Statements[i]);
			end;
			SetLength(TBESENASTNodeProgram(Result).Body.Statements, 0);
			raise;
		end;
	end;

	procedure ParseProgramStatements;
	var IsDirectivePrologue, FirstDirective: boolean;
		Statements, i: integer;
	begin
		Statements := 0;
		try
			IsDirectivePrologue := True;
			FirstDirective := True;
			UseStrictAlreadyParsed := False;
			while not Lexer.IsEOF do begin
				if IsDirectivePrologue then begin
					ParseDirective(IsDirectivePrologue, FirstDirective, TBESENASTNodeProgram(Result).Body);
				end;
				Statement := ParseSourceElement;
				if assigned(Statement) then begin
					if Statements >= length(TBESENASTNodeProgram(Result).Body.Statements) then begin
						SetLength(TBESENASTNodeProgram(Result).Body.Statements, Statements + 256);
					end;
					TBESENASTNodeProgram(Result).Body.Statements[Statements] := Statement;
					Inc(Statements);
				end else begin
					AddError('Fatal error');
					break;
				end;
			end;
			SetLength(TBESENASTNodeProgram(Result).Body.Statements, Statements);
		except
			for i := 0 to Statements - 1 do begin
				BesenFreeAndNil(TBESENASTNodeProgram(Result).Body.Statements[i]);
			end;
			SetLength(TBESENASTNodeProgram(Result).Body.Statements, 0);
			Statements := 0;
			raise;
		end;
	end;
begin
	Labels := nil;
	LabelSets := nil;
	CurrentLabelSet := nil;
	LabelSetList := TBESENPointerList.Create;
	LabelList := TBESENPointerList.Create;
	OldIsStrict := TBESEN(Instance).IsStrict;
	try
		NextToken;
		InForHeader := False;
		if IsFunction then begin
			IsInFunction := True;
			try
				Result := ParseFunctionExpression(True, False);
			except
				Result := nil;
				raise;
			end;
		end else if IsJSON then begin
			IsInFunction := False;
			Result := TBESENASTNodeProgram.Create(Instance);
			try
				CheckJSON(Lexer.Source);
				TBESEN(Instance).IsStrict := False;
				TBESENASTNodeProgram(Result).Body.IsStrict := TBESEN(Instance).IsStrict;
				ParseJSONStatements;
			except
				SetLength(TBESENASTNodeProgram(Result).Body.Statements, 0);
				raise;
			end;
		end else begin
			IsInFunction := False;
			Result := TBESENASTNodeProgram.Create(Instance);
			try
				OldToken := CurrentToken;
				TBESENASTNodeProgram(Result).Body.IsStrict := TBESEN(Instance).IsStrict;
				try
					ParseProgramStatements;
				except
					on e: EBESENUseStrict do begin
						TBESENASTNodeProgram(Result).Body.IsStrict := TBESEN(Instance).IsStrict;
						Lexer.Restore(OldToken);
						NextToken;
						ParseProgramStatements;
					end;
				end;
				TBESENASTNodeProgram(Result).Body.IsStrict := TBESEN(Instance).IsStrict;
			except
				SetLength(TBESENASTNodeProgram(Result).Body.Statements, 0);
				raise;
			end;
		end;
	finally
		CurrentToken.Name := '';
		CurrentToken.StringValue := '';
		CleanUpLabels;
		TBESEN(Instance).IsStrict := OldIsStrict;
		BESENFreeAndNil(LabelSetList);
		BESENFreeAndNil(LabelList);
	end;
end;

end.

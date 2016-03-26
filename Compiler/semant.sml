signature SEMANT = 
sig
	type expty
	type venv
	type tenv
	type ty
	
	val transVar: venv * tenv * Absyn.var * Translate.level -> expty 
	val	transExp: venv * tenv * Absyn.exp * Translate.level -> expty 
	val	transDec: venv * tenv * Absyn.dec * Translate.level -> {venv: venv, tenv: tenv} 
	val	transTy: tenv * Absyn.ty -> Types.ty 
		
	val	transProg: Absyn.exp -> unit
end

structure Semant :> SEMANT =
struct
	structure A = Absyn
	structure E = Env
	structure Er = ErrorMsg
	structure S = Symbol
	structure T = Types
	structure Tr = Translate
	structure Tmp = Temp
	
	type expty = {exp: Tr.exp, ty: T.ty}
	type venv = E.enventry S.table
	type tenv = T.ty S.table
	type ty = T.ty

	val loopDepth = ref 0
	val breakCount = ref 0
	
	(* Helper Functions *)
	fun actual_ty (ty: T.ty, pos: A.pos) =
		(case ty of
			T.NAME(sym, tyOpt) => 
				(case !tyOpt of
					SOME(t) => (actual_ty (t, pos))
					| NONE => (Er.error pos ("Cannot evaluate the type: "^(S.name sym)); T.ERROR))
			| T.ARRAY(t,u) => T.ARRAY(actual_ty(t,pos), u)
			| _ => ty)
			
	fun assertSubTypes (type1: T.ty, type2: T.ty, pos1: A.pos, pos2: A.pos) =
		let
			val trueType1 = actual_ty(type1, pos1)
			val trueType2 = actual_ty(type2, pos2)
		in
			if trueType1 = trueType2 then
				true
			else if trueType1 = T.NIL then
				(case trueType2 of
					T.RECORD(fields, unique) => true
					| _ => false)
			else if trueType2 = T.NIL then
				(case trueType1 of
					T.RECORD(fields, unique) => true
					| _ => false)
			else
				false
		end
			
	(* Helper Methods for checking recursive types *)
	structure tempDecSet =  BinarySetFn 
	(
		struct 
			type ord_key = string
	  		val compare = String.compare
  		end
  	)

	fun typeNoRepeatName(typeDecList) = 
		let
			fun addDec({name=name, ty=typ, pos=pos}, curSet)= tempDecSet.add(curSet, (S.name name));
		in
			if tempDecSet.numItems(foldr addDec tempDecSet.empty typeDecList) = List.length(typeDecList) then 
				true
			else 
				false
		end

	fun funNoRepeatName(funDecList) = 
		let
			fun addDec({name=name, params=params, result=result, body=body, pos=pos}, curSet) = tempDecSet.add(curSet, (S.name name))
		in
			if tempDecSet.numItems(foldr addDec tempDecSet.empty funDecList) = List.length(funDecList) then 
				true
			else 
				false
		end

	fun hasDefinedType(originalName: A.symbol, ty: T.ty, pos: A.pos, firstTime: int) = 
	(
		case ty of
			T.NAME(sym, tyOpt) => 
				if (originalName=sym andalso firstTime=0) then 
					(ErrorMsg.error pos ("Cyclic type declaration detected: "^(S.name sym)); false)
				else 
				(
					case !tyOpt of
						SOME(t) => (hasDefinedType (originalName,t,pos,0))
					   | NONE => (ErrorMsg.error pos ("Cannot define the type: "^(S.name sym)); false)
				)
			| _ => true
	)

	fun checkInt ({exp=exp, ty=ty},pos) = 
		assertSubTypes(ty, T.INT, pos, pos)
		
	fun checkUnit ({exp=exp, ty=ty}, pos) =
		assertSubTypes(ty, T.UNIT, pos, pos)
		
	fun checkString ({exp=exp, ty=ty}, pos) =
		assertSubTypes(ty, T.STRING, pos, pos)
		
	fun checkNil ({exp=exp, ty=ty}, pos) =
		assertSubTypes(ty, T.NIL, pos, pos)

	fun transExp(venv,tenv,exp,level) = 
		let
			fun subTransExp (A.VarExp var) = transVar(venv,tenv,var,level)
			| subTransExp (A.NilExp) = {exp=(), ty=T.NIL}
			| subTransExp (A.IntExp i) = {exp=(), ty=T.INT}
			| subTransExp (A.StringExp (str,pos)) = {exp=(), ty=T.STRING}
			| subTransExp (A.CallExp {func=func, args=args, pos=pos}) = 
				(
				case S.look(venv, func) of 
					SOME (E.FunEntry {formals=formals, result=result, level=level, label=label}) => 
						let
							val transArgs = map subTransExp args
							fun checkArgsType ([], [], pos) = true
			  				| checkArgsType (_, [], pos) = false
			  				| checkArgsType ([], _, pos) = false
			  				| checkArgsType (arg1ty::arglst1, arg2ty::arglst2, pos) =
								if assertSubTypes(arg1ty,arg2ty, pos, pos) then
									checkArgsType(arglst1,arglst2, pos)
								else 
									false
						in
							if length(transArgs) <> length(formals) then
		  						(Er.error pos "Incorrect number of arguments in fuction "; {exp=(),ty=actual_ty(result, pos)})
		  					else 
		  					(
		  						(
		  							if checkArgsType (formals, map (#ty) transArgs, pos)  then 
		  								()
			  						else 
			  							(Er.error pos "Function has incorrect parameters")
		  						);
		  						{exp=(),ty=actual_ty(result, pos)}
		  					)
						end
					|  _ => (Er.error pos "No such function exists"; {exp=(),ty=T.ERROR})
				)
			| subTransExp (A.OpExp {left=left, oper=oper, right=right, pos=pos}) = 
				if (oper=A.PlusOp orelse oper=A.MinusOp orelse oper=A.TimesOp orelse oper=A.DivideOp orelse oper=A.LtOp orelse oper=A.LeOp orelse oper=A.GtOp orelse oper=A.GeOp) then
					(if (checkInt(transExp(venv,tenv,left,level),pos)) then
						(if(checkInt(transExp(venv,tenv,right,level),pos)) then
							{exp=(), ty=T.INT}
						else
							((Er.error pos ("Right OPERAND is not of type INT"));{exp=(), ty=T.ERROR}))
					else
						((Er.error pos ("Left OPERAND is not of type INT"));{exp=(), ty=T.ERROR})
					)
				else if (oper=A.EqOp orelse oper=A.NeqOp) then
					let
						val {exp=exp, ty=leftType} = transExp(venv,tenv,left,level)
						val {exp=exp, ty=rightType} = transExp(venv,tenv,right,level)
					in
						if assertSubTypes(leftType,rightType,pos,pos) then
							{exp=(), ty=actual_ty (leftType,pos)}
						else
							(Er.error pos "Type mismatch between left and right expressions of operand"; {exp=(),ty=T.ERROR})
					end
					
				else
					(Er.error pos "Could not discern the operator type"; {exp=(), ty=T.ERROR})
			| subTransExp (A.RecordExp {fields=fields, typ=typ, pos=pos}) = 
				let 
					val T.RECORD(fieldTypes, unique) = 
						(case S.look(tenv,typ) of
							SOME(t) => actual_ty (t,pos)
							| NONE => (Er.error pos ("Undefined field type"); T.RECORD([], ref())))
					fun resolveFieldLists((symbol, exp, pos)::fieldList, (tySymbol,ty)::fieldTypeList) =
						if(S.name symbol = S.name tySymbol) then
							if (assertSubTypes(#ty (transExp(venv,tenv,exp,level)), actual_ty(ty,pos), pos, pos) = true) then
								resolveFieldLists(fieldList,fieldTypeList)
							else
								(Er.error pos ("Field and type are not able to resolve to the same subtypes");false)
						else
							(Er.error pos ("Field and type cannot be resolved to same symbol");false)
					| resolveFieldLists([],[]) = true (*Everything has been resolved from the previous lists*)
					| resolveFieldLists(_,_) = false (*Makes the list of matches exhaustive, hides compiler error*)
				in
					if (resolveFieldLists(fields, fieldTypes)) then
						{exp=(), ty=T.RECORD(fieldTypes, unique)}
					else
						(Er.error pos "Could not resolve the record field list";{exp=(), ty=T.ERROR})
				end
			| subTransExp (A.SeqExp exps) = 
				let
					fun subTransExps ([]) = {exp=(), ty=T.UNIT}
					| subTransExps ([(exp,pos)]) = transExp(venv, tenv, exp,level)
					| subTransExps((exp, pos)::l) = (transExp(venv,tenv,exp,level);subTransExps(l));
				in
					subTransExps exps
				end
			| subTransExp (A.AssignExp {var=var, exp=exp, pos=pos}) = 
				let
					val {exp=expExp, ty=expTy} = transExp (venv,tenv,exp, level)
					val {exp=varExp, ty=varTy} = transVar (venv,tenv,var, level)
				in
					if (assertSubTypes(expTy, varTy, pos, pos)) then
						{exp=(), ty=T.UNIT}
					else
						((Er.error pos ("Cannot assign a value to variable that is not a subtype of the variable type"); {exp=(), ty=T.ERROR}))
				end
			| subTransExp (A.IfExp {test=test, then'=thenexp, else'=elsexp, pos=pos}) = 
				(case elsexp of
					NONE => 
						(let
							val realThenExp = transExp(venv,tenv,thenexp,level)
							val testExp = transExp(venv,tenv,test,level)
						in
							if (checkInt(testExp, pos)) then
								if (checkUnit(realThenExp, pos)) then
									{exp=(), ty=T.UNIT}
								else
									((Er.error pos "THEN expression is not of type UNIT");{exp=(), ty=T.ERROR})
							else
								((Er.error pos "TEST expression is not of type INT");{exp=(), ty=T.ERROR})
						end)
					| SOME e => 
						(let
							val realThenExp = transExp(venv,tenv,thenexp,level)
							val realElseExp = transExp(venv,tenv,e,level)
							val testExp = transExp(venv,tenv,test,level)
						in
							if (checkInt(testExp, pos)) then
								(if (assertSubTypes(#ty realThenExp, #ty realElseExp, pos, pos)) then
									{exp=(), ty=actual_ty(#ty realElseExp, pos)}
								else
									((Er.error pos "Type Mismatch between THEN and ELSE expressions");{exp=(), ty=T.ERROR}))
							else
								((Er.error pos "TEST expression is not of type");{exp=(), ty=T.ERROR})
						end))
			| subTransExp (A.WhileExp {test=test, body=body, pos=pos}) = 
				let
					val _ = loopDepth := !loopDepth + 1
					val testExpTy = transExp(venv,tenv,test,level)
					val bodyExpTy = transExp(venv,tenv,body,level)
					val _ = loopDepth := !loopDepth - 1
					val _ = breakCount := 0
				in
					(if checkInt(testExpTy, pos) then
						(if checkUnit(bodyExpTy, pos) then
							{exp=(), ty=T.UNIT}
						else
							(Er.error pos "WHILE LOOP BODY is not of type UNIT"; { exp=(), ty=T.ERROR}))
					else
						(Er.error pos "WHILE LOOP TEST expression is not of type INT"; { exp=(), ty=T.ERROR}))
				end
			| subTransExp (A.ForExp {var=var, escape=escape, lo=lo, hi=hi, body=body, pos=pos}) = 
				let
					val _ = loopDepth := !loopDepth + 1
					val accessLevel = Tr.allocLocal level (!escape)
					val venv' = S.enter(venv, var, (E.VarEntry ({access=accessLevel, ty=T.INT})))
					val bodyExpTy = transExp(venv', tenv, body,level)
					val loExpTy = transExp(venv', tenv, lo,level)
					val hiExpTy = transExp(venv', tenv, hi,level)
					val _ = loopDepth := !loopDepth - 1
					val _ = breakCount := 0
				in
					(if checkInt(loExpTy, pos) then
						(if checkInt(hiExpTy, pos) then
							(if (checkUnit(bodyExpTy, pos) orelse checkNil(bodyExpTy, pos)) then
								{exp=(), ty=T.UNIT}
							else
								(
								(Er.error pos "FOR LOOP BODY is not of type UNIT"; { exp=(), ty=T.ERROR})))
						else
							(Er.error pos "FOR LOOP HI expression is not of type INT"; { exp=(), ty=T.ERROR}))
					else
						(Er.error pos "FOR LOOP LO expression is not of type INT"; { exp=(), ty=T.ERROR}))
				end
			| subTransExp (A.BreakExp pos) = 
				let
					val _ = breakCount := !breakCount + 1
				in
					if !loopDepth = 0 then
						(Er.error pos "BREAK can occur only inside a loop"; { exp=(), ty=T.ERROR })
					else if !breakCount > 1 then
						(Er.error pos "No more loops to BREAK"; { exp=(), ty=T.ERROR})
					else
						{ exp=(), ty=T.UNIT }
				end
			| subTransExp (A.LetExp {decs=decs, body=body, pos=pos}) =
				let
					fun extractDec (venv,tenv,decs) = 
						(case decs of
							[] => {venv=venv, tenv=tenv}
							| (dec::l) =>
								let
									val {venv=newVenv, tenv=newTenv} = transDec(venv,tenv,dec, level)
								in
									extractDec(newVenv, newTenv, l)
								end)
					val {venv=finalVenv, tenv=finalTenv} = extractDec(venv,tenv,decs)
				in
					transExp(finalVenv, finalTenv, body,level)
				end
			| subTransExp (A.ArrayExp {typ=typ, size=size, init=init, pos=pos}) = 
				let
					val sizeExpTy = transExp(venv,tenv,size,level);
					val initExpTy = transExp(venv,tenv,init,level);
				in
					(case S.look(tenv,typ) of
						SOME (ty) =>
							(case (actual_ty(ty,pos)) of
								T.ARRAY(t,u) =>
									if (checkInt(sizeExpTy,pos)) then
										if (assertSubTypes(t, #ty initExpTy, pos, pos)) then
											{exp=(), ty=T.ARRAY(t,u)}
										else
											(Er.error pos ("Type mismatch between initial expression and base type"); {exp=(), ty=T.ERROR})
									else
										(Er.error pos "SIZE of array must be defined as an INT"; {exp=(), ty=T.ERROR})
								| _ => 
									(Er.error pos ("Cannot define an array as anything other than as an array"); {exp=(), ty=T.ERROR}))
						| NONE =>
							(Er.error pos ("Could not define base type of array"); {exp=(), ty=T.ERROR}))
				end
		in
			subTransExp exp
		end

	and transVar(venv,tenv,var, level) = 
		let
			fun subTransVar (A.SimpleVar(simVar,pos)) =
				(case S.look(venv, simVar) of
					SOME (E.VarEntry({access=_,ty=t})) => {exp=(), ty=actual_ty(t,pos)}
					| SOME(_) => (Er.error pos ("Expected VARIABLE, but instead found a FUNCTION"); {exp=(), ty=T.ERROR})
					| NONE => (Er.error pos ("Undefined variable " ^ S.name(simVar)); {exp=(), ty=T.ERROR}))
			| subTransVar (A.FieldVar (var, symbol, pos)) = 
				let
					val {exp=varExp, ty=varType} = transVar(venv, tenv, var, level);
				in
					(case varType of
						T.RECORD(fields, unique) =>
						(case List.find (fn recTups => (#1 recTups) = symbol) fields of
							NONE => 
								(Er.error pos "Could not find the correct FIELD VAR";{exp=(), ty=T.ERROR})
							| SOME(recTup) => {exp=(), ty=actual_ty(#2 recTup, pos)})
						| _ =>
							(Er.error pos ("Field variable must be of type T.RECORD"); {exp=(), ty=T.ERROR}))
				end
			| subTransVar (A.SubscriptVar (var, exp, pos)) = 
				(let
					val {exp=varExp, ty=varType} = transVar(venv,tenv,var, level);
					val expExpTy = transExp(venv,tenv,exp,level)
				in
					if (checkInt(expExpTy, pos)) then
						(case varType of
							T.ARRAY (baseType, unique) => {exp=(), ty = (actual_ty (baseType, pos))}
							| _ => (Er.error pos ("Variable must be of type T.ARRAY"); {exp=(), ty=T.ERROR}))
					else
						(Er.error pos ("ARRAY subscript must be of type INT");{exp=(), ty=T.ERROR})
				end)
		in
			subTransVar var
		end

	and transDec(venv,tenv,dec,level) = 
		let 
			fun subTransDec (A.FunctionDec funcs) = 
				(let
					fun getReturnType res =
						case (case res of
								SOME (rt,p) => S.look(tenv,rt)
								| NONE => NONE) of
							SOME(t) => t
							| NONE => T.UNIT
					fun processHeader ({name=name, params=params, result=result, body=body, pos=pos}, newVenv)=
						let
							fun transparam{name,escape,typ,pos} =
								case S.look(tenv,typ) of
									SOME t => t
									| NONE => (Er.error pos ("Could not resolve the type of the parameter when processing header"); T.ERROR)
							val params' = map transparam params
							val envParams = map (fn {escape,...} => !escape) params
						in
							S.enter(newVenv, name, E.FunEntry {formals = params', result = getReturnType(result), level=Tr.newLevel{parent=level, name=name, formals=envParams}, label=name})
						end
					fun processBody(venv, []) = ()
					| processBody(venv, {name=name, params=params,result=result, body=body, pos=pos}::func) = 
						let
							fun enterparam({name,escape,typ,pos}, newVenv) =
								let
									val localAccessLevel = Tr.allocLocal level (!escape)
									val ty =
										case S.look(tenv,typ) of
											SOME t => t
											| NONE => (Er.error pos ("Could not resolve the type of the parameter when processing function body");T.ERROR)
								in
									S.enter(newVenv, name, E.VarEntry({access=localAccessLevel, ty=ty}))
								end
							val venv' = foldr enterparam venv params
							val {exp=bodyExp, ty=bodyTy} = transExp(venv', tenv, body,level)
						in
							(
								if assertSubTypes(bodyTy, getReturnType(result), pos, pos) then
								(
									if (assertSubTypes(getReturnType(result), T.UNIT, pos, pos) andalso assertSubTypes(bodyTy, T.UNIT, pos, pos) <> true) then
										(Er.error pos ("Function body should be of type T.UNIT"))
									else
										()
								)
								else
									Er.error pos ("Function body and return do not have same types");
								processBody(venv, func)
							)
						end
					val venv' = foldr processHeader venv funcs;
				in
					(processBody(venv', funcs);
					if funNoRepeatName(funcs) then
						{venv = venv', tenv=tenv}
					else
						(Er.error 0 ("Functions with same name exist in mutually recursive environment");{venv = venv, tenv=tenv}))
				end)
			| subTransDec (A.VarDec {name=name, escape=escape, typ=typ, init=init, pos=pos}) = 
				let 
					val {exp=varExp, ty=varTy} = transExp(venv,tenv,init,level)
					val accessLevel = Tr.allocLocal level (!escape)
				in
					(case varTy of
						T.NIL =>
							( case typ of
								NONE => ((Er.error pos "No initial type to assign VALUE to ");{venv=S.enter(venv,name,E.VarEntry({access=accessLevel, ty=varTy})),tenv=tenv})
								| SOME ((t,p)) => 
									(case S.look(tenv,t) of
										SOME(tyyy) =>
											(case (actual_ty(tyyy,p)) of
												T.RECORD(_,_) => 
													({venv=S.enter(venv,name,E.VarEntry({access=accessLevel, ty=actual_ty(tyyy,p)})),tenv=tenv})
												| _ => 
													((Er.error pos "NIL type of assigned value not constrained by RECORD type ");{venv=S.enter(venv,name,E.VarEntry({access=accessLevel, ty=varTy})),tenv=tenv}))
										| NONE => 
											((Er.error pos "NIL type of assigned value cannot be constrained by undefined variable type");{venv=S.enter(venv,name,E.VarEntry({access=accessLevel, ty=varTy})),tenv=tenv})
											))
						| _ =>
							((case typ of
								NONE=> ({venv=S.enter(venv,name,E.VarEntry({access=accessLevel, ty=varTy})),tenv=tenv})
								| SOME((t,p)) =>
									(case S.look(tenv,t) of
										SOME(tyyy) =>
											if varTy = actual_ty(tyyy,p) 
											then
												({venv=S.enter(venv,name,E.VarEntry({access=accessLevel, ty=tyyy})),tenv=tenv})
											else 
												(
												((Er.error pos ("TYPE mismatch between variable type and intilization value type "));{venv=S.enter(venv,name,E.VarEntry({access=accessLevel, ty=varTy})),tenv=tenv}))
										| NONE =>
											((Er.error pos "Type of variable is undefined");{venv=S.enter(venv,name,E.VarEntry({access=accessLevel, ty=varTy})),tenv=tenv})))))
				end
			| subTransDec (A.TypeDec decs) = 
				let
					fun processTypes(tenv, types) =
						let
							fun addEmptyType ({name=name, ty=ty, pos=pos}, tenv) =
								S.enter(tenv, name, T.NAME(name, ref NONE))

							val tenv' = foldr addEmptyType tenv types

							fun findRealType ({name=name, ty=ty, pos=pos}, tenv') = 
								let
									val realType = transTy(tenv', ty)
								in
									(* Update NONE type to actual type if exists *)
									case S.look(tenv', name) of 
										SOME(T.NAME(sym, tyOpt)) => (let val temp = (tyOpt := SOME(realType)) in tenv' end)
										| _ => (ErrorMsg.error pos "Problem with mutual type recursion."; tenv')
								end

							val tenv'' = foldr findRealType tenv' types

							fun detectTypeCycle([]) = true
							| detectTypeCycle({name=name, ty=ty, pos=pos}::dec) =
									case S.look(tenv'', name) of
										SOME(t) => if hasDefinedType(name, t, pos, 1) then detectTypeCycle(dec) else false
										| NONE =>  (ErrorMsg.error pos "Unable to find defined type"; false)
						in
							if detectTypeCycle(types) then 
								(
									if typeNoRepeatName(types) then 
										{venv = venv, tenv = tenv''}
									else 
										(
										(Er.error 0 "Types with same name exist in mutually recursive enviornment");
										{venv = venv, tenv = tenv})
								) 
							else 
								{venv = venv, tenv = tenv}
						end			
				in
					processTypes(tenv, decs)
				end
		in
			subTransDec dec
		end

	and transTy(tenv,ty) = 
		let
			fun subTransTy (A.NameTy (tySym, pos)) = 
				(case S.look(tenv, tySym) of
					SOME (t) => t
					| NONE => (Er.error pos ("Undefined type "^S.name(tySym)); T.ERROR))
			| subTransTy (A.RecordTy field) =
				let 
					val fieldVals =
						let
							fun extractFieldInfo({name, escape, typ, pos}) =
								(case S.look(tenv, typ) of
									SOME (t) => (name, t)
									| NONE => (Er.error pos("Undefined type "^S.name(name)); (name, T.ERROR)))
						in
							map extractFieldInfo field
						end
				in
					T.RECORD(fieldVals, ref())
				end
			| subTransTy (A.ArrayTy (sym,pos)) =
				(case S.look(tenv,sym) of
					SOME (t) => T.ARRAY(t, ref())
					| NONE => (Er.error pos("Undefined type "^S.name(sym)^";Expecting type T.ARRAY"); T.ERROR))
		in
			subTransTy ty
		end
	
	(* Main function which traverses the AST *)
	fun transProg (expr:A.exp) = 
		let
			val venv = Env.base_venv
			val tenv = Env.base_tenv
			val base = Tr.newLevel({parent=Tr.outermost, name=Tmp.namedlabel("base"),formals=[]})
			val tree = transExp(venv, tenv, expr,base)
		in
			()
	end
end

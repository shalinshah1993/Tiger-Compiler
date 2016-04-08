signature FRAME = 
sig 
	type frame
	val wordSize : int
	datatype register = Reg of string
  	datatype access = InFrame of int
                  | InReg of Temp.temp

	val newFrame : {name: Temp.label,
					formals: bool list} -> frame
	val name : frame -> Temp.label
	val formals : frame -> access list
	val allocLocal : frame -> bool -> access

	val FP : Temp.temp
	val exp : access -> Tree.exp -> Tree.exp

	val RV : Temp.temp
	val zero : Temp.temp
	val SP : Temp.temp
	val RA : Temp.temp
	val procEntryExit1 : frame * Tree.stm -> Tree.stm

	val externalCall: string * Tree.exp list -> Tree.exp

	datatype frag = PROC of {body: Tree.stm, frame: frame}
            | STRING of Temp.label * string
			
	val specialArgs : Temp.temp list
	val calleeSave : Temp.temp list
	val callerSave : Temp.temp list
	val argRegs : Temp.temp list
end

structure MIPSFrame :> FRAME 
= 
struct
	structure Tr = Tree
	structure S = Symbol
	structure Tp = Temp
	structure A = Assem

	val wordSize = 4
	datatype register = Reg of string

	(* List of Registers for MIPS *)
	(* ZERO Register - value cannot be anything but 0 *)
	val zero = Temp.newtemp()

	(* Function Result Registers - Functions return integer results in v0, and 64-bit integer results in v0 and v1 *)
	val v0 = Temp.newtemp()
	val v1 = Temp.newtemp()

	(* Function Args Registers - hold the first four words of integer type arguments. *)
	val a0 = Temp.newtemp()
	val a1 = Temp.newtemp()
	val a2 = Temp.newtemp()
	val a3 = Temp.newtemp()

	(* Temp Registers - You as thy will *)
	val t0 = Temp.newtemp()
	val t1 = Temp.newtemp()
	val t2 = Temp.newtemp()
	val t3 = Temp.newtemp()
	val t4 = Temp.newtemp()
	val t5 = Temp.newtemp()
	val t6 = Temp.newtemp()
	val t7 = Temp.newtemp()
	val t8 = Temp.newtemp()
	val t9 = Temp.newtemp()

	(* Saved Register - Saved across function calls, saved by callee before using *)
	val s0 = Temp.newtemp()
	val s1 = Temp.newtemp()
	val s2 = Temp.newtemp()
	val s3 = Temp.newtemp()
	val s4 = Temp.newtemp()
	val s5 = Temp.newtemp()
	val s6 = Temp.newtemp()
	val s7 = Temp.newtemp()
	val s8 = Temp.newtemp()

	(* Frame-pointer - Points at the beginning of previous stored frame *)
	val FP = Temp.newtemp()   
	(* Stack-pointer - Points at the top of the stack *)
	val SP = Temp.newtemp()   
	(* Return address *)
	val RA = Temp.newtemp()   
	(* Return value *)
	val RV = Temp.newtemp()   

	val specialArgs = [zero,RV,FP,SP,RA]
	val argRegs = [a0,a1,a2,a3]
	val calleeSave = [s0,s1,s2,s3,s4,s5,s6,s7]
	val callerSave = [t0,t1,t2,t3,t4,t5,t6,t7]
	
	(* can store on register or in frame on memory *)
	datatype access = InFrame of int 
					| InReg of Tp.temp

	type frame = {name: Tp.label, formals: access list, offset: int ref}				
	
	datatype frag = PROC of {body: Tr.stm, frame: frame}
					| STRING of Tp.label * string
		
 	fun newFrame({name = name, formals = formals}) = 
 		let
 			val currOffset = ref 0

 			fun allocFormals([]) = []
 			| allocFormals(hasEscaped::others) = 
 				(
 					if hasEscaped then
 						(currOffset := !currOffset - wordSize; InFrame(!currOffset)::allocFormals(others))
 					else
 						InReg(Tp.newtemp())::allocFormals(others)
 				)
 		in
 			{name = name, formals = allocFormals(formals), offset = currOffset}
 		end

 	fun name({name = name, formals = formals, offset = offset}) = name
 	
 	fun formals({name = name, formals = formals, offset = offset}) = formals	

 	fun allocLocal ({name = name, formals = formals, offset = currOffset}) hasEscaped = 
 		(
 			if hasEscaped then
 				(currOffset := !currOffset - wordSize; InFrame(!currOffset))
 			else
 				 InReg(Tp.newtemp())
 		)

 	(* For offset k we need frame pointer while for register we don't *)
	fun exp (InFrame(k)) fp:Tr.exp = Tr.MEM(Tr.BINOP(Tr.PLUS, fp, Tr.CONST(k)))
    | exp (InReg (t)) fp:Tr.exp = Tr.TEMP(t)

    (* Dummy implementation as described by Appel *)
    fun procEntryExit1(frame, body) = body
	
	fun procEntryExit2(frame, body) = 
		body @
			[A.OPER{assem="",
				src=[zero, RA, SP]@calleeSave,
				dst=[],
				jump=SOME[]}]
				
	(* Does this part still have JOUETTE in it? *)
	fun procEntryExit3({name=name, formals=params,offset=locals}:frame, body: Assem.instr list) =
		{prolog="PROCEDURE " ^ Symbol.name name ^ "\n",
		body=body,
		epilog= "ED " ^ Symbol.name name ^ "\n"}

    fun externalCall(funcName, argList) = Tr.CALL(Tr.NAME(Tp.namedlabel(funcName)), argList)
end
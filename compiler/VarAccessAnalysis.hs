module VarAccessAnalysis where

import Data.Generics (Data, Typeable, mkQ, mkT, gmapQ, gmapT, everything, everywhere)
import Language.Fortran.Parser
import Language.Fortran
import Data.Char
import Data.List
import LanguageFortranTools
import qualified Data.Map as DMap

--	The code in this file is used to analyse which variables are read and written and where in a certain
--	program. This information is then used to determine whether or not a variable in a loop can be deemed
--	temporary and therefore governs how variables are treated. 

--	THIS WILL BE CHANGED TO A MAP, RATHER THAN A LIST.
--	Type used to colate data on variable accesses throughout a program.
--						Name of variable 	All reads 	All writes
type VarAccessRecord = (VarName Anno, 	[SrcSpan], 	[SrcSpan])
-- type VarValueRecord = (VarName Anno, [(SrcSpan, Expr Anno)])

type LocalVarAccessAnalysis = [VarAccessRecord]
type LocalVarValueAnalysis = DMap.Map (VarName Anno) [(SrcSpan, Expr Anno)]
--																			Subroutine arguments 	Declared var names
type VarAccessAnalysis = (LocalVarAccessAnalysis,	LocalVarValueAnalysis, [VarName Anno],	 	[VarName Anno])

analyseAllVarAccess:: Program Anno -> VarAccessAnalysis
analyseAllVarAccess prog = (localVarAccesses, localVarValues, arguments, declarations)
						where 
							--	LocalVarAccesses is made up of information on all of the reads and writes throughout
							--	the program being analysed. It is a list of triplets where each triplet contains a 
							--	VarName, a list of read locations of that VarName and a list of write locations of that
							--	VarName
							localVarAccesses = everything (combineVarAccessAnalysis) (mkQ [] (analyseAllVarAccess_fortran declarations [])) prog
							
							--	Arguments to this program block are treated as de facto non temporary variables,
							--	due to the fact that arguments are passed by reference by default in fortran.
							arguments = getArguments prog

							--	The main motivation for the tracking the declarations at the top of a program is for
							--	differentiating function calls from array accesses as Language-Fortran does not do this
							--	automatically it seems. 
							declarations = everything (++) (mkQ [] getDeclaredVarNames) prog

							localVarValues = everything (combineMaps) (mkQ DMap.empty analyseAllVarValues_fortran) prog



--	Since Language-Fortran does not seem to differentate between function calls and array access, it was necessary
--	to find a way to identify a function call. This function acheives that. When an expression is passed in, a top level
--	VarNames is extracted (The possibility for multipe varnames is also dealt with here as the Language-Fortran
--	specifcation allows for this). A check to see whether this VarName was NOT declared at the top of the program is done 
--	and a check to see whether the expr in question contains other expressions is also performed. If both of these checks
--	pass then the expr is a function call. (The second check here comes from the fact that arguments that a function is
--	called with are stored in a list inside the original expr. If there are no arguments to the function, a NullExpr
--	object can be found. For a normal scaler value, there would be absolutely nothing in this internal list, not even a 
--	NullExpr object)
isFunctionCall :: VarAccessAnalysis -> Expr Anno -> Bool
isFunctionCall accessAnalysis expr =  (all (\x -> not (elem x declaredVarNames)) exprVarNames) && subVars /= []
						where 
							subVars = extractContainedVars expr
							exprVarNames = extractVarNames expr
							declaredVarNames = (\(_,_,_,x) -> x) accessAnalysis

isFunctionCall_varNames :: [VarName Anno] -> Expr Anno -> Bool
isFunctionCall_varNames declaredVarNames expr =  (all (\x -> not (elem x declaredVarNames)) exprVarNames) && subVars /= []
						where 
							subVars = extractContainedVars expr
							exprVarNames = extractVarNames expr

isNullExpr :: Expr Anno -> Bool
isNullExpr (NullExpr _ _) = True
isNullExpr _ = False

getArguments :: Program Anno -> [VarName Anno]
getArguments prog = argNames
		where
			argNames = everything (++) (mkQ [] getArgNamesAsVarNames) prog--foldl (++) [] (foldl (++) [] (map (gmapQ (mkQ [] getArguments_list)) prog))

getArguments_list :: Arg Anno -> [VarName Anno]
getArguments_list arg = everything (++) (mkQ [] getArgNamesAsVarNames) arg

getArgNamesAsVarNames :: ArgName Anno -> [VarName Anno]
getArgNamesAsVarNames (ArgName _ str) = [VarName nullAnno str]
getArgNamesAsVarNames _ = []

getDeclaredVarNames :: Decl Anno -> [VarName Anno]
getDeclaredVarNames (Decl _ _ lst _) = foldl (\accum (expr1, _, _) -> accum ++ extractVarNames expr1) [] lst
getDeclaredVarNames decl = []

analyseAllVarValues_fortran :: Fortran Anno -> LocalVarValueAnalysis
analyseAllVarValues_fortran (Assg _ src expr1 expr2) = foldl (\accum item -> appendToMap item (src, expr2) accum) DMap.empty varnames
								where
									varnames = extractVarNames expr1
analyseAllVarValues_fortran _ = DMap.empty


--	Function compiles the lists of read and write accesses for the code in question. The function is recursive and makes use of SYB.
--	There are two cases, either the current piece of code is an assignment to a variable or it is not. If the code is an assignment
--	then there must be additions made to the set of writes for a variable, as well as the set(s) of reads for some variable(s). In
--	the other case, only reads must be added.
--analyseAllVarAccess_fortran :: LocalVarAccessAnalysis -> Fortran Anno -> LocalVarAccessAnalysis
--analyseAllVarAccess_fortran prevAnalysis (Assg _ _ writeExpr readExpr) = aggregateAnalysis
analyseAllVarAccess_fortran :: [VarName Anno] -> LocalVarAccessAnalysis -> Fortran Anno -> LocalVarAccessAnalysis
analyseAllVarAccess_fortran declarations prevAnalysis (Assg _ _ writeExpr readExpr) = aggregateAnalysis
												where
													aggregateAnalysis = combineVarAccessAnalysis prevAnalysis analysisWithWritesReads

													fnCall = isFunctionCall_varNames declarations readExpr
													readExprs = case fnCall of
														True ->	extractContainedVars readExpr
														False -> extractOperands readExpr
													readVarNames = foldl (\accum item -> accum ++ (extractVarNames item)) [] readExprs
													writtenVarNames = foldl (\accum item -> accum ++ (extractVarNames item)) [] (extractOperands writeExpr)
													analysisWithReads = foldl (addVarReadAccess (srcSpan readExpr)) prevAnalysis readVarNames
													analysisWithWritesReads = foldl (addVarWriteAccess (srcSpan readExpr)) analysisWithReads writtenVarNames

--analyseAllVarAccess_fortran prevAnalysis codeSeg =  aggregateAnalysis
analyseAllVarAccess_fortran declarations prevAnalysis codeSeg =  aggregateAnalysis
												where 
													aggregateAnalysis = foldl (combineVarAccessAnalysis) [] (gmapQ (mkQ [] (analyseAllVarAccess_fortran declarations currentAnalysis)) codeSeg)						

													extractedExprs = gmapQ (mkQ (Null nullAnno nullSrcSpan) extractExprs) codeSeg
													--readExprs = foldl (\accum item -> accum ++ extractOperands item) [] extractedExprs
													readExprs = foldl (getAccessedExprs declarations) [] extractedExprs
													readVarNames = foldl (\accum item -> accum ++ extractVarNames item) [] readExprs	
													analysisWithReads = foldl (addVarReadAccess (srcSpan codeSeg)) prevAnalysis readVarNames	
													currentAnalysis = combineVarAccessAnalysis prevAnalysis analysisWithReads	

getValueAtSrcSpan :: VarName Anno -> SrcSpan -> VarAccessAnalysis -> Expr Anno
getValueAtSrcSpan varname target_src (_, analysis, _, _) = valueAtSrc
								where
									values = DMap.findWithDefault [] varname analysis
									valueAtSrc = foldl (\accum (item_src, expr) -> if checkSrcSpanBefore item_src target_src then expr else accum) (NullExpr nullAnno nullSrcSpan) values

getAccessedExprs :: [VarName Anno] -> [Expr Anno] -> Expr Anno -> [Expr Anno]
getAccessedExprs declarations accum item = case fnCall of
											True ->	accum ++ extractContainedVars item
											False -> accum ++ extractOperands item
										where 
											fnCall = isFunctionCall_varNames declarations item

-- 	Recursive function to add a record of a read for a certain VarName
addVarReadAccess :: SrcSpan -> LocalVarAccessAnalysis -> VarName Anno -> LocalVarAccessAnalysis
addVarReadAccess srcspan ((varnameAnalysis, src_reads, src_writes):xs) varname  | varnameAnalysis == varname = [(varname, src_reads ++ [srcspan], src_writes)] ++ xs
																				| otherwise = [(varnameAnalysis, src_reads, src_writes)] ++ (addVarReadAccess srcspan xs varname)
addVarReadAccess srcspan [] varname	= [(varname, [srcspan], [])]

-- 	Recursive function to add a record of a write for a certain VarName
addVarWriteAccess :: SrcSpan -> LocalVarAccessAnalysis -> VarName Anno -> LocalVarAccessAnalysis
addVarWriteAccess srcspan ((varnameAnalysis, src_reads, src_writes):xs) varname  | varnameAnalysis == varname = [(varname, src_reads, src_writes ++ [srcspan])] ++ xs
																				| otherwise = [(varnameAnalysis, src_reads, src_writes)] ++ (addVarWriteAccess srcspan xs varname)
addVarWriteAccess srcspan [] varname	= [(varname, [], [srcspan])]															

--	Helper function used to bring together sets of variable access analysis records.
combineVarAccessAnalysis :: LocalVarAccessAnalysis -> LocalVarAccessAnalysis -> LocalVarAccessAnalysis
combineVarAccessAnalysis a b = foldl (addVarAccessAnalysis) a b 

addVarAccessAnalysis :: LocalVarAccessAnalysis -> (VarName Anno, [SrcSpan], 	[SrcSpan]) -> LocalVarAccessAnalysis
addVarAccessAnalysis ((varnameAnalysis, readsAnalysis, writesAnalysis):xs) (newVarName, newReads, newWrites) 	| varnameAnalysis == newVarName = [(varnameAnalysis, combinedReads, combinedWrites)] ++ xs
																												| otherwise = [(varnameAnalysis, readsAnalysis, writesAnalysis)] ++ (addVarAccessAnalysis xs (newVarName, newReads, newWrites))
																												where
																													combinedReads = listRemoveDuplications (readsAnalysis ++ newReads)
																													combinedWrites = listRemoveDuplications (writesAnalysis ++ newWrites)
addVarAccessAnalysis [] (newVarName, newReads, newWrites) = [(newVarName, newReads, newWrites)]


--	The function is directly called by Transformer.hs when it is attempting to parallelise a certain loop. This function is supplied with a start
--	and end point for a loop (SrcSpan) and the VarAccessAnalysis record for the program. The returned list is all of the VarNames that must be
--	considdered non temporary for that loop. For a variable to be considered non temporary, it must either be an argument to this code block or
--	it must be read after the end of the loop, before any data is written to it. In the second case, this means that a variable is non temporary
--	if the final value left in it by the loop is read and used elsewhere.
getNonTempVars :: SrcSpan -> VarAccessAnalysis -> [VarName Anno]
getNonTempVars codeBlockSpan accessAnalysis = (map (\(x, _, _) -> x) hangingReads) ++ subroutineArguments
						where
							localVarAccesses = (\(x,_, _, _) -> x) accessAnalysis
							subroutineArguments = (\(_,_, x, _) -> x) accessAnalysis
							readsAfterBlock = varAccessAnalysis_readsAfter codeBlockSpan localVarAccesses
							writesReadsAfterBlock = varAccessAnalysis_writesAfter codeBlockSpan readsAfterBlock
							hangingReads = filter (checkHangingReads) writesReadsAfterBlock

varAccessAnalysis_writesAfter :: SrcSpan -> LocalVarAccessAnalysis -> LocalVarAccessAnalysis
varAccessAnalysis_writesAfter codeBlockSpan accessAnalysis = foldl (\accum item -> accum ++ varAccessAnalysis_writesAfter' codeBlockSpan item) [] accessAnalysis

varAccessAnalysis_writesAfter' :: SrcSpan -> VarAccessRecord ->  LocalVarAccessAnalysis
varAccessAnalysis_writesAfter' (start, SrcLoc file_end line_end column_end) (varname, readSpans, writeSpans) = [(varname, readSpans, newWriteSpans)]
										where
											newWriteSpans = filter (\((SrcLoc _ line_write column_write), _) -> line_write >= line_end) writeSpans

varAccessAnalysis_readsAfter :: SrcSpan -> LocalVarAccessAnalysis -> LocalVarAccessAnalysis
varAccessAnalysis_readsAfter codeBlockSpan accessAnalysis = foldl (\accum item -> accum ++ varAccessAnalysis_readsAfter' codeBlockSpan item) [] accessAnalysis

varAccessAnalysis_readsAfter' :: SrcSpan -> VarAccessRecord ->  LocalVarAccessAnalysis
varAccessAnalysis_readsAfter' (start, SrcLoc file_end line_end column_end) (varname, readSpans, writeSpans) = if newReadSpans /= [] then [(varname, newReadSpans, writeSpans)] else []
										where
											newReadSpans = filter (\((SrcLoc _ line_read column_read), _) -> line_read >= line_end) readSpans

checkHangingReads :: VarAccessRecord -> Bool
checkHangingReads (varname, readSpans, writeSpans) = case earliestRead of
														Just r ->	case earliestWrite of
																		Just w -> not (checkSrcSpanBefore_line w r)-- checkSrcSpanBefore_line r w
																		Nothing -> True
														Nothing ->	False
								where 
									earliestRead = getEarliestSrcSpan readSpans
									earliestWrite = getEarliestSrcSpan writeSpans
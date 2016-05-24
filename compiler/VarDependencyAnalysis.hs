module VarDependencyAnalysis where

--	The code in this file is used to perform some simple dependency analysis for a block of code. A call to 'analyseDependencies'
--	will produce a set of direct dependencies between variables. A direct dependency is formed when one variable is used in the 
--	calculation of another variable's assignment. It is possible under this scheme for variables to depend upon themselves and this
--	fact is ued by Transformer.hs when looking to determine whether or not a loop represnets a reduction. This module also contains
--	functions to get indirect dependencies and determine whether or not loops exhibit loop carried dependencies.

import Data.Generics (Data, Typeable, mkQ, mkT, gmapQ, gmapT, everything, everywhere)
import Language.Fortran.Parser
import Language.Fortran
import Data.Char
import Data.List
import qualified Data.Map.Strict as DMap

import LanguageFortranTools
import VarAccessAnalysis

-- 	STRATEGY FOR NEW LOOP CARRIED DEPENDENCY CHECK
-- 	Looking to build up a table of all of the possible combinations of loopVar/loop iterator values. This will only be really useful
--	when constant folding works. For now, we use macros to hardcode the values for loop bounds. With the table, we check for loop 
--	carried dependencies by looking at all accesses of a particular array within a particular loop. Given the set of distinct
--	expressions that define array indices for READs and and the distinct set of expressions that define array indices for WRITES,
--	make sure that no READ WRITE pair can exist at the same time in the table of possible combinations of loop iterator values. 
-- 
--	For example:
-- 		for j in range(0,10,1)
-- 			for k in range(i%2,10,2)
-- 				p(j,k) = p(j,k-1) + 12
-- 
-- 	There cannot exist a situation where (j,k) exists in the table and (j,k-1) exists therefore there is no loop carried dependency
--
--	Building and extending the table will be performed when a new for loop is encountered. This is going to involve adding more
--	arguments to some already rather complex functions and adding functionality to build this table. Further complications occur
--	when loop bounds are defined in terms of outer loop iterators. The table itself will be a map of maps of maps of maps... to
--	the power of the current loop nest depth. For example, the table will be a map of maps of maps for a triple nested loop
--	iterating over i, j and k where each level of the map corresponds to a loop iterator variable. For example, if the value (1,1,4)
-- 	is allowed for (i,j,k) then table[1][1][4] exists and contains an empty map. If the value (1,1,5) is not allowed for (i,j,k) then
--	table[1][1][5] will not exist.

--	Type used to colate dependency data between variables within a particular block of code
--										Variable A 		depends on all these expressions
type VarDependencyAnalysis = DMap.Map (VarName Anno) [Expr Anno]

--	Type used to colate all of the indexes at which variables are accessed in a chosen way (read/write).
--	There are two ArrayAccessExpressions passed around during analysis, one that holds all of the indexs
--	of a variable that are written to, and one that tracks where the variable is read. These data
--	structures are used to determine whether loop carried dependencies exist in a particular loop.
--										Variable A 		is accessed at index
type ArrayAccessExpressions = DMap.Map (VarName Anno) 	[Expr Anno]

--	Type used when determining allowed values for iterator variables. Holds the currently chosen values
--	for previous iterator variables that allow the calculation of inner iterator variables in the case
--	of nested loops whose bounds depends on previous iterator variables.
type ValueTable = DMap.Map String Int

--	Type used to store all possible tuples of iterator values for nested iterator variables.
data LoopIterTable = LoopIterRecord (DMap.Map Int LoopIterTable) 
					| Empty
					deriving (Show)

analyseDependencies :: Fortran Anno -> VarDependencyAnalysis
analyseDependencies codeSeg = foldl (\accum item -> constructDependencies accum item) DMap.empty assignments
						where
							assignments = everything (++) (mkQ [] extractAssigments) codeSeg

extractAssigments :: Fortran Anno -> [Fortran Anno]
extractAssigments codeSeg = case codeSeg of 
								Assg _ _ _ _ -> [codeSeg]
								_	-> []

constructDependencies :: VarDependencyAnalysis -> Fortran Anno -> VarDependencyAnalysis
constructDependencies prevAnalysis (Assg _ _ expr1 expr2) = foldl (\accum item -> addDependencies accum item readOperands) prevAnalysis writtenVarNames
							where
								--	As part of Language-Fortran's assignment type, the first expression represents the 
								--	variable being assigned to and the second expression is the thing being assigned
								writtenOperands = filter (isVar) (extractOperands expr1)
								readOperands = filter (isVar) (extractOperands expr2)

								writtenVarNames = foldl (\accum item -> accum ++ extractVarNames item) [] writtenOperands

constructDependencies prevAnalysis _ = prevAnalysis

--addDependencies :: VarDependencyAnalysis -> VarName Anno -> [VarName Anno] -> VarDependencyAnalysis
--	A dependent depends on a dependee. For example
--		A = B + 12
--	A depends on B. A is the dependee, B is the dependent
addDependencies :: VarDependencyAnalysis -> VarName Anno -> [Expr Anno] -> VarDependencyAnalysis
addDependencies prevAnalysis dependent dependees = foldl (\accum item -> addDependency accum dependent item) prevAnalysis dependees

addDependency :: VarDependencyAnalysis -> VarName Anno -> Expr Anno -> VarDependencyAnalysis
addDependency prevAnalysis dependent dependee = appendToMap dependent dependee prevAnalysis

getDirectDependencies :: VarDependencyAnalysis -> VarName Anno -> [Expr Anno]
getDirectDependencies analysis queryVarname = DMap.findWithDefault [] queryVarname analysis

getIndirectDependencies :: VarDependencyAnalysis -> VarName Anno -> [Expr Anno]
getIndirectDependencies analysis queryVarname = getIndirectDependencies' analysis queryVarname []

getIndirectDependencies' :: VarDependencyAnalysis -> VarName Anno -> [Expr Anno] -> [Expr Anno]
getIndirectDependencies' analysis queryVarname previouslyProcessed = foldl (\accum item -> accum ++ getIndirectDependencies' analysis (head $ extractVarNames item)  newProcessed) newDependencies newDependencies
											where
												newDependencies = listSubtract (getDirectDependencies analysis queryVarname) previouslyProcessed
												newProcessed = newDependencies ++ previouslyProcessed

isDirectlyDependentOn :: VarDependencyAnalysis -> VarName Anno -> Expr Anno -> Bool
isDirectlyDependentOn analysis potDependent potDependee = elem potDependee dependencies
										where
											dependencies = getDirectDependencies analysis potDependent 

isIndirectlyDependentOn' :: VarDependencyAnalysis -> VarName Anno -> Expr Anno -> [Expr Anno] -> Bool
isIndirectlyDependentOn' analysis potDependent potDependee previouslyProcessed 	|	isDirectlyDependentOn analysis potDependent potDependee = True
																				|	otherwise = foldl (||) False $ map (\x -> isIndirectlyDependentOn' analysis (head $ extractVarNames x) potDependee newProcessed) newDependencies
																						where
																							newDependencies = listSubtract (getDirectDependencies analysis potDependent) previouslyProcessed
																							newProcessed = newDependencies ++ previouslyProcessed

isIndirectlyDependentOn :: VarDependencyAnalysis -> VarName Anno -> Expr Anno -> Bool
isIndirectlyDependentOn analysis potDependent potDependee	|	isDirectlyDependentOn analysis potDependent potDependee = True
															|	otherwise = foldl (||) False $ map (\x -> isIndirectlyDependentOn' analysis (head $ extractVarNames x) potDependee []) dependencies

																	where 
																		dependencies = getDirectDependencies analysis potDependent 

loopCarriedDependencyCheck_query :: [VarName Anno] -> Fortran Anno -> [Expr Anno]
loopCarriedDependencyCheck_query loopIterators codeSeg = everything (++) (mkQ [] (loopCarriedDependencyCheck_query' loopIterators dependencyAnalysis)) codeSeg
					where
						dependencyAnalysis = analyseDependencies codeSeg

loopCarriedDependencyCheck_query' :: [VarName Anno] -> VarDependencyAnalysis -> Fortran Anno -> [Expr Anno]
loopCarriedDependencyCheck_query' loopIterators dependencyAnalysis (Assg _ _ expr _) = loopCarriedDependencyCheck loopIterators Empty dependencyAnalysis expr 
loopCarriedDependencyCheck_query' _ _ _ = []

loopCarriedDependencyCheck :: [VarName Anno] -> LoopIterTable -> VarDependencyAnalysis -> Expr Anno -> [Expr Anno]
loopCarriedDependencyCheck loopIterators loopIterTable dependencyAnalysis expr = loopCarriedDependencyProof
								where
									exprLoopIteratorUsage = loopIteratorUsage loopIterators expr
									dependencies = getIndirectDependencies dependencyAnalysis (head $ extractVarNames expr)
									selfDependencies = filter (\item -> listIntersection (extractVarNames item) (extractVarNames expr) /= []) dependencies

									loopCarriedDependencyProof = filter (\item -> exprLoopIteratorUsage /= loopIteratorUsage loopIterators item) selfDependencies

loopCarriedDependencyCheck_beta :: [VarName Anno] -> LoopIterTable -> VarDependencyAnalysis -> Expr Anno -> [Expr Anno]
loopCarriedDependencyCheck_beta loopIterators loopIterTable dependencyAnalysis expr = []
								where
									dependencies = getIndirectDependencies dependencyAnalysis (head $ extractVarNames expr)
					
loopIteratorUsage :: [VarName Anno] -> Expr Anno -> [[Expr Anno]]
loopIteratorUsage loopIterators expr = loopIteratorUsageList
			where
				accessExprs = map (extractOperands) (extractContainedVars expr)
				loopIteratorUsageList = map (\item -> if (varNameUsageCheck item loopIterators) then map (applyGeneratedSrcSpans) item else []) accessExprs

varNameUsageCheck :: [Expr Anno] -> [VarName Anno] -> Bool
varNameUsageCheck exprs varnames =  match
			where
				usedVarnames = foldl (\accum item -> accum ++ extractUsedVarName item) [] exprs
				match = (listIntersection varnames usedVarnames) /= []

extendLoopIterTable :: LoopIterTable -> ValueTable -> [VarName Anno] -> Expr Anno -> Expr Anno -> Expr Anno -> LoopIterTable
extendLoopIterTable oldTable valueTable ([]) startExpr endExpr stepExpr = addRangeToIterTable oldTable range
		where
			range = evaluateRange valueTable startExpr endExpr stepExpr
extendLoopIterTable Empty valueTable _ startExpr endExpr stepExpr = addRangeToIterTable Empty range
		where
			range = evaluateRange valueTable startExpr endExpr stepExpr
extendLoopIterTable oldTable valueTable loopVars startExpr endExpr stepExpr = foldl 
																				--(\accum item -> extendLoopIterTable accum (DMap.insert firstLoopVarStr item DMap.empty) newLoopVars startExpr endExpr stepExpr)
																				(extendLoopIterTableWithValues_foldl valueTable loopVars startExpr endExpr stepExpr)
																				oldTable 
																				allowedValues
		where
			allowedValues = case oldTable of
								LoopIterRecord a -> DMap.keys a
								_ -> []

extendLoopIterTableWithValues_foldl :: ValueTable -> [VarName Anno] -> Expr Anno -> Expr Anno -> Expr Anno -> LoopIterTable -> Int -> LoopIterTable
extendLoopIterTableWithValues_foldl valueTable loopVars startExpr endExpr stepExpr (LoopIterRecord oldRecord) chosenValue = LoopIterRecord (DMap.insert chosenValue newSubTable oldRecord)
		where
			oldSubTable = DMap.findWithDefault Empty chosenValue oldRecord
			newSubTable = extendLoopIterTable oldSubTable (DMap.insert firstLoopVarStr chosenValue valueTable) newLoopVars startExpr endExpr stepExpr
			firstLoopVarStr = varnameStr (head loopVars)
			newLoopVars = tail loopVars

addRangeToIterTable :: LoopIterTable -> [Int] -> LoopIterTable
addRangeToIterTable oldTable range = LoopIterRecord (foldl (\accum key -> DMap.insert key Empty accum) oldRecord range)
		where
			oldRecord = case oldTable of
							Empty -> DMap.empty
							LoopIterRecord a -> a

evaluateRange :: ValueTable -> Expr Anno -> Expr Anno -> Expr Anno -> [Int]
evaluateRange vt startExpr endExpr stepExpr = range
		where
			startInt = evaluateExpr vt startExpr
			endInt = evaluateExpr vt endExpr
			stepInt = evaluateExpr vt stepExpr
			range = case startInt of
						Nothing -> []
						Just start -> case endInt of
										Nothing -> []
										Just end -> case stepInt of
														Nothing -> []
														Just step -> [start,start+step..end]


evaluateExpr :: ValueTable -> Expr Anno -> Maybe(Int)
evaluateExpr vt (Bin _ _ binOp expr1 expr2) = case binOp of
												Plus _ -> maybeBinOp (evaluateExpr vt expr1) (evaluateExpr vt expr2) (+)
												Minus _ -> maybeBinOp (evaluateExpr vt expr1) (evaluateExpr vt expr2) (-)
												Mul _ -> maybeBinOp (evaluateExpr vt expr1) (evaluateExpr vt expr2) (*)
												Div _ -> maybeBinOp (evaluateExpr vt expr1) (evaluateExpr vt expr2) (quot)
												Power _ -> maybeBinOp (evaluateExpr vt expr1) (evaluateExpr vt expr2) (^)
												_ -> Nothing
evaluateExpr vt (Unary _ _ unOp expr) = case unOp of 
												UMinus _ -> maybeNegative (evaluateExpr vt expr)
												Not _ -> Nothing
evaluateExpr vt (Var p src lst) | varString == "mod" = maybeBinOp (evaluateExpr vt expr1) (evaluateExpr vt expr2) (mod)
								| otherwise = DMap.lookup varString vt
			where
				varString = varnameStr $ head $ extractUsedVarName (Var p src lst)
				headExprList = snd (head lst)
				expr1 = head headExprList
				expr2 = head $ tail headExprList
evaluateExpr _ (Con _ _ str) = Just(read str :: Int)
evaluateExpr _ _ = Nothing

maybeBinOp :: Maybe(Int) -> Maybe(Int) -> (Int -> Int -> Int) -> Maybe(Int)
maybeBinOp maybeInt1 maybeInt2 op = case maybeInt1 of
											Nothing -> Nothing
											Just int1 -> case maybeInt2 of
															Nothing -> Nothing
															Just int2 -> Just(op int1 int2)

maybeNegative :: Maybe(Int) -> Maybe(Int)
maybeNegative (Just(int)) = Just(-int)
maybeNegative Nothing = Nothing
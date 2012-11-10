{-# OPTIONS_GHC -XFlexibleInstances #-}
--
-- Matcher2.hs
--
-- Match a pattern expression against another expression;
-- return the matching subexpression.
--
-- Gregory Wright, 15 June 2012
--

module Math.Symbolic.Wheeler.Matcher2 where


import Control.Monad.State
import Data.DList (empty, snoc)
import Data.List
import qualified Data.Map as Map
import Data.Maybe


import Math.Symbolic.Wheeler.Canonicalize
import Math.Symbolic.Wheeler.Common
import Math.Symbolic.Wheeler.Debug
import Math.Symbolic.Wheeler.Expr
import Math.Symbolic.Wheeler.Matchable
import Math.Symbolic.Wheeler.Pattern
import Math.Symbolic.Wheeler.Symbol


-- The MatchInfo record contains the information
-- about where a pattern tree matched the subject
-- tree: where the root of the pattern tree occurs
-- in the subject, the nodes of the subject tree that
-- were matched and the environment (pattern variable
-- substitutions) that were required for the match.
--
data MatchInfo = MatchInfo {
  matchRoot    :: Breadcrumbs',
  matchPaths   :: NodeLocations,
  matchEnviron :: Map.Map PatternVar Binding
  }
  deriving Show               


-- The top level match function returns a list of locations
-- in the subject expression where the pattern expression
-- matches.
--
-- An empty list indicates that there were no matches.
--
-- By convention the pattern expression is the first
-- argument, but match is actually symmetric in its
-- arguments.
--
matches :: Expr -> Expr -> [ MatchInfo ]
matches pat subj = map snd $ filter fst $ map (oneMatch pat) (subExprs subj)


-- hasMatch is a utility function that returns True is the
-- pattern matches, False if not.
--
hasMatch :: Expr -> Expr -> Bool
hasMatch pat subj = (not . null) $ matches pat subj


-- Given an expression, generate a list of subtrees and the breadcrumb
-- trail to the root of each subtree.
--
subExprs :: Expr -> [ (Breadcrumbs', Expr) ]
subExprs ex = subEx empty ex
  where
    subEx :: Breadcrumbs' -> Expr -> [ (Breadcrumbs', Expr) ]
    subEx bc s@(Sum ts)     = (bc, s) : concatMap (\(n, x) -> subEx (snoc bc (Scxt n)) x) (zip [1..] ts)    
    subEx bc p@(Product fs) = (bc, p) : concatMap (\(n, x) -> subEx (snoc bc (Pcxt n)) x) (zip [1..] fs)
    subEx bc e              = (bc, e) : []
    

-- Given a pattern and subject subexpression, test if it matches.
-- The subject expression is assumed to be a subexpression of
-- a given expression, so it comes with a breadcrumb trail.
--
-- An environment containing the matches for pattern variables
-- is also returned.
--
oneMatch :: Expr -> (Breadcrumbs', Expr) -> (Bool, MatchInfo)
oneMatch pat (bc, subj) = let
  (mat, (env, nls)) = runState (oneMatch_ pat subj bc) (Map.empty, [])
  in
   (mat, MatchInfo { matchRoot    = bc, 
                     matchPaths   = nls, 
                     matchEnviron = env})


-- Match a single pattern against a subject expression.  The State
-- monad contains the Environ of pattern variables and the
-- corresponding matched variables.  The return value is a Bool
-- indicating if the pattern expression matched, and a list of
-- the node locations in the subject tree that matched.  If the
-- first element of the return pair is False, the list of node locations
-- is still valid, containing those locations that did match before
-- a failure was detected.
--
oneMatch_ :: Expr             -- pattern
          -> Expr             -- subject
          -> Breadcrumbs'     -- current subject node
          -> State Environ Bool
oneMatch_ (Sum ts) (Sum ts') node                                 = sumMatch     ts ts' node
oneMatch_ (Product fs) (Product fs') node                         = productMatch fs fs' node
oneMatch_ (Symbol (Simple s)) (Symbol (Simple s')) node           = objMatch s s' node
oneMatch_ (Symbol (Tensor t)) (Symbol (Tensor t')) node           = objMatch t t' node
oneMatch_ (Symbol (DiracSpinor d)) (Symbol (DiracSpinor d')) node = objMatch d d' node
oneMatch_ pat subj node                                           = objMatch_ pat subj node


objMatch :: Matchable a => a -> a -> Breadcrumbs' -> State Environ Bool
objMatch x y nl = do
  v <- leafMatch x y
  if v
    then do
      (env, nls) <- get
      put (env, nl : nls)
      return True
    else return False


objMatch_ :: Eq a => a -> a -> Breadcrumbs' -> State Environ Bool
objMatch_ x y nl =
  if x == y
    then do
      (env, nodes) <- get
      put (env, nl : nodes)
      return True
    else return False


-- Match the patterns of a sum against the members of
-- the expression list.  The patterns can match in any order.
-- The NodeLocations will record the that the matches were
-- in a sum context.
--
sumMatch :: [ Expr ]
         -> [ Expr ]
         -> Breadcrumbs'
         -> State Environ Bool
sumMatch [] _ _           = do return True
sumMatch _ [] _           = do return False
sumMatch pats subjs node  = do
  let
    subjs' = zipWith (\x y -> (node `snoc` Scxt x, y)) [1..] subjs
    (vpats, epats) = partition isPattern pats
    pats' = epats ++ vpats
    
  -- The current node matches, as it is a Sum in both
  -- the pattern and subject tree. Record the node.
  (env, nl) <- get
  put (env, node : nl)
  unorderedMatch pats' subjs'


-- A complication of the unordered match is that the
-- explicit elements must be matched first, followed by patterns
-- containing a variable.  This prevents the pattern
-- variable from capturing a term or factor that should
-- match an explicit term or factor.  So the input
-- list of expression is required to be sorted, with
-- explicit patterns ahead of all variable patterns.
--
unorderedMatch :: [ Expr ]
               -> [ (Breadcrumbs', Expr) ]
               -> State Environ Bool
unorderedMatch []       _     = return True
unorderedMatch (p : ps) subjs = do
  let
    um :: Expr
       -> [ (Breadcrumbs', Expr) ]
       -> [ (Breadcrumbs', Expr) ]
       -> State Environ (Bool, [ (Breadcrumbs', Expr) ])
    um _ [] fs = return (False, fs)
    um pat (sbj@(node, s) : ss) fs = do
      mat <- oneMatch_ pat s node
      if mat then return (True, ss ++ fs) else um pat ss (sbj : fs)
  
  (mat, subjs') <- um p subjs []
  if mat then unorderedMatch ps subjs' else return False


-- Match the patterns against the members of the expression list
-- in the way appropriate to a product: in any order for commuting
-- factors, in order for noncommuting factors in the same
-- representation space.
--
productMatch :: [ Expr ]
             -> [ Expr ]
             -> Breadcrumbs'
             -> State Environ Bool
productMatch pats subjs node = do
  let
    -- The subject and pattern factors are firs
    -- sorted by representation space.  This will
    -- allow treating commuting and noncommuting factors
    -- differently

    subjs' = zipWith (\x y -> (node `snoc` Pcxt x, y)) [1..] subjs

    subjectFactorsByRepSpace   = groupFactors' subjs'
    commutingSubjectFactors    = lookup [] subjectFactorsByRepSpace
    noncommutingSubjectFactors = filter (not . null . fst) subjectFactorsByRepSpace
    
    csubjs = if isJust commutingSubjectFactors
             then fromJust commutingSubjectFactors
             else []
                  
    patternFactorsByRepSpace   = groupFactors pats
    commutingPatternFactors    = lookup [] patternFactorsByRepSpace
    noncommutingPatternFactors = filter (not . null . fst) patternFactorsByRepSpace
    
    cpats = if isJust commutingPatternFactors
            then let 
              (vp, ep) = partition isPattern (fromJust commutingPatternFactors)
              in
               ep ++ vp
            else []
  
  -- handle all of the cases of commuting patterns/subjects:
  case (cpats, csubjs) of
    ([], _) -> orderedMatches noncommutingPatternFactors noncommutingSubjectFactors
    (_, []) -> return False
    _       -> do     
      mat <- unorderedMatch cpats csubjs  
      if mat
        then orderedMatches noncommutingPatternFactors noncommutingSubjectFactors
        else return False
  

groupFactors' :: [ (Breadcrumbs', Expr) ]
              -> [ ([ String ], [ (Breadcrumbs', Expr) ]) ]
groupFactors' es =
  let
    es'  = groupExprs' es
    es'' = map (\x -> (repSpaces (snd (head x)), x)) es'
  in
   if isJust (lookup [] es'') then es'' else ([], []) : es''


groupExprs' :: [ (Breadcrumbs', Expr) ] -> [[ (Breadcrumbs', Expr) ]]
groupExprs' [] = []
groupExprs' pp@((_, p) : _) =
    let
        (p', q') = partition (\x -> repSpaces (snd x) == repSpaces p) pp
    in
        p' : groupExprs' q' 


-- Match noncommuting factors.
--
orderedMatches :: [ ([ String ], [ Expr ]) ]
               -> [ ([ String ], [ (Breadcrumbs', Expr) ]) ]
               -> State Environ Bool
orderedMatches []  _          = return True
orderedMatches _   []         = return False
orderedMatches (p : ps) subjs = do
  let
    subj = lookup (fst p) subjs
  if isNothing subj
    then return False
    else do 
      mat <- infixMatch (snd p) (fromJust subj)
      if not mat
        then return False
        else orderedMatches ps subjs

  
-- Test if the patterns are satisfied by contiguous members
-- of the expression list.
--
infixMatch :: [ Expr ]
           -> [ (Breadcrumbs', Expr) ]
           -> State Environ Bool
infixMatch _ [] = return False
infixMatch needle haystack = do
  saved_env <- get
  mat       <- (prefixMatch needle) haystack
  if mat then return True
    else do put saved_env
            infixMatch needle (tail haystack)



-- Test if the patterns are satisfied (in order) by the leading
-- elements of the expression list.
--
prefixMatch :: [ Expr ]
            -> [ (Breadcrumbs', Expr) ]
            -> State Environ Bool  
prefixMatch [] _ = do return True
prefixMatch _ [] = do return False
prefixMatch (p : ps) ((bc, x) : xs) = do
  v  <- prefixMatch ps xs
  v' <- oneMatch_ p x bc
  return (v && v')


partitionSum :: (Expr -> Bool) -> Expr -> (Expr, Expr)
partitionSum p (Sum ts) =
  let
    (t, t') = partition p ts 
  in
   (Sum t, Sum t')
partitionSum _ e = (0, e)


partitionProduct :: (Expr -> Bool) -> Expr -> (Expr, Expr)
partitionProduct p (Product fs) =
  let
    (mfs, nfs) = partition p fs 
  in
   (Product mfs, Product nfs)
partitionProduct _ e = (1, e)